import AppKit
import Foundation

@MainActor
extension ManagedAppActions {
    func requestAppMigration(of app: AppSnapshot, to target: MigrationTarget) {
        let source = managedAppTarget(for: app.bundleIdentifier)
        guard source != target, !hasPendingMigration(bundleID: app.bundleIdentifier) else { return }
        enqueueMigrationRequests([PendingMigration(
            batchID: UUID(),
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            source: source,
            target: target,
            content: .app
        )])
    }

    func requestAppAndDataMigration(of app: AppSnapshot, to target: MigrationTarget) {
        let dataSource = managedDataContainer(for: app.bundleIdentifier).map { MigrationTarget.container($0.id) } ?? .local
        let appSource = managedAppTarget(for: app.bundleIdentifier)
        guard dataSource != target || appSource != target,
              !hasPendingMigration(bundleID: app.bundleIdentifier) else { return }
        var pending = PendingMigration(
            batchID: UUID(),
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            source: dataSource,
            target: target,
            content: .appAndData
        )
        if dataSource != target, migrationTargetContainsData(for: pending) {
            pending.overwriteExisting = true
            activeDialog = .confirmMigrationOverwrite(pending, appToAdd: nil)
            return
        }
        enqueueMigrationRequests([pending])
    }

    func requestMigration(of app: AppSnapshot, from source: MigrationTarget, to target: MigrationTarget) {
        guard source != target, !hasPendingMigration(bundleID: app.bundleIdentifier) else { return }
        if managedAppTarget(for: app.bundleIdentifier) != .local {
            activeDialog = .message(
                title: "Migrate App & Data Together",
                message: "This App is stored externally. Use Migrate App & Data so the App is not left on different external storage."
            )
            return
        }
        guard isInstalledApp(app) else {
            activeDialog = .message(
                title: "App Not Found",
                message: "The recorded App no longer exists. Reinstall or add the matching App before migrating its data. The external data Volume was not changed."
            )
            return
        }
        var pending = PendingMigration(
            batchID: UUID(),
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            source: source,
            target: target
        )
        if migrationTargetContainsData(for: pending) {
            pending.overwriteExisting = true
            activeDialog = .confirmMigrationOverwrite(pending, appToAdd: nil)
            return
        }
        enqueueMigrationRequests([pending])
    }

    func confirmMigrationOverwrite(_ pending: PendingMigration, appToAdd: AppSnapshot?) {
        if let appToAdd { addManagedApps([appToAdd]) }
        enqueueMigrationRequests([pending])
    }

