import Foundation

@MainActor
final class MigrationAppExecutor {
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
        guard let app = model.apps.first(where: {
            $0.bundleIdentifier == request.bundleIdentifier
        }) else {
            throw failure("The App is no longer available.")
        }
        setOperation("Preparing the App migration…", progress: 0)

        switch (request.source, request.target) {
        case (.local, .container(let targetID)):
            guard let target = model.container(identifiedBy: targetID) else {
                throw failure("The target storage is unavailable.")
            }
            try await localToExternal(request: request, app: app, target: target)

        case (.container(let sourceID), .local):
            guard let source = model.container(identifiedBy: sourceID) else {
                throw failure("The source storage is unavailable.")
            }
            try await externalToLocal(request: request, app: app, source: source)

        case (.container(let sourceID), .container(let targetID)):
            guard let source = model.container(identifiedBy: sourceID),
                  let target = model.container(identifiedBy: targetID) else {
                throw failure("The source or target storage is unavailable.")
            }
            try await externalToExternal(
                request: request,
                app: app,
                source: source,
                target: target
            )

        case (.local, .local):
            break
        }

        setOperation("The App migration completed.", progress: 1)
    }

    private func externalToExternal(
        request: PendingMigration,
        app: AppSnapshot,
        source sourceContainer: ExternalAPFSContainer,
        target targetContainer: ExternalAPFSContainer
    ) async throws {
        guard sourceContainer.id != targetContainer.id else {
            throw failure("The source and target storage are the same.")
        }
        let bundleID = app.bundleIdentifier
        guard var info = try migrationStore.record(for: request.id)?.appInfo,
              case let .managementVolume(sourceVolumeUUID, sourceRelativePath) = info.bundle.location,
              sourceContainer.volumes.contains(where: {
                  $0.volumeUUID?.caseInsensitiveCompare(sourceVolumeUUID) == .orderedSame
              }) else {
            throw failure("The external App location does not belong to the source storage.")
        }

        var staging: URL?
        var destination: URL?
        var destinationBackup: URL?
        var destinationCommitted = false
        var sourceWasDeleted = false

        do {
            let sourceManagement = try await migrationStorage.prepareManagementVolume(for: sourceContainer)
            let targetManagement = try await migrationStorage.prepareManagementVolume(for: targetContainer)
            guard sourceManagement.volumeUUID.caseInsensitiveCompare(sourceVolumeUUID) == .orderedSame else {
                throw failure("The source App management volume identity changed.")
            }
            let sourceStoredInfo = try await metadata.loadAppInfo(
                bundleID: bundleID,
                at: sourceManagement.root
            )
            if info.localAppPathHint == nil {
                info.localAppPathHint = sourceStoredInfo?.localAppPathHint
                    ?? model.appInfo(for: bundleID)?.localAppPathHint
            }

            let source = sourceManagement.root.appendingPathComponent(sourceRelativePath)
            guard FileSystemUtilities.itemExists(at: source),
                  Bundle(url: source)?.bundleIdentifier == bundleID else {
                throw failure("The external App bundle is missing or invalid.")
            }
            let applications = targetManagement.root.appendingPathComponent(
                ExStorageLayout.applicationsDirectoryName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: applications,
                withIntermediateDirectories: true
            )
            let targetURL = applications.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            destination = targetURL
            if let interrupted = info.bundle.migration?.stagingRelativePath {
                let interruptedURL = applications.appendingPathComponent(interrupted)
                if FileSystemUtilities.itemExists(at: interruptedURL) {
                    try FileManager.default.removeItem(at: interruptedURL)
                }
            }
            if FileSystemUtilities.itemExists(at: targetURL),
               Bundle(url: targetURL)?.bundleIdentifier != bundleID {
                throw failure("An unrelated item already exists at \(targetURL.lastPathComponent).")
            }
            let targetLocation = ManagedLocation.managementVolume(
                volumeUUID: targetManagement.volumeUUID,
                relativePath: "\(ExStorageLayout.applicationsDirectoryName)/\(targetURL.lastPathComponent)"
            )
            let stagingURL = applications.appendingPathComponent(
                ".\(source.lastPathComponent).\(UUID().uuidString).in-progress",
                isDirectory: true
            )
            staging = stagingURL
            info.bundle.migration = ComponentMigrationState(
                destination: targetLocation,
                verified: false,
                phase: .copying,
                stagingRelativePath: stagingURL.lastPathComponent
            )
            try checkpoint(info, phase: .copying, progress: 0.15)
            let logURL = MigrationTrace.prepareCommandLog(kind: "migrate")
            try await MigrationFileOperations.copyApplication(
                from: source,
                to: stagingURL,
                logURL: logURL
            )
            info.bundle.migration?.phase = .verifying
            try checkpoint(info, phase: .verifying, progress: 0.65)
            try await MigrationFileOperations.verifyApplication(from: source, to: stagingURL)

            if FileSystemUtilities.itemExists(at: targetURL) {
                let backup = applications.appendingPathComponent(
                    ".\(targetURL.lastPathComponent).\(UUID().uuidString).overwrite-backup",
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: targetURL, to: backup)
                destinationBackup = backup
            }
            try FileManager.default.moveItem(at: stagingURL, to: targetURL)
            staging = nil
            destinationCommitted = true
            info.bundle.migration?.verified = true
            info.bundle.migration?.phase = .committing
            try checkpoint(info, phase: .committing, progress: 0.9)

            info.bundle.location = targetLocation
            info.bundle.migration = nil
            try FileManager.default.removeItem(at: source)
            sourceWasDeleted = true
            // The external metadata is already committed and the source has
            // been removed. A best-effort journal refresh must not turn that
            // completed move into a second rollback transaction.
            try? persistCommittedState(info)
            updateManagedApp(bundleID: bundleID, path: targetURL.path)
            if let destinationBackup, FileSystemUtilities.itemExists(at: destinationBackup) {
                try? FileManager.default.removeItem(at: destinationBackup)
            }
        } catch {
            runtime.setPhase(.rollingBack)
            if let staging, FileSystemUtilities.itemExists(at: staging) {
                try? FileManager.default.removeItem(at: staging)
            }

            if !sourceWasDeleted {
                if destinationCommitted,
                   let destination,
                   FileSystemUtilities.itemExists(at: destination) {
                    try? FileManager.default.removeItem(at: destination)
                }
                if let destinationBackup, let destination,
                   FileSystemUtilities.itemExists(at: destinationBackup) {
                    try? FileManager.default.moveItem(at: destinationBackup, to: destination)
                }
            }
            throw error
        }
    }

    private func localToExternal(
        request: PendingMigration,
        app: AppSnapshot,
        target: ExternalAPFSContainer
    ) async throws {
        let bundleID = app.bundleIdentifier
        guard var info = try migrationStore.record(for: request.id)?.appInfo else {
            throw failure("AppInfo is unavailable for this App.")
        }
        let source = app.applicationURL
        let originalLocation = info.bundle.location
        if info.localAppPathHint == nil, case let .local(path) = originalLocation {
            info.localAppPathHint = path
        }
        var staging: URL?

        do {
            let management = try await migrationStorage.prepareManagementVolume(for: target)
            let applications = management.root.appendingPathComponent(
                ExStorageLayout.applicationsDirectoryName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: applications,
                withIntermediateDirectories: true
            )
            let destination = applications.appendingPathComponent(
                source.lastPathComponent,
                isDirectory: true
            )
            if let interrupted = info.bundle.migration?.stagingRelativePath {
                let interruptedURL = applications.appendingPathComponent(interrupted)
                if FileSystemUtilities.itemExists(at: interruptedURL) {
                    try FileManager.default.removeItem(at: interruptedURL)
                }
            }
            if FileSystemUtilities.itemExists(at: destination) {
                guard Bundle(url: destination)?.bundleIdentifier == bundleID else {
                    throw failure("An unrelated item already exists at \(destination.lastPathComponent).")
                }
            }

            let externalLocation = ManagedLocation.managementVolume(
                volumeUUID: management.volumeUUID,
                relativePath: "\(ExStorageLayout.applicationsDirectoryName)/\(destination.lastPathComponent)"
            )
            let stagingURL = applications.appendingPathComponent(
                ".\(source.lastPathComponent).\(UUID().uuidString).in-progress",
                isDirectory: true
            )
            staging = stagingURL
            info.bundle.migration = ComponentMigrationState(
                destination: externalLocation,
                verified: false,
                phase: .copying,
                stagingRelativePath: stagingURL.lastPathComponent
            )
            try checkpoint(info, phase: .copying, progress: 0.15)
            let logURL = MigrationTrace.prepareCommandLog(kind: "migrate")
            try await MigrationFileOperations.copyApplication(
                from: source,
                to: stagingURL,
                logURL: logURL
            )
            info.bundle.migration?.phase = .verifying
            try checkpoint(info, phase: .verifying, progress: 0.65)
            try await MigrationFileOperations.verifyApplication(from: source, to: stagingURL)
            if FileSystemUtilities.itemExists(at: destination) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagingURL, to: destination)
            staging = nil
            info.bundle.migration?.verified = true
            info.bundle.migration?.phase = .committing
            try checkpoint(info, phase: .committing, progress: 0.9)

            info.bundle.location = externalLocation
            info.bundle.migration = nil
            try await recordLocalAppPathHint(
                bundleID: bundleID,
                localPathHint: info.localAppPathHint,
                target: target,
                at: management.root
            )
            do {
                try await deleteLocalApplication(source)
            } catch {
                info.bundle.location = originalLocation
                throw error
            }
            try persistCommittedState(info)
            updateManagedApp(bundleID: bundleID, path: destination.path)
        } catch {
            runtime.setPhase(.rollingBack)
            if let staging, FileSystemUtilities.itemExists(at: staging) {
                try? FileManager.default.removeItem(at: staging)
            }
            info.bundle.location = originalLocation
            info.bundle.migration = nil
            throw error
        }
    }

    private func externalToLocal(
        request: PendingMigration,
        app: AppSnapshot,
        source container: ExternalAPFSContainer
    ) async throws {
        let bundleID = app.bundleIdentifier
        guard var info = try migrationStore.record(for: request.id)?.appInfo,
              case let .managementVolume(_, relativePath) = info.bundle.location else {
            throw failure("The external App location is unavailable.")
        }
        let originalLocation = info.bundle.location
        var staging: URL?

        do {
            let management = try await migrationStorage.prepareManagementVolume(for: container)
            let source = management.root.appendingPathComponent(relativePath)
            guard FileSystemUtilities.itemExists(at: source) else {
                throw failure("The external App bundle is missing.")
            }
            guard let storedInfo = try await metadata.loadAppInfo(
                bundleID: bundleID,
                at: management.root
            ) else {
                throw failure("AppInfo is unavailable for this external App.")
            }
            let recordedHint = storedInfo.localAppPathHint
            let destination = localRestoreDestination(
                source: source,
                bundleID: bundleID,
                pathHint: recordedHint
            )
            let applications = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: applications,
                withIntermediateDirectories: true
            )
            if FileSystemUtilities.itemExists(at: destination) {
                guard Bundle(url: destination)?.bundleIdentifier == bundleID else {
                    throw failure("An unrelated App already exists at \(destination.path).")
                }
            }
            if let interrupted = info.bundle.migration?.stagingRelativePath {
                let interruptedURL = applications.appendingPathComponent(interrupted)
                if FileSystemUtilities.itemExists(at: interruptedURL) {
                    try FileManager.default.removeItem(at: interruptedURL)
                }
            }
            let stagingURL = applications.appendingPathComponent(
                ".\(source.lastPathComponent).\(UUID().uuidString).in-progress",
                isDirectory: true
            )
            staging = stagingURL
            let localLocation = ManagedLocation.local(path: ExStorageLayout.portableLocalPath(destination))
            info.bundle.migration = ComponentMigrationState(
                destination: localLocation,
                verified: false,
                phase: .copying,
                stagingRelativePath: stagingURL.lastPathComponent
            )
            try checkpoint(info, phase: .copying, progress: 0.15)
            let logURL = MigrationTrace.prepareCommandLog(kind: "migrate")
            try await MigrationFileOperations.copyApplication(from: source, to: stagingURL, logURL: logURL)
            info.bundle.migration?.phase = .verifying
            try checkpoint(info, phase: .verifying, progress: 0.65)
            try await MigrationFileOperations.verifyApplication(from: source, to: stagingURL)
            info.bundle.migration?.verified = true
            info.bundle.migration?.phase = .committing
            try checkpoint(info, phase: .committing, progress: 0.9)
            if FileSystemUtilities.itemExists(at: destination) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagingURL, to: destination)
            staging = nil
            try FileManager.default.removeItem(at: source)
            info.bundle.location = localLocation
            info.localAppPathHint = recordedHint
            info.bundle.migration = nil
            try await metadata.saveAppInfo(storedInfo, at: management.root)
            model.setAppInfo(storedInfo, containerID: container.id)
            try persistCommittedState(info)
            updateManagedApp(bundleID: bundleID, path: destination.path)
        } catch {
            runtime.setPhase(.rollingBack)
            if let staging, FileSystemUtilities.itemExists(at: staging) {
                try? FileManager.default.removeItem(at: staging)
            }
            info.bundle.location = originalLocation
            info.bundle.migration = nil
            throw error
        }
    }

    private func checkpoint(
        _ info: ManagedApplicationInfo,
        phase: MigrationExecutionPhase,
        progress: Double
    ) throws {
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

    private func updateManagedApp(bundleID: String, path: String) {
        guard model.app(identifiedBy: bundleID) != nil else { return }
        model.updateAppLocation(path: path, persistence: .managed, for: bundleID)
        appStore.save(model.apps)
    }

    private func recordLocalAppPathHint(
        bundleID: String,
        localPathHint: String?,
        target: ExternalAPFSContainer,
        at root: URL
    ) async throws {
        let dataVolumeUUID: String
        if let existing = try await metadata.loadAppInfo(bundleID: bundleID, at: root) {
            dataVolumeUUID = existing.dataVolumeUUID
        } else if runtime.activeRequest?.content == .appAndData {
            // The Data executor runs next and creates the authoritative AppInfo
            // after the new Data Volume receives its stable UUID.
            return
        } else {
            throw failure("The target Data Volume is unavailable for this App migration.")
        }
        let updated = try await metadata.upsertAppInfo(
            bundleID: bundleID,
            dataVolumeUUID: dataVolumeUUID,
            localAppPathHint: localPathHint,
            at: root
        )
        model.setAppInfo(updated, containerID: target.id)
    }

    private func localRestoreDestination(
        source: URL,
        bundleID: String,
        pathHint: String?
    ) -> URL {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard let pathHint, !pathHint.isEmpty else { return fallback }
        let candidate = ExStorageLayout.resolveLocalPath(pathHint).standardizedFileURL
        guard candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return fallback
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = candidate.path
        let isInsideHome = path.hasPrefix(home + "/")
        let isInsideApplications = path.hasPrefix("/Applications/")
        guard isInsideHome || isInsideApplications else { return fallback }
        if FileSystemUtilities.itemExists(at: candidate),
           Bundle(url: candidate)?.bundleIdentifier != bundleID {
            return fallback
        }
        return candidate
    }

    private func persistCommittedState(_ info: ManagedApplicationInfo) throws {
        guard let request = runtime.activeRequest,
              var record = try migrationStore.record(for: request.id) else { return }
        record.appInfo = info
        try migrationStore.save(record)
    }

    private func deleteLocalApplication(_ url: URL) async throws {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            throw failure("Refusing to permanently delete a path that is not an App bundle.")
        }
        try await Task.detached(priority: .utility) {
            guard FileSystemUtilities.itemExists(at: url) else { return }
            try FileManager.default.removeItem(at: url)
        }.value
    }

    private func setOperation(_ message: String, progress: Double?) {
        statusReporter.update(message: message, progress: progress)
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "PlayCoverExStorage.Migration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
