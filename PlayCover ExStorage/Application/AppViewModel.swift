import AppKit
import Combine
import Foundation

// MARK: - View Models (UI-only scaffolding)
@MainActor
final class AppViewModel: ObservableObject {
    private static let lastAppPathKey = "LastDroppedApplicationPath"
    private let storageDiscovery: any ExternalStorageDiscovering
    private let appStore: any ManagedAppPersisting
    private let privilegedClient: XPCPrivilegedClient

    // External containers list
    @Published var containers: [ExternalAPFSContainer] = []
    @Published var selectedContainerID: ExternalAPFSContainer.ID? = nil

    // The registry is the source of truth. Selection stores only a stable Bundle ID;
    // app metadata is derived from the selected registry record.
    @Published var selectedAppBundleID: String? = nil
    @Published var managedApps: [ManagedApp] = []
    @Published private(set) var dataSizeCache: [String: Int64] = [:]
    @Published private(set) var calculatingDataSizeBundleIDs: Set<String> = []

    @Published var migrationStagesCompleted: Set<MigrationStage> = [] {
        didSet { mirrorActiveMigrationState() }
    }

    // These four properties remain the serial migration scheduler's presentation.
    // Per-app UI and connection operations use appOperationStates instead.
    @Published var operation: AppOperation = .idle {
        didSet { mirrorActiveMigrationState() }
    }
    @Published var operationMessage: String = "Drop an app and select an external APFS SSD to begin." {
        didSet { mirrorActiveMigrationState() }
    }
    @Published var operationProgress: Double? = nil {
        didSet { mirrorActiveMigrationState() }
    }
    @Published private(set) var appOperationStates: [String: AppOperationState] = [:]
    @Published var activeDialog: AppDialog? = nil
    @Published var localAppDeletionRequest: LocalAppDeletionRequest? = nil
    @Published var externalAppDeletionRequest: ExternalAppDeletionRequest? = nil
    @Published var volumeDeletionRequest: VolumeDeletionRequest? = nil
    @Published var migrationReconnectChoice: MigrationReconnectChoice? = nil
    @Published private(set) var activeMigration: MigrationPresentation? = nil {
        didSet { mirrorActiveMigrationState() }
    }
    @Published private(set) var queuedMigrations: [PendingMigration] = []
    @Published private(set) var preparingMigrations: [PendingMigration] = []
    @Published private(set) var migrationHistory: [MigrationHistoryRecord] = []
    @Published private(set) var migrationErrors: [String: String] = [:]
    @Published private(set) var requestedSidebarTarget: MigrationTarget?
    private var currentMigrationBatchID: UUID?
    private var currentMigrationFocusesSource = false
    private var spaceAlertedBatchIDs: Set<UUID> = []
    @Published var connectionConflict: ConnectionConflict? = nil
    private var pendingOpenAfterConnectURL: URL?

    /// A persisted Bundle ID alone is not enough to present an item as an app.
    /// The recorded path must still point at a readable application bundle with
    /// the same identifier; otherwise its external APFS volume is shown as an
    /// ordinary volume.
    func isInstalledApp(_ app: ManagedApp) -> Bool {
        guard !app.applicationPath.isEmpty,
              FileManager.default.fileExists(atPath: app.applicationPath),
              let bundle = Bundle(url: app.applicationURL) else { return false }
        return bundle.bundleIdentifier == app.bundleIdentifier
    }

    private var refreshInProgress = false
    private var refreshRequested = false
    private var refreshCompletions: [() -> Void] = []
    private var queuedMigrationInFlight = false

    var selectedApp: ManagedApp? {
        guard let selectedAppBundleID else { return nil }
        return managedApps.first { $0.bundleIdentifier == selectedAppBundleID }
    }

