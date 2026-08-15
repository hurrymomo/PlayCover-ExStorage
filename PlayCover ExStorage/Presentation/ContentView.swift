import SwiftUI

// MARK: - Main ContentView
struct ContentView: View {
    @StateObject private var viewModel: AppViewModel
    @State private var sidebarSelection: StorageSidebarSelection? = .allApps
    @State private var selectedAppBundleIDs: Set<String> = []
    @State private var selectedOtherVolumeID: String?
    @State private var volumeDeleteConfirmationText = ""

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: AppViewModel())
    }

    @MainActor
    init(viewModel: @autoclosure @escaping () -> AppViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        NavigationSplitView {
            StorageSidebarView(
                viewModel: viewModel,
                selection: $sidebarSelection,
                onExplicitSelection: clearAppSelection
            )
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if sidebarSelection == .migrations {
                    MigrationActivityView(viewModel: viewModel)
                } else {
                    contextStatusBar
                    Divider()
                    ManagedAppListView(
                        viewModel: viewModel,
                        selection: sidebarSelection ?? .allApps,
                        selectedAppBundleID: $viewModel.selectedAppBundleID,
                        selectedAppBundleIDs: $selectedAppBundleIDs,
                        selectedOtherVolumeID: $selectedOtherVolumeID,
                        sidebarSelection: $sidebarSelection
                    )
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .task {
            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                viewModel.refreshExternalVolumes()
            }
        }
        .onChange(of: sidebarSelection) { selection in
            viewModel.selectedAppBundleID = nil
            selectedAppBundleIDs.removeAll()
            selectedOtherVolumeID = nil
            guard let selection,
                  case let .container(id) = selection,
                  let container = viewModel.containers.first(where: { $0.id == id }) else { return }
            viewModel.selectContainer(container)
        }
        .onChange(of: viewModel.requestedSidebarTarget) { target in
            guard let target else { return }
            switch target {
            case .local:
                sidebarSelection = .local
            case .container(let id):
                sidebarSelection = .container(id)
            }
            viewModel.consumeRequestedSidebarTarget()
        }
        .padding(0)
        .frame(minWidth: 900, minHeight: 600)
        .alert(item: $viewModel.activeDialog) { dialog in
            switch dialog {
            case .confirmRestore:
                Alert(
                    title: Text("Restore Local App Data?"),
                    message: Text("This copies and verifies the latest external data locally, switches the app back to local Data, and only then removes the external APFS Volume."),
                    primaryButton: .destructive(Text("Restore")) { viewModel.restore() },
                    secondaryButton: .cancel()
                )
            case let .migrationRolledBackForFullDiskAccess(error):
                Alert(
                    title: Text("Migration Rolled Back"),
                    message: Text("The external volume could not be mounted at the app Data folder. The new volume was removed and the original local Data directory was restored.\n\nThis may be caused by missing Full Disk Access. Enable PlayCover ExStorage in Privacy & Security, then reopen the app and try again.\n\nError: \(error)"),
                    primaryButton: .default(Text("Open Settings & Quit")) {
                        openFullDiskAccessSettingsAndQuit()
                    },
                    secondaryButton: .cancel(Text("Not Now"))
                )
            case let .reconnectFailedForFullDiskAccess(error):
                Alert(
                    title: Text("Reconnect Failed"),
                    message: Text("The external volume could not be mounted at the app Data folder. No local backup was modified, and the external volume remains available.\n\nThis may be caused by missing Full Disk Access. Enable PlayCover ExStorage in Privacy & Security, then reopen the app and try again.\n\nError: \(error)"),
                    primaryButton: .default(Text("Open Settings & Quit")) {
                        openFullDiskAccessSettingsAndQuit()
                    },
                    secondaryButton: .cancel(Text("Not Now"))
                )
            case let .confirmExternalOverwrite(pending):
                Alert(
                    title: Text("Overwrite Existing App Volume?"),
                    message: Text("The target SSD already contains a Volume for \(pending.appName). Overwriting permanently removes that target copy before migration starts. The source copy will remain intact unless the new copy is verified and connected."),
                    primaryButton: .destructive(Text("Overwrite")) {
                        viewModel.startExternalToExternalMigration(pending, overwrite: true)
                    },
                    secondaryButton: .cancel {
                        viewModel.cancelMigrationAwaitingConfirmation()
                    }
                )
            case let .confirmLocalOverwrite(pending):
                Alert(
                    title: Text("Overwrite Local App Data?"),
                    message: Text("The local Data directory for \(pending.appName) is not empty. Overwrite temporarily preserves it for rollback, restores and verifies the external data, then removes the replaced local copy."),
                    primaryButton: .destructive(Text("Overwrite")) {
                        guard case let .container(sourceID) = pending.source,
                              let source = viewModel.containers.first(where: { $0.id == sourceID }) else { return }
                        viewModel.selectContainer(source)
                        viewModel.restore(overwriteLocalData: true)
                    },
                    secondaryButton: .cancel {
                        viewModel.cancelMigrationAwaitingConfirmation()
                    }
                )
            case let .confirmConnectAndOpen(appName, containerID):
                Alert(
                    title: Text("Connect & Open \(appName)?"),
                    message: Text("The App's data Volume is disconnected. Connect it to the local Data path, verify the mount, and then open the App?"),
                    primaryButton: .default(Text("Connect & Open")) {
                        viewModel.confirmConnectAndOpen(containerID: containerID)
                    },
                    secondaryButton: .cancel {
                        viewModel.cancelPendingOpenAfterConnect()
                    }
                )
            case let .confirmMigrationBatch(request):
                Alert(
                    title: Text("Migrate \(request.apps.count) Apps?"),
                    message: Text("Apps will be checked and migrated one at a time. Existing destination data for a matching App will be overwritten. Invalid items are ignored."),
                    primaryButton: .destructive(Text("Overwrite & Migrate")) {
                        viewModel.confirmMigrationBatch(request)
                    },
                    secondaryButton: .cancel()
                )
            case let .message(title, message):
                Alert(title: Text(title), message: Text(message), dismissButton: .default(Text("OK")))
            }
        }
        .alert("Delete Volume?", isPresented: volumeDeletionPresented, presenting: viewModel.volumeDeletionRequest) { request in
            TextField("Type Delete to confirm", text: $volumeDeleteConfirmationText)
            Button("Delete", role: .destructive) {
                selectedOtherVolumeID = nil
                viewModel.selectedAppBundleID = nil
                selectedAppBundleIDs.removeAll()
                viewModel.volumeDeletionRequest = nil
                volumeDeleteConfirmationText = ""
                viewModel.deleteConfirmedVolume(
                    device: request.device,
                    uuid: request.volumeUUID,
                    containerReference: request.containerReference,
                    name: request.name
                )
            }
            .disabled(volumeDeleteConfirmationText != "Delete")
            Button("Cancel", role: .cancel) {
                viewModel.volumeDeletionRequest = nil
                volumeDeleteConfirmationText = ""
            }
        } message: { request in
            Text("This permanently deletes the APFS Volume “\(request.name)” and all data stored in it. Type Delete exactly to continue. This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete Local App?",
            isPresented: localAppDeletionPresented,
            titleVisibility: .visible
        ) {
            Button("Delete App", role: .destructive) {
                guard let request = viewModel.localAppDeletionRequest else { return }
                selectedAppBundleIDs.remove(request.app.bundleIdentifier)
                viewModel.localAppDeletionRequest = nil
                viewModel.deleteLocalApp(request.app, includingData: false)
            }
            Button("Delete App & Data", role: .destructive) {
                guard let request = viewModel.localAppDeletionRequest else { return }
                selectedAppBundleIDs.remove(request.app.bundleIdentifier)
                viewModel.localAppDeletionRequest = nil
                viewModel.deleteLocalApp(request.app, includingData: true)
            }
            Button("Cancel", role: .cancel) {
                viewModel.localAppDeletionRequest = nil
            }
        } message: {
            if let request = viewModel.localAppDeletionRequest {
                Text("Delete App removes “\(request.app.name)” but keeps its local Container data. Delete App & Data permanently removes both the App and ~/Library/Containers/\(request.app.bundleIdentifier).")
            }
        }
        .confirmationDialog(
            "Delete External App?",
            isPresented: externalAppDeletionPresented,
            titleVisibility: .visible
        ) {
            Button("Delete App", role: .destructive) {
                guard let request = viewModel.externalAppDeletionRequest else { return }
                selectedAppBundleIDs.remove(request.app.bundleIdentifier)
                viewModel.externalAppDeletionRequest = nil
                viewModel.deleteExternalApp(request, includingVolume: false)
            }
            Button("Delete App & Volume", role: .destructive) {
                guard let request = viewModel.externalAppDeletionRequest else { return }
                selectedAppBundleIDs.remove(request.app.bundleIdentifier)
                selectedOtherVolumeID = nil
                viewModel.externalAppDeletionRequest = nil
                viewModel.deleteExternalApp(request, includingVolume: true)
            }
            Button("Cancel", role: .cancel) {
                viewModel.externalAppDeletionRequest = nil
            }
        } message: {
            if let request = viewModel.externalAppDeletionRequest {
                Text("Delete App removes the local “\(request.app.name).app” but keeps the external Volume and its data. Delete App & Volume permanently removes both the App and the APFS Volume “\(request.volumeName)”.")
            }
        }
        .alert("Existing App Volume Found", isPresented: migrationReconnectAlertPresented) {
            Button("Reconnect") {
                if let choice = viewModel.migrationReconnectChoice {
                    viewModel.reconnectFromMigrationChoice(choice)
                }
            }
            Button("Replace & Migrate", role: .destructive) {
                if let choice = viewModel.migrationReconnectChoice {
                    viewModel.startMigration(replacing: choice)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let choice = viewModel.migrationReconnectChoice {
                Text("A disconnected volume named \(choice.volumeName) already exists on \(choice.diskName). Reconnect it, or replace it by deleting the existing volume and starting a new migration.")
            }
        }
        .alert("Local Data Found", isPresented: connectionConflictPresented) {
            Button("Remove & Connect", role: .destructive) {
                resolveConnectionConflict(using: .remove)
            }
            Button("Hide & Connect") {
                resolveConnectionConflict(using: .hide)
            }
            Button("Cancel", role: .cancel) {
                viewModel.connectionConflict = nil
                viewModel.cancelPendingOpenAfterConnect()
            }
        } message: {
            Text("This App has non-empty local Data. Remove & Connect permanently deletes that local copy. Hide & Connect keeps it underneath the mounted external Volume, where it remains hidden and continues using disk space.")
        }
    }

    private var selectedContainer: ExternalAPFSContainer? {
        guard let sidebarSelection,
              case let .container(id) = sidebarSelection else { return nil }
        return viewModel.containers.first(where: { $0.id == id })
    }

    private var selectedApp: ManagedApp? {
        viewModel.selectedApp
    }

    private var selectedOtherVolume: ExternalVolume? {
        guard let selectedOtherVolumeID, let selectedContainer else { return nil }
        return selectedContainer.volumes.first { $0.id == selectedOtherVolumeID }
    }

    private func clearAppSelection() {
        viewModel.selectedAppBundleID = nil
        selectedAppBundleIDs.removeAll()
        selectedOtherVolumeID = nil
    }

    @ViewBuilder
    private var contextStatusBar: some View {
        if let selectedApp {
            AppSelectionStatusView(viewModel: viewModel, app: selectedApp)
        } else if let selectedOtherVolume {
            OtherVolumeStatusView(volume: selectedOtherVolume)
        } else if let selectedContainer {
            DriveStatusView(
                viewModel: viewModel,
                container: selectedContainer,
                managedApps: viewModel.managedApps
            )
        } else if sidebarSelection == .allApps {
            AllAppsStatusView(viewModel: viewModel)
        } else if sidebarSelection == .local {
            LocalAppsStatusView(viewModel: viewModel)
        } else {
            MigrationProgressView(viewModel: viewModel)
        }
    }

    private var migrationReconnectAlertPresented: Binding<Bool> {
        Binding(
            get: { viewModel.migrationReconnectChoice != nil },
            set: { presented in
                if !presented {
                    viewModel.migrationReconnectChoice = nil
                }
            }
        )
    }

    private var localAppDeletionPresented: Binding<Bool> {
        Binding(
            get: { viewModel.localAppDeletionRequest != nil },
            set: { presented in
                if !presented { viewModel.localAppDeletionRequest = nil }
            }
        )
    }

    private var externalAppDeletionPresented: Binding<Bool> {
        Binding(
            get: { viewModel.externalAppDeletionRequest != nil },
            set: { presented in
                if !presented { viewModel.externalAppDeletionRequest = nil }
            }
        )
    }

    private var volumeDeletionPresented: Binding<Bool> {
        Binding(
            get: { viewModel.volumeDeletionRequest != nil },
            set: { presented in
                if !presented {
                    viewModel.volumeDeletionRequest = nil
                    volumeDeleteConfirmationText = ""
                }
            }
        )
    }

    private var connectionConflictPresented: Binding<Bool> {
        Binding(
            get: { viewModel.connectionConflict != nil },
            set: { if !$0 { viewModel.connectionConflict = nil } }
        )
    }

    private func resolveConnectionConflict(using policy: LocalDataConnectionPolicy) {
        guard let conflict = viewModel.connectionConflict,
              let app = viewModel.managedApps.first(where: {
                  $0.bundleIdentifier == conflict.bundleIdentifier
              }) else { return }
        viewModel.connectionConflict = nil
        viewModel.selectManagedApp(app)
        viewModel.reconnectAppData(localDataPolicy: policy)
    }

    private func migrationConfirmationMessage(_ pending: PendingMigration) -> String {
        let source = migrationTargetName(pending.source)
        let target = migrationTargetName(pending.target)
        if case (.container, .container) = (pending.source, pending.target) {
            return "Move app data from \(source) to \(target)? Direct drive-to-drive migration is not implemented yet; confirming will not change any data."
        }
        return "Move app data from \(source) to \(target)? Verify that the app is closed and do not disconnect the drive during migration."
    }

    private func migrationTargetName(_ target: MigrationTarget) -> String {
        switch target {
        case .local:
            return "Local"
        case .container(let id):
            return viewModel.containers.first(where: { $0.id == id })?.displayName
                ?? "External APFS Storage"
        }
    }

    private func openFullDiskAccessSettingsAndQuit() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
