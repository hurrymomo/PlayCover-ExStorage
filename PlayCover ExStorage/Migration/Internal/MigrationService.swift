import Foundation

enum MigrationServiceError: LocalizedError {
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case let .duplicate(bundleID):
            "A migration for \(bundleID) is already active or queued."
        }
    }
}

/// The application-facing migration boundary. It owns serial scheduling and
/// exposes only starting, status inspection, and durable recovery.
@MainActor
final class MigrationService: MigrationServicing {
    private let model: AppModel
    private let storageService: any StorageServicing
    private let appStore: any ManagedAppPersisting
    private let metadataStore: ExStorageMetadataStore
    private let migrationStore: LocalMigrationStore
    private let sleepPreventer = MigrationSleepPreventer()
    let status: MigrationStatus
    private let statusReporter: MigrationStatusReporter
    private let runtime: MigrationRuntimeState
    private lazy var appExecutor = MigrationAppExecutor(
        model: model,
        storage: storageService,
        appStore: appStore,
        metadata: metadataStore,
        migrationStore: migrationStore,
        runtime: runtime,
        statusReporter: statusReporter
    )
    private lazy var dataExecutor = MigrationDataExecutor(
        model: model,
        storage: storageService,
        appStore: appStore,
        metadata: metadataStore,
        migrationStore: migrationStore,
        runtime: runtime,
        statusReporter: statusReporter
    )
    private lazy var combinedExecutor = MigrationCombinedExecutor(
        model: model,
        migrationStore: migrationStore,
        runtime: runtime,
        statusReporter: statusReporter,
        appExecutor: appExecutor,
        dataExecutor: dataExecutor
    )