    var applicationName: String? { selectedApp?.name }
    var bundleIdentifier: String? { selectedApp?.bundleIdentifier }
    var applicationURL: URL? {
        guard let path = selectedApp?.applicationPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    func isMigrationLocked(bundleID: String) -> Bool {
        preparingMigrations.contains(where: { $0.bundleIdentifier == bundleID })
            || queuedMigrations.contains(where: { $0.bundleIdentifier == bundleID })
            || appOperationState(for: bundleID).operation.isRunning
    }

    func appOperationState(for bundleID: String) -> AppOperationState {
        appOperationStates[bundleID] ?? AppOperationState()
    }

    func isAppOperationRunning(bundleID: String) -> Bool {
        appOperationState(for: bundleID).operation.isRunning
    }

    func appFailureMessage(bundleID: String) -> String? {
        if let message = migrationErrors[bundleID] { return message }
        return nil
    }

    private func setAppOperation(
        bundleID: String,
        operation: AppOperation,
        message: String,
        progress: Double? = nil,
        migrationStages: Set<MigrationStage> = []
    ) {
        appOperationStates[bundleID] = AppOperationState(
            operation: operation,
            message: message,
            progress: progress,
            migrationStages: migrationStages
        )
    }

    private func mirrorActiveMigrationState() {
        guard let bundleID = activeMigration?.bundleIdentifier else { return }
        setAppOperation(
            bundleID: bundleID,
            operation: operation,
            message: operationMessage,
            progress: operationProgress,
            migrationStages: migrationStagesCompleted
        )
    }

    private func clearAppError(bundleID: String, after action: String) {
        guard migrationErrors.removeValue(forKey: bundleID) != nil else { return }
        MigrationTrace.event("app.error.cleared", bundleID: bundleID, details: "action=\(action)")
    }

    init(
        storageDiscovery: any ExternalStorageDiscovering = DiskUtilStorageDiscovery(),
        appStore: (any ManagedAppPersisting)? = nil,
        privilegedClient: XPCPrivilegedClient = .shared
    ) {
        self.storageDiscovery = storageDiscovery
        self.appStore = appStore ?? ManagedAppStore()
        self.privilegedClient = privilegedClient
        restoreManagedApps()
    }

    func refreshExternalVolumes(completion: (() -> Void)? = nil) {
        if let completion { refreshCompletions.append(completion) }
        if refreshInProgress {
            refreshRequested = true
            return
        }
        refreshInProgress = true
        let selectedReference = containers
            .first(where: { $0.id == selectedContainerID })?
            .containerReference
        Task {
            var discoveredContainerIDs: Set<UUID> = []
            var discoveredVolumeIDs: [UUID: Set<String>] = [:]
            await self.storageDiscovery.discoverProgressively { container in
                discoveredContainerIDs.insert(container.id)
                let existingVolumes = self.containers.first(where: { $0.id == container.id })?.volumes ?? []
                let updated = ExternalAPFSContainer(
                    containerUUID: container.containerUUID,
                    containerReference: container.containerReference,
                    displayName: container.displayName,
                    connectionType: container.connectionType,
                    capacityTotalBytes: container.capacityTotalBytes,
                    capacityFreeBytes: container.capacityFreeBytes,
                    volumes: existingVolumes
                )
                self.containers.removeAll { $0.id == container.id }
                self.containers.append(updated)
                self.containers.sort {
                    (($0.displayName ?? ""), $0.containerReference)
                        < (($1.displayName ?? ""), $1.containerReference)
                }
            } onVolume: { containerID, volume in
                discoveredVolumeIDs[containerID, default: []].insert(volume.id)
                self.addOrUpdateVolume(containerID: containerID, volume: volume)
            }

            self.containers = self.containers.compactMap { container in
                guard discoveredContainerIDs.contains(container.id) else { return nil }
                let validVolumeIDs = discoveredVolumeIDs[container.id] ?? []
                return ExternalAPFSContainer(
                    containerUUID: container.containerUUID,
                    containerReference: container.containerReference,
                    displayName: container.displayName,
                    connectionType: container.connectionType,
                    capacityTotalBytes: container.capacityTotalBytes,
                    capacityFreeBytes: container.capacityFreeBytes,
                    volumes: container.volumes.filter { validVolumeIDs.contains($0.id) }
                )
            }
            let found = self.containers
            await self.discoverManagedApps(matching: found)
            var promotedExistingMigration = false
            let discoveredVolumeNames = Set(found.flatMap(\.volumes).map(\.name))
            for index in self.managedApps.indices
                where self.managedApps[index].persistence == .sessionOnly
                    && discoveredVolumeNames.contains(self.managedApps[index].bundleIdentifier) {
                self.managedApps[index].persistence = .managed
                promotedExistingMigration = true
            }
            if promotedExistingMigration {
                self.persistManagedApps()
            }
            self.selectedContainerID = found.first(where: { $0.containerReference == selectedReference })?.id
                ?? found.first?.id
            self.refreshInProgress = false
            let completions = self.refreshCompletions
            self.refreshCompletions.removeAll()
            completions.forEach { $0() }
            if self.refreshRequested {
                self.refreshRequested = false
                self.refreshExternalVolumes()
            }
        }
    }

    private func archiveFinishedMigration() {
        guard let migration = activeMigration,
              !operation.isRunning,
              !migrationHistory.contains(where: { $0.migration.id == migration.id }) else { return }
        let appName = managedApps.first(where: {
            $0.bundleIdentifier == migration.bundleIdentifier
        })?.name ?? migration.bundleIdentifier
        migrationHistory.append(MigrationHistoryRecord(
            migration: migration,
            appName: appName,
            succeeded: operation == .succeeded,
            message: operationMessage,
            sourceAvailableBytes: availableCapacitySnapshot(for: migration.source),
            targetAvailableBytes: availableCapacitySnapshot(for: migration.target)
        ))
    }

    private func availableCapacitySnapshot(for target: MigrationTarget) -> Int64? {
        switch target {
        case .local:
            return localAvailableCapacity()
        case .container(let id):
            // Migration history is presentation data. Never perform a synchronous full-disk
            // discovery on the main actor merely to capture this optional snapshot; doing so
            // blocked sidebar clicks for several seconds immediately after a migration.
            return containers.first(where: { $0.id == id })?.capacityFreeBytes
        }
    }

    func selectContainer(_ container: ExternalAPFSContainer) {
        selectedContainerID = container.id
        if let bundleID = bundleIdentifier, let applicationName,
           !isAppOperationRunning(bundleID: bundleID) {
            setAppOperation(
                bundleID: bundleID,
                operation: .idle,
                message: "\(applicationName) and \(container.displayName ?? container.containerReference) are ready."
            )
        }
    }

    func consumeRequestedSidebarTarget() {
        requestedSidebarTarget = nil
    }

    @discardableResult
    func handleAppDrop(url: URL, calculateDisplaySize: Bool = true) -> ManagedApp? {
        guard url.pathExtension == "app" else {
            activeDialog = .message(title: "Invalid App", message: "Only .app bundles are accepted.")
            return nil
        }

        guard let record = managedAppRecord(from: url) else {
            activeDialog = .message(title: "Invalid App", message: "The app does not provide a valid Bundle ID.")
            return nil
        }
        if let index = managedApps.firstIndex(where: { $0.bundleIdentifier == record.bundleIdentifier }) {
            managedApps[index] = record
        } else {
            managedApps.append(record)
        }
        selectedAppBundleID = record.bundleIdentifier
        persistManagedApps()
        if calculateDisplaySize {
            calculateDataSizeIfNeeded(for: record.bundleIdentifier)
        }
        if !isAppOperationRunning(bundleID: record.bundleIdentifier) {
            setAppOperation(
                bundleID: record.bundleIdentifier,
                operation: .idle,
                message: "\(record.name) is ready. Select an external APFS SSD."
            )
        }
        return record
    }

    func selectManagedApp(_ app: ManagedApp) {
        selectedAppBundleID = app.bundleIdentifier
        calculateDataSizeIfNeeded(for: app.bundleIdentifier)
        guard !app.applicationPath.isEmpty,
              FileManager.default.fileExists(atPath: app.applicationPath) else {
            if !isAppOperationRunning(bundleID: app.bundleIdentifier) {
                setAppOperation(
                    bundleID: app.bundleIdentifier,
                    operation: .idle,
                    message: "External data was found for \(app.bundleIdentifier), but the app is not installed on this Mac."
                )
            }
            return
        }
        if !isAppOperationRunning(bundleID: app.bundleIdentifier) {
            setAppOperation(
                bundleID: app.bundleIdentifier,
                operation: .idle,
                message: "\(app.name) is ready. Select an external APFS SSD."
            )
        }
    }

    func calculateDataSizeIfNeeded(for bundleID: String) {
        guard dataSizeCache[bundleID] == nil,
              !calculatingDataSizeBundleIDs.contains(bundleID) else { return }
        calculatingDataSizeBundleIDs.insert(bundleID)
        let dataPath = localDataPath(for: bundleID)
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) {
                try? Self.allocatedSize(of: dataPath)
            }.value
            guard let self else { return }
            if let size { self.dataSizeCache[bundleID] = size }
            self.calculatingDataSizeBundleIDs.remove(bundleID)
        }
    }

    func keepInLibrary(bundleID: String) {
        guard let index = managedApps.firstIndex(where: { $0.bundleIdentifier == bundleID }) else { return }
        managedApps[index].persistence = .kept
        persistManagedApps()
        setAppOperation(
            bundleID: bundleID,
            operation: .succeeded,
            message: "\(managedApps[index].name) will remain in All Apps after ExStorage is reopened."
        )
    }

    func removeFromLibrary(bundleID: String) {
        guard managedApps.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        managedApps.removeAll { $0.bundleIdentifier == bundleID }
        persistManagedApps()
        if selectedAppBundleID == bundleID { selectedAppBundleID = nil }
        appOperationStates.removeValue(forKey: bundleID)
    }

    func requestDelete(_ app: ManagedApp) {
        if let container = containers.first(where: {
            $0.volumes.contains { $0.name == app.bundleIdentifier }
        }), let volume = container.volumes.first(where: { $0.name == app.bundleIdentifier }),
           let device = volume.bsdDevice, let uuid = volume.volumeUUID {
            externalAppDeletionRequest = ExternalAppDeletionRequest(
                app: app,
                volumeName: volume.name,
                device: device,
                volumeUUID: uuid,
                containerReference: container.containerReference
            )
        } else {
            localAppDeletionRequest = LocalAppDeletionRequest(app: app)
        }
    }

    func deleteExternalApp(_ request: ExternalAppDeletionRequest, includingVolume: Bool) {
        let app = request.app
        guard !operation.isRunning else { return }
        guard isInstalledApp(app), app.applicationURL.pathExtension == "app" else {
            activeDialog = .message(
                title: "Cannot Delete App",
                message: "The recorded App path is no longer a valid application bundle."
            )
            return
        }
        let applicationURL = app.applicationURL

        operationMessage = includingVolume
            ? "Deleting \(app.name) and its external Volume…"
            : "Deleting \(app.name)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                if includingVolume {
                    let identity = await Task.detached(priority: .userInitiated) {
                        DiskUtilDiscovery.volumeIdentity(for: request.device)
                    }.value
                    guard identity?.volumeUUID == request.volumeUUID,
                          identity?.containerReference == request.containerReference else {
                        throw self.operationError("Refusing to delete a Volume whose UUID or APFS Container changed.")
                    }
                }

                try await self.moveApplicationToTrash(applicationURL)
                if includingVolume {
                    try await self.deleteVerifiedVolume(
                        device: request.device,
                        expectedUUID: request.volumeUUID,
                        expectedContainerReference: request.containerReference
                    )
                    self.removeVolume(device: request.device)
                }
                self.managedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
                self.persistManagedApps()
                self.selectedAppBundleID = nil
                self.operation = .idle
                self.operationMessage = includingVolume
                    ? "Moved \(app.name) to Trash and deleted its external Volume."
                    : "Moved \(app.name) to Trash. The external Volume and its data were kept."
            } catch {
                self.operation = .failed
                self.operationMessage = error.localizedDescription
                self.activeDialog = .message(title: "Delete Failed", message: error.localizedDescription)
            }
        }
    }

    func deleteLocalApp(_ app: ManagedApp, includingData: Bool) {
        guard !operation.isRunning else { return }
        guard isInstalledApp(app), app.applicationURL.pathExtension == "app" else {
            activeDialog = .message(
                title: "Cannot Delete App",
                message: "The recorded App path is no longer a valid application bundle."
            )
            return
        }
        let applicationURL = app.applicationURL
        guard !containers.flatMap(\.volumes).contains(where: {
            $0.name == app.bundleIdentifier
        }) else {
            activeDialog = .message(
                title: "Cannot Delete Local App",
                message: "This App currently has data on an external Volume. Manage that Volume from its SSD page."
            )
            return
        }

        let dataPath = localDataPath(for: app.bundleIdentifier)
        if includingData {
            let mountedExternally = containers.flatMap(\.volumes).contains { volume in
                guard let mountPoint = volume.mountPoint else { return false }
                return URL(fileURLWithPath: mountPoint).standardizedFileURL.path
                    == dataPath.standardizedFileURL.path
            }
            guard !mountedExternally else {
                activeDialog = .message(
                    title: "External Data Is Connected",
                    message: "Disconnect the external App data before deleting local App data. The external Volume was not changed."
                )
                return
            }
        }

        operationMessage = includingData ? "Deleting \(app.name) and its local data…" : "Deleting \(app.name)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.moveApplicationToTrash(applicationURL)
                if includingData, FileManager.default.fileExists(atPath: dataPath.path) {
                    try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                }
                self.managedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
                self.persistManagedApps()
                self.selectedAppBundleID = nil
                self.operation = .idle
                self.operationMessage = includingData
                    ? "Moved \(app.name) to Trash and deleted its local Data directory."
                    : "Moved \(app.name) to Trash. Its local Container data was kept."
            } catch {
                self.operation = .failed
                self.operationMessage = error.localizedDescription
                self.activeDialog = .message(title: "Delete Failed", message: error.localizedDescription)
            }
        }
    }

    func requestDelete(_ volume: ExternalVolume, in container: ExternalAPFSContainer) {
        guard let device = volume.bsdDevice, let uuid = volume.volumeUUID else {
            activeDialog = .message(
                title: "Cannot Delete Volume",
                message: "The Volume does not currently have a verifiable APFS device and UUID. Refresh the drive and try again."
            )
            return
        }
        volumeDeletionRequest = VolumeDeletionRequest(
            name: volume.name,
            device: device,
            volumeUUID: uuid,
            containerReference: container.containerReference
        )
    }

    func deleteConfirmedVolume(device: String, uuid: String, containerReference: String, name: String) {
        guard !operation.isRunning else { return }
        operationMessage = "Deleting \(name)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.deleteVerifiedVolume(
                    device: device,
                    expectedUUID: uuid,
                    expectedContainerReference: containerReference
                )
                self.removeVolume(device: device)
                self.operation = .idle
                self.operationMessage = "Deleted \(name)."
            } catch {
                self.operation = .failed
                self.operationMessage = error.localizedDescription
                self.activeDialog = .message(title: "Delete Failed", message: error.localizedDescription)
            }
        }
    }

    func requestMigration(of app: ManagedApp, from source: MigrationTarget, to target: MigrationTarget) {
        guard source != target, !isMigrationLocked(bundleID: app.bundleIdentifier) else { return }
        guard isInstalledApp(app) else {
            activeDialog = .message(
                title: "App Not Found",
                message: "The recorded App no longer exists. Reinstall or add the matching App before migrating its data. The external data Volume was not changed."
            )
            return
        }
        let pending = PendingMigration(
            batchID: UUID(),
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            source: source,
            target: target,
            focusesSourceOnSuccess: true
        )
        enqueueMigrationRequests([pending])
    }

    func retryMigration(_ record: MigrationHistoryRecord) {
        guard !record.succeeded,
              let app = managedApps.first(where: {
                  $0.bundleIdentifier == record.migration.bundleIdentifier
              }) else { return }
        let currentSource = containers.first(where: {
            $0.volumes.contains { $0.name == app.bundleIdentifier }
        }).map { MigrationTarget.container($0.id) } ?? .local
        guard currentSource == record.migration.source else {
            activeDialog = .message(
                title: "Migration Location Changed",
                message: "\(app.name) is no longer at the original source for this task. Start a new migration from its current location instead."
            )
            return
        }
        if case let .container(targetID) = record.migration.target,
           !containers.contains(where: { $0.id == targetID }) {
            activeDialog = .message(
                title: "Target Drive Not Available",
                message: "Connect the original target drive, then retry this migration."
            )
            return
        }
        requestMigration(of: app, from: currentSource, to: record.migration.target)
    }

    private func enqueueMigrationRequests(_ requests: [PendingMigration]) {
        MigrationTrace.event(
            "queue.enqueue.request",
            details: "count=\(requests.count) queuedBefore=\(queuedMigrations.count) preparing=\(preparingMigrations.count) inFlight=\(queuedMigrationInFlight)"
        )
        for request in requests where
            request.source != request.target
                && activeMigration?.bundleIdentifier != request.bundleIdentifier
                && !preparingMigrations.contains(where: { $0.bundleIdentifier == request.bundleIdentifier })
                && !queuedMigrations.contains(where: { $0.bundleIdentifier == request.bundleIdentifier }) {
            queuedMigrations.append(request)
            MigrationTrace.event(
                "queue.enqueued",
                bundleID: request.bundleIdentifier,
                details: "id=\(request.id) batch=\(request.batchID) source=\(request.source) target=\(request.target)"
            )
        }
        startNextQueuedMigrationIfPossible()
    }

    func prepareDroppedAppBatch(urls: [URL], to target: MigrationTarget) {
        let records = urls.compactMap { url -> ManagedApp? in
            guard url.pathExtension == "app" else { return nil }
            return managedAppRecord(from: url)
        }
        prepareMigrationBatch(records, addingToLibrary: true, to: target)
    }

    func prepareExistingAppBatch(_ apps: [ManagedApp], to target: MigrationTarget) {
        prepareMigrationBatch(apps, addingToLibrary: false, to: target)
    }

    private func prepareMigrationBatch(
        _ candidates: [ManagedApp],
        addingToLibrary: Bool,
        to target: MigrationTarget
    ) {
        MigrationTrace.event(
            "drop.batch.prepare",
            details: "candidates=\(candidates.count) addToLibrary=\(addingToLibrary) target=\(target)"
        )
        var seenBundleIDs: Set<String> = []
        let apps = candidates.filter { app in
            guard seenBundleIDs.insert(app.bundleIdentifier).inserted,
                  isInstalledApp(app) else { return false }
            let source = containers.first(where: {
                $0.volumes.contains { $0.name == app.bundleIdentifier }
            }).map { MigrationTarget.container($0.id) } ?? .local
            return source != target && !isMigrationLocked(bundleID: app.bundleIdentifier)
        }
        guard !apps.isEmpty else {
            MigrationTrace.event("drop.batch.ignored", details: "no eligible apps target=\(target)")
            // Non-App items and invalid bundles are intentionally ignored.
            return
        }
        activeDialog = .confirmMigrationBatch(MigrationBatchRequest(
            apps: apps,
            target: target,
            addsToLibrary: addingToLibrary
        ))
    }

    func confirmMigrationBatch(_ request: MigrationBatchRequest) {
        MigrationTrace.event(
            "drop.batch.confirmed",
            details: "apps=\(request.apps.map(\.bundleIdentifier).joined(separator: ",")) target=\(request.target)"
        )
        if request.addsToLibrary {
            for app in request.apps {
                if let index = managedApps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                    managedApps[index] = app
                } else {
                    managedApps.append(app)
                }
            }
            persistManagedApps()
        }
        let batchID = UUID()
        let pending = request.apps.compactMap { app -> PendingMigration? in
            let source = containers.first(where: {
                $0.volumes.contains { $0.name == app.bundleIdentifier }
            }).map { MigrationTarget.container($0.id) } ?? .local
            guard source != request.target else { return nil }
            return PendingMigration(
                batchID: batchID,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                source: source,
                target: request.target,
                overwriteExisting: true
            )
        }
        enqueueMigrationRequests(pending)
    }

    private func startNextQueuedMigrationIfPossible() {
        MigrationTrace.event(
            "queue.start.attempt",
            details: "queued=\(queuedMigrations.count) preparing=\(preparingMigrations.count) inFlight=\(queuedMigrationInFlight)"
        )
        guard !queuedMigrationInFlight, !queuedMigrations.isEmpty else { return }
        let next = queuedMigrations.removeFirst()
        MigrationTrace.event(
            "queue.start.selected",
            bundleID: next.bundleIdentifier,
            details: "id=\(next.id) source=\(next.source) target=\(next.target)"
        )
        guard let app = managedApps.first(where: { $0.bundleIdentifier == next.bundleIdentifier }) else {
            startNextQueuedMigrationIfPossible()
            return
        }
        guard isInstalledApp(app) else {
            migrationErrors[next.bundleIdentifier] = "The App is no longer installed."
            startNextQueuedMigrationIfPossible()
            return
        }
        queuedMigrationInFlight = true
        archiveFinishedMigration()
        activeMigration = nil
        selectManagedApp(app)
        preparingMigrations.append(next)
        MigrationTrace.event("preflight.begin", bundleID: next.bundleIdentifier, details: "id=\(next.id)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try self.ensureLocalDataDirectory(for: next.bundleIdentifier)
                try await self.preflightMigration(next)
                // Preparing ends at the preflight boundary. The concrete
                // migration method owns all state after this point.
                self.preparingMigrations.removeAll { $0.id == next.id }
                MigrationTrace.event(
                    "preflight.succeeded",
                    bundleID: next.bundleIdentifier,
                    details: "preparingRemaining=\(self.preparingMigrations.count)"
                )
                self.performConfirmedMigration(next)
            } catch {
                self.preparingMigrations.removeAll { $0.id == next.id }
                MigrationTrace.event(
                    "preflight.failed",
                    bundleID: next.bundleIdentifier,
                    details: "error=\(error.localizedDescription) preparingRemaining=\(self.preparingMigrations.count)"
                )
                self.migrationErrors[next.bundleIdentifier] = error.localizedDescription
                self.presentInsufficientSpaceAlertIfNeeded(error, batchID: next.batchID)
                self.queuedMigrationInFlight = false
                DispatchQueue.main.async { [weak self] in
                    self?.startNextQueuedMigrationIfPossible()
                }
            }
        }
    }

    private func finishQueuedMigrationIfNeeded(recordFailure: Bool = true) {
        let finishedBatchID = activeMigration?.batchID
        if let bundleID = activeMigration?.bundleIdentifier {
            // A completed migration must never remain represented by a stale
            // drag-preflight placeholder, even if a drop callback was repeated.
            preparingMigrations.removeAll { $0.bundleIdentifier == bundleID }
            MigrationTrace.event(
                "migration.finish",
                bundleID: bundleID,
                details: "operation=\(operation) queued=\(queuedMigrations.count) preparing=\(preparingMigrations.count) inFlight=\(queuedMigrationInFlight) message=\(operationMessage)"
            )
            if operation == .failed && recordFailure {
                migrationErrors[bundleID] = operationMessage
            } else if operation == .succeeded {
                clearAppError(bundleID: bundleID, after: "migrate")
                if currentMigrationFocusesSource, let source = activeMigration?.source {
                    requestedSidebarTarget = source
                }
            }
        }
        archiveFinishedMigration()
        activeMigration = nil
        currentMigrationFocusesSource = false
        guard queuedMigrationInFlight else { return }
        queuedMigrationInFlight = false
        if let finishedBatchID,
           !queuedMigrations.contains(where: { $0.batchID == finishedBatchID }) {
            spaceAlertedBatchIDs.remove(finishedBatchID)
        }
        if !queuedMigrations.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.startNextQueuedMigrationIfPossible() }
        }
    }

    func cancelMigrationAwaitingConfirmation() {
        guard queuedMigrationInFlight else { return }
        queuedMigrationInFlight = false
        DispatchQueue.main.async { [weak self] in
            self?.startNextQueuedMigrationIfPossible()
        }
    }

    private func abortQueuedMigrationBeforeStart(bundleID: String, message: String) {
        migrationErrors[bundleID] = message
        operation = .failed
        operationMessage = message
        queuedMigrationInFlight = false
        DispatchQueue.main.async { [weak self] in
            self?.startNextQueuedMigrationIfPossible()
        }
    }

    private func performConfirmedMigration(_ pendingMigration: PendingMigration) {
        currentMigrationBatchID = pendingMigration.batchID
        currentMigrationFocusesSource = pendingMigration.focusesSourceOnSuccess
        MigrationTrace.event(
            "migration.route",
            bundleID: pendingMigration.bundleIdentifier,
            details: "source=\(pendingMigration.source) target=\(pendingMigration.target) overwrite=\(pendingMigration.overwriteExisting)"
        )

        switch (pendingMigration.source, pendingMigration.target) {
        case (.local, .container(let containerID)):
            guard let container = containers.first(where: { $0.id == containerID }) else {
                activeDialog = .message(title: "Drive Not Available", message: "The selected external drive is no longer connected.")
                abortQueuedMigrationBeforeStart(
                    bundleID: pendingMigration.bundleIdentifier,
                    message: "The selected external drive is no longer connected."
                )
                return
            }
            selectContainer(container)
            requestMigration()

        case (.container(let sourceContainerID), .local):
            guard let sourceContainer = containers.first(where: { $0.id == sourceContainerID }) else {
                activeDialog = .message(title: "Drive Not Available", message: "The source external drive is no longer connected.")
                abortQueuedMigrationBeforeStart(
                    bundleID: pendingMigration.bundleIdentifier,
                    message: "The source external drive is no longer connected."
                )
                return
            }
            selectContainer(sourceContainer)
            let dataPath = localDataPath(for: pendingMigration.bundleIdentifier)
            let sourceIsConnected = sourceContainer.volumes.contains {
                $0.name == pendingMigration.bundleIdentifier
                    && connectionState(for: $0, bundleID: pendingMigration.bundleIdentifier) == .connected
            }
            if !sourceIsConnected && !isDirectoryEmptyOrMissing(dataPath) {
                if pendingMigration.overwriteExisting {
                    restore(overwriteLocalData: true)
                } else {
                    activeDialog = .confirmLocalOverwrite(pendingMigration)
                }
            } else {
                restore()
            }

        case (.container, .container(let targetID)):
            guard let target = containers.first(where: { $0.id == targetID }) else {
                activeDialog = .message(title: "Drive Not Available", message: "The target external drive is no longer connected.")
                abortQueuedMigrationBeforeStart(
                    bundleID: pendingMigration.bundleIdentifier,
                    message: "The target external drive is no longer connected."
                )
                return
            }
            if target.volumes.contains(where: { $0.name == pendingMigration.bundleIdentifier }) {
                if pendingMigration.overwriteExisting {
                    startExternalToExternalMigration(pendingMigration, overwrite: true)
                } else {
                    activeDialog = .confirmExternalOverwrite(pendingMigration)
                }
            } else {
                startExternalToExternalMigration(pendingMigration, overwrite: false)
            }

        case (.local, .local):
            break
        }
    }

    func disconnectAppData() {
        guard let bundleID = bundleIdentifier,
              !isAppOperationRunning(bundleID: bundleID),
              let volume = containers.flatMap(\.volumes).first(where: {
                  $0.name == bundleID && connectionState(for: $0, bundleID: bundleID) == .connected
              }) else { return }
        let dataPath = localDataPath(for: bundleID)
        MigrationTrace.event(
            "disconnect.begin",
            bundleID: bundleID,
            details: "path=\(dataPath.path) device=\(volume.bsdDevice ?? "unknown")"
        )
        setAppOperation(
            bundleID: bundleID,
            operation: .reconnecting,
            message: "Disconnecting \(bundleID) from external storage…"
        )
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshExternalVolumes() }
            do {
                try await self.runPrivileged { try $0.unmount(byMountPoint: dataPath) }
                if let device = volume.bsdDevice {
                    self.updateMountPoint(for: device, to: nil)
                }
                self.setAppOperation(
                    bundleID: bundleID,
                    operation: .succeeded,
                    message: "\(bundleID) was disconnected. Its external data was not deleted."
                )
                self.clearAppError(bundleID: bundleID, after: "disconnect")
                MigrationTrace.event("disconnect.succeeded", bundleID: bundleID)
            } catch {
                self.setAppOperation(
                    bundleID: bundleID,
                    operation: .failed,
                    message: error.localizedDescription
                )
                self.migrationErrors[bundleID] = error.localizedDescription
                MigrationTrace.event(
                    "disconnect.failed",
                    bundleID: bundleID,
                    details: "error=\(error.localizedDescription)"
                )
            }
        }
    }


    func requestOpenSelectedApp() {
        guard let applicationURL,
              FileManager.default.fileExists(atPath: applicationURL.path) else {
            activeDialog = .message(title: "App Not Found", message: "Locate or add the app again before opening it.")
            return
        }

        guard let bundleID = bundleIdentifier,
              let container = containers.first(where: {
                  $0.volumes.contains { $0.name == bundleID }
              }),
              let volume = container.volumes.first(where: { $0.name == bundleID }) else {
            openApplication(at: applicationURL)
            return
        }
        if connectionState(for: volume, bundleID: bundleID) == .connected {
            openApplication(at: applicationURL)
            return
        }
        guard !isAppOperationRunning(bundleID: bundleID) else { return }
        activeDialog = .confirmConnectAndOpen(
            appName: applicationName ?? bundleID,
            containerID: container.id
        )
    }

    func openAppData(for app: ManagedApp) {
        let containerURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(app.bundleIdentifier, isDirectory: true)
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            activeDialog = .message(
                title: "App Data Not Found",
                message: "No container exists at \(containerURL.path). Launch the App once, then try again."
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([containerURL])
    }

    func showAppInFinder(_ app: ManagedApp) {
        let applicationURL = app.applicationURL
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            activeDialog = .message(
                title: "App Not Found",
                message: "The recorded App no longer exists at \(applicationURL.path)."
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
    }

    func confirmConnectAndOpen(containerID: UUID) {
        if let bundleID = bundleIdentifier, isAppOperationRunning(bundleID: bundleID) { return }
        guard let applicationURL,
              let container = containers.first(where: { $0.id == containerID }) else {
            activeDialog = .message(title: "Drive Not Available", message: "The App or its external drive is no longer available.")
            return
        }
        pendingOpenAfterConnectURL = applicationURL
        selectContainer(container)
        requestReconnectAppData()
    }

    func cancelPendingOpenAfterConnect() {
        pendingOpenAfterConnectURL = nil
    }

    private func openPendingAppIfNeeded() {
        guard let url = pendingOpenAfterConnectURL else { return }
        pendingOpenAfterConnectURL = nil
        openApplication(at: url)
    }

    private func openApplication(at applicationURL: URL) {
        let openedBundleID = Bundle(url: applicationURL)?.bundleIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true
        configuration.environment = sanitizedLaunchEnvironment()
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let error {
                    if let openedBundleID {
                        self.migrationErrors[openedBundleID] = error.localizedDescription
                    }
                    self.activeDialog = .message(
                        title: "App Could Not Open",
                        message: error.localizedDescription
                    )
                } else if let openedBundleID {
                    self.clearAppError(bundleID: openedBundleID, after: "open")
                }
            }
        }
    }

    private func sanitizedLaunchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let debuggingPrefixes = ["DYLD_", "__XPC_DYLD_", "XCODE_", "XCInjectBundle", "MTL_"]
        for key in environment.keys where debuggingPrefixes.contains(where: { key.hasPrefix($0) }) {
            environment.removeValue(forKey: key)
        }
        // Explicitly override the variable responsible for Xcode's View Debugger injection.
        environment["DYLD_INSERT_LIBRARIES"] = ""
        return environment
    }

    private func restoreManagedApps() {
        // The legacy single-App key would otherwise resurrect the last session-only drop
        // every time the new persistent registry is empty.
        UserDefaults.standard.removeObject(forKey: Self.lastAppPathKey)
        let saved = appStore.load()
        if !saved.isEmpty {
            managedApps = saved
            persistManagedApps()
        }
        // Launch into the All Apps overview. Individual Apps are selected only after an
        // explicit click or drop, so the initial status bar shows the library summary.
        selectedAppBundleID = nil
    }

    private func managedAppRecord(from url: URL) -> ManagedApp? {
        guard let appBundle = Bundle(url: url) else { return nil }
        let bundleID = appBundle.bundleIdentifier
            ?? appBundle.object(forInfoDictionaryKey: kCFBundleIdentifierKey as String) as? String
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let displayName = appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? appBundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let persistence = managedApps.first(where: { $0.bundleIdentifier == bundleID })?.persistence
            ?? (containers.flatMap(\.volumes).contains { $0.name == bundleID } ? .managed : .sessionOnly)
        return ManagedApp(
            bundleIdentifier: bundleID,
            name: displayName,
            applicationPath: url.path,
            persistence: persistence
        )
    }

    private func persistManagedApps() {
        appStore.save(managedApps)
    }

    private func discoverManagedApps(matching containers: [ExternalAPFSContainer]) async {
        let bundleIDPattern = try? NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#)
        let volumeNames = Set(containers.flatMap(\.volumes).map(\.name))
        var changed = false

        for bundleID in volumeNames.sorted() {
            let range = NSRange(bundleID.startIndex..., in: bundleID)
            // Apple bundle identifiers are reverse-DNS style. Requiring a dot prevents ordinary
            // Volume names such as "990EVO" from causing a slow, unsuccessful Launch Services
            // lookup after every disk refresh.
            guard bundleID.contains("."),
                  bundleIDPattern?.firstMatch(in: bundleID, range: range) != nil else { continue }

            // Refreshes run after every migration. Avoid asking Launch Services to locate and
            // reopen every already-known App bundle on the main actor; that synchronous work
            // can briefly delay a sidebar click immediately after a migration completes.
            if let index = managedApps.firstIndex(where: { $0.bundleIdentifier == bundleID }),
               isInstalledApp(managedApps[index]) {
                if managedApps[index].persistence != .managed {
                    managedApps[index].persistence = .managed
                    changed = true
                }
                continue
            }

            let discoveredMetadata = await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                guard let appURL = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
                    .first(where: { candidate in
                        fileManager.fileExists(atPath: candidate.path)
                            && Bundle(url: candidate)?.bundleIdentifier == bundleID
                    }) else { return (path: Optional<String>.none, name: Optional<String>.none) }
                let bundle = Bundle(url: appURL)
                let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                return (path: Optional(appURL.path), name: name)
            }.value
            let appPath = discoveredMetadata.path
            let displayName = discoveredMetadata.name
                ?? managedApps.first(where: { $0.bundleIdentifier == bundleID })?.name
                ?? bundleID
            let discovered = ManagedApp(
                bundleIdentifier: bundleID,
                name: displayName,
                applicationPath: appPath ?? "",
                persistence: .managed
            )

            if let index = managedApps.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
                let existing = managedApps[index]
                let updated = ManagedApp(
                    bundleIdentifier: bundleID,
                    name: appPath == nil ? existing.name : displayName,
                    applicationPath: appPath ?? existing.applicationPath,
                    persistence: .managed
                )
                if updated != existing {
                    managedApps[index] = updated
                    changed = true
                }
            } else {
                managedApps.append(discovered)
                changed = true
            }
        }

        if changed {
            persistManagedApps()
        }
    }

    private func markAppManaged(bundleID: String) {
        guard let index = managedApps.firstIndex(where: { $0.bundleIdentifier == bundleID }) else { return }
        managedApps[index].persistence = .managed
        persistManagedApps()
    }

    private func validateMigrationInputs(updatesMigrationScheduler: Bool = true) -> Bool {
        func fail(_ message: String) -> Bool {
            if !updatesMigrationScheduler, let bundleID = bundleIdentifier {
                setAppOperation(bundleID: bundleID, operation: .failed, message: message)
            } else {
                operation = .failed
                operationMessage = message
            }
            return false
        }
        guard bundleIdentifier != nil, applicationName != nil else {
            return fail("Drop a valid .app with a Bundle ID first.")
        }
        guard let _ = containers.first(where: { $0.id == selectedContainerID }) else {
            return fail("Select an external APFS SSD first.")
        }
        guard let applicationURL,
              FileManager.default.fileExists(atPath: applicationURL.path) else {
            return fail("Locate or install the matching app before changing its data location.")
        }

        return true
    }

    func requestMigration() {
        guard validateMigrationInputs(), let bundleID = bundleIdentifier else { return }

        if containers.flatMap(\.volumes).contains(where: {
            connectionState(for: $0, bundleID: bundleID) == .connected
        }) {
            activeDialog = .message(
                title: "App Data Already Connected",
                message: "The matching external volume is already mounted at this app's Data directory. There is nothing to migrate."
            )
            return
        }

        if let match = containers.lazy.compactMap({ container -> MigrationReconnectChoice? in
            guard let volume = container.volumes.first(where: {
                $0.name == bundleID
                    && $0.bsdDevice != nil
                    && connectionState(for: $0, bundleID: bundleID) == .disconnected
            }), let device = volume.bsdDevice else { return nil }
            return MigrationReconnectChoice(
                containerID: container.id,
                diskName: container.displayName ?? container.containerReference,
                volumeName: bundleID,
                device: device,
                mountPoint: volume.mountPoint
            )
        }).first {
            migrationReconnectChoice = match
            return
        }

        startMigration()
    }

    func reconnectFromMigrationChoice(_ choice: MigrationReconnectChoice) {
        guard let container = containers.first(where: { $0.id == choice.containerID }) else {
            refreshExternalVolumes()
            operation = .failed
            operationMessage = "The external disk changed. Select it again and retry reconnecting."
            return
        }
        selectContainer(container)
        requestReconnectAppData()
    }

    func startMigration(replacing existingVolume: MigrationReconnectChoice? = nil) {
        guard validateMigrationInputs(), let bundleID = bundleIdentifier,
              let selected = containers.first(where: { $0.id == selectedContainerID }) else { return }

        let dataPath = localDataPath(for: bundleID)
        let backupPath = dataPath.deletingLastPathComponent().appendingPathComponent("Data.backup", isDirectory: true)
        let dataExists = FileManager.default.fileExists(atPath: dataPath.path)
        let backupExists = FileManager.default.fileExists(atPath: backupPath.path)
        guard dataExists || (existingVolume != nil && backupExists) else {
            operation = .failed
            operationMessage = "No local Data directory exists for \(bundleID). Launch the app once, then try again."
            return
        }
        guard existingVolume != nil || !backupExists else {
            operation = .failed
            operationMessage = "Data.backup already exists. Restore or remove that backup before migrating again."
            return
        }
        let selectedMatches = selected.volumes.filter { $0.name == bundleID }
        guard selectedMatches.isEmpty
                || (selectedMatches.count == 1 && selectedMatches.first?.bsdDevice == existingVolume?.device) else {
            operation = .failed
            operationMessage = "The selected SSD already contains a volume named \(bundleID). Reconnect it, or select a different SSD for a new migration."
            return
        }

        MigrationTrace.event("local-to-external.start", bundleID: bundleID, details: "target=\(selected.id) replacing=\(existingVolume != nil)")
        archiveFinishedMigration()
        activeMigration = MigrationPresentation(
            batchID: currentMigrationBatchID ?? UUID(),
            bundleIdentifier: bundleID,
            source: .local,
            target: .container(selected.id),
            targetContainerID: selected.id
        )
        migrationStagesCompleted = []
        operation = .migrating
        operationProgress = 0
        operationMessage = "Preparing the selected APFS container…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshExternalVolumes() }
            var createdVolume: CreatedAPFSVolume?
            var localDataRenamed = false
            do {
                self.operationMessage = "Checking source size and target free space…"
                let requiredBytes = try await Task.detached(priority: .utility) {
                    try Self.allocatedSize(of: dataPath)
                }.value
                let replacedBytes = existingVolume.flatMap { existing in
                    selected.volumes.first(where: { $0.bsdDevice == existing.device })?.usedBytes
                } ?? 0
                try await self.ensureSufficientSpace(
                    requiredBytes: requiredBytes,
                    availableBytes: await self.freshAvailableCapacity(for: selected.id).map { $0 + replacedBytes },
                    destinationName: selected.displayName ?? "the target SSD"
                )
                MigrationTrace.event(
                    "migration.command-log.begin",
                    bundleID: bundleID,
                    details: "operation=\(self.activeMigration?.id.uuidString ?? "unknown") route=local-to-external"
                )
                let logURL = try OperationLog.prepare(named: "migrate")
                try await self.runPrivileged { try $0.beginOperationLog(at: logURL) }
                try await self.runPrivileged { try $0.ensureHelperAvailable() }

                if let existingVolume {
                    self.operationMessage = "Removing the existing \(bundleID) volume before migration…"
                    if let mountPoint = self.usableMountPoint(existingVolume.mountPoint) {
                        try await self.runPrivileged {
                            try $0.unmount(byMountPoint: URL(fileURLWithPath: mountPoint))
                        }
                    }
                    try await self.runPrivileged {
                        try $0.deleteAPFSVolume(byDevice: existingVolume.device)
                    }
                    self.removeVolume(device: existingVolume.device)

                    if FileManager.default.fileExists(atPath: backupPath.path) {
                        if self.isDirectoryEmptyOrMissing(dataPath) {
                            if FileManager.default.fileExists(atPath: dataPath.path) {
                                try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                            }
                            try await self.runPrivileged {
                                try $0.renameItem(from: backupPath, to: dataPath)
                            }
                        } else {
                            try await self.runPrivileged { try $0.deleteItem(at: backupPath) }
                        }
                    }
                }

                self.migrationStagesCompleted.insert(.apfsContainerIdentified)
                self.operationProgress = 0.12
                self.operationMessage = "Creating a dedicated volume for \(bundleID)…"

                let created = try await self.runPrivileged {
                    try $0.createAPFSVolume(containerRef: selected.containerReference, name: bundleID)
                }
                self.migrationStagesCompleted.insert(.applicationVolumeCreated)
                self.operationProgress = 0.28
                self.operationMessage = "Copying app data to the external volume…"

                let volumeRoot = self.temporaryVolumeMountPoint(for: created.bsdDevice)
                createdVolume = CreatedAPFSVolume(bsdDevice: created.bsdDevice, mountPoint: volumeRoot)
                self.migrationStagesCompleted.insert(.temporaryUnmount)
                self.operationProgress = 0.36
                self.operationMessage = "Testing access to the app Data mount point before copying…"

                try await self.runPrivileged { try $0.renameItem(from: dataPath, to: backupPath) }
                localDataRenamed = true
                self.migrationStagesCompleted.insert(.localBackupCreated)
                self.migrationStagesCompleted.insert(.mountPointPrepared)

                self.operationProgress = 0.48
                self.operationMessage = "Copying app data to the external volume…"
                try await self.runPrivileged {
                    try $0.mountAPFS(byDevice: created.bsdDevice, at: volumeRoot, options: ["noowners", "nobrowse"])
                }
                try await self.copyAsCurrentUser(from: backupPath, to: volumeRoot, logURL: logURL)
                self.operationMessage = "Verifying the copied app data…"
                try await self.verifyCopy(from: backupPath, to: volumeRoot)
                self.migrationStagesCompleted.insert(.dataCopied)
                self.migrationStagesCompleted.insert(.copyVerified)

                self.operationProgress = 0.9
                self.operationMessage = "Data copy completed. Leaving the external volume disconnected…"
                try await self.runPrivileged { try $0.unmount(byMountPoint: volumeRoot) }
                try? await self.runPrivileged { try $0.deleteItem(at: volumeRoot) }

                self.addOrUpdateVolume(
                    containerID: selected.id,
                    volume: ExternalVolume(
                        name: bundleID,
                        mountPoint: nil,
                        bsdDevice: created.bsdDevice,
                        availableBytes: nil,
                        usedBytes: nil
                    )
                )

                // Data.backup is transactional rollback state, not a permanent second copy.
                try await self.runPrivileged { try $0.deleteItem(at: backupPath) }
                self.operation = .succeeded
                self.operationProgress = 1
                self.operationMessage = "App data is now stored on the external APFS volume and remains disconnected."
                self.markAppManaged(bundleID: bundleID)
                self.finishQueuedMigrationIfNeeded()
            } catch {
                MigrationTrace.event("local-to-external.failed", bundleID: bundleID, details: "error=\(error.localizedDescription)")
                let migrationError = error
                var rollbackSucceeded = true
                if localDataRenamed {
                    try? await self.runPrivileged { try $0.unmount(byMountPoint: dataPath) }
                    if let volumeRoot = createdVolume?.mountPoint {
                        try? await self.runPrivileged { try $0.unmount(byMountPoint: volumeRoot) }
                        try? await self.runPrivileged { try $0.deleteItem(at: volumeRoot) }
                    }
                    if FileManager.default.fileExists(atPath: dataPath.path) {
                        if self.isDirectoryEmptyOrMissing(dataPath) {
                            do {
                                try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                            } catch {
                                rollbackSucceeded = false
                            }
                        } else {
                            rollbackSucceeded = false
                        }
                    }
                    if FileManager.default.fileExists(atPath: backupPath.path) {
                        do {
                            try await self.runPrivileged { try $0.renameItem(from: backupPath, to: dataPath) }
                        } catch {
                            rollbackSucceeded = false
                        }
                    }
                }
                if let createdVolume {
                    do {
                        try await self.runPrivileged { try $0.deleteAPFSVolume(byDevice: createdVolume.bsdDevice) }
                    } catch {
                        rollbackSucceeded = false
                    }
                }
                self.operation = .failed
                self.operationProgress = nil
                if !rollbackSucceeded {
                    self.operationMessage = "Migration failed and rollback could not be fully verified. Do not retry until the migration log is reviewed. Original error: \(migrationError.localizedDescription)"
                } else {
                    self.operationMessage = migrationError.localizedDescription
                }
                self.presentInsufficientSpaceAlertIfNeeded(migrationError)
                self.finishQueuedMigrationIfNeeded()
            }
        }
    }

    func requestReconnectAppData() {
        guard let bundleID = bundleIdentifier else { return }
        guard !isAppOperationRunning(bundleID: bundleID) else { return }
        let dataPath = localDataPath(for: bundleID)
        guard isDirectoryEmptyOrMissing(dataPath) else {
            connectionConflict = ConnectionConflict(bundleIdentifier: bundleID)
            return
        }
        reconnectAppData()
    }

    func reconnectAppData(localDataPolicy: LocalDataConnectionPolicy = .requireEmpty) {
        guard validateMigrationInputs(updatesMigrationScheduler: false), let bundleID = bundleIdentifier,
              let selected = containers.first(where: { $0.id == selectedContainerID }) else { return }
        guard !isAppOperationRunning(bundleID: bundleID) else { return }

        setAppOperation(
            bundleID: bundleID,
            operation: .reconnecting,
            message: "Looking for \(bundleID) on \(selected.displayName ?? selected.containerReference)…"
        )

        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshExternalVolumes() }
            var mountAttempted = false
            var localDataWillBeHidden = false
            do {
                let logURL = try OperationLog.prepare(named: "reconnect")
                try await self.runPrivileged { try $0.beginOperationLog(at: logURL) }
                let matches = selected.volumes.filter { $0.name == bundleID && $0.bsdDevice != nil }
                guard matches.count <= 1 else {
                    throw NSError(domain: "Reconnect", code: 2, userInfo: [NSLocalizedDescriptionKey: "More than one volume named \(bundleID) exists on the selected SSD."])
                }
                guard let match = matches.first, let device = match.bsdDevice else {
                    throw NSError(domain: "Reconnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "No volume named \(bundleID) was found on the selected SSD."])
                }

                let dataPath = self.localDataPath(for: bundleID)
                if connectionState(for: match, bundleID: bundleID) == .connected {
                    self.setAppOperation(
                        bundleID: bundleID,
                        operation: .succeeded,
                        message: "\(bundleID) is already connected."
                    )
                    self.clearAppError(bundleID: bundleID, after: "connect")
                    self.markAppManaged(bundleID: bundleID)
                    self.openPendingAppIfNeeded()
                    return
                }
                if let currentMount = self.usableMountPoint(match.mountPoint) {
                    try await self.runPrivileged {
                        try $0.unmount(byMountPoint: URL(fileURLWithPath: currentMount))
                    }
                }
                localDataWillBeHidden = !self.isDirectoryEmptyOrMissing(dataPath)
                if localDataWillBeHidden && localDataPolicy == .requireEmpty {
                    self.setAppOperation(bundleID: bundleID, operation: .idle, message: "Ready")
                    self.connectionConflict = ConnectionConflict(bundleIdentifier: bundleID)
                    return
                }
                if localDataWillBeHidden && localDataPolicy == .remove {
                    self.setAppOperation(
                        bundleID: bundleID,
                        operation: .reconnecting,
                        message: "Removing the local Data directory before connecting…"
                    )
                    try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                    localDataWillBeHidden = false
                } else if localDataWillBeHidden {
                    self.setAppOperation(
                        bundleID: bundleID,
                        operation: .reconnecting,
                        message: "The local Data directory is not empty. Reconnecting will temporarily hide its contents without deleting them…"
                    )
                }
                mountAttempted = true
                try await self.runPrivileged {
                    try $0.mountAPFS(byDevice: device, at: dataPath, options: ["noowners", "nobrowse"])
                }
                self.updateMountPoint(for: device, to: dataPath.path)
                self.clearAppError(bundleID: bundleID, after: "connect")
                self.markAppManaged(bundleID: bundleID)
                self.setAppOperation(
                    bundleID: bundleID,
                    operation: .succeeded,
                    message: localDataWillBeHidden
                        ? "\(bundleID) is connected. Existing local Data is temporarily hidden and was not deleted."
                        : "\(bundleID) is connected to \(dataPath.path)."
                )
                self.openPendingAppIfNeeded()
                if localDataWillBeHidden {
                    self.activeDialog = .message(
                        title: "Local Data Temporarily Hidden",
                        message: "The external volume is connected successfully. The existing local Data directory was not deleted, but its contents are hidden while the external volume is mounted. They will become visible again after the volume is unmounted."
                    )
                }
            } catch {
                self.pendingOpenAfterConnectURL = nil
                if mountAttempted {
                    self.setAppOperation(
                        bundleID: bundleID,
                        operation: .failed,
                        message: "Reconnect could not mount the external volume. No local backup was modified. Enable Full Disk Access, then try again."
                    )
                    self.activeDialog = .localDataMountFailed(error: error.localizedDescription)
                } else {
                    self.setAppOperation(
                        bundleID: bundleID,
                        operation: .failed,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    func requestRestore() {
        guard !operation.isRunning else { return }
        guard validateMigrationInputs() else { return }
        activeDialog = .confirmRestore
    }

    func restore(overwriteLocalData: Bool = false) {
        guard !operation.isRunning else { return }
        guard validateMigrationInputs(), let bundleID = bundleIdentifier else { return }
        if let selectedContainerID {
            archiveFinishedMigration()
            activeMigration = MigrationPresentation(
                batchID: currentMigrationBatchID ?? UUID(),
                bundleIdentifier: bundleID,
                source: .container(selectedContainerID),
                target: .local,
                targetContainerID: selectedContainerID
            )
        }
        operation = .restoring
        operationProgress = nil
        operationMessage = "Preparing to restore local app data…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshExternalVolumes() }
            var localDataMountFailed = false
            do {
                self.operationMessage = "Checking source size and local free space…"
                let sourceVolume = self.containers
                    .flatMap(\.volumes)
                    .first(where: { $0.name == bundleID })
                let requiredBytes: Int64?
                if let usedBytes = sourceVolume?.usedBytes {
                    requiredBytes = usedBytes
                } else if let mountPoint = self.usableMountPoint(sourceVolume?.mountPoint) {
                    requiredBytes = try? await Task.detached(priority: .utility) {
                        try Self.allocatedSize(of: URL(fileURLWithPath: mountPoint))
                    }.value
                } else {
                    requiredBytes = nil
                }
                guard let requiredBytes else {
                    throw self.operationError("The source data size could not be determined safely.")
                }
                try await self.ensureSufficientSpace(
                    requiredBytes: requiredBytes,
                    availableBytes: self.localAvailableCapacity(),
                    destinationName: "Local"
                )
                let logURL = try OperationLog.prepare(named: "restore")
                try await self.runPrivileged { try $0.beginOperationLog(at: logURL) }
                let dataPath = self.localDataPath(for: bundleID)
                let backupPath = dataPath.deletingLastPathComponent().appendingPathComponent("Data.backup", isDirectory: true)
                let recoveryPath = dataPath.deletingLastPathComponent().appendingPathComponent("Data.restore-in-progress", isDirectory: true)
                let overwriteBackupPath = dataPath.deletingLastPathComponent().appendingPathComponent("Data.overwrite-backup", isDirectory: true)
                let volume = try self.resolveVolume(for: bundleID)
                var mountedPath = self.usableMountPoint(volume.mountPoint).map { URL(fileURLWithPath: $0) }

                self.operationMessage = "Copying the latest data back from the external volume…"
                if mountedPath == nil {
                    if !self.isDirectoryEmptyOrMissing(dataPath) {
                        guard overwriteLocalData else {
                            throw self.operationError("The local Data directory is not empty. Cancel or explicitly overwrite it before restoring.")
                        }
                        if FileManager.default.fileExists(atPath: overwriteBackupPath.path) {
                            throw self.operationError("A previous overwrite backup still exists. Resolve it before retrying migration.")
                        }
                        try await self.runPrivileged {
                            try $0.renameItem(from: dataPath, to: overwriteBackupPath)
                        }
                    }
                    do {
                        try await self.runPrivileged {
                            try $0.mountAPFS(byDevice: volume.device, at: dataPath, options: ["noowners", "nobrowse"])
                        }
                    } catch {
                        localDataMountFailed = true
                        self.activeDialog = .localDataMountFailed(error: error.localizedDescription)
                        throw error
                    }
                    mountedPath = dataPath
                }
                if FileManager.default.fileExists(atPath: recoveryPath.path) {
                    try await self.runPrivileged { try $0.deleteItem(at: recoveryPath) }
                }
                do {
                    let sourceManifest = try await self.makeMigrationManifest(at: mountedPath!)
                    try await self.copyVolumeContentsAsCurrentUser(
                        from: mountedPath!,
                        to: recoveryPath,
                        logURL: logURL
                    )
                    self.operationMessage = "Verifying the restored app data…"
                    try await self.verifyCopy(sourceManifest: sourceManifest, destination: recoveryPath)
                } catch {
                    if FileManager.default.fileExists(atPath: recoveryPath.path) {
                        try? await self.runPrivileged { try $0.deleteItem(at: recoveryPath) }
                    }
                    throw error
                }

                if let mountedPath {
                    try await self.runPrivileged { try $0.unmount(byMountPoint: mountedPath) }
                }
                if FileManager.default.fileExists(atPath: dataPath.path) {
                    try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                }
                try await self.runPrivileged { try $0.renameItem(from: recoveryPath, to: dataPath) }
                // The local copy is complete and in its final location before source deletion.
                try await self.runPrivileged { try $0.deleteAPFSVolume(byDevice: volume.device) }
                if FileManager.default.fileExists(atPath: backupPath.path) {
                    try await self.runPrivileged { try $0.deleteItem(at: backupPath) }
                }
                if FileManager.default.fileExists(atPath: overwriteBackupPath.path) {
                    try await self.runPrivileged { try $0.deleteItem(at: overwriteBackupPath) }
                }
                self.removeVolume(device: volume.device)
                self.operation = .succeeded
                self.markAppManaged(bundleID: bundleID)
                self.operationMessage = "Local data was restored and the external app volume was removed."
                self.finishQueuedMigrationIfNeeded()
            } catch {
                let dataPath = self.localDataPath(for: bundleID)
                let recoveryPath = dataPath.deletingLastPathComponent()
                    .appendingPathComponent("Data.restore-in-progress", isDirectory: true)
                let overwriteBackupPath = dataPath.deletingLastPathComponent()
                    .appendingPathComponent("Data.overwrite-backup", isDirectory: true)
                if FileManager.default.fileExists(atPath: recoveryPath.path) {
                    try? await self.runPrivileged { try $0.deleteItem(at: recoveryPath) }
                }
                if FileManager.default.fileExists(atPath: overwriteBackupPath.path),
                   self.isDirectoryEmptyOrMissing(dataPath) {
                    if FileManager.default.fileExists(atPath: dataPath.path) {
                        try? await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                    }
                    try? await self.runPrivileged {
                        try $0.renameItem(from: overwriteBackupPath, to: dataPath)
                    }
                }
                self.operation = .failed
                self.operationMessage = localDataMountFailed
                    ? "The external volume could not be mounted at the app's local Data folder."
                    : error.localizedDescription
                self.presentInsufficientSpaceAlertIfNeeded(error)
                self.finishQueuedMigrationIfNeeded(recordFailure: !localDataMountFailed)
            }
        }
    }

    func startExternalToExternalMigration(_ pending: PendingMigration, overwrite: Bool) {
        MigrationTrace.event(
            "external-to-external.start",
            bundleID: pending.bundleIdentifier,
            details: "source=\(pending.source) target=\(pending.target) overwrite=\(overwrite)"
        )
        guard case let .container(sourceID) = pending.source,
              case let .container(targetID) = pending.target,
              let sourceContainer = containers.first(where: { $0.id == sourceID }),
              let targetContainer = containers.first(where: { $0.id == targetID }),
              let sourceVolume = sourceContainer.volumes.first(where: {
                  $0.name == pending.bundleIdentifier && $0.bsdDevice != nil
              }),
              let sourceDevice = sourceVolume.bsdDevice else {
            let message = "The source or target Volume is no longer available."
            activeDialog = .message(title: "Drive Not Available", message: message)
            preparingMigrations.removeAll { $0.bundleIdentifier == pending.bundleIdentifier }
            abortQueuedMigrationBeforeStart(bundleID: pending.bundleIdentifier, message: message)
            return
        }

        archiveFinishedMigration()
        activeMigration = MigrationPresentation(
            batchID: pending.batchID,
            bundleIdentifier: pending.bundleIdentifier,
            source: pending.source,
            target: pending.target,
            targetContainerID: targetID
        )
        operation = .migrating
        operationProgress = 0
        operationMessage = "Preparing drive-to-drive migration…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshExternalVolumes() }
            let dataPath = self.localDataPath(for: pending.bundleIdentifier)
            var sourceMount = self.usableMountPoint(sourceVolume.mountPoint).map(URL.init(fileURLWithPath:))
            let originalSourceMount = sourceMount
            var temporarySourceMount: URL?
            var createdTarget: CreatedAPFSVolume?
            var sourceWasUnmounted = false
            let sourceWasConnected = connectionState(
                for: sourceVolume,
                bundleID: pending.bundleIdentifier
            ) == .connected
            do {
                MigrationTrace.event("external-to-external.helper.begin", bundleID: pending.bundleIdentifier)
                MigrationTrace.event(
                    "migration.command-log.begin",
                    bundleID: pending.bundleIdentifier,
                    details: "operation=\(pending.id) batch=\(pending.batchID) route=external-to-external"
                )
                let logURL = try OperationLog.prepare(named: "migrate")
                try await self.runPrivileged { try $0.beginOperationLog(at: logURL) }
                try await self.runPrivileged { try $0.ensureHelperAvailable() }

                let replacedTarget = overwrite
                    ? targetContainer.volumes.first(where: {
                        $0.name == pending.bundleIdentifier && $0.bsdDevice != nil
                    })
                    : nil
                guard let sourceIdentity = await Task.detached(priority: .userInitiated, operation: {
                    DiskUtilDiscovery.volumeIdentity(for: sourceDevice)
                }).value else {
                    throw self.operationError("The source Volume UUID could not be read.")
                }
                MigrationTrace.event("external-to-external.source-identity.ready", bundleID: pending.bundleIdentifier, details: "device=\(sourceDevice)")
                let replacedTargetIdentity: DiskUtilDiscovery.VolumeIdentity? = if let device = replacedTarget?.bsdDevice {
                    await Task.detached(priority: .userInitiated) {
                        DiskUtilDiscovery.volumeIdentity(for: device)
                    }.value
                } else {
                    nil
                }

                if sourceMount == nil {
                    let mountPoint = self.temporaryVolumeMountPoint(for: sourceDevice)
                    try await self.runPrivileged {
                        try $0.mountAPFS(byDevice: sourceDevice, at: mountPoint, options: ["noowners", "nobrowse"])
                    }
                    temporarySourceMount = mountPoint
                    sourceMount = mountPoint
                }
                guard let sourceMount else { throw self.operationError("The source Volume could not be mounted.") }
                MigrationTrace.event("external-to-external.source-mounted", bundleID: pending.bundleIdentifier, details: "path=\(sourceMount.path)")

                self.operationMessage = "Checking source size and target free space…"
                let requiredBytes = try await Task.detached(priority: .utility) {
                    try Self.allocatedSize(of: sourceMount)
                }.value
                MigrationTrace.event("external-to-external.source-size.ready", bundleID: pending.bundleIdentifier, details: "bytes=\(requiredBytes)")
                let replacedBytes = replacedTarget?.usedBytes ?? 0
                try await self.ensureSufficientSpace(
                    requiredBytes: requiredBytes,
                    availableBytes: await self.freshAvailableCapacity(for: targetID).map { $0 + replacedBytes },
                    destinationName: targetContainer.displayName ?? "the target SSD"
                )

                let target = try await self.runPrivileged {
                    try $0.createAPFSVolume(
                        containerRef: targetContainer.containerReference,
                        name: pending.bundleIdentifier
                    )
                }
                MigrationTrace.event("external-to-external.target-created", bundleID: pending.bundleIdentifier, details: "device=\(target.bsdDevice)")
                guard let targetIdentity = await Task.detached(priority: .userInitiated, operation: {
                    DiskUtilDiscovery.volumeIdentity(for: target.bsdDevice)
                }).value else {
                    throw self.operationError("The new target Volume UUID could not be read.")
                }
                self.activeMigration?.targetVolumeUUID = targetIdentity.volumeUUID
                let targetMount = self.temporaryVolumeMountPoint(for: target.bsdDevice)
                createdTarget = CreatedAPFSVolume(bsdDevice: target.bsdDevice, mountPoint: targetMount)
                try await self.runPrivileged {
                    try $0.mountAPFS(byDevice: target.bsdDevice, at: targetMount, options: ["noowners", "nobrowse"])
                }
                self.operationProgress = 0.2
                self.operationMessage = "Copying app data to the target SSD…"
                let sourceManifest = try await self.makeMigrationManifest(at: sourceMount)
                try await self.copyVolumeContentsAsCurrentUser(from: sourceMount, to: targetMount, logURL: logURL)
                MigrationTrace.event("external-to-external.copy.completed", bundleID: pending.bundleIdentifier)
                self.operationProgress = 0.72
                self.operationMessage = "Verifying the target SSD copy…"
                try await self.verifyCopy(sourceManifest: sourceManifest, destination: targetMount)
                MigrationTrace.event("external-to-external.verify.completed", bundleID: pending.bundleIdentifier)

                try await self.runPrivileged { try $0.unmount(byMountPoint: sourceMount) }
                sourceWasUnmounted = true
                if let temporarySourceMount {
                    try? await self.runPrivileged { try $0.deleteItem(at: temporarySourceMount) }
                }
                try await self.runPrivileged { try $0.unmount(byMountPoint: targetMount) }
                try? await self.runPrivileged { try $0.deleteItem(at: targetMount) }
                var targetMountPoint: String?
                var connectionWarning: String?
                if sourceWasConnected {
                    if let replacedMount = self.usableMountPoint(replacedTarget?.mountPoint) {
                        try? await self.runPrivileged {
                            try $0.unmount(byMountPoint: URL(fileURLWithPath: replacedMount))
                        }
                    }
                    if FileManager.default.fileExists(atPath: dataPath.path), self.isDirectoryEmptyOrMissing(dataPath) {
                        try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                    }
                    do {
                        try await self.runPrivileged {
                            try $0.mountAPFS(byDevice: target.bsdDevice, at: dataPath, options: ["noowners", "nobrowse"])
                        }
                        try await self.verifyMountedVolume(
                            device: target.bsdDevice,
                            expectedPath: dataPath,
                            expectedContainerReference: targetContainer.containerReference
                        )
                        targetMountPoint = dataPath.path
                    } catch {
                        connectionWarning = error.localizedDescription
                        self.activeDialog = .localDataMountFailed(error: error.localizedDescription)
                        try? await self.runPrivileged { try $0.unmount(byMountPoint: dataPath) }
                    }
                }
                // Publish the verified target immediately. A full diskutil refresh still runs
                // afterward to reconcile capacity and mount metadata, but the destination page
                // must not briefly become empty when the migration placeholder disappears.
                self.addOrUpdateVolume(
                    containerID: targetContainer.id,
                    volume: ExternalVolume(
                        name: pending.bundleIdentifier,
                        mountPoint: targetMountPoint,
                        bsdDevice: target.bsdDevice,
                        volumeUUID: targetIdentity.volumeUUID,
                        availableBytes: nil,
                        usedBytes: requiredBytes
                    )
                )
                self.operationProgress = 0.95
                var cleanupWarnings: [String] = []
                if let replacedTargetDevice = replacedTarget?.bsdDevice {
                    if let replacedMount = self.usableMountPoint(replacedTarget?.mountPoint) {
                        try? await self.runPrivileged {
                            try $0.unmount(byMountPoint: URL(fileURLWithPath: replacedMount))
                        }
                    }
                    do {
                        guard let replacedTargetIdentity else {
                            throw self.operationError("The replaced target Volume UUID could not be verified.")
                        }
                        try await self.deleteVerifiedVolume(
                            device: replacedTargetDevice,
                            expectedUUID: replacedTargetIdentity.volumeUUID,
                            expectedContainerReference: targetContainer.containerReference
                        )
                        self.removeVolume(device: replacedTargetDevice)
                    } catch {
                        cleanupWarnings.append("the replaced target copy")
                    }
                }
                do {
                    try await self.deleteVerifiedVolume(
                        device: sourceDevice,
                        expectedUUID: sourceIdentity.volumeUUID,
                        expectedContainerReference: sourceContainer.containerReference
                    )
                    self.removeVolume(device: sourceDevice)
                } catch {
                    cleanupWarnings.append("the source copy")
                }
                self.operation = .succeeded
                self.operationProgress = 1
                if let connectionWarning {
                    self.operationMessage = "App data was migrated correctly, but reconnecting failed. It remains disconnected: \(connectionWarning)"
                } else if cleanupWarnings.isEmpty {
                    self.operationMessage = "App data was migrated to the target SSD."
                } else {
                    self.operationMessage = "App data was migrated, but cleanup could not remove \(cleanupWarnings.joined(separator: " and "))."
                }
                self.finishQueuedMigrationIfNeeded()
            } catch {
                MigrationTrace.event("external-to-external.failed", bundleID: pending.bundleIdentifier, details: "error=\(error.localizedDescription)")
                if let temporarySourceMount {
                    try? await self.runPrivileged { try $0.unmount(byMountPoint: temporarySourceMount) }
                    try? await self.runPrivileged { try $0.deleteItem(at: temporarySourceMount) }
                }
                if let createdTarget {
                    try? await self.runPrivileged { try $0.unmount(byMountPoint: dataPath) }
                    if let targetMount = createdTarget.mountPoint {
                        try? await self.runPrivileged { try $0.unmount(byMountPoint: targetMount) }
                        try? await self.runPrivileged { try $0.deleteItem(at: targetMount) }
                    }
                    if let expectedUUID = self.activeMigration?.targetVolumeUUID {
                        try? await self.deleteVerifiedVolume(
                            device: createdTarget.bsdDevice,
                            expectedUUID: expectedUUID,
                            expectedContainerReference: targetContainer.containerReference
                        )
                    }
                }
                if sourceWasUnmounted, let originalSourceMount {
                    try? await self.runPrivileged {
                        try $0.mountAPFS(byDevice: sourceDevice, at: originalSourceMount, options: ["noowners", "nobrowse"])
                    }
                }
                self.operation = .failed
                self.operationProgress = nil
                self.operationMessage = error.localizedDescription
                self.presentInsufficientSpaceAlertIfNeeded(error)
                self.finishQueuedMigrationIfNeeded()
            }
        }
    }

    private func localDataPath(for bundleID: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    private func ensureLocalDataDirectory(for bundleID: String) throws {
        let dataPath = localDataPath(for: bundleID)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dataPath.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw operationError("The App Data path exists but is not a directory: \(dataPath.path)")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: dataPath,
                withIntermediateDirectories: true
            )
        } catch {
            throw operationError("Could not create \(bundleID)/Data: \(error.localizedDescription)")
        }
    }

    nonisolated private static func allocatedSize(of root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .isDirectoryKey]
        let fileManager = FileManager.default
        var total = Int64((try? root.resourceValues(forKeys: keys).fileAllocatedSize) ?? 0)
        let rootItems = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).filter { !VolumeMetadataPolicy.isExcludedRootItem($0) }
        for rootItem in rootItems {
            let rootValues = try rootItem.resourceValues(forKeys: keys)
            total += Int64(rootValues.fileAllocatedSize ?? 0)
            guard rootValues.isDirectory == true else { continue }
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: rootItem,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw NSError(domain: "DataSize", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not inspect \(rootItem.path)."])
            }
            for case let item as URL in enumerator {
                total += Int64(try item.resourceValues(forKeys: keys).fileAllocatedSize ?? 0)
            }
            if let enumerationError { throw enumerationError }
        }
        return total
    }

    private func resolveVolume(for bundleID: String) throws -> (device: String, mountPoint: String?) {
        guard let selected = containers.first(where: { $0.id == selectedContainerID }) else {
            throw NSError(domain: "Restore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select the SSD containing the migrated volume."])
        }
        let matches = selected.volumes.filter { $0.name == bundleID && $0.bsdDevice != nil }
        if matches.count > 1 {
            throw NSError(domain: "Restore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Multiple matching volumes were found on the selected SSD."])
        }
        if let match = matches.first, let device = match.bsdDevice {
            return (device, match.mountPoint)
        }
        throw NSError(domain: "Restore", code: 3, userInfo: [NSLocalizedDescriptionKey: "No migrated volume named \(bundleID) was found on the selected SSD."])
    }

    private func runPrivileged<T: Sendable>(
        _ operation: @escaping @Sendable (XPCPrivilegedClient) throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try operation(self.privilegedClient)
        }.value
    }

    private func temporaryVolumeMountPoint(for device: String) -> URL {
        // BSD slice identifiers are reused after a temporary APFS volume is
        // deleted. A deterministic mount path can therefore collide with a
        // directory left behind by an interrupted or failed migration.
        // Give every mount attempt its own path; rollback already removes it.
        URL(
            fileURLWithPath: "/Volumes/.PlayCover-ExStorage-\(device)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func localAvailableCapacity() -> Int64? {
        guard let bytes = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity else { return nil }
        return Int64(bytes)
    }

    private func freshAvailableCapacity(for containerID: UUID) async -> Int64? {
        MigrationTrace.event("capacity.refresh.begin", details: "container=\(containerID)")
        let capacity = await Task.detached(priority: .utility) {
            DiskUtilDiscovery.containerFreeCapacitySnapshots()[containerID]
        }.value
        MigrationTrace.event(
            "capacity.refresh.end",
            details: "container=\(containerID) bytes=\(capacity.map(String.init) ?? "nil")"
        )
        return capacity
    }

    private func preflightMigration(_ pending: PendingMigration) async throws {
        let requiredBytes: Int64
        switch pending.source {
        case .local:
            let dataPath = localDataPath(for: pending.bundleIdentifier)
            requiredBytes = try await Task.detached(priority: .utility) {
                try Self.allocatedSize(of: dataPath)
            }.value
        case .container(let sourceID):
            guard let sourceContainer = containers.first(where: { $0.id == sourceID }),
                  let sourceVolume = sourceContainer.volumes.first(where: {
                      $0.name == pending.bundleIdentifier
                  }) else {
                throw operationError("The source app Volume is no longer available.")
            }
            if let usedBytes = sourceVolume.usedBytes {
                requiredBytes = usedBytes
            } else if let mountPoint = usableMountPoint(sourceVolume.mountPoint) {
                requiredBytes = try await Task.detached(priority: .utility) {
                    try Self.allocatedSize(of: URL(fileURLWithPath: mountPoint))
                }.value
            } else {
                throw operationError("The source data size could not be determined safely.")
            }
        }

        switch pending.target {
        case .local:
            try await ensureSufficientSpace(
                requiredBytes: requiredBytes,
                availableBytes: localAvailableCapacity(),
                destinationName: "Local"
            )
        case .container(let targetID):
            guard let targetContainer = containers.first(where: { $0.id == targetID }) else {
                throw operationError("The target drive is no longer available.")
            }
            let replaceableBytes = targetContainer.volumes.first(where: {
                $0.name == pending.bundleIdentifier
            })?.usedBytes ?? 0
            try await ensureSufficientSpace(
                requiredBytes: requiredBytes,
                availableBytes: await freshAvailableCapacity(for: targetID).map { $0 + replaceableBytes },
                destinationName: targetContainer.displayName ?? "the target SSD"
            )
        }
    }

    private func ensureSufficientSpace(
        requiredBytes: Int64,
        availableBytes: Int64?,
        destinationName: String
    ) async throws {
        guard let availableBytes else {
            throw operationError("The available space on \(destinationName) could not be determined safely.")
        }
        let safetyMargin = max(Int64(2_000_000_000), requiredBytes / 20)
        let requiredWithMargin = requiredBytes + safetyMargin
        guard availableBytes >= requiredWithMargin else {
            throw NSError(
                domain: "PlayCoverExStorage.InsufficientSpace",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Not enough space on \(destinationName). The migration needs \(StorageByteFormatter.string(requiredWithMargin)) including safety space, but only \(StorageByteFormatter.string(availableBytes)) is available."
                ]
            )
        }
    }

    private func presentInsufficientSpaceAlertIfNeeded(_ error: Error, batchID explicitBatchID: UUID? = nil) {
        let nsError = error as NSError
        guard nsError.domain == "PlayCoverExStorage.InsufficientSpace" else {
            if explicitBatchID != nil {
                activeDialog = .message(title: "Migration Cannot Start", message: nsError.localizedDescription)
            }
            return
        }
        let batchID = explicitBatchID ?? activeMigration?.batchID ?? currentMigrationBatchID ?? UUID()
        guard spaceAlertedBatchIDs.insert(batchID).inserted else { return }
        presentNativeAlert(title: "Not Enough Storage", message: nsError.localizedDescription)
    }

    private func presentNativeAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func copyAsCurrentUser(from source: URL, to destination: URL, logURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OperationLog.copyWithDitto(from: source, to: destination, logURL: logURL)
        }.value
    }

    private func copyVolumeContentsAsCurrentUser(from source: URL, to destination: URL, logURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OperationLog.copyVolumeContentsWithDitto(from: source, to: destination, logURL: logURL)
        }.value
    }

    private func verifyCopy(from source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            try MigrationVerifier.verifyCopy(from: source, to: destination)
        }.value
    }

    private func makeMigrationManifest(at source: URL) async throws -> MigrationVerifier.Manifest {
        try await Task.detached(priority: .utility) {
            try MigrationVerifier.makeManifest(at: source)
        }.value
    }

    private func verifyCopy(
        sourceManifest: MigrationVerifier.Manifest,
        destination: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            try MigrationVerifier.verifyCopy(sourceManifest: sourceManifest, destination: destination)
        }.value
    }

    private func verifyMountedVolume(
        device: String,
        expectedPath: URL,
        expectedContainerReference: String
    ) async throws {
        let matches = await Task.detached(priority: .userInitiated) {
            guard let deviceIdentity = DiskUtilDiscovery.volumeIdentity(for: device),
                  let pathIdentity = DiskUtilDiscovery.volumeIdentity(for: expectedPath.path) else {
                return false
            }
            return deviceIdentity.volumeUUID == pathIdentity.volumeUUID
                && pathIdentity.containerReference == expectedContainerReference
                && URL(fileURLWithPath: pathIdentity.mountPoint ?? "").standardizedFileURL.path
                    == expectedPath.standardizedFileURL.path
        }.value
        guard matches else {
            throw operationError("The Data path is not mounted from the expected APFS Volume UUID.")
        }
    }

    private func deleteVerifiedVolume(
        device: String,
        expectedUUID: String,
        expectedContainerReference: String
    ) async throws {
        let identity = await Task.detached(priority: .userInitiated) {
            DiskUtilDiscovery.volumeIdentity(for: device)
        }.value
        guard identity?.volumeUUID == expectedUUID,
              identity?.containerReference == expectedContainerReference else {
            throw operationError("Refusing to delete a Volume whose UUID or APFS Container changed.")
        }
        try await runPrivileged { try $0.deleteAPFSVolume(byDevice: device) }
    }

    private func moveApplicationToTrash(_ applicationURL: URL) async throws {
        guard applicationURL.pathExtension == "app" else {
            throw operationError("Refusing to trash a path that is not an App bundle.")
        }
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw operationError("The App no longer exists at its recorded path.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([applicationURL]) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func usableMountPoint(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }

    private func isDirectoryEmptyOrMissing(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty) ?? false
    }

    private func operationError(_ message: String) -> NSError {
        NSError(domain: "PlayCoverExStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func updateMountPoint(for device: String, to mountPoint: String?) {
        containers = containers.map { container in
            ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                displayName: container.displayName,
                connectionType: container.connectionType,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: container.volumes.map {
                    $0.bsdDevice == device ? $0.replacingMountPoint(mountPoint) : $0
                }
            )
        }
    }

    private func addOrUpdateVolume(containerID: ExternalAPFSContainer.ID, volume: ExternalVolume) {
        containers = containers.map { container in
            guard container.id == containerID else { return container }
            var volumes = container.volumes.filter { $0.bsdDevice != volume.bsdDevice }
            volumes.append(volume)
            return ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                displayName: container.displayName,
                connectionType: container.connectionType,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: volumes
            )
        }
    }

    private func removeVolume(device: String) {
        containers = containers.map { container in
            ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                displayName: container.displayName,
                connectionType: container.connectionType,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: container.volumes.filter { $0.bsdDevice != device }
            )
        }
    }
}
