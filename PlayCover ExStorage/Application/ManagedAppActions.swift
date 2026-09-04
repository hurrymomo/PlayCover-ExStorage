import AppKit
import Combine
import Foundation

// MARK: - Application workflow coordination
@MainActor
final class ManagedAppActions: ObservableObject {
    static let lastAppPathKey = "LastDroppedApplicationPath"
    let model: AppModel
    let viewModel: AppViewModel
    let appStore: any ManagedAppPersisting
    let storageService: any StorageServicing
    let migrationService: any MigrationServicing
    let metadataStore: ExStorageMetadataStore
    let migrationStorage: ManagementVolumeAccess

    // External containers list
    var containers: [ExternalAPFSContainer] {
        model.allContainers()
    }
    var selectedContainerID: ExternalAPFSContainer.ID? {
        get {
            guard case let .container(id) = viewModel.sidebarSelection else { return nil }
            return id
        }
        set {
            viewModel.selectSidebar(newValue.map(StorageSidebarSelection.container) ?? .allApps)
        }
    }

    // The registry is the source of truth. Selection stores only a stable Bundle ID;
    // app metadata is derived from the selected registry record.
    var selectedAppBundleID: String? {
        get { viewModel.selectedAppBundleID }
        set { viewModel.selectApp(identifiedBy: newValue) }
    }
    var apps: [AppSnapshot] {
        model.apps
    }

    // These four properties remain the serial migration scheduler's viewModel.
    // Per-app UI and connection operations use appOperationStates instead.
    var operation: AppOperation {
        get { model.operation }
        set { model.updateOperation(newValue) }
    }
    var operationMessage: String {
        get { model.operationMessage }
        set { model.updateOperationMessage(newValue) }
    }
    var operationProgress: Double? {
        get { model.operationProgress }
        set { model.updateOperationProgress(newValue) }
    }
    var activeDialog: AppDialog? {
        get { viewModel.activeDialog }
        set { viewModel.presentDialog(newValue) }
    }
    var appDeletionRequest: AppDeletionRequest? {
        get { viewModel.appDeletionRequest }
        set { viewModel.setAppDeletionRequest(newValue) }
    }
    var volumeDeletionRequest: VolumeDeletionRequest? {
        get { viewModel.volumeDeletionRequest }
        set { viewModel.setVolumeDeletionRequest(newValue) }
    }
    var connectionConflict: ConnectionConflict? {
        get { viewModel.connectionConflict }
        set { viewModel.setConnectionConflict(newValue) }
    }
    var pendingOpenAfterConnectURL: URL?

    /// A persisted Bundle ID alone is not enough to present an item as an app.
    /// The recorded path must still point at a readable application bundle with
    /// the same identifier; otherwise its external APFS volume is shown as an
    /// ordinary volume.
    func isInstalledApp(_ app: AppSnapshot) -> Bool {
        guard !app.applicationPath.isEmpty,
              storageService.itemExists(at: app.applicationURL),
              let bundle = Bundle(url: app.applicationURL) else { return false }
        return bundle.bundleIdentifier == app.bundleIdentifier
    }

    var refreshInProgress = false
    var refreshRequested = false
    var refreshCompletions: [() -> Void] = []
    var selectedApp: AppSnapshot? {
        guard let selectedAppBundleID else { return nil }
        return apps.first { $0.bundleIdentifier == selectedAppBundleID }
    }

    var applicationName: String? { selectedApp?.name }
    var bundleIdentifier: String? { selectedApp?.bundleIdentifier }
    var applicationURL: URL? {
        guard let path = selectedApp?.applicationPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    func hasPendingMigration(bundleID: String) -> Bool {
        let snapshot = migrationService.status.snapshot
        return snapshot.active?.bundleIdentifier == bundleID
            || snapshot.queued.contains { $0.bundleIdentifier == bundleID }
    }

    func appOperationState(for bundleID: String) -> AppOperationState {
        model.appOperationState(for: bundleID)
    }

    func isAppOperationRunning(bundleID: String) -> Bool {
        hasPendingMigration(bundleID: bundleID)
            || appOperationState(for: bundleID).operation.isRunning
    }

    func appFailureMessage(bundleID: String) -> String? {
        model.appFailureMessage(for: bundleID)
    }

    func managedDataVolume(for bundleID: String) -> ExternalVolume? {
        model.managedDataVolume(for: bundleID)
    }

    func managedDataContainer(for bundleID: String) -> ExternalAPFSContainer? {
        model.managedDataContainer(for: bundleID)
    }

    func hasExternalApp(bundleID: String) -> Bool {
        managedAppContainer(for: bundleID) != nil
    }

    func managedAppContainer(for bundleID: String) -> ExternalAPFSContainer? {
        guard let app = model.app(identifiedBy: bundleID), !app.applicationPath.isEmpty else { return nil }
        let appPath = app.applicationURL.standardizedFileURL.path
        return containers.first { container in
            container.volumes.contains { volume in
                guard volume.name == ExStorageLayout.managementVolumeName,
                      let mountPoint = volume.mountPoint else { return false }
                let root = URL(fileURLWithPath: mountPoint, isDirectory: true).standardizedFileURL.path
                return appPath.hasPrefix(root + "/")
            }
        }
    }

    func managedAppTarget(for bundleID: String) -> MigrationTarget {
        managedAppContainer(for: bundleID).map { .container($0.id) } ?? .local
    }

    func setAppOperation(
        bundleID: String,
        operation: AppOperation,
        message: String,
        progress: Double? = nil
    ) {
        model.setAppOperationState(
            AppOperationState(operation: operation, message: message, progress: progress),
            for: bundleID
        )
    }

    func clearAppError(bundleID: String, after action: String) {
        guard model.clearAppFailureMessage(for: bundleID) else { return }
        MigrationTrace.event("app.error.cleared", bundleID: bundleID, details: "action=\(action)")
    }

    func openOtherVolume(_ volume: ExternalVolume) {
        if let mountPoint = usableMountPoint(volume.mountPoint) {
            NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint, isDirectory: true))
            return
        }