    init(
        model: AppModel,
        storageService: any StorageServicing,
        appStore: any ManagedAppPersisting
    ) {
        let reporter = MigrationStatusReporter()
        status = MigrationStatus(updates: reporter.updates)
        statusReporter = reporter
        runtime = MigrationRuntimeState(reporter: reporter)
        self.model = model
        self.storageService = storageService
        self.appStore = appStore
        self.metadataStore = ExStorageMetadataStore()
        self.migrationStore = LocalMigrationStore(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        updateSleepPrevention()
    }

    @discardableResult
    func startMigration(_ request: PendingMigration) throws -> UUID {
        guard !runtime.isLocked(bundleIdentifier: request.bundleIdentifier) else {
            throw MigrationServiceError.duplicate(request.bundleIdentifier)
        }
        runtime.enqueue(request)
        updateSleepPrevention()
        startNextIfPossible()
        return request.id
    }

    private func resumeMigration(from record: LocalMigrationRecord) async throws {
        let record = try await MigrationRecoveryReconciler.reconcile(
            record,
            model: model,
            storage: storageService,
            metadata: metadataStore,
            appStore: appStore,
            migrationStore: migrationStore
        )
        if record.phase == .completed {
            try? migrationStore.delete(id: record.request.id)
            return
        }
        let request = try MigrationRecoveryPlanner.request(
            from: record,
            containers: model.allContainers(),
            managedApps: model.apps
        )
        guard !runtime.isLocked(bundleIdentifier: request.bundleIdentifier) else {
            throw MigrationServiceError.duplicate(request.bundleIdentifier)
        }
        // Recovery is prioritized over session-only requests, which are not
        // durable and may safely wait behind the interrupted transaction.
        runtime.enqueue(request, atFront: true)
        updateSleepPrevention()
        startNextIfPossible()
    }

    func resumeInterruptedMigration() async {
        do {
            let records = try migrationStore.records()
            for queuedRecord in records where queuedRecord.phase == .queued {
                try? migrationStore.delete(id: queuedRecord.request.id)
            }
            guard let record = records.first(where: {
                $0.phase != .queued && $0.phase != .needsAttention
            }) else { return }
            await MigrationTrace.$migrationID.withValue(record.request.id) {
                do {
                    try await resumeMigration(from: record)
                    MigrationTrace.event("migration.recovery.enqueued", bundleID: record.request.bundleIdentifier)
                } catch MigrationServiceError.duplicate {
                    return
                } catch {
                    try? migrationStore.markNeedsAttention(id: record.request.id, error: error.localizedDescription)
                    runtime.recordError(error.localizedDescription, for: record.request.bundleIdentifier)
                    model.setAppFailureMessage(error.localizedDescription, for: record.request.bundleIdentifier)
                    MigrationTrace.event(
                        "migration.recovery.needs-attention",
                        bundleID: record.request.bundleIdentifier,
                        details: "error=\(error.localizedDescription)"
                    )
                }
            }
        } catch {
            MigrationTrace.event("migration.recovery.load.failed", details: error.localizedDescription)
        }
    }

    private func executionFinished(success: Bool, error: String? = nil) {
        let finishedRequest = runtime.activeRequest
        if let finishedRequest {
            if success {
                try? migrationStore.delete(id: finishedRequest.id)
            } else if let error {
                try? migrationStore.markNeedsAttention(id: finishedRequest.id, error: error)
            }
        }
        runtime.finish(success: success, error: error)
        if let bundleID = finishedRequest?.bundleIdentifier {
            if let error {
                model.setAppFailureMessage(error, for: bundleID)
            } else {
                model.clearAppFailureMessage(for: bundleID)
            }
        }
        statusReporter.finish(success: success, error: error)
        updateSleepPrevention()
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        guard !runtime.isExecuting,
              runtime.activeRequest == nil,
              !runtime.queuedRequests.isEmpty,
              let next = runtime.beginNext() else { return }
        statusReporter.begin(next)
        updateSleepPrevention()
        guard let app = model.apps.first(where: {
            $0.bundleIdentifier == next.bundleIdentifier
        }) else {
            failBeforeExecution(next, message: "The App is no longer available.")
            return
        }
        guard isInstalled(app) else {
            failBeforeExecution(next, message: "The App is no longer installed.")
            return
        }
        do {
            if try migrationStore.record(for: next.id) == nil {
                try migrationStore.save(LocalMigrationRecord(
                    request: next,
                    appInfo: committedAppInfo(for: next.bundleIdentifier),
                    phase: .preparing,
                    lastError: nil
                ))
            }
        } catch {
            failBeforeExecution(next, message: error.localizedDescription)
            return
        }
        if next.content == .app {
            appExecutor.execute(next) { [weak self] result in
                switch result {
                case .success:
                    self?.executionFinished(success: true)
                case .failure(let error):
                    self?.executionFinished(success: false, error: error.localizedDescription)
                }
            }
        } else if next.content == .appAndData {
            combinedExecutor.execute(next) { [weak self] result in
                switch result {
                case .success:
                    self?.executionFinished(success: true)
                case .failure(let error):
                    self?.executionFinished(success: false, error: error.localizedDescription)
                }
            }
        } else if dataExecutor.supports(next) {
            dataExecutor.execute(next) { [weak self] result in
                switch result {
                case .success:
                    self?.executionFinished(success: true)
                case .failure(let error):
                    self?.executionFinished(success: false, error: error.localizedDescription)
                }
            }
        } else {
            executionFinished(
                success: false,
                error: "The Migration request route is unsupported."
            )
        }
    }

    private func isInstalled(_ app: AppSnapshot) -> Bool {
        guard !app.applicationPath.isEmpty,
              FileSystemUtilities.itemExists(at: app.applicationURL),
              let bundle = Bundle(url: app.applicationURL) else { return false }
        return bundle.bundleIdentifier == app.bundleIdentifier
    }

    private func failBeforeExecution(_ request: PendingMigration, message: String) {
        executionFinished(success: false, error: message)
    }

    private func committedAppInfo(for bundleID: String) -> ManagedApplicationInfo {
        let app = model.apps.first { $0.bundleIdentifier == bundleID }
        let appURL = app?.applicationURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Unknown.app")
        let dataURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        let bundleLocation = managedBundleLocation(for: appURL)
        let storedInfo = model.appInfo(for: bundleID)
        let localAppPathHint: String?
        if let recordedHint = storedInfo?.localAppPathHint {
            localAppPathHint = recordedHint
        } else if app?.applicationPath.isEmpty == false,
                  case let .local(path) = bundleLocation {
            localAppPathHint = path
        } else {
            localAppPathHint = nil
        }
        let dataLocation: ManagedLocation
        if let storedInfo {
            dataLocation = .dataVolume(volumeUUID: storedInfo.dataVolumeUUID)
        } else {
            dataLocation = .local(path: ExStorageLayout.portableLocalPath(dataURL))
        }
        return ManagedApplicationInfo(
            bundleID: bundleID,
            version: Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            localAppPathHint: localAppPathHint,
            bundle: ManagedBundleState(
                location: bundleLocation,
                migration: nil
            ),
            data: ManagedDataState(
                location: dataLocation,
                migration: nil
            )
        )
    }

    private func managedBundleLocation(for appURL: URL) -> ManagedLocation {
        let path = appURL.standardizedFileURL.path
        for container in model.allContainers() {
            guard let management = container.volumes.first(where: {
                $0.name == ExStorageLayout.managementVolumeName
            }), let mountPoint = management.mountPoint,
            let volumeUUID = management.volumeUUID else { continue }
            let root = URL(fileURLWithPath: mountPoint, isDirectory: true).standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            return .managementVolume(
                volumeUUID: volumeUUID,
                relativePath: String(path.dropFirst(root.count + 1))
            )
        }
        return .local(path: ExStorageLayout.portableLocalPath(appURL))
    }

    private func updateSleepPrevention() {
        sleepPreventer.setMigrationActive(
            runtime.isExecuting
                || runtime.activeRequest != nil
                || !runtime.queuedRequests.isEmpty
        )
    }
}
