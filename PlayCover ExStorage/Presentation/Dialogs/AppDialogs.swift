import AppKit
import SwiftUI

struct AppDialogsModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var actions: ManagedAppActions
    @State private var volumeDeleteConfirmationText = ""

    func body(content: Content) -> some View {
        content
            .alert(item: activeDialog) { dialog in
                switch dialog {
                case .confirmRestore:
                    Alert(
                        title: Text("Restore Local App Data?"),
                        message: Text("This copies and verifies the latest external data locally, switches the app back to local Data, and only then removes the external APFS Volume."),
                        primaryButton: .destructive(Text("Restore")) { actions.restore() },
                        secondaryButton: .cancel()
                    )
                case let .localDataMountFailed(error):
                    Alert(
                        title: Text("App Data Mount Failed"),
                        message: Text("The external volume could not be mounted at the app's local Data folder. The current operation was stopped safely.\n\nThis may be caused by missing Full Disk Access. Enable PlayCover ExStorage in Privacy & Security, then reopen the app and try again.\n\nError: \(error)"),
                        primaryButton: .default(Text("Open Settings & Quit")) { openFullDiskAccessSettingsAndQuit() },
                        secondaryButton: .cancel(Text("Not Now"))
                    )
                case let .confirmMigrationOverwrite(pending, appToAdd):
                    Alert(
                        title: Text("Overwrite Existing App Data?"),
                        message: Text("The destination already contains data for \(pending.appName). Overwriting will replace that destination data after the migration starts."),
                        primaryButton: .destructive(Text("Overwrite")) {
                            actions.confirmMigrationOverwrite(pending, appToAdd: appToAdd)
                        },
                        secondaryButton: .cancel()
                    )
                case let .confirmMigrationBatch(request):
                    Alert(
                        title: Text("Migrate \(request.apps.count) Apps?"),
                        message: Text(migrationBatchConfirmationMessage(request)),
                        primaryButton: .destructive(Text("Overwrite & Migrate")) { actions.confirmMigrationBatch(request) },
                        secondaryButton: .cancel()
                    )
                case let .message(title, message):
                    Alert(title: Text(title), message: Text(message), dismissButton: .default(Text("OK")))
                }
            }
            .alert("Delete Volume?", isPresented: volumeDeletionPresented, presenting: viewModel.volumeDeletionRequest) { request in
                TextField("Type Delete to confirm", text: $volumeDeleteConfirmationText)
                Button("Delete", role: .destructive) {
                    viewModel.clearDetailSelection()
                    viewModel.setVolumeDeletionRequest(nil)
                    volumeDeleteConfirmationText = ""
                    actions.deleteConfirmedVolume(device: request.device, uuid: request.volumeUUID, containerReference: request.containerReference, name: request.name)
                }
                .disabled(volumeDeleteConfirmationText != "Delete")
                Button("Cancel", role: .cancel) {
                    viewModel.setVolumeDeletionRequest(nil)
                    volumeDeleteConfirmationText = ""
                }
            } message: { request in
                Text("This permanently deletes the APFS Volume “\(request.name)” and all data stored in it. Type Delete exactly to continue. This action cannot be undone.")
            }
            .confirmationDialog("Delete App?", isPresented: appDeletionPresented, titleVisibility: .visible) {
                Button("Delete App", role: .destructive) { delete(.app) }
                Button("Delete Data", role: .destructive) { delete(.data) }
                Button("Delete App & Data", role: .destructive) { delete(.appAndData) }
                Button("Cancel", role: .cancel) { viewModel.setAppDeletionRequest(nil) }
            } message: {
                if let request = viewModel.appDeletionRequest {
                    Text("Delete App removes “\(request.app.name).app” but keeps its Data. Delete Data keeps the App and permanently removes its Data. Delete App & Data permanently removes both.")
                }
            }
            .alert("Local Data Found", isPresented: connectionConflictPresented) {
                Button("Remove & Connect", role: .destructive) { resolveConnectionConflict(using: .remove) }
                Button("Hide & Connect") { resolveConnectionConflict(using: .hide) }
                Button("Cancel", role: .cancel) {
                    viewModel.setConnectionConflict(nil)
                    actions.cancelPendingOpenAfterConnect()
                }
            } message: {
                Text("This App has non-empty local Data. Remove & Connect permanently deletes that local copy. Hide & Connect keeps it underneath the mounted external Volume, where it remains hidden and continues using disk space.")
            }
    }

    private var activeDialog: Binding<AppDialog?> {
        Binding(
            get: { viewModel.activeDialog },
            set: { viewModel.presentDialog($0) }
        )
    }

    private var appDeletionPresented: Binding<Bool> {
        Binding(
            get: { viewModel.appDeletionRequest != nil },
            set: { if !$0 { viewModel.setAppDeletionRequest(nil) } }
        )
    }

    private var connectionConflictPresented: Binding<Bool> {
        Binding(
            get: { viewModel.connectionConflict != nil },
            set: { if !$0 { viewModel.setConnectionConflict(nil) } }
        )
    }

    private var volumeDeletionPresented: Binding<Bool> {
        Binding(
            get: { viewModel.volumeDeletionRequest != nil },
            set: { presented in
                if !presented {
                    viewModel.setVolumeDeletionRequest(nil)
                    volumeDeleteConfirmationText = ""
                }
            }
        )
    }

    private func delete(_ selection: AppDeletionSelection) {
        guard let request = viewModel.appDeletionRequest else { return }
        if selection != .app, case .external = request.dataLocation {
            viewModel.selectOtherVolume(identifiedBy: nil)
        }
        viewModel.setAppDeletionRequest(nil)
        actions.delete(request, selection: selection)
    }

    private func resolveConnectionConflict(using policy: LocalDataConnectionPolicy) {
        guard let conflict = viewModel.connectionConflict,
              let app = model.app(identifiedBy: conflict.bundleIdentifier) else { return }
        viewModel.setConnectionConflict(nil)
        actions.selectManagedApp(app)
        actions.reconnectAppData(localDataPolicy: policy)
    }

    private func migrationBatchConfirmationMessage(_ request: MigrationBatchRequest) -> String {
        let conflicts = request.conflictingMigrations
        let newCount = request.migrations.count - conflicts.count
        var lines = [
            "\(request.migrations.count) Apps will be added to the migration queue and processed one at a time.",
            "\(newCount) will create new destination data; \(conflicts.count) will overwrite existing destination data."
        ]
        if !conflicts.isEmpty {
            let names = conflicts.prefix(5).map(\.appName).joined(separator: ", ")
            let remaining = conflicts.count - min(conflicts.count, 5)
            lines.append(remaining > 0 ? "Overwrite: \(names), and \(remaining) more." : "Overwrite: \(names).")
        }
        return lines.joined(separator: "\n\n")
    }

    private func openFullDiskAccessSettingsAndQuit() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApplication.shared.terminate(nil) }
    }
}

extension View {
    func appDialogs(
        viewModel: AppViewModel,
        actions: ManagedAppActions
    ) -> some View {
        modifier(
            AppDialogsModifier(
                viewModel: viewModel,
                actions: actions
            )
        )
    }
}
