import SwiftUI

struct ManagedAppListView: View {
    private enum GridAppItem: Identifiable {
        case installed(AppSnapshot)
        case migration(AppSnapshot, queued: Bool)

        var id: String {
            switch self {
            case .installed(let app): "installed:\(app.bundleIdentifier)"
            case .migration(let app, _): "migration:\(app.bundleIdentifier)"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject var viewModel: AppViewModel
    let migrationStatus: MigrationStatus
    let actions: ManagedAppActions
    @State private var selectedAppBundleIDs: Set<String> = []

    private var selection: StorageSidebarSelection {
        viewModel.sidebarSelection ?? .allApps
    }

    private var selectedAppBundleID: String? { viewModel.selectedAppBundleID }
    private var selectedOtherVolumeID: String? { viewModel.selectedOtherVolumeID }

    private var selectedAppBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedAppBundleID },
            set: { viewModel.selectApp(identifiedBy: $0) }
        )
    }

    private var selectedOtherVolumeBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedOtherVolumeID },
            set: { viewModel.selectOtherVolume(identifiedBy: $0) }
        )
    }

    private var selectedContainer: ExternalAPFSContainer? {
        guard case let .container(id) = selection else { return nil }
        return model.allContainers().first { $0.id == id }
    }

    private var dropMigrationTarget: MigrationTarget? {
        switch selection {
        case .local: .local
        case .container(let id): .container(id)
        case .allApps: nil
        }
    }

    private var appsAtLocation: [AppSnapshot] {
        let installedApps = model.apps.filter(actions.isInstalledApp)
        let appsAtLocation: [AppSnapshot]
        switch selection {
        case .allApps:
            appsAtLocation = installedApps
        case .local:
            appsAtLocation = installedApps.filter { app in
                model.managedDataContainer(for: app.bundleIdentifier) == nil
            }
        case .container:
            appsAtLocation = installedApps.filter { app in
                model.managedDataContainer(for: app.bundleIdentifier)?.id == selectedContainer?.id
            }
        }
        return appsAtLocation
    }

    private var scheduledMigrations: [(app: AppSnapshot, queued: Bool)] {
        var result: [(AppSnapshot, Bool)] = []
        if let active = migrationStatus.snapshot.active,
           let app = model.apps.first(where: { $0.bundleIdentifier == active.bundleIdentifier }) {
            result.append((app, false))
        }
        for pending in migrationStatus.snapshot.queued {
            guard let app = model.apps.first(where: { $0.bundleIdentifier == pending.bundleIdentifier }),
                  !result.contains(where: { $0.0.bundleIdentifier == app.bundleIdentifier }) else { continue }
            result.append((app, true))
        }
        return result
    }

    /// A migration is represented by the same inert card at both its source
    /// and destination. All Apps shows that card once.
    private var migrationApps: [(app: AppSnapshot, queued: Bool)] {
        scheduledMigrations.filter { migration in
            guard let request = request(for: migration.app.bundleIdentifier) else { return false }
            return migrationAppearsHere(request)
        }
    }

    private var gridAppItems: [GridAppItem] {
        let migrationByBundleID = Dictionary(
            uniqueKeysWithValues: scheduledMigrations.map { ($0.app.bundleIdentifier, $0) }
        )
        var representedBundleIDs: Set<String> = []
        var items = appsAtLocation.map { app -> GridAppItem in
            representedBundleIDs.insert(app.bundleIdentifier)
            if let migration = migrationByBundleID[app.bundleIdentifier] {
                // Replace the App in place so beginning a migration does not
                // make its card jump to the end of the grid.
                return .migration(app, queued: migration.queued)
            }
            return .installed(app)
        }
        items += migrationApps.compactMap { migration in
            guard !representedBundleIDs.contains(migration.app.bundleIdentifier) else { return nil }
            return .migration(migration.app, queued: migration.queued)
        }
        return items
    }

    private func migrationAppearsHere(_ migration: PendingMigration) -> Bool {
        switch selection {
        case .allApps:
            return true
        case .local:
            return migration.source == .local || migration.target == .local
        case .container(let id):
            let location = MigrationTarget.container(id)
            return migration.source == location || migration.target == location
        }
    }

    private func request(for bundleIdentifier: String) -> PendingMigration? {
        if migrationStatus.snapshot.active?.bundleIdentifier == bundleIdentifier {
            return migrationStatus.snapshot.active
        }
        return migrationStatus.snapshot.queued.first { $0.bundleIdentifier == bundleIdentifier }
    }

    private var otherVolumes: [ExternalVolume] {
        guard let selectedContainer else { return [] }
        let managedBundleIDs = Set(
            model.apps
                .filter(actions.isInstalledApp)
                .map(\.bundleIdentifier)
        )
        return selectedContainer.volumes.filter {
            !managedBundleIDs.contains($0.name)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !appsAtLocation.isEmpty || !migrationApps.isEmpty || !otherVolumes.isEmpty {
                GeometryReader { geometry in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.clearDetailSelection()
                                    selectedAppBundleIDs.removeAll()
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
                                            actions: actions,
                                            app: app,
                                            selectedAppBundleID: selectedAppBinding,
                                            selectedAppBundleIDs: $selectedAppBundleIDs,
                                            selectedOtherVolumeID: selectedOtherVolumeBinding
                                        )
                                    case .migration(let app, let queued):
                                        MigrationAppPlaceholder(
                                            status: migrationStatus,
                                            actions: actions,
                                            app: app,
                                            queued: queued
                                        )
                                    }
                                }
                                ForEach(otherVolumes) { volume in
                                    OtherVolumeRow(
                                        actions: actions,
                                        container: selectedContainer!,
                                        volume: volume,
                                        isSelected: selectedOtherVolumeID == volume.id
                                    ) {
                                        viewModel.selectApp(identifiedBy: nil)
                                        selectedAppBundleIDs.removeAll()
                                        viewModel.selectOtherVolume(identifiedBy: volume.id)
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
        .task(id: model.storageRevision) {
            guard model.storageRevision > 0 else { return }
            actions.synchronizeManagedAppsWithStorage()
        }
        .onChange(of: selection) { _ in
            DispatchQueue.main.async {
                viewModel.clearDetailSelection()
                selectedAppBundleIDs.removeAll()
            }
        }
        .onChange(of: Set(model.apps.map(\.bundleIdentifier))) { availableBundleIDs in
            selectedAppBundleIDs.formIntersection(availableBundleIDs)
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
                    actions.prepareDroppedAppBatch(urls: urls, to: target)
                } else {
                    for url in urls { actions.handleAppDrop(url: url) }
                    viewModel.selectSidebar(.allApps)
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
                            model.apps.first { $0.bundleIdentifier == bundleID }
                        }
                        actions.prepareExistingAppBatch(apps, to: target)
                    }
                }
        }
        return true
    }
}
