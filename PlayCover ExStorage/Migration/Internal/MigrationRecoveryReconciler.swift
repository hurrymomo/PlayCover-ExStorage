import Foundation

/// Resolves durable commit checkpoints before a recovery request is planned.
/// A verified App copy may already be complete even when the process stopped
/// before AppInfo and the in-memory App registry were committed.
@MainActor
enum MigrationRecoveryReconciler {
    static func reconcile(
        _ record: LocalMigrationRecord,
        model: AppModel,
        storage: any StorageServicing,
        metadata: ExStorageMetadataStore,
        appStore: any ManagedAppPersisting,
        migrationStore: LocalMigrationStore
    ) async throws -> LocalMigrationRecord {
        var record = record
        var info = record.appInfo
        if let migration = info.data.migration, migration.verified {
            let sourceExists = dataLocationExists(info.data.location, model: model, storage: storage)
            let destinationExists = dataLocationExists(migration.destination, model: model, storage: storage)
            if !sourceExists, destinationExists {
                info.data.location = migration.destination
                info.data.migration = nil
                record.appInfo = info
                record.phase = .completed
                try migrationStore.save(record)
                try await persistCommittedDataInfo(
                    info,
                    request: record.request,
                    model: model,
                    storage: storage,
                    metadata: metadata
                )
                return record
            }
        }
        guard let migration = info.bundle.migration,
              migration.verified,
              case let .managementVolume(expectedVolumeUUID, relativePath) = migration.destination,
              let container = model.allContainers().first(where: { container in
                  container.volumes.contains { volume in
                      volume.volumeUUID?.caseInsensitiveCompare(expectedVolumeUUID) == .orderedSame
                  }
              }) else {
            return record
        }

        let access = ManagementVolumeAccess(model: model, storage: storage, metadata: metadata)
        let management = try await access.prepareManagementVolume(for: container)
        guard expectedVolumeUUID.caseInsensitiveCompare(management.volumeUUID) == .orderedSame else {
            try await access.releaseManagementVolumeIfNeeded(management)
            return record
        }

        let destination = management.root.appendingPathComponent(relativePath)
        let sourceExists = try await appLocationExists(
            info.bundle.location,
            model: model,
            storage: storage,
            metadata: metadata
        )
        guard sourceExists == false, storage.itemExists(at: destination) else {
            try await access.releaseManagementVolumeIfNeeded(management)
            return record
        }

        info.bundle.location = migration.destination
        info.bundle.migration = nil
        if info.migrationTransaction != nil {
            info.migrationTransaction?.nextStage = .data
        } else {
            record.phase = .completed
        }
        record.appInfo = info
        try migrationStore.save(record)

        if let record = managedApp(at: destination, bundleID: info.bundleID) {
            model.insertOrUpdateApp(
                bundleIdentifier: record.bundleIdentifier,
                name: record.name,
                applicationPath: record.applicationPath,
                persistence: record.persistence
            )
            appStore.save(model.apps)
        }
        if let appInfo = try await metadata.loadAppInfo(bundleID: info.bundleID, at: management.root) {
            model.setAppInfo(appInfo, containerID: container.id)
        }

        // The destination App is now authoritative and needs the management
        // volume to remain mounted for launch, so it is intentionally retained.
        return record
    }

    /// `nil` means that an external source is unavailable, so recovery must not
    /// assume it was deleted merely because its management volume is detached.
    private static func appLocationExists(
        _ location: ManagedLocation,
        model: AppModel,
        storage: any StorageServicing,
        metadata: ExStorageMetadataStore
    ) async throws -> Bool? {
        switch location {
        case let .local(path):
            return storage.itemExists(at: ExStorageLayout.resolveLocalPath(path))
        case .dataVolume:
            return nil
        case let .managementVolume(volumeUUID, relativePath):
            guard let container = model.allContainers().first(where: { container in
                container.volumes.contains {
                    $0.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame
                }
            }) else { return nil }
            let access = ManagementVolumeAccess(model: model, storage: storage, metadata: metadata)
            let management = try await access.prepareManagementVolume(for: container)
            guard management.volumeUUID.caseInsensitiveCompare(volumeUUID) == .orderedSame else {
                try await access.releaseManagementVolumeIfNeeded(management)
                return nil
            }
            let exists = storage.itemExists(at: management.root.appendingPathComponent(relativePath))
            try await access.releaseManagementVolumeIfNeeded(management)
            return exists
        }
    }

    private static func dataLocationExists(
        _ location: ManagedLocation,
        model: AppModel,
        storage: any StorageServicing
    ) -> Bool {
        switch location {
        case let .local(path):
            return storage.itemExists(at: ExStorageLayout.resolveLocalPath(path))
        case let .dataVolume(volumeUUID), let .managementVolume(volumeUUID, _):
            return model.allContainers().contains { container in
                container.volumes.contains {
                    $0.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame
                }
            }
        }
    }

    private static func persistCommittedDataInfo(
        _ info: ManagedApplicationInfo,
        request: PendingMigration,
        model: AppModel,
        storage: any StorageServicing,
        metadata: ExStorageMetadataStore
    ) async throws {
        let access = ManagementVolumeAccess(model: model, storage: storage, metadata: metadata)
        switch request.target {
        case let .container(targetID):
            guard let target = model.container(identifiedBy: targetID) else { return }
            let management = try await access.prepareManagementVolume(for: target)
            let storedInfo = try await metadata.saveAppInfo(info, at: management.root)
            model.setAppInfo(storedInfo, containerID: targetID)
        case .local:
            guard case let .container(sourceID) = request.source,
                  let source = model.container(identifiedBy: sourceID) else {
                model.clearAppInfo(for: info.bundleID)
                return
            }
            let management = try await access.prepareManagementVolume(for: source)
            if request.content == .appAndData {
                try await metadata.deleteAppInfo(bundleID: info.bundleID, at: management.root)
            }
            model.clearAppInfo(for: info.bundleID)
        }
    }

    private static func managedApp(at url: URL, bundleID: String) -> AppSnapshot? {
        guard let bundle = Bundle(url: url) else { return nil }
        let discoveredID = bundle.bundleIdentifier
            ?? bundle.object(forInfoDictionaryKey: kCFBundleIdentifierKey as String) as? String
        guard discoveredID == bundleID else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return AppSnapshot(
            bundleIdentifier: bundleID,
            name: name,
            applicationPath: url.path,
            persistence: .managed
        )
    }
}
