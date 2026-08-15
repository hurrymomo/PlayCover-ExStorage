import SwiftUI

// MARK: - Subviews
enum StorageSidebarSelection: Hashable {
    case allApps
    case local
    case migrations
    case container(UUID)
}

struct StorageSidebarView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var selection: StorageSidebarSelection?
    let onExplicitSelection: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Apps", systemImage: "square.grid.2x2")
                    .tag(StorageSidebarSelection.allApps)
                HStack {
                    Image(systemName: "macbook")
                        .foregroundStyle(localHasError ? .red : .secondary)
                    Text("Local")
                    Spacer(minLength: 0)
                }
                    .contentShape(Rectangle())
                    .tag(StorageSidebarSelection.local)
                    .onDrop(of: ["public.file-url", "public.utf8-plain-text"], isTargeted: nil) { providers in
                        handleDrop(providers, onto: .local)
                    }
            }
            Section("External Drives") {
                ForEach(viewModel.containers) { container in
                    HStack {
                        ZStack {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(containerHasError(container) ? .red : .secondary)
                        }
                        .frame(width: 18, height: 18)
                        Text(container.displayName ?? "External APFS Storage")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(StorageSidebarSelection.container(container.id))
                    .onTapGesture {
                        // The row gesture intercepts List's default selection.
                        // Apply both related state changes in the next run-loop
                        // turn to avoid an AttributeGraph re-entrant update.
                        DispatchQueue.main.async {
                            selection = .container(container.id)
                            onExplicitSelection()
                        }
                    }
                    .onDrop(of: ["public.file-url", "public.utf8-plain-text"], isTargeted: nil) { providers in
                        handleDrop(providers, onto: .container(container.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Storage")
        .toolbar {
            Button {
                viewModel.refreshExternalVolumes()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh external drives")
        }
    }

    private var localHasError: Bool {
        let externalBundleIDs = Set(viewModel.containers.flatMap(\.volumes).map(\.name))
        return viewModel.managedApps.contains { app in
            !externalBundleIDs.contains(app.bundleIdentifier)
                && viewModel.appFailureMessage(bundleID: app.bundleIdentifier) != nil
        }
    }

    private func containerHasError(_ container: ExternalAPFSContainer) -> Bool {
        let bundleIDs = Set(container.volumes.map(\.name))
        return viewModel.managedApps.contains { app in
            bundleIDs.contains(app.bundleIdentifier)
                && viewModel.appFailureMessage(bundleID: app.bundleIdentifier) != nil
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], onto target: MigrationTarget) -> Bool {
        guard !providers.isEmpty else { return false }
        MigrationTrace.event("drop.sidebar.received", details: "providers=\(providers.count) target=\(target)")
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier("public.file-url")
        }
        if !fileProviders.isEmpty {
            Task { @MainActor in
                var urls: [URL] = []
                for provider in fileProviders {
                    if let url = await droppedFileURL(from: provider) { urls.append(url) }
                }
                viewModel.prepareDroppedAppBatch(urls: urls, to: target)
            }
        }
        for provider in providers where
            !provider.hasItemConformingToTypeIdentifier("public.file-url")
                && provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text") {
                provider.loadItem(forTypeIdentifier: "public.utf8-plain-text", options: nil) { item, _ in
                    guard let payload = dragPayloadString(item) else { return }
                    Task { @MainActor in
                        MigrationTrace.event("drop.sidebar.payload", details: "target=\(target) payload=\(payload)")
                        let apps = draggedBundleIDs(from: payload).compactMap { bundleID in
                            viewModel.managedApps.first { $0.bundleIdentifier == bundleID }
                        }
                        viewModel.prepareExistingAppBatch(apps, to: target)
                    }
                }
        }
        return true
    }

}

struct ManagedAppListView: View {
    private enum GridAppItem: Identifiable {
        case installed(ManagedApp)
        case incoming(ManagedApp, queued: Bool)

        var id: String {
            switch self {
            case .installed(let app): "installed:\(app.bundleIdentifier)"
            case .incoming(let app, _): "incoming:\(app.bundleIdentifier)"
            }
        }
    }

    @ObservedObject var viewModel: AppViewModel
    let selection: StorageSidebarSelection
    @Binding var selectedAppBundleID: String?
    @Binding var selectedAppBundleIDs: Set<String>
    @Binding var selectedOtherVolumeID: String?
    @Binding var sidebarSelection: StorageSidebarSelection?

    private var selectedContainer: ExternalAPFSContainer? {
        guard case let .container(id) = selection else { return nil }
        return viewModel.containers.first { $0.id == id }
    }

    private var dropMigrationTarget: MigrationTarget? {
        switch selection {
        case .local: .local
        case .container(let id): .container(id)
        case .allApps, .migrations: nil
        }
    }

    private var visibleApps: [ManagedApp] {
        let installedApps = viewModel.managedApps.filter(viewModel.isInstalledApp)
        switch selection {
        case .allApps: return installedApps
        case .local:
            return installedApps.filter { app in
                !viewModel.containers.flatMap(\.volumes).contains { $0.name == app.bundleIdentifier }
            }
        case .container:
            return installedApps.filter { app in
                let isActiveTarget = viewModel.operation.isRunning
                    && viewModel.activeMigration?.target == selectedContainer.map { .container($0.id) }
                    && viewModel.activeMigration?.bundleIdentifier == app.bundleIdentifier
                let isQueuedTarget = viewModel.queuedMigrations.contains { pending in
                    guard case let .container(targetID) = pending.target else { return false }
                    return targetID == selectedContainer?.id && pending.bundleIdentifier == app.bundleIdentifier
                }
                return !isActiveTarget && !isQueuedTarget
                    && selectedContainer?.volumes.contains { $0.name == app.bundleIdentifier } == true
            }
        case .migrations:
            return []
        }
    }

    private var incomingMigrationApps: [(app: ManagedApp, queued: Bool)] {
        guard let destination = dropMigrationTarget else { return [] }
        var result: [(ManagedApp, Bool)] = []
        if viewModel.operation.isRunning,
           viewModel.activeMigration?.target == destination,
           let bundleID = viewModel.activeMigration?.bundleIdentifier,
           let app = viewModel.managedApps.first(where: { $0.bundleIdentifier == bundleID }) {
            result.append((app, false))
        }
        for pending in viewModel.queuedMigrations {
            guard pending.target == destination,
                  let app = viewModel.managedApps.first(where: { $0.bundleIdentifier == pending.bundleIdentifier }),
                  !result.contains(where: { $0.0.bundleIdentifier == app.bundleIdentifier }) else { continue }
            result.append((app, true))
        }
        for pending in viewModel.preparingMigrations {
            guard pending.target == destination,
                  let app = viewModel.managedApps.first(where: { $0.bundleIdentifier == pending.bundleIdentifier }),
                  !result.contains(where: { $0.0.bundleIdentifier == app.bundleIdentifier }) else { continue }
            result.append((app, false))
        }
        return result
    }

    private var gridAppItems: [GridAppItem] {
        visibleApps.map(GridAppItem.installed)
            + incomingMigrationApps.map { GridAppItem.incoming($0.app, queued: $0.queued) }
    }

    private var otherVolumes: [ExternalVolume] {
        guard let selectedContainer else { return [] }
        let managedBundleIDs = Set(
            viewModel.managedApps
                .filter(viewModel.isInstalledApp)
                .map(\.bundleIdentifier)
        )
        return selectedContainer.volumes.filter { !managedBundleIDs.contains($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !visibleApps.isEmpty || !incomingMigrationApps.isEmpty || !otherVolumes.isEmpty {
                GeometryReader { geometry in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedAppBundleID = nil
                                    selectedAppBundleIDs.removeAll()
                                    selectedOtherVolumeID = nil
                                }
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 112, maximum: 138), spacing: 18)],
                                alignment: .leading,
                                spacing: 18
                            ) {
                                ForEach(gridAppItems) { item in
                                    switch item {
                                    case .installed(let app):
                                        ManagedAppRow(
                                            viewModel: viewModel,
                                            app: app,
                                            selectedAppBundleID: $selectedAppBundleID,
                                            selectedAppBundleIDs: $selectedAppBundleIDs,
                                            selectedOtherVolumeID: $selectedOtherVolumeID
                                        )
                                    case .incoming(let app, let queued):
                                        MigrationAppPlaceholder(
                                            viewModel: viewModel,
                                            app: app,
                                            queued: queued
                                        )
                                    }
                                }
                                ForEach(otherVolumes) { volume in
                                    OtherVolumeRow(
                                        viewModel: viewModel,
                                        container: selectedContainer!,
                                        volume: volume,
                                        isSelected: selectedOtherVolumeID == volume.id
                                    ) {
                                        selectedAppBundleID = nil
                                        selectedAppBundleIDs.removeAll()
                                        selectedOtherVolumeID = volume.id
                                    }
                                }
                            }
                            .padding(20)
                        }
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(emptyTitle).font(.title3.bold())
                    Text(emptyDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDrop(of: ["public.file-url", "public.utf8-plain-text"], isTargeted: nil, perform: handleDrop)
    }

    private var emptyTitle: String { selection == .allApps ? "No Managed Apps" : "No Apps Here" }
    private var emptyDescription: String {
        selection == .allApps
            ? "Drop a PlayCover app here to add it without migrating its data."
            : "No managed app currently belongs to this location."
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        MigrationTrace.event(
            "drop.content.received",
            details: "providers=\(providers.count) target=\(String(describing: dropMigrationTarget))"
        )
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier("public.file-url")
        }
        if !fileProviders.isEmpty {
            Task { @MainActor in
                var urls: [URL] = []
                for provider in fileProviders {
                    if let url = await droppedFileURL(from: provider) { urls.append(url) }
                }
                if let target = dropMigrationTarget {
                    viewModel.prepareDroppedAppBatch(urls: urls, to: target)
                } else {
                    for url in urls { viewModel.handleAppDrop(url: url) }
                    sidebarSelection = .allApps
                }
            }
        }
        for provider in providers where
            !provider.hasItemConformingToTypeIdentifier("public.file-url")
                && provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text") {
                provider.loadItem(forTypeIdentifier: "public.utf8-plain-text", options: nil) { item, _ in
                    guard let text = dragPayloadString(item) else { return }
                    Task { @MainActor in
                        guard let target = dropMigrationTarget else { return }
                        MigrationTrace.event("drop.content.payload", details: "target=\(target) payload=\(text)")
                        let apps = draggedBundleIDs(from: text).compactMap { bundleID in
                            viewModel.managedApps.first { $0.bundleIdentifier == bundleID }
                        }
                        viewModel.prepareExistingAppBatch(apps, to: target)
                    }
                }
        }
        return true
    }
}

