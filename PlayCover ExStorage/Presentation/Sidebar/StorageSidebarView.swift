import SwiftUI

// MARK: - Subviews
struct StorageSidebarView: View {
    @EnvironmentObject private var updateController: UpdateController
    @EnvironmentObject private var model: AppModel
    @ObservedObject var viewModel: AppViewModel
    let storageService: any StorageServicing
    let onPrepareDroppedAppBatch: ([URL], MigrationTarget) -> Void
    let onPrepareExistingAppBatch: ([AppSnapshot], MigrationTarget) -> Void
    @State private var isSidebarCollapsed = false

    private var selection: Binding<StorageSidebarSelection?> {
        Binding(
            get: { viewModel.sidebarSelection },
            set: { newSelection in
                DispatchQueue.main.async {
                    viewModel.selectSidebar(newSelection)
                }
            }
        )
    }

    private var displayedContainers: [ExternalAPFSContainer] {
        ViewUtilities.sortedContainers(model.allContainers())
    }

    var body: some View {
        List(selection: selection) {
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
                ForEach(displayedContainers) { container in
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
                            viewModel.selectSidebar(.container(container.id))
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
        .background {
            SidebarCollapsedStateReader(isCollapsed: $isSidebarCollapsed)
        }
        .toolbar {
            sidebarToolbar
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                toggleSidebar()
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            .help("Show or hide the sidebar")
        }

        ToolbarItem {
            HStack(spacing: -2) {
                Button {
                    refreshExternalStorage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh external drives")

                Button {
                    updateController.checkForUpdates(.interactive)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .blue)
                }
                .opacity(shouldShowUpdateButton ? 1 : 0)
                .disabled(!shouldShowUpdateButton || !updateController.canCheckForUpdates)
                .accessibilityHidden(!shouldShowUpdateButton)
                .help(updateController.availableVersion.map { "Update to version \($0)" } ?? "Update available")
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: isSidebarCollapsed ? 0 : nil)
            .clipped()
            .offset(x: -7)
            .opacity(isSidebarCollapsed ? 0 : 1)
            .allowsHitTesting(!isSidebarCollapsed)
            .accessibilityHidden(isSidebarCollapsed)
        }
    }

    private func toggleSidebar() {
        let isExpanding = isSidebarCollapsed
        if !isExpanding {
            isSidebarCollapsed = true
        }
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            with: nil
        )
        if isExpanding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isSidebarCollapsed = false
            }
        }
    }

    private func refreshExternalStorage() {
        Task {
            let snapshot = await storageService.scanSnapshot()
            model.replaceStorage(with: snapshot)
        }
    }

    private struct SidebarCollapsedStateReader: NSViewRepresentable {
        @Binding var isCollapsed: Bool

        func makeNSView(context: Context) -> TrackingView {
            TrackingView()
        }

        func updateNSView(_ nsView: TrackingView, context: Context) {
            nsView.onChange = { collapsed in
                DispatchQueue.main.async {
                    isCollapsed = collapsed
                }
            }
            nsView.connect()
        }

        final class TrackingView: NSView {
            var onChange: ((Bool) -> Void)?
            private var observation: NSKeyValueObservation?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                DispatchQueue.main.async { [weak self] in self?.connect() }
            }

            func connect() {
                var responder: NSResponder? = self
                while let next = responder?.nextResponder {
                    if let controller = next as? NSSplitViewController,
                       let sidebarItem = controller.splitViewItems.first {
                        guard observation == nil else { return }
                        observation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
                            self?.onChange?(item.isCollapsed)
                        }
                        return
                    }
                    responder = next
                }
            }
        }
    }

    private var shouldShowUpdateButton: Bool {
        updateController.isUpdateAvailable
    }

    private var localHasError: Bool {
        return model.apps.contains { app in
            model.managedDataContainer(for: app.bundleIdentifier) == nil
                && model.appFailureMessage(for: app.bundleIdentifier) != nil
        }
    }

    private func containerHasError(_ container: ExternalAPFSContainer) -> Bool {
        return model.apps.contains { app in
            model.managedDataContainer(for: app.bundleIdentifier)?.id == container.id
                && model.appFailureMessage(for: app.bundleIdentifier) != nil
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
                onPrepareDroppedAppBatch(urls, target)
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
                            model.apps.first { $0.bundleIdentifier == bundleID }
                        }
                        onPrepareExistingAppBatch(apps, target)
                    }
                }
        }
        return true
    }

}
