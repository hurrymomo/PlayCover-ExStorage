import AppKit
import Foundation

@MainActor
extension ManagedAppActions {
    @discardableResult
    func handleAppDrop(url: URL, calculateDisplaySize: Bool = true) -> AppSnapshot? {
        guard url.pathExtension == "app" else {
            activeDialog = .message(title: "Invalid App", message: "Only .app bundles are accepted.")
            return nil
        }

        guard let record = managedAppRecord(from: url) else {
            activeDialog = .message(title: "Invalid App", message: "The app does not provide a valid Bundle ID.")
            return nil
        }
        model.insertOrUpdateApp(
            bundleIdentifier: record.bundleIdentifier,
            name: record.name,
            applicationPath: record.applicationPath,
            persistence: record.persistence
        )
        selectedAppBundleID = record.bundleIdentifier
        persistManagedApps()
        if calculateDisplaySize {
            calculateDataSizeIfNeeded(for: record.bundleIdentifier)
            calculateAppSizeIfNeeded(for: record.bundleIdentifier)
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

    func selectManagedApp(_ app: AppSnapshot) {
        selectedAppBundleID = app.bundleIdentifier
        calculateDataSizeIfNeeded(for: app.bundleIdentifier)
        calculateAppSizeIfNeeded(for: app.bundleIdentifier)
        guard !app.applicationPath.isEmpty,
              FileSystemUtilities.itemExists(at: app.applicationURL) else {
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
        guard let index = apps.firstIndex(where: { $0.bundleIdentifier == bundleID }),
              apps[index].dataSize == .unknown else { return }
        model.updateDataSize(.calculating, for: bundleID)
        let dataPath = localDataPath(for: bundleID)
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) {
                try? FileSystemUtilities.allocatedSize(of: dataPath)
            }.value
            guard let self else { return }
            self.model.updateDataSize(
                size.map(ManagedAppSizeState.available) ?? .unknown,
                for: bundleID
            )
        }
    }

    func calculateAppSizeIfNeeded(for bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleIdentifier == bundleID }),
              apps[index].appSize == .unknown,
              let app = apps.first(where: { $0.bundleIdentifier == bundleID }),
              FileSystemUtilities.itemExists(at: app.applicationURL) else { return }
        model.updateAppSize(.calculating, for: bundleID)
        let applicationURL = app.applicationURL
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) {
                try? FileSystemUtilities.allocatedSize(of: applicationURL)
            }.value
            guard let self else { return }
            self.model.updateAppSize(
                size.map(ManagedAppSizeState.available) ?? .unknown,
                for: bundleID
            )
        }
    }

    func keepInLibrary(bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleIdentifier == bundleID }) else { return }
        model.updateAppPersistence(.kept, for: bundleID)
        persistManagedApps()
        setAppOperation(
            bundleID: bundleID,
            operation: .succeeded,
            message: "\(apps[index].name) will remain in All Apps after ExStorage is reopened."
        )
    }

    func removeFromLibrary(bundleID: String) {
        guard apps.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        model.removeApp(bundleIdentifier: bundleID)
        persistManagedApps()
        if selectedAppBundleID == bundleID { selectedAppBundleID = nil }
        model.clearAppOperationState(for: bundleID)
    }

    func restoreManagedApps() {
        ManagedAppLibrary.restore(into: model, from: appStore)
        // Launch into the All Apps overview. Individual Apps are selected only after an
        // explicit click or drop, so the initial status bar shows the library summary.
        selectedAppBundleID = nil
    }

    func managedAppRecord(from url: URL) -> AppSnapshot? {
        ManagedAppLibrary.record(from: url, model: model)
    }

    func persistManagedApps() {
        ManagedAppLibrary.persist(model, using: appStore)
    }

    func discoverManagedApps(matching containers: [ExternalAPFSContainer]) async {
        struct ExternalCandidate {
            let app: AppSnapshot
            let hasMatchingDataInfo: Bool
            let containerReference: String
        }
        struct AppInfoLocation {
            var info: ExStorageAppInfo
            let root: URL
            let containerID: UUID
            let containerReference: String
        }

        var externalCandidates: [String: [ExternalCandidate]] = [:]
        var appInfoLocations: [String: [AppInfoLocation]] = [:]
        var managementRoots: [URL] = []
        var changed = false

        for container in containers.sorted(by: { $0.containerReference < $1.containerReference })
            where container.volumes.contains(where: { $0.name == ExStorageLayout.managementVolumeName }) {
            do {
                let management = try await migrationStorage.prepareManagementVolume(for: container)
                managementRoots.append(management.root.standardizedFileURL)
                let appInfo = try await metadataStore.loadAllAppInfo(at: management.root)
                for info in appInfo {
                    appInfoLocations[info.bundleID, default: []].append(
                        AppInfoLocation(
                            info: info,
                            root: management.root,
                            containerID: container.id,
                            containerReference: container.containerReference
                        )
                    )
                }
                let dataBundleIDs: Set<String> = Set(
                    appInfo.compactMap { info -> String? in
                        return container.volumes.contains {
                            $0.volumeUUID?.caseInsensitiveCompare(info.dataVolumeUUID) == .orderedSame
                        } ? info.bundleID : nil
                    }
                )
                for url in try await metadataStore.applicationBundleURLs(at: management.root) {
                    guard let app = verifiedAppRecord(at: url),
                          dataBundleIDs.contains(app.bundleIdentifier) else { continue }
                    externalCandidates[app.bundleIdentifier, default: []].append(
                        ExternalCandidate(
                            app: app,
                            hasMatchingDataInfo: dataBundleIDs.contains(app.bundleIdentifier),
                            containerReference: container.containerReference
                        )
                    )
                }
            } catch {
                MigrationTrace.event(
                    "managed-app.external-scan.failed",
                    details: "container=\(container.id) error=\(error.localizedDescription)"
                )
            }
        }

        var resolvedBundleIDs = Set<String>()
        for (bundleID, candidates) in externalCandidates {
            if candidates.count > 1 {
                MigrationTrace.event(
                    "managed-app.external-duplicate",
                    bundleID: bundleID,
                    details: "matches=\(candidates.count)"
                )
            }
            let selected = candidates.sorted {
                if $0.hasMatchingDataInfo != $1.hasMatchingDataInfo {
                    return $0.hasMatchingDataInfo && !$1.hasMatchingDataInfo
                }
                return $0.containerReference < $1.containerReference
            }[0]
            if model.insertOrUpdateApp(
                bundleIdentifier: selected.app.bundleIdentifier,
                name: selected.app.name,
                applicationPath: selected.app.applicationPath,
                persistence: .managed
            ) {
                changed = true
            }
            resolvedBundleIDs.insert(bundleID)
        }

        let bundleIDs = Set(apps.map(\.bundleIdentifier))
            .union(externalCandidates.keys)
            .union(appInfoLocations.keys)

        for bundleID in bundleIDs.sorted() where !resolvedBundleIDs.contains(bundleID) {
            let locations = appInfoLocations[bundleID]?
                .sorted { $0.containerReference < $1.containerReference }
                ?? []
            let hintedApp = locations
                .lazy
                .compactMap { location -> AppSnapshot? in
                    return self.verifiedAppRecord(
                        at: ExStorageLayout.resolveLocalPath(location.info.localAppPathHint),
                        expectedBundleID: bundleID
                    )
                }
                .first
            let systemMatch = NSWorkspace.shared
                .urlsForApplications(withBundleIdentifier: bundleID)
                .compactMap { verifiedAppRecord(at: $0, expectedBundleID: bundleID) }
                .first { candidate in
                    let path = candidate.applicationURL.standardizedFileURL.path
                    return !managementRoots.contains { path.hasPrefix($0.path + "/") }
                }
            guard let selected = systemMatch ?? hintedApp else { continue }

            if let systemMatch {
                let portablePath = ExStorageLayout.portableLocalPath(systemMatch.applicationURL)
                for location in locations where location.info.localAppPathHint != portablePath {
                    do {
                        if let updated = try await metadataStore.updateLocalAppPathHint(
                            bundleID: bundleID,
                            localAppPathHint: portablePath,
                            at: location.root
                        ), model.appInfoContainerID(for: bundleID) == location.containerID {
                            model.setAppInfo(updated, containerID: location.containerID)
                        }
                    } catch {
                        MigrationTrace.event(
                            "managed-app.hint-update.failed",
                            bundleID: bundleID,
                            details: "container=\(location.containerID) error=\(error.localizedDescription)"
                        )
                    }
                }
            }
            if model.insertOrUpdateApp(
                bundleIdentifier: selected.bundleIdentifier,
                name: selected.name,
                applicationPath: selected.applicationPath,
                persistence: .managed
            ) {
                changed = true
            }
        }

        if changed {
            persistManagedApps()
        }
    }

    private func verifiedAppRecord(
        at url: URL,
        expectedBundleID: String? = nil
    ) -> AppSnapshot? {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              FileSystemUtilities.itemKind(at: url) == .directory,
              let record = managedAppRecord(from: url),
              expectedBundleID == nil || record.bundleIdentifier == expectedBundleID else {
            return nil
        }
        return AppSnapshot(
            bundleIdentifier: record.bundleIdentifier,
            name: record.name,
            applicationPath: record.applicationPath,
            persistence: .managed
        )
    }

    func markAppManaged(bundleID: String) {
        guard model.app(identifiedBy: bundleID) != nil else { return }
        model.updateAppPersistence(.managed, for: bundleID)
        persistManagedApps()
    }

}