struct MigrationAppPlaceholder: View {
    @ObservedObject var viewModel: AppViewModel
    let app: ManagedApp
    let queued: Bool

    private var isActive: Bool {
        viewModel.activeMigration?.bundleIdentifier == app.bundleIdentifier
            && viewModel.operation.isRunning
    }

    private var failed: Bool {
        viewModel.activeMigration?.bundleIdentifier == app.bundleIdentifier
            && viewModel.operation == .failed
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                appIcon
                    .opacity(0.48)
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.28))
                    .frame(width: 64, height: 64)
                if queued {
                    VStack(spacing: 2) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Queued").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.hierarchical)
                } else if isActive, let progress = viewModel.operationProgress {
                    ZStack {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .frame(width: 34, height: 34)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                } else {
                    VStack(spacing: 2) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        if !isActive {
                            Text("Preparing")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            Text(app.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(viewModel.operationMessage)
        .accessibilityLabel("\(app.name), \(queued ? "queued" : (failed ? "migration failed" : progressLabel))")
    }

    @ViewBuilder
    private var appIcon: some View {
        if FileManager.default.fileExists(atPath: app.applicationPath) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.applicationPath))
                .resizable()
                .frame(width: 64, height: 64)
                .cornerRadius(14)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 38))
                .frame(width: 64, height: 64)
        }
    }

    private var progressLabel: String {
        guard let progress = viewModel.operationProgress else { return "Preparing…" }
        return "\(Int((progress * 100).rounded()))%"
    }
}