        guard let expectedDevice = volume.bsdDevice,
              let expectedUUID = volume.volumeUUID else {
            activeDialog = .message(
                title: "Cannot Connect Volume",
                message: "The Volume does not currently have a verifiable APFS device and UUID. Refresh the drive and try again."
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = await self.storageService.scanSnapshot()
                guard let current = snapshot.containers.flatMap(\.volumes).first(where: {
                    $0.bsdDevice == expectedDevice
                        && $0.volumeUUID?.caseInsensitiveCompare(expectedUUID) == .orderedSame
                }) else {
                    throw self.operationError("The Volume identity changed. Refresh the drive and try again.")
                }

                if let currentMountPoint = self.usableMountPoint(current.mountPoint) {
                    self.updateMountPoint(for: expectedDevice, to: currentMountPoint)
                    NSWorkspace.shared.open(URL(fileURLWithPath: currentMountPoint, isDirectory: true))
                    return
                }

                let mountPoint = self.otherVolumeMountPoint(name: current.name, volumeUUID: expectedUUID)
                try await self.storageService.mountAPFSVolume(
                    device: expectedDevice,
                    at: mountPoint,
                    options: []
                )
                self.updateMountPoint(for: expectedDevice, to: mountPoint.path)
                NSWorkspace.shared.open(mountPoint)
            } catch {
                self.activeDialog = .message(
                    title: "Connect & Open Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func otherVolumeMountPoint(name: String, volumeUUID: String) -> URL {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let nameComponent = safeName.isEmpty || safeName == "." || safeName == ".." ? "Volume" : safeName
        let uuidComponent = volumeUUID.uppercased().filter {
            $0.isLetter || $0.isNumber || $0 == "-"
        }
        return URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent("\(nameComponent)-\(uuidComponent)", isDirectory: true)
    }

    init(
        model: AppModel,
        viewModel: AppViewModel,
        appStore: (any ManagedAppPersisting)? = nil,
        storageService: any StorageServicing = UserStorageService.shared,
        migrationService: any MigrationServicing
    ) {
        self.model = model
        self.viewModel = viewModel
        self.appStore = appStore ?? ManagedAppStore()
        self.storageService = storageService
        let metadataStore = ExStorageMetadataStore()
        self.metadataStore = metadataStore
        self.migrationStorage = ManagementVolumeAccess(
            model: model,
            storage: storageService,
            metadata: metadataStore
        )
        self.migrationService = migrationService
        restoreManagedApps()
        storageService.setStorageChangeHandler { [weak self] change in
            self?.handleStorageDeviceChange(change)
        }
    }

    private func handleStorageDeviceChange(_ change: StorageDeviceChange) {
        switch change {
        case let .inserted(device):
            Task {
                let inserted = await storageService.scanContainers(onPhysicalDevice: device)
                guard !inserted.isEmpty else { return }
                model.insertOrUpdateContainers(inserted)
                synchronizeManagedAppsWithStorage(in: inserted)
            }

        case let .removed(device):
            let removedIDs = model.invalidateContainers(onPhysicalDevice: device)
            guard !removedIDs.isEmpty else { return }
            if case let .container(selectedID) = viewModel.sidebarSelection,
               removedIDs.contains(selectedID) {
                viewModel.selectSidebar(.allApps)
            }
            if let active = migrationService.status.snapshot.active,
               migrationTouches(active, anyOf: removedIDs) {
                model.setAppFailureMessage(
                    "The external storage was disconnected during migration.",
                    for: active.bundleIdentifier
                )
            }
        }
    }

    private func migrationTouches(_ migration: PendingMigration, anyOf containerIDs: Set<UUID>) -> Bool {
        [migration.source, migration.target].contains { target in
            guard case let .container(id) = target else { return false }
            return containerIDs.contains(id)
        }
    }


}