    func enqueueMigrationRequests(_ requests: [PendingMigration]) {
        let status = migrationService.status.snapshot
        MigrationTrace.event(
            "queue.enqueue.request",
            details: "count=\(requests.count) queuedBefore=\(status.queued.count) inFlight=\(status.active != nil)"
        )
        for request in requests where
            request.content == .appAndData || request.source != request.target {
            MigrationTrace.$migrationID.withValue(request.id) {
                do {
                    try migrationService.startMigration(request)
                    MigrationTrace.event(
                        "queue.enqueued",
                        bundleID: request.bundleIdentifier,
                        details: "batch=\(request.batchID) source=\(request.source) target=\(request.target)"
                    )
                } catch {
                    MigrationTrace.event(
                        "queue.enqueue.rejected",
                        bundleID: request.bundleIdentifier,
                        details: "error=\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func prepareDroppedAppBatch(urls: [URL], to target: MigrationTarget) {
        let records = urls.compactMap { url -> AppSnapshot? in
            guard url.pathExtension == "app" else { return nil }
            return managedAppRecord(from: url)
        }
        prepareMigrationBatch(records, addingToLibrary: true, to: target)
    }

    func prepareExistingAppBatch(_ apps: [AppSnapshot], to target: MigrationTarget) {
        prepareMigrationBatch(apps, addingToLibrary: false, to: target)
    }

    func prepareMigrationBatch(
        _ candidates: [AppSnapshot],
        addingToLibrary: Bool,
        to target: MigrationTarget
    ) {
        MigrationTrace.event(
            "drop.batch.prepare",
            details: "candidates=\(candidates.count) addToLibrary=\(addingToLibrary) target=\(target)"
        )
        var seenBundleIDs: Set<String> = []
        let validApps = candidates.filter { app in
            guard seenBundleIDs.insert(app.bundleIdentifier).inserted,
                  isInstalledApp(app),
                  !hasPendingMigration(bundleID: app.bundleIdentifier) else { return false }
            return true
        }
        let appsAlreadyAtTarget = validApps.filter { app in
            let source = managedDataContainer(for: app.bundleIdentifier)
                .map { MigrationTarget.container($0.id) } ?? .local
            return source == target
        }
        if addingToLibrary, !appsAlreadyAtTarget.isEmpty {
            addManagedApps(appsAlreadyAtTarget)
        }
        let apps = validApps.filter { app in
            let source = managedDataContainer(for: app.bundleIdentifier)
                .map { MigrationTarget.container($0.id) } ?? .local
            return source != target
        }
        guard !apps.isEmpty else {
            MigrationTrace.event(
                "drop.batch.completed-without-migration",
                details: "added=\(appsAlreadyAtTarget.count) target=\(target)"
            )
            // Non-App items and invalid bundles are intentionally ignored.
            return
        }
        let batchID = UUID()
        let migrations = apps.compactMap { app -> PendingMigration? in
            let source = managedDataContainer(for: app.bundleIdentifier)
                .map { MigrationTarget.container($0.id) } ?? .local
            guard source != target else { return nil }
            var pending = PendingMigration(
                batchID: batchID,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                source: source,
                target: target
            )
            if managedAppTarget(for: app.bundleIdentifier) != .local {
                pending.content = .appAndData
            }
            pending.overwriteExisting = migrationTargetContainsData(for: pending)
            return pending
        }

        if migrations.count == 1, let pending = migrations.first, let app = apps.first {
            if pending.overwriteExisting {
                activeDialog = .confirmMigrationOverwrite(
                    pending,
                    appToAdd: addingToLibrary ? app : nil
                )
            } else {
                if addingToLibrary { addManagedApps([app]) }
                enqueueMigrationRequests([pending])
            }
            return
        }
        activeDialog = .confirmMigrationBatch(MigrationBatchRequest(
            apps: apps,
            migrations: migrations,
            target: target,
            addsToLibrary: addingToLibrary
        ))
    }

    func confirmMigrationBatch(_ request: MigrationBatchRequest) {
        MigrationTrace.event(
            "drop.batch.confirmed",
            details: "apps=\(request.apps.map(\.bundleIdentifier).joined(separator: ",")) target=\(request.target)"
        )
        if request.addsToLibrary { addManagedApps(request.apps) }
        // One batch confirmation grants overwrite permission to every task. This
        // also makes execution deterministic if a target appears while waiting.
        enqueueMigrationRequests(request.migrations.map { migration in
            var migration = migration
            migration.overwriteExisting = true
            return migration
        })
    }

    func addManagedApps(_ apps: [AppSnapshot]) {
        for app in apps {
            model.insertOrUpdateApp(
                bundleIdentifier: app.bundleIdentifier,
                name: app.name,
                applicationPath: app.applicationPath,
                persistence: app.persistence
            )
        }
        persistManagedApps()
    }

    func migrationTargetContainsData(for pending: PendingMigration) -> Bool {
        switch pending.target {
        case .container(let targetID):
            return containers.first(where: { $0.id == targetID })?.volumes.contains {
                $0.name == pending.bundleIdentifier
            } == true
        case .local:
            guard case let .container(sourceID) = pending.source,
                  let source = containers.first(where: { $0.id == sourceID }) else { return false }
            let sourceIsConnected = source.volumes.contains {
                $0.name == pending.bundleIdentifier
                    && connectionState(for: $0, bundleID: pending.bundleIdentifier) == .connected
            }
            return !sourceIsConnected && !isDirectoryEmptyOrMissing(
                localDataPath(for: pending.bundleIdentifier)
            )
        }
    }

}