struct OtherVolumeRow: View {
    @ObservedObject var viewModel: AppViewModel
    let container: ExternalAPFSContainer
    let volume: ExternalVolume
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
            Text(volume.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Delete…", role: .destructive) {
                select()
                viewModel.requestDelete(volume, in: container)
            }
        }
        .help("Unrecognized APFS Volume — read only")
    }
}

struct ManagedAppRow: View {
    @ObservedObject var viewModel: AppViewModel
    let app: ManagedApp
    @Binding var selectedAppBundleID: String?
    @Binding var selectedAppBundleIDs: Set<String>
    @Binding var selectedOtherVolumeID: String?

    private var matchingVolume: ExternalVolume? {
        viewModel.containers.flatMap(\.volumes).first { $0.name == app.bundleIdentifier }
    }

    private var matchingContainer: ExternalAPFSContainer? {
        return viewModel.containers.first { $0.volumes.contains { $0.name == app.bundleIdentifier } }
    }

    private var migrationLocked: Bool {
        viewModel.isMigrationLocked(bundleID: app.bundleIdentifier)
    }

    private var isActiveMigration: Bool {
        viewModel.operation.isRunning && viewModel.activeMigration?.bundleIdentifier == app.bundleIdentifier
    }

    private var isQueuedMigration: Bool {
        viewModel.queuedMigrations.contains { $0.bundleIdentifier == app.bundleIdentifier }
    }

    private var isPreparingMigration: Bool {
        viewModel.preparingMigrations.contains { $0.bundleIdentifier == app.bundleIdentifier }
    }

