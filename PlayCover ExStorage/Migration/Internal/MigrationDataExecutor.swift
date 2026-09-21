import Foundation

@MainActor
final class MigrationDataExecutor {
    private let model: AppModel
    private let storage: any StorageServicing
    private let appStore: any ManagedAppPersisting
    private let metadata: ExStorageMetadataStore
    private let migrationStore: LocalMigrationStore
    private let migrationStorage: ManagementVolumeAccess
    private let runtime: MigrationRuntimeState
    private let statusReporter: MigrationStatusReporter

    init(
        model: AppModel,
        storage: any StorageServicing,
        appStore: any ManagedAppPersisting,
        metadata: ExStorageMetadataStore,
        migrationStore: LocalMigrationStore,
        runtime: MigrationRuntimeState,
        statusReporter: MigrationStatusReporter
    ) {
        self.model = model
        self.storage = storage
        self.appStore = appStore
        self.metadata = metadata
        self.migrationStore = migrationStore
        self.runtime = runtime
        self.statusReporter = statusReporter
        migrationStorage = ManagementVolumeAccess(model: model, storage: storage, metadata: metadata)
    }

    func supports(_ request: PendingMigration) -> Bool {
        guard request.content == .data else { return false }
        if case .local = request.source, case .container = request.target { return true }
        if case .container = request.source, case .local = request.target { return true }
        if case .container = request.source, case .container = request.target { return true }
        return false
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

    func executeAsync(_ request: PendingMigration) async throws {
        switch (request.source, request.target) {
                case (.local, .container(let targetID)):
                    guard let target = model.container(identifiedBy: targetID) else {
                        throw failure("The target storage is unavailable.")
                    }
                    try await localToExternal(request, target: target)
                case (.container(let sourceID), .local):
                    guard let source = model.container(identifiedBy: sourceID) else {
                        throw failure("The source storage is unavailable.")
                    }
                    try await externalToLocal(request, source: source)
                case (.container(let sourceID), .container(let targetID)):
                    guard let source = model.container(identifiedBy: sourceID),
                          let target = model.container(identifiedBy: targetID) else {
                        throw failure("The source or target storage is unavailable.")
                    }
                    try await externalToExternal(request, source: source, target: target)
                default:
                    throw failure("This Data migration route is not available.")
        }
    }

    private func externalToExternal(
        _ request: PendingMigration,
        source sourceContainer: ExternalAPFSContainer,
        target targetContainer: ExternalAPFSContainer
    ) async throws {
        let bundleID = request.bundleIdentifier
        guard sourceContainer.id != targetContainer.id else {
            throw failure("The source and target storage are the same.")
        }
        guard let sourceVolume = sourceVolume(bundleID: bundleID, in: sourceContainer),
              let sourceDevice = sourceVolume.bsdDevice else {
            throw failure("The source Data Volume is unavailable.")
        }
        if model.managedAppContainer(for: bundleID)?.id == sourceContainer.id {
            throw failure("The App is also stored on the source storage. Migrate App & Data together.")
        }
        guard let sourceIdentity = await storage.volumeIdentity(for: sourceDevice),
        sourceIdentity.containerReference == sourceContainer.containerReference else {
            throw failure("The source Data Volume identity could not be verified.")
        }
        let recoveryTarget = request.recoveryDestinationVolumeUUID.flatMap { uuid in
            targetContainer.volumes.first {
                $0.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame && $0.bsdDevice != nil
            }
        }
        let replacedTarget = recoveryTarget == nil && request.overwriteExisting
            ? targetContainer.volumes.first { $0.name == bundleID && $0.bsdDevice != nil }
            : nil
        if recoveryTarget == nil, replacedTarget == nil,
           targetContainer.volumes.contains(where: { $0.name == bundleID }) {
            throw failure("The target storage already contains a Data Volume for this App.")
        }

        setOperation("Preparing drive-to-drive migration…", progress: 0)
        let dataPath = localDataPath(bundleID)
        var sourceMount = usableMountPoint(sourceVolume.mountPoint).map(URL.init(fileURLWithPath:))
        let originalSourceMount = sourceMount
        let sourceWasConnected = sourceMount?.standardizedFileURL.path == dataPath.standardizedFileURL.path
        var temporarySourceMount: URL?
        var sourceWasUnmounted = false
        var targetMount: URL?
        var targetDevice: String?
        var targetUUID: String?
        var sourceManagement: ManagementVolumeContext?
        var targetManagement: ManagementVolumeContext?
        var targetOriginalInfo: ExStorageAppInfo?

        do {
            let logURL = MigrationTrace.prepareCommandLog(kind: "migrate")
            sourceManagement = try await migrationStorage.prepareManagementVolume(for: sourceContainer)
            targetManagement = try await migrationStorage.prepareManagementVolume(for: targetContainer)
            guard let targetManagement else { throw failure("The target management Volume is unavailable.") }
            targetOriginalInfo = try await metadata.loadAppInfo(bundleID: bundleID, at: targetManagement.root)
            if sourceMount == nil {
                let mount = temporaryMountPoint(sourceDevice)
                try await storage.mountAPFSVolume(
                    device: sourceDevice,
                    at: mount,
                    options: ["noowners", "nobrowse"]
                )
                temporarySourceMount = mount
                sourceMount = mount
            }
            guard let sourceMount else { throw failure("The source Data Volume could not be mounted.") }
            let requiredBytes = try await Task.detached(priority: .utility) {
                try MigrationFileOperations.allocatedSize(of: sourceMount)
            }.value
            let capacity = await freshAvailableCapacity(targetContainer)
            try ensureSufficientSpace(
                requiredBytes: requiredBytes,
                availableBytes: capacity.map { $0 + (replacedTarget?.usedBytes ?? 0) },
                destinationName: targetContainer.displayName ?? "the target SSD"
            )

            let created: CreatedAPFSVolume
            if let recoveryTarget, let device = recoveryTarget.bsdDevice {
                if let mount = usableMountPoint(recoveryTarget.mountPoint) {
                    try await storage.unmountVolume(at: URL(fileURLWithPath: mount))
                }
                created = CreatedAPFSVolume(bsdDevice: device, mountPoint: nil)
            } else {
                created = try await storage.createAPFSVolume(
                    containerReference: targetContainer.containerReference,
                    name: bundleID
                )
            }
            guard let identity = await storage.volumeIdentity(for: created.bsdDevice),
            identity.containerReference == targetContainer.containerReference else {
                throw failure("The target Data Volume identity could not be verified.")
            }
            targetDevice = created.bsdDevice
            targetUUID = identity.volumeUUID
            var info = try await loadOrCreateAppInfo(
                bundleID: bundleID,
                dataPath: dataPath,
                managementRoot: targetManagement.root
            )
            info.data.location = .dataVolume(volumeUUID: sourceIdentity.volumeUUID)
            info.data.migration = ComponentMigrationState(
                destination: .dataVolume(volumeUUID: identity.volumeUUID),
                verified: false,
                phase: .copying
            )
            try await checkpoint(info, at: targetManagement.root, phase: .copying, progress: 0.15)

            let mount = temporaryMountPoint(created.bsdDevice)
            targetMount = mount
            try await storage.mountAPFSVolume(
                device: created.bsdDevice,
                at: mount,
                options: ["noowners", "nobrowse"]
            )
            let manifest = try await MigrationFileOperations.manifest(at: sourceMount)
            try await MigrationFileOperations.copyData(
                from: sourceMount,
                to: mount,
                logURL: logURL,
                sourceManifest: manifest,
                progressRange: 0.2...0.72,
                onProgress: { [weak self] progress in
                    self?.statusReporter.updateProgress(progress)
                }
            )
            info.data.migration?.phase = .verifying
            try await checkpoint(info, at: targetManagement.root, phase: .verifying, progress: 0.75)
            try await MigrationFileOperations.verifyData(sourceManifest: manifest, destination: mount)
            info.data.migration?.verified = true
            info.data.migration?.phase = .committing
            try await checkpoint(info, at: targetManagement.root, phase: .committing, progress: 0.88)

            try await storage.unmountVolume(at: sourceMount)
            sourceWasUnmounted = true
            if let temporarySourceMount { try? await storage.deletePrivilegedItem(at: temporarySourceMount) }
            try await storage.unmountVolume(at: mount)
            targetMount = nil
            try? await storage.deletePrivilegedItem(at: mount)

            var finalMountPoint: String?
            if sourceWasConnected {
                if FileSystemUtilities.itemExists(at: dataPath),
                   FileSystemUtilities.directoryIsEmptyOrMissing(at: dataPath) {
                    try await storage.deletePrivilegedItem(at: dataPath)
                }
                try ensureLocalDataDirectory(bundleID: bundleID)
                try await storage.mountAPFSVolume(
                    device: created.bsdDevice,
                    at: dataPath,
                    options: ["noowners", "nobrowse"]
                )
                finalMountPoint = dataPath.path
            }
            addOrUpdateVolume(
                containerID: targetContainer.id,
                volume: ExternalVolume(
                    name: bundleID,
                    mountPoint: finalMountPoint,
                    bsdDevice: created.bsdDevice,
                    volumeUUID: identity.volumeUUID,
                    availableBytes: nil,
                    usedBytes: requiredBytes
                )
            )
            if let replacedDevice = replacedTarget?.bsdDevice,
               let replacedIdentity = await storage.volumeIdentity(for: replacedDevice) {
                try await deleteVerifiedVolume(
                    device: replacedDevice,
                    expectedUUID: replacedIdentity.volumeUUID,
                    containerReference: targetContainer.containerReference
                )
                removeVolume(device: replacedDevice)
            }
            try await deleteVerifiedVolume(
                device: sourceDevice,
                expectedUUID: sourceIdentity.volumeUUID,
                containerReference: sourceContainer.containerReference
            )
            removeVolume(device: sourceDevice)
            info.data.location = .dataVolume(volumeUUID: identity.volumeUUID)
            info.data.migration = nil
            let storedInfo = try await metadata.saveAppInfo(info, at: targetManagement.root)
            model.setAppInfo(storedInfo, containerID: targetContainer.id)
            try persistCommittedState(info)
            if let sourceManagement {
                try? await metadata.deleteAppInfo(bundleID: bundleID, at: sourceManagement.root)
            }
            statusReporter.update(
                message: "App data was migrated to the target SSD.",
                progress: 1
            )
        } catch {
            runtime.setPhase(.rollingBack)
            if let targetMount {
                try? await storage.unmountVolume(at: targetMount)
                try? await storage.deletePrivilegedItem(at: targetMount)
            }
            if let targetDevice, let targetUUID {
                try? await deleteVerifiedVolume(
                    device: targetDevice,
                    expectedUUID: targetUUID,
                    containerReference: targetContainer.containerReference
                )
                removeVolume(device: targetDevice)
            }
            if let temporarySourceMount {
                try? await storage.unmountVolume(at: temporarySourceMount)
                try? await storage.deletePrivilegedItem(at: temporarySourceMount)
            }
            if sourceWasUnmounted, let originalSourceMount {
                try? await storage.mountAPFSVolume(
                    device: sourceDevice,
                    at: originalSourceMount,
                    options: ["noowners", "nobrowse"]
                )
            }
            if let targetManagement {
                if let targetOriginalInfo {
                    _ = try? await metadata.saveAppInfo(targetOriginalInfo, at: targetManagement.root)
                } else {
                    try? await metadata.deleteAppInfo(bundleID: bundleID, at: targetManagement.root)
                }
            }
            throw error
        }
    }

    private func externalToLocal(
        _ request: PendingMigration,
        source container: ExternalAPFSContainer
    ) async throws {
        let bundleID = request.bundleIdentifier
        let dataPath = localDataPath(bundleID)
        guard let sourceVolume = sourceVolume(bundleID: bundleID, in: container),
              let sourceDevice = sourceVolume.bsdDevice else {
            throw failure("The source Data Volume is unavailable.")
        }
        guard let sourceIdentity = await storage.volumeIdentity(for: sourceDevice),
        sourceIdentity.containerReference == container.containerReference else {
            throw failure("The source Data Volume identity could not be verified.")
        }
        let requiredBytes: Int64
        if let used = sourceVolume.usedBytes {
            requiredBytes = used
        } else if let mount = usableMountPoint(sourceVolume.mountPoint) {
            requiredBytes = try await Task.detached(priority: .utility) {
                try MigrationFileOperations.allocatedSize(of: URL(fileURLWithPath: mount))
            }.value
        } else {
            throw failure("The source data size could not be determined safely.")
        }
        try ensureSufficientSpace(
            requiredBytes: requiredBytes,
            availableBytes: localAvailableCapacity(),
            destinationName: "Local"
        )

        setOperation("Preparing to restore local App data…", progress: 0)
        let backupPath = dataPath.deletingLastPathComponent()
            .appendingPathComponent("Data.overwrite-backup", isDirectory: true)
        let recoveryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PlayCover ExStorage/Recovery", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data.restore-in-progress", isDirectory: true)
        let resuming = request.recoveryPhase != nil
        var management: ManagementVolumeContext?
        var temporaryMount: URL?
        var originalMount: URL?
        var originalInfo: ManagedApplicationInfo?

        do {
            let logURL = MigrationTrace.prepareCommandLog(kind: "restore")
            management = try await migrationStorage.prepareManagementVolume(for: container)
            guard let management else { throw failure("The source ExStorage management volume is unavailable.") }
            var info = try await loadOrCreateAppInfo(
                bundleID: bundleID,
                dataPath: dataPath,
                managementRoot: management.root
            )
            originalInfo = info
            info.data.migration = ComponentMigrationState(
                destination: .local(path: ExStorageLayout.portableLocalPath(dataPath)),
                verified: false,
                phase: .copying
            )
            try await checkpoint(info, at: management.root, phase: .copying, progress: 0.1)

            if let mounted = usableMountPoint(sourceVolume.mountPoint) {
                originalMount = URL(fileURLWithPath: mounted)
                try await storage.unmountVolume(at: originalMount!)
            }
            if !FileSystemUtilities.directoryIsEmptyOrMissing(at: dataPath) {
                guard request.overwriteExisting else {
                    throw failure("The local Data directory is not empty. Explicit overwrite approval is required.")
                }
                if FileSystemUtilities.itemExists(at: backupPath), !resuming {
                    throw failure("A previous overwrite backup still exists.")
                }
                if !FileSystemUtilities.itemExists(at: backupPath) {
                    try await storage.movePrivilegedItem(from: dataPath, to: backupPath)
                }
            }

            let mount = temporaryMountPoint(sourceDevice)
            temporaryMount = mount
            try await storage.mountAPFSVolume(
                device: sourceDevice,
                at: mount,
                options: ["noowners", "nobrowse"]
            )
            if FileSystemUtilities.itemExists(at: recoveryPath), !resuming {
                try await storage.deletePrivilegedItem(at: recoveryPath)
            }
            try FileManager.default.createDirectory(
                at: recoveryPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let manifest = try await MigrationFileOperations.manifest(at: mount)
            try await MigrationFileOperations.copyData(
                from: mount,
                to: recoveryPath,
                logURL: logURL,
                sourceManifest: manifest,
                progressRange: 0.15...0.8,
                onProgress: { [weak self] progress in
                    self?.statusReporter.updateProgress(progress)
                }
            )
            info.data.migration?.phase = .verifying
            try await checkpoint(info, at: management.root, phase: .verifying, progress: 0.82)
            try await MigrationFileOperations.verifyData(
                sourceManifest: manifest,
                destination: recoveryPath
            )
            info.data.migration?.verified = true
            info.data.migration?.phase = .committing
            try await checkpoint(info, at: management.root, phase: .committing, progress: 0.9)

            try await storage.unmountVolume(at: mount)
            temporaryMount = nil
            try? await storage.deletePrivilegedItem(at: mount)
            try ensureLocalDataDirectory(bundleID: bundleID)
            if FileSystemUtilities.itemExists(at: dataPath) {
                try await storage.deletePrivilegedItem(at: dataPath)
            }
            try await storage.movePrivilegedItem(from: recoveryPath, to: dataPath)
            try await deleteVerifiedVolume(
                device: sourceDevice,
                expectedUUID: sourceIdentity.volumeUUID,
                containerReference: container.containerReference
            )
            if FileSystemUtilities.itemExists(at: backupPath) {
                try await storage.deletePrivilegedItem(at: backupPath)
            }
            info.data.location = .local(path: ExStorageLayout.portableLocalPath(dataPath))
            info.data.migration = nil
            try await persistAfterLocalRestore(info, management: management)
            try persistCommittedState(info)
            removeVolume(device: sourceDevice)
            markManaged(bundleID)
            statusReporter.update(
                message: "Local data was restored and the external Data Volume was removed.",
                progress: 1
            )
        } catch {
            runtime.setPhase(.rollingBack)
            if FileSystemUtilities.itemExists(at: recoveryPath) {
                try? await storage.deletePrivilegedItem(at: recoveryPath)
            }
            if let temporaryMount {
                try? await storage.unmountVolume(at: temporaryMount)
                try? await storage.deletePrivilegedItem(at: temporaryMount)
            }
            if let originalMount {
                try? await storage.mountAPFSVolume(
                    device: sourceDevice,
                    at: originalMount,
                    options: ["noowners", "nobrowse"]
                )
            }
            if FileSystemUtilities.itemExists(at: backupPath),
               FileSystemUtilities.directoryIsEmptyOrMissing(at: dataPath) {
                if FileSystemUtilities.itemExists(at: dataPath) {
                    try? await storage.deletePrivilegedItem(at: dataPath)
                }
                try? await storage.movePrivilegedItem(from: backupPath, to: dataPath)
            }
            if var originalInfo, let management {
                originalInfo.data.migration = nil
                _ = try? await metadata.saveAppInfo(originalInfo, at: management.root)
            }
            throw error
        }
    }

    private func localToExternal(
        _ request: PendingMigration,
        target container: ExternalAPFSContainer
    ) async throws {
        let bundleID = request.bundleIdentifier
        let dataPath = localDataPath(bundleID)
        try ensureLocalDataDirectory(bundleID: bundleID)
        let existing = existingTargetVolume(for: request, in: container)
        if existing != nil, !request.overwriteExisting,
           request.recoveryDestinationVolumeUUID == nil {
            throw failure("The destination already contains a Data Volume for this App.")
        }

        setOperation("Checking source size and target free space…", progress: 0)
        let requiredBytes = try await Task.detached(priority: .utility) {
            try MigrationFileOperations.allocatedSize(of: dataPath)
        }.value
        let availableCapacity = await freshAvailableCapacity(container)
        try ensureSufficientSpace(
            requiredBytes: requiredBytes,
            availableBytes: availableCapacity.map {
                $0 + (existing?.usedBytes ?? 0)
            },
            destinationName: container.displayName ?? "the target SSD"
        )

        var management: ManagementVolumeContext?
        var targetMount: URL?
        var targetDevice: String?
        var targetUUID: String?
        var targetOriginalInfo: ExStorageAppInfo?
        do {
            let logURL = MigrationTrace.prepareCommandLog(kind: "migrate")
            management = try await migrationStorage.prepareManagementVolume(for: container)
            guard let management else { throw failure("The ExStorage management volume is unavailable.") }
            targetOriginalInfo = try await metadata.loadAppInfo(bundleID: bundleID, at: management.root)
            let device: String
            if let existing, let existingDevice = existing.bsdDevice {
                device = existingDevice
                if let mount = usableMountPoint(existing.mountPoint) {
                    try await storage.unmountVolume(at: URL(fileURLWithPath: mount))
                }
            } else {
                device = try await storage.createAPFSVolume(
                    containerReference: container.containerReference,
                    name: bundleID
                ).bsdDevice
            }
            guard let identity = await storage.volumeIdentity(for: device),
            identity.containerReference == container.containerReference else {
                throw failure("The destination Data Volume identity could not be verified.")
            }
            targetDevice = device
            targetUUID = identity.volumeUUID
            var info = try await loadOrCreateAppInfo(
                bundleID: bundleID,
                dataPath: dataPath,
                managementRoot: management.root
            )
            info.data.migration = ComponentMigrationState(
                destination: .dataVolume(volumeUUID: identity.volumeUUID),
                verified: false,
                phase: .copying
            )
            try await checkpoint(info, at: management.root, phase: .copying, progress: 0.25)

            let mount = temporaryMountPoint(device)
            targetMount = mount
            try await storage.mountAPFSVolume(
                device: device,
                at: mount,
                options: ["noowners", "nobrowse"]
            )
            let manifest = try await MigrationFileOperations.manifest(at: dataPath)
            try await MigrationFileOperations.copyData(
                from: dataPath,
                to: mount,
                logURL: logURL,
                sourceManifest: manifest,
                progressRange: 0.35...0.8,
                onProgress: { [weak self] progress in
                    self?.statusReporter.updateProgress(progress)
                }
            )
            info.data.migration?.phase = .verifying
            try await checkpoint(info, at: management.root, phase: .verifying, progress: 0.82)
            try await MigrationFileOperations.verifyData(sourceManifest: manifest, destination: mount)
            info.data.migration?.verified = true
            info.data.migration?.phase = .committing
            try await checkpoint(info, at: management.root, phase: .committing, progress: 0.9)

            try await storage.unmountVolume(at: mount)
            targetMount = nil
            try? await storage.deletePrivilegedItem(at: mount)
            // Idempotent commit: after a crash during commit the source may
            // already be gone; repeating deletion remains successful.
            if FileSystemUtilities.itemExists(at: dataPath) {
                try await storage.deletePrivilegedItem(at: dataPath)
            }
            info.data.location = .dataVolume(volumeUUID: identity.volumeUUID)
            info.data.migration = nil
            let storedInfo = try await metadata.saveAppInfo(info, at: management.root)
            model.setAppInfo(storedInfo, containerID: container.id)
            try persistCommittedState(info)
            addOrUpdateVolume(
                containerID: container.id,
                volume: ExternalVolume(
                    name: bundleID,
                    mountPoint: nil,
                    bsdDevice: device,
                    volumeUUID: identity.volumeUUID,
                    availableBytes: nil,
                    usedBytes: requiredBytes
                )
            )
            markManaged(bundleID)
            statusReporter.update(
                message: "App data is now stored on the external APFS Volume and remains disconnected.",
                progress: 1
            )
        } catch {
            runtime.setPhase(.rollingBack)
            if let targetMount {
                try? await storage.unmountVolume(at: targetMount)
                try? await storage.deletePrivilegedItem(at: targetMount)
            }
            if let management {
                if let targetOriginalInfo {
                    _ = try? await metadata.saveAppInfo(targetOriginalInfo, at: management.root)
                } else {
                    try? await metadata.deleteAppInfo(bundleID: bundleID, at: management.root)
                }
                if let targetDevice, let targetUUID {
                    try? await deleteVerifiedVolume(
                        device: targetDevice,
                        expectedUUID: targetUUID,
                        containerReference: container.containerReference
                    )
                    removeVolume(device: targetDevice)
                }
            }
            throw error
        }
    }

    private func existingTargetVolume(
        for request: PendingMigration,
        in container: ExternalAPFSContainer
    ) -> ExternalVolume? {
        if let recoveryUUID = request.recoveryDestinationVolumeUUID {
            return container.volumes.first {
                $0.volumeUUID?.caseInsensitiveCompare(recoveryUUID) == .orderedSame
            }
        }
        return container.volumes.first { $0.name == request.bundleIdentifier }
    }

    private func sourceVolume(
        bundleID: String,
        in container: ExternalAPFSContainer
    ) -> ExternalVolume? {
        guard let info = model.appInfo(for: bundleID),
              model.appInfoContainerID(for: bundleID) == container.id else { return nil }
        return container.volumes.first {
            $0.volumeUUID?.caseInsensitiveCompare(info.dataVolumeUUID) == .orderedSame
        }
    }

    private func persistAfterLocalRestore(
        _ info: ManagedApplicationInfo,
        management: ManagementVolumeContext
    ) async throws {
        if runtime.activeRequest?.content == .appAndData {
            try await metadata.deleteAppInfo(bundleID: info.bundleID, at: management.root)
        }
        model.clearAppInfo(for: info.bundleID)
    }

    private func loadOrCreateAppInfo(
        bundleID: String,
        dataPath: URL,
        managementRoot: URL
    ) async throws -> ManagedApplicationInfo {
        if let request = runtime.activeRequest,
           let local = try migrationStore.record(for: request.id)?.appInfo {
            return local
        }
        guard let app = model.apps.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw failure("The application metadata is unavailable.")
        }
        let storedInfo: ExStorageAppInfo?
        if let currentInfo = model.appInfo(for: bundleID) {
            storedInfo = currentInfo
        } else {
            storedInfo = try await metadata.loadAppInfo(bundleID: bundleID, at: managementRoot)
        }
        let bundleLocation = managedBundleLocation(for: app.applicationURL)
        let version = Bundle(url: app.applicationURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let localAppPathHint: String?
        if let recordedHint = storedInfo?.localAppPathHint {
            localAppPathHint = recordedHint
        } else if !app.applicationPath.isEmpty,
                  case let .local(path) = bundleLocation {
            localAppPathHint = path
        } else {
            localAppPathHint = nil
        }
        let dataLocation: ManagedLocation
        if let storedInfo {
            dataLocation = .dataVolume(volumeUUID: storedInfo.dataVolumeUUID)
        } else {
            dataLocation = .local(path: ExStorageLayout.portableLocalPath(dataPath))
        }
        return ManagedApplicationInfo(
            bundleID: bundleID,
            version: version,
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

    private func checkpoint(
        _ info: ManagedApplicationInfo,
        at root: URL,
        phase: MigrationExecutionPhase,
        progress: Double
    ) async throws {
        runtime.setPhase(phase)
        statusReporter.updatePhase(phase)
        statusReporter.updateProgress(progress)
        guard let request = runtime.activeRequest else {
            throw failure("The active migration request is unavailable.")
        }
        try migrationStore.save(LocalMigrationRecord(
            request: request,
            appInfo: info,
            phase: phase,
            lastError: nil
        ))
    }

    private func ensureSufficientSpace(
        requiredBytes: Int64,
        availableBytes: Int64?,
        destinationName: String
    ) throws {
        guard let availableBytes else {
            throw failure("The available space on \(destinationName) could not be determined safely.")
        }
        let margin = max(Int64(2_000_000_000), requiredBytes / 20)
        guard availableBytes >= requiredBytes + margin else {
            throw failure("Not enough space on \(destinationName).")
        }
    }

    private func freshAvailableCapacity(_ container: ExternalAPFSContainer) async -> Int64? {
        let capacity = await storage.availableCapacity(for: container)
        if let capacity {
            model.updateContainerFreeCapacity(
                capacity,
                for: container.id,
                expectedContainerReference: container.containerReference
            )
        }
        return capacity
    }

    private func localAvailableCapacity() -> Int64? {
        guard let bytes = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity else { return nil }
        return Int64(bytes)
    }

    private func deleteVerifiedVolume(
        device: String,
        expectedUUID: String,
        containerReference: String
    ) async throws {
        let identity = await storage.volumeIdentity(for: device)
        guard identity?.volumeUUID == expectedUUID,
              identity?.containerReference == containerReference else {
            throw failure("Refusing to delete a Data Volume whose identity changed.")
        }
        try await storage.deleteAPFSVolume(device: device)
    }

    private func addOrUpdateVolume(containerID: UUID, volume: ExternalVolume) {
        model.replaceContainers(model.allContainers().map { container in
            guard container.id == containerID else { return container }
            var volumes = container.volumes.filter { $0.bsdDevice != volume.bsdDevice }
            volumes.append(volume)
            return replacingVolumes(of: container, with: volumes)
        })
    }

    private func removeVolume(device: String) {
        model.replaceContainers(model.allContainers().map { container in
            replacingVolumes(of: container, with: container.volumes.filter { $0.bsdDevice != device })
        })
    }

    private func replacingVolumes(
        of container: ExternalAPFSContainer,
        with volumes: [ExternalVolume]
    ) -> ExternalAPFSContainer {
        ExternalAPFSContainer(
            containerUUID: container.containerUUID,
            containerReference: container.containerReference,
            physicalStoreDeviceIdentifiers: container.physicalStoreDeviceIdentifiers,
            displayName: container.displayName,
            connectionType: container.connectionType,
            capacityTotalBytes: container.capacityTotalBytes,
            capacityFreeBytes: container.capacityFreeBytes,
            volumes: volumes
        )
    }

    private func markManaged(_ bundleID: String) {
        guard model.app(identifiedBy: bundleID) != nil else { return }
        model.updateAppPersistence(.managed, for: bundleID)
        appStore.save(model.apps)
    }

    private func persistCommittedState(_ info: ManagedApplicationInfo) throws {
        guard let request = runtime.activeRequest,
              var record = try migrationStore.record(for: request.id) else { return }
        record.appInfo = info
        try migrationStore.save(record)
    }

    private func setOperation(_ message: String, progress: Double?) {
        statusReporter.update(message: message, progress: progress)
    }

    private func localDataPath(_ bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
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

    /// An App does not need to have been launched before its Data can be
    /// migrated or used as an APFS mount point. Creating the complete local
    /// container path also covers Apps whose bundle-ID directory is missing.
    private func ensureLocalDataDirectory(bundleID: String) throws {
        let dataPath = localDataPath(bundleID)
        switch FileSystemUtilities.itemKind(at: dataPath) {
        case .directory:
            return
        case .file:
            throw failure("The local Data path for \(bundleID) exists but is not a directory.")
        case .missing:
            do {
                try FileManager.default.createDirectory(
                    at: dataPath,
                    withIntermediateDirectories: true
                )
            } catch {
                throw failure("Could not create \(bundleID)/Data: \(error.localizedDescription)")
            }
        }
    }

    private func temporaryMountPoint(_ device: String) -> URL {
        URL(
            fileURLWithPath: "/Volumes/.PlayCover-ExStorage-\(device)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func usableMountPoint(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return path
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "PlayCoverExStorage.Migration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
