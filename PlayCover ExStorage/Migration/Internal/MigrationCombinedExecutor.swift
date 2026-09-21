import Foundation

/// Durable orchestration for App + Data. Each component executor owns its own
/// copy checkpoint and rollback; this executor persists which component must
/// run next so a relaunch between the two commits cannot lose the transaction.
@MainActor
final class MigrationCombinedExecutor {
    private let model: AppModel
    private let migrationStore: LocalMigrationStore
    private let runtime: MigrationRuntimeState
    private let statusReporter: MigrationStatusReporter
    private let appExecutor: MigrationAppExecutor
    private let dataExecutor: MigrationDataExecutor

    init(
        model: AppModel,
        migrationStore: LocalMigrationStore,
        runtime: MigrationRuntimeState,
        statusReporter: MigrationStatusReporter,
        appExecutor: MigrationAppExecutor,
        dataExecutor: MigrationDataExecutor
    ) {
        self.model = model
        self.migrationStore = migrationStore
        self.runtime = runtime
        self.statusReporter = statusReporter
        self.appExecutor = appExecutor
        self.dataExecutor = dataExecutor
    }

    func execute(
        _ request: PendingMigration,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        Task {
            await MigrationTrace.$migrationID.withValue(request.id) {
                MigrationTrace.event(
                    "migration.execution.started",
                    bundleID: request.bundleIdentifier,
                    details: "content=\(request.content.rawValue)"
                )
                do {
                    try await executeAsync(request)
                    MigrationTrace.event("migration.execution.succeeded", bundleID: request.bundleIdentifier)
                    completion(.success(()))
                } catch {
                    MigrationTrace.event(
                        "migration.execution.failed",
                        bundleID: request.bundleIdentifier,
                        details: "error=\(error.localizedDescription)"
                    )
                    completion(.failure(error))
                }
            }
        }
    }

    private func executeAsync(_ request: PendingMigration) async throws {
        guard request.content == .appAndData else {
            throw failure("The combined executor only accepts App & Data migrations.")
        }
        guard let record = try migrationStore.record(for: request.id) else {
            throw failure("The local migration record is unavailable.")
        }
        var transaction = record.appInfo.migrationTransaction
            ?? MigrationTransactionState(
                request: request,
                nextStage: .app,
                originalAppLocation: record.appInfo.bundle.location,
                originalDataLocation: record.appInfo.data.location
            )
        try saveTransaction(transaction)

        do {
            if transaction.nextStage == .app {
                let source = appTarget(request.bundleIdentifier)
                if source != request.target {
                    let appRequest = componentRequest(
                        request,
                        source: source,
                        content: .app
                    )
                    try await appExecutor.executeAsync(appRequest)
                }
                transaction.nextStage = .data
                try saveTransaction(transaction)
            }

            let source = dataTarget(request.bundleIdentifier)
            if source != request.target {
                let dataRequest = componentRequest(
                    request,
                    source: source,
                    content: .data
                )
                try await dataExecutor.executeAsync(dataRequest)
            }
        } catch {
            do {
                try await rollback(transaction)
                // The original state is authoritative again. A successfully
                // compensated failure has nothing left to resume or inspect.
                try migrationStore.delete(id: request.id)
            } catch let rollbackError {
                throw failure(
                    "Migration failed: \(error.localizedDescription) Rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
        try clearTransaction(for: request)
        statusReporter.update(
            message: "The App and Data migration completed.",
            progress: 1
        )
    }

    /// Component executors are individually transactional. For an App & Data
    /// request they also act as compensating operations: if the second
    /// component fails, move every already-committed component back to the
    /// locations captured before the combined transaction began.
    private func rollback(_ transaction: MigrationTransactionState) async throws {
        runtime.setPhase(.rollingBack)
        statusReporter.update(
            message: "Rolling back the App and Data migration…",
            progress: nil
        )

        if let originalDataLocation = transaction.originalDataLocation {
            let originalTarget = try target(for: originalDataLocation)
            let currentTarget = dataTarget(transaction.request.bundleIdentifier)
            if currentTarget != originalTarget {
                let request = componentRequest(
                    transaction.request,
                    source: currentTarget,
                    content: .data,
                    target: originalTarget
                )
                try await dataExecutor.executeAsync(request)
            }
        }

        if let originalAppLocation = transaction.originalAppLocation {
            let originalTarget = try target(for: originalAppLocation)
            let currentTarget = appTarget(transaction.request.bundleIdentifier)
            if currentTarget != originalTarget {
                let request = componentRequest(
                    transaction.request,
                    source: currentTarget,
                    content: .app,
                    target: originalTarget
                )
                try await appExecutor.executeAsync(request)
            }
        }
    }

    private func componentRequest(
        _ transaction: PendingMigration,
        source: MigrationTarget,
        content: MigrationContent,
        target: MigrationTarget? = nil
    ) -> PendingMigration {
        PendingMigration(
            id: transaction.id,
            batchID: transaction.batchID,
            bundleIdentifier: transaction.bundleIdentifier,
            appName: transaction.appName,
            source: source,
            target: target ?? transaction.target,
            content: content,
            overwriteExisting: transaction.overwriteExisting,
            recoveryDestinationVolumeUUID: transaction.recoveryDestinationVolumeUUID,
            recoveryPhase: transaction.recoveryPhase
        )
    }

    private func target(for location: ManagedLocation) throws -> MigrationTarget {
        switch location {
        case .local:
            return .local
        case let .managementVolume(volumeUUID, _), let .dataVolume(volumeUUID):
            guard let container = container(containing: volumeUUID) else {
                throw failure("The original storage required for rollback is unavailable.")
            }
            return .container(container.id)
        }
    }

    private func saveTransaction(_ transaction: MigrationTransactionState) throws {
        guard var record = try migrationStore.record(for: transaction.request.id) else {
            throw failure("The local migration record is unavailable.")
        }
        record.appInfo.migrationTransaction = transaction
        try migrationStore.save(record)
    }

    private func clearTransaction(for request: PendingMigration) throws {
        guard var record = try migrationStore.record(for: request.id) else { return }
        record.appInfo.migrationTransaction = nil
        try migrationStore.save(record)
    }

    private func appTarget(_ bundleID: String) -> MigrationTarget {
        model.managedAppTarget(for: bundleID)
    }

    private func dataTarget(_ bundleID: String) -> MigrationTarget {
        guard let info = model.appInfo(for: bundleID),
              let container = container(containing: info.dataVolumeUUID) else { return .local }
        return .container(container.id)
    }

    private func container(containing volumeUUID: String) -> ExternalAPFSContainer? {
        model.allContainers().first { container in
            container.volumes.contains {
                $0.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame
            }
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "PlayCoverExStorage.Migration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