    private var migrationError: String? {
        viewModel.appFailureMessage(bundleID: app.bundleIdentifier)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if FileManager.default.fileExists(atPath: app.applicationPath) {
                        let icon = NSWorkspace.shared.icon(forFile: app.applicationPath)
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64).cornerRadius(14)
                    } else {
                        Image(systemName: "app.dashed").font(.system(size: 38)).frame(width: 64, height: 64)
                    }
                    if isActiveMigration || isQueuedMigration || isPreparingMigration {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.black.opacity(0.42))
                            .frame(width: 64, height: 64)
                        if isQueuedMigration && !isActiveMigration {
                            Text("Queued")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else if isActiveMigration, let progress = viewModel.operationProgress {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        } else {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                    }
                }
                if migrationError != nil && !migrationLocked {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .offset(x: 5, y: -5)
                }
            }
            HStack(alignment: .top, spacing: 5) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(app.name)
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .opacity(migrationLocked ? 0.72 : 1)
        .background {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                }
                RightClickSelectionDetector(
                    isEnabled: !migrationLocked,
                    onLeftMouseDown: selectApp,
                    onRightClick: {
                        selectedOtherVolumeID = nil
                        selectedAppBundleIDs = [app.bundleIdentifier]
                        selectedAppBundleID = app.bundleIdentifier
                    }
                )
            }
        }
        .contentShape(Rectangle())
        .disabled(migrationLocked)
        .onTapGesture(count: 2) {
            viewModel.selectManagedApp(app)
            viewModel.requestOpenSelectedApp()
        }
        .accessibilityAction(.default) {
            viewModel.selectManagedApp(app)
            viewModel.requestOpenSelectedApp()
        }
        .onDrag {
            let bundleIDs = selectedAppBundleIDs.contains(app.bundleIdentifier)
                ? selectedAppBundleIDs.sorted()
                : [app.bundleIdentifier]
            return NSItemProvider(object: appDragPayload(bundleIDs) as NSString)
        }
        .contextMenu {
            if !migrationLocked {
                Button("Connect & Open") {
                    viewModel.selectManagedApp(app)
                    viewModel.requestOpenSelectedApp()
                }
                Button("Open App Data") {
                    viewModel.openAppData(for: app)
                }
                Button("Show in Finder") {
                    viewModel.showAppInFinder(app)
                }
                Divider()
                Menu("Migrate To") {
                    migrationTargetButton(title: "Local", target: .local)
                    ForEach(viewModel.containers) { container in
                        migrationTargetButton(
                            title: "\(container.displayName ?? "External APFS Storage") · \(container.containerReference)",
                            target: .container(container.id)
                        )
                    }
                }
                Divider()
                Button("Connect") {
                    viewModel.selectManagedApp(app)
                    if let matchingContainer {
                        viewModel.selectContainer(matchingContainer)
                        viewModel.requestReconnectAppData()
                    }
                }
                .disabled(matchingVolume == nil || statusText == "Connected")
                Button("Disconnect") {
                    viewModel.selectManagedApp(app)
                    viewModel.disconnectAppData()
                }
                .disabled(statusText != "Connected")
                Divider()
                if app.persistence == .sessionOnly, matchingVolume == nil {
                    Button("Keep in Library") {
                        viewModel.keepInLibrary(bundleID: app.bundleIdentifier)
                    }
                }
                if matchingVolume == nil {
                    Button("Remove from Library") {
                        selectedAppBundleID = nil
                        selectedAppBundleIDs.remove(app.bundleIdentifier)
                        viewModel.removeFromLibrary(bundleID: app.bundleIdentifier)
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    viewModel.requestDelete(app)
                }
            }
        }
    }

    private var statusText: String {
        guard let volume = matchingVolume else { return "Offline" }
        return connectionState(for: volume, bundleID: app.bundleIdentifier) == .connected ? "Connected" : "Disconnected"
    }
    private var currentTarget: MigrationTarget {
        matchingContainer.map { .container($0.id) } ?? .local
    }

    @ViewBuilder
    private func migrationTargetButton(title: String, target: MigrationTarget) -> some View {
        Button {
            viewModel.requestMigration(of: app, from: currentTarget, to: target)
        } label: {
            Text(target == currentTarget ? "✓  \(title)" : "    \(title)")
        }
        .disabled(target == currentTarget)
    }
    private var isSelected: Bool {
        selectedAppBundleIDs.contains(app.bundleIdentifier)
    }

    private func selectApp() {
        selectedOtherVolumeID = nil
        if NSEvent.modifierFlags.contains(.command) {
            if selectedAppBundleIDs.contains(app.bundleIdentifier) {
                selectedAppBundleIDs.remove(app.bundleIdentifier)
                if selectedAppBundleID == app.bundleIdentifier {
                    selectedAppBundleID = selectedAppBundleIDs.first
                }
            } else {
                selectedAppBundleIDs.insert(app.bundleIdentifier)
                selectedAppBundleID = app.bundleIdentifier
                viewModel.selectManagedApp(app)
            }
        } else {
            selectedAppBundleIDs = [app.bundleIdentifier]
            selectedAppBundleID = app.bundleIdentifier
            viewModel.selectManagedApp(app)
        }
    }

    private var statusDotColor: Color {
        guard matchingVolume != nil else { return StorageStatusColors.local }
        return statusText == "Connected" ? StorageStatusColors.connected : StorageStatusColors.disconnected
    }
}

struct RightClickSelectionDetector: NSViewRepresentable {
    let isEnabled: Bool
    let onLeftMouseDown: () -> Void
    let onRightClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onLeftMouseDown: onLeftMouseDown, onRightClick: onRightClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.observedView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onLeftMouseDown = onLeftMouseDown
        context.coordinator.onRightClick = onRightClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var isEnabled: Bool
        var onLeftMouseDown: () -> Void
        var onRightClick: () -> Void
        weak var observedView: NSView?
        private var monitor: Any?
        private var isReplayingRightClick = false

        init(isEnabled: Bool, onLeftMouseDown: @escaping () -> Void, onRightClick: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onLeftMouseDown = onLeftMouseDown
            self.onRightClick = onRightClick
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let view = observedView,
                      event.window === view.window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                guard isEnabled else { return event }
                if event.type == .leftMouseDown {
                    if event.clickCount == 1 {
                        onLeftMouseDown()
                    }
                    return event
                }
                if isReplayingRightClick {
                    isReplayingRightClick = false
                    return event
                }
                onRightClick()
                // Let SwiftUI commit the selection before it constructs the context menu.
                // Replaying the same event on the next run-loop turn avoids replacing menu
                // items while AppKit is already presenting them.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    isReplayingRightClick = true
                    NSApp.postEvent(event, atStart: true)
                }
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

struct MigrationProgressView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: viewModel.operation.symbol)
                .font(.title)
                .foregroundStyle(statusColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(viewModel.operation.title)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if viewModel.operation == .migrating {
                        Text("\(viewModel.migrationStagesCompleted.count) of \(MigrationStage.allCases.count) steps")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(viewModel.operationMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(viewModel.operationMessage)

                if let progress = viewModel.operationProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else if viewModel.operation.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 82, alignment: .center)
    }

    private var statusColor: Color {
        switch viewModel.operation {
        case .succeeded: .green
        case .failed: .red
        case .idle: .secondary
        default: .accentColor
        }
    }
}

struct DriveStatusView: View {
    @ObservedObject var viewModel: AppViewModel
    let container: ExternalAPFSContainer
    let managedApps: [ManagedApp]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.fill")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 5) {
                Text(container.displayName ?? "External APFS Storage")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 14) {
                    detail("Capacity", container.capacityTotalBytes.map(StorageByteFormatter.string) ?? "Unknown")
                    detail("Available", container.capacityFreeBytes.map(StorageByteFormatter.string) ?? "Unknown")
                    detail("Device", container.containerReference)
                    detail("Connection", container.connectionType ?? "Unknown")
                    detail("UUID", shortUUID)
                    if managedAppCount > 0 {
                        detail("Connected Apps", "\(connectedAppCount)", color: StorageStatusColors.connected)
                        detail("Disconnected Apps", "\(disconnectedAppCount)", color: .secondary)
                    }
                    detail("Errors", "\(errorCount)", color: errorCount > 0 ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 82, alignment: .center)
        .help(container.containerUUID.uuidString)
    }

    private var shortUUID: String {
        String(container.containerUUID.uuidString.prefix(8)).uppercased()
    }

    private var managedAppCount: Int {
        managedMatches.count
    }

    private var connectedAppCount: Int {
        managedMatches.filter {
            connectionState(for: $0.volume, bundleID: $0.app.bundleIdentifier) == .connected
        }.count
    }

    private var disconnectedAppCount: Int { managedAppCount - connectedAppCount }

    private var errorCount: Int {
        managedMatches.filter {
            viewModel.appFailureMessage(bundleID: $0.app.bundleIdentifier) != nil
        }.count
    }

    private var managedMatches: [(app: ManagedApp, volume: ExternalVolume)] {
        managedApps.filter(viewModel.isInstalledApp).compactMap { app in
            container.volumes.first(where: { $0.name == app.bundleIdentifier }).map { (app, $0) }
        }
    }

    private func detail(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

struct AppSelectionStatusView: View {
    @ObservedObject var viewModel: AppViewModel
    let app: ManagedApp

    private var matchingVolume: ExternalVolume? {
        matchingContainer?.volumes.first { $0.name == app.bundleIdentifier }
    }

    private var matchingContainer: ExternalAPFSContainer? {
        if let selectedContainerID = viewModel.selectedContainerID,
           let selectedContainer = viewModel.containers.first(where: { $0.id == selectedContainerID }),
           selectedContainer.volumes.contains(where: { $0.name == app.bundleIdentifier }) {
            return selectedContainer
        }
        return viewModel.containers.first { $0.volumes.contains { $0.name == app.bundleIdentifier } }
    }

    private var locationText: String {
        guard let matchingContainer else { return "Local" }
        return matchingContainer.displayName ?? "External APFS Storage"
    }

    private var deviceText: String {
        matchingContainer?.containerReference ?? "Internal"
    }

    var body: some View {
        HStack(spacing: 14) {
            if FileManager.default.fileExists(atPath: app.applicationPath) {
                let icon = NSWorkspace.shared.icon(forFile: app.applicationPath)
                Image(nsImage: icon).resizable().frame(width: 48, height: 48).cornerRadius(10)
            } else {
                Image(systemName: "app.dashed").font(.title).frame(width: 48)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(app.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(app.bundleIdentifier)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 18) {
                    detail("Status", statusText, color: statusColor, symbol: statusSymbol)
                        .frame(width: 92, alignment: .leading)
                    detail("Data Size", dataSizeText)
                    detail("Device", deviceText)
                        .frame(width: 58, alignment: .leading)
                    locationDetail
                }
            }
            .frame(width: 460, alignment: .leading)
            if let errorMessage = viewModel.appFailureMessage(bundleID: app.bundleIdentifier) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OPERATION ERROR")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(errorMessage)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private var statusText: String {
        guard let volume = matchingVolume else { return "Offline" }
        return connectionState(for: volume, bundleID: app.bundleIdentifier) == .connected ? "Connected" : "Disconnected"
    }
    private var statusSymbol: String { "circle.fill" }
    private var statusColor: Color { matchingVolume == nil ? StorageStatusColors.local : (statusText == "Connected" ? StorageStatusColors.connected : StorageStatusColors.disconnected) }

    private var locationDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("LOCATION")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(locationText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 170, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                .help(locationText)
        }
    }

    private func detail(_ title: String, _ value: String, color: Color = .secondary, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            if let symbol {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .semibold))
                    Text(value)
                        .font(.system(size: 13))
                }
                .foregroundStyle(color)
                .lineLimit(1)
            } else {
                Text(value)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }

    private var dataSizeText: String {
        if let usedBytes = matchingVolume?.usedBytes {
            return StorageByteFormatter.string(usedBytes)
        }
        if let size = viewModel.dataSizeCache[app.bundleIdentifier] {
            return StorageByteFormatter.string(size)
        }
        return viewModel.calculatingDataSizeBundleIDs.contains(app.bundleIdentifier) ? "Calculating…" : "Unknown"
    }
}

struct OtherVolumeStatusView: View {
    let volume: ExternalVolume

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.title).foregroundStyle(.secondary).frame(width: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(volume.name).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 18) {
                    detail("Type", "Other Volume")
                    detail("Used", volume.usedBytes.map(StorageByteFormatter.string) ?? "Unknown")
                    detail("Available", volume.availableBytes.map(StorageByteFormatter.string) ?? "Unknown")
                    detail("Device", volume.bsdDevice ?? "Unknown")
                    if let uuid = volume.volumeUUID {
                        detail("UUID", String(uuid.prefix(8)).uppercased())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct AllAppsStatusView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("All Apps").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 22) {
                    detail("Apps", totalCount, color: .primary)
                    detail("Connected", connectedCount, color: StorageStatusColors.connected)
                    detail("Disconnected", disconnectedCount, color: disconnectedCount > 0 ? StorageStatusColors.disconnected : .secondary)
                    detail("Local", localCount, color: .secondary)
                    detail("Errors", errorCount, color: errorCount > 0 ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private var validApps: [ManagedApp] {
        viewModel.managedApps.filter(viewModel.isInstalledApp)
    }

    private var totalCount: Int { validApps.count }

    private var connectedCount: Int {
        validApps.filter { app in
            guard let volume = matchingVolume(for: app) else { return false }
            return connectionState(for: volume, bundleID: app.bundleIdentifier) == .connected
        }.count
    }

    private var disconnectedCount: Int {
        validApps.filter { app in
            guard let volume = matchingVolume(for: app) else { return false }
            return connectionState(for: volume, bundleID: app.bundleIdentifier) != .connected
        }.count
    }

    private var localCount: Int {
        validApps.filter { matchingVolume(for: $0) == nil }.count
    }

    private var errorCount: Int {
        validApps.filter {
            viewModel.appFailureMessage(bundleID: $0.bundleIdentifier) != nil
        }.count
    }

    private func matchingVolume(for app: ManagedApp) -> ExternalVolume? {
        viewModel.containers.lazy.flatMap(\.volumes).first { $0.name == app.bundleIdentifier }
    }

    private func detail(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

struct LocalAppsStatusView: View {
    @ObservedObject var viewModel: AppViewModel

    private var localApps: [ManagedApp] {
        viewModel.managedApps.filter(viewModel.isInstalledApp).filter { app in
            !viewModel.containers.lazy.flatMap(\.volumes).contains {
                $0.name == app.bundleIdentifier
            }
        }
    }

    private var localCount: Int { localApps.count }

    private var errorCount: Int {
        localApps.filter {
            viewModel.appFailureMessage(bundleID: $0.bundleIdentifier) != nil
        }.count
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "macbook")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("Local").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 18) {
                    detail("Apps", "\(localCount)")
                    detail("Available", availableStorage)
                    detail("Errors", "\(errorCount)", color: errorCount > 0 ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private var availableStorage: String {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let bytes = values.volumeAvailableCapacity else {
            return "Unknown"
        }
        return StorageByteFormatter.string(Int64(bytes))
    }

    private func detail(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

struct MigrationActivityView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var sourceAvailable: Int64?
    @State private var targetAvailable: Int64?
    @State private var sourceAvailableChange: Int64 = 0
    @State private var targetAvailableChange: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Migrating").font(.title2.bold())
                    Text("App data migration activity")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    statistic("Tasks", totalTaskCount, color: .primary)
                    statistic("Completed", completedTaskCount, color: StorageStatusColors.connected)
                    statistic("Failed", failedTaskCount, color: failedTaskCount > 0 ? .red : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                if let migration = viewModel.activeMigration,
                   let app = viewModel.managedApps.first(where: { $0.bundleIdentifier == migration.bundleIdentifier }) {
                    HStack(spacing: 14) {
                        appIcon(for: app)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(app.name).font(.headline)
                                Spacer()
                                Text(statusText).font(.caption.weight(.semibold)).foregroundStyle(statusColor)
                            }
                            migrationRoute(from: migration.source, to: migration.target, showsLiveCapacity: true)
                            Text(viewModel.operationMessage)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let progress = viewModel.operationProgress {
                                HStack(spacing: 10) {
                                    ProgressView(value: progress).progressViewStyle(.linear)
                                    Text("\(Int((progress * 100).rounded()))%")
                                        .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
                                }
                            } else if viewModel.operation.isRunning {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .padding(20)
                }
                ForEach(viewModel.queuedMigrations) { pending in
                    HStack(spacing: 14) {
                        if let queuedApp = viewModel.managedApps.first(where: { $0.bundleIdentifier == pending.bundleIdentifier }) {
                            appIcon(for: queuedApp)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(pending.appName).font(.headline)
                                Spacer()
                                Text("Queued").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            migrationRoute(from: pending.source, to: pending.target)
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
                ForEach(Array(viewModel.migrationHistory.reversed())) { record in
                HStack(spacing: 14) {
                    if let app = viewModel.managedApps.first(where: {
                        $0.bundleIdentifier == record.migration.bundleIdentifier
                    }) {
                        appIcon(for: app)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(record.appName).font(.headline)
                            Spacer()
                            if !record.succeeded {
                                Button("Retry") {
                                    viewModel.retryMigration(record)
                                }
                                .buttonStyle(.borderless)
                                .font(.caption.weight(.semibold))
                            }
                            Text(record.succeeded ? "Completed" : "Failed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(record.succeeded ? StorageStatusColors.connected : .red)
                        }
                        migrationRoute(
                            from: record.migration.source,
                            to: record.migration.target,
                            sourceCapacity: record.succeeded ? record.sourceAvailableBytes : nil,
                            targetCapacity: record.succeeded ? record.targetAvailableBytes : nil,
                            showsSavedCapacity: record.succeeded
                        )
                        Text("Task \(shortTaskID(record.id))  •  \(record.completedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(record.message)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            if viewModel.activeMigration == nil,
               viewModel.queuedMigrations.isEmpty,
               viewModel.migrationHistory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No Active Migrations").font(.title3.bold())
                }
                .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: viewModel.activeMigration?.id) {
            resetLiveCapacity()
            guard viewModel.activeMigration != nil else { return }
            while !Task.isCancelled, viewModel.activeMigration != nil {
                sampleLiveCapacity()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder private func appIcon(for app: ManagedApp, failed: Bool = false) -> some View {
        if FileManager.default.fileExists(atPath: app.applicationPath) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.applicationPath))
                .resizable()
                .saturation(failed ? 0 : 1)
                .colorMultiply(failed ? .red : .white)
                .frame(width: 52, height: 52)
                .cornerRadius(11)
        } else {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "app.dashed")
                .font(.system(size: 32))
                .foregroundStyle(failed ? .red : .secondary)
                .frame(width: 52, height: 52)
        }
    }

    private var statusText: String {
        switch viewModel.operation {
        case .failed: "Failed"
        case .succeeded: "Completed"
        case .migrating, .restoring: "Migrating"
        default: "Preparing"
        }
    }

    private var statusColor: Color {
        switch viewModel.operation {
        case .failed: .red
        case .succeeded: StorageStatusColors.connected
        default: .accentColor
        }
    }

    private var totalTaskCount: Int {
        viewModel.migrationHistory.count
            + (viewModel.activeMigration == nil ? 0 : 1)
            + viewModel.queuedMigrations.count
    }

    private var completedTaskCount: Int {
        viewModel.migrationHistory.filter(\.succeeded).count
    }

    private var failedTaskCount: Int {
        viewModel.migrationHistory.filter { !$0.succeeded }.count
    }

    private func statistic(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func shortTaskID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).uppercased()
    }

    private func migrationRoute(
        from source: MigrationTarget,
        to target: MigrationTarget,
        showsLiveCapacity: Bool = false,
        sourceCapacity: Int64? = nil,
        targetCapacity: Int64? = nil,
        showsSavedCapacity: Bool = false
    ) -> some View {
        // Keep Local visually anchored on the left. For an external-to-local
        // migration the semantic direction is therefore right-to-left.
        let localIsDestination = target == .local && source != .local
        let leftTarget = localIsDestination ? target : source
        let rightTarget = localIsDestination ? source : target
        let leftIsSource = !localIsDestination
        let leftLiveCapacity = leftIsSource ? sourceAvailable : targetAvailable
        let leftLiveChange = leftIsSource ? sourceAvailableChange : targetAvailableChange
        let rightLiveCapacity = leftIsSource ? targetAvailable : sourceAvailable
        let rightLiveChange = leftIsSource ? targetAvailableChange : sourceAvailableChange
        let leftSavedCapacity = leftIsSource ? sourceCapacity : targetCapacity
        let rightSavedCapacity = leftIsSource ? targetCapacity : sourceCapacity

        return ZStack {
            HStack(spacing: 44) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(leftIsSource ? "FROM" : "TO")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        Text(targetName(leftTarget))
                        if showsLiveCapacity {
                            capacityLabel(leftLiveCapacity, change: leftLiveChange)
                        } else if showsSavedCapacity, let leftSavedCapacity {
                            savedCapacityLabel(leftSavedCapacity, increased: leftIsSource)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(leftIsSource ? "TO" : "FROM")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        if showsLiveCapacity {
                            capacityLabel(rightLiveCapacity, change: rightLiveChange)
                        } else if showsSavedCapacity, let rightSavedCapacity {
                            savedCapacityLabel(rightSavedCapacity, increased: !leftIsSource)
                        }
                        Text(targetName(rightTarget))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Image(systemName: localIsDestination ? "arrow.left" : "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func savedCapacityLabel(_ bytes: Int64, increased: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: increased ? "arrow.up.to.line" : "arrow.down.to.line")
            Text(StorageByteFormatter.string(bytes))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(increased ? StorageStatusColors.connected : .red)
    }

    @ViewBuilder
    private func capacityLabel(_ bytes: Int64?, change: Int64) -> some View {
        if let bytes {
            HStack(spacing: 3) {
                if change != 0 {
                    Image(systemName: change > 0 ? "arrow.up.to.line" : "arrow.down.to.line")
                }
                Text(StorageByteFormatter.string(bytes))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(
                change > 0
                    ? StorageStatusColors.connected
                    : (change < 0 ? .red : .secondary)
            )
        } else {
            Text("Available —")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func resetLiveCapacity() {
        sourceAvailable = nil
        targetAvailable = nil
        sourceAvailableChange = 0
        targetAvailableChange = 0
    }

    private func sampleLiveCapacity() {
        guard let migration = viewModel.activeMigration else { return }
        let newSource = availableCapacity(for: migration.source)
        let newTarget = availableCapacity(for: migration.target)
        sourceAvailableChange = capacityChange(from: sourceAvailable, to: newSource)
        targetAvailableChange = capacityChange(from: targetAvailable, to: newTarget)
        sourceAvailable = newSource
        targetAvailable = newTarget
    }

    private func capacityChange(from previous: Int64?, to current: Int64?) -> Int64 {
        guard let previous, let current else { return 0 }
        return current - previous
    }

    private func availableCapacity(for target: MigrationTarget) -> Int64? {
        switch target {
        case .local:
            return capacity(at: URL(fileURLWithPath: NSHomeDirectory()))
        case .container(let id):
            guard let container = viewModel.containers.first(where: { $0.id == id }) else { return nil }
            for volume in container.volumes {
                guard let mountPoint = volume.mountPoint, !mountPoint.isEmpty else { continue }
                if let capacity = capacity(at: URL(fileURLWithPath: mountPoint)) {
                    return capacity
                }
            }
            return container.capacityFreeBytes
        }
    }

    private func capacity(at url: URL) -> Int64? {
        guard let bytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity else { return nil }
        return Int64(bytes)
    }

    private func targetName(_ target: MigrationTarget) -> String {
        switch target {
        case .local: "Local"
        case .container(let id):
            viewModel.containers.first(where: { $0.id == id })?.displayName ?? "External SSD"
        }
    }
}
