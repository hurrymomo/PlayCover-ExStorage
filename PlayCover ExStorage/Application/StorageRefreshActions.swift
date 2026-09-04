import AppKit
import Foundation

@MainActor
extension ManagedAppActions {
    /// Reconciles app records and on-disk metadata after AppModel receives a
    /// new storage snapshot. It does not scan the filesystem itself.
    func synchronizeManagedAppsWithStorage(
        in containersToSynchronize: [ExternalAPFSContainer]? = nil,
        completion: (() -> Void)? = nil
    ) {
        if let completion { refreshCompletions.append(completion) }
        if refreshInProgress {
            refreshRequested = true
            return
        }
        refreshInProgress = true
        Task {
            let found = containersToSynchronize ?? self.containers
            for container in found where !container.volumes.contains(where: {
                $0.name == ExStorageLayout.managementVolumeName
            }) {
                do {
                    let management = try await self.migrationStorage.prepareManagementVolume(for: container)
                    await self.rebuildAppInfo(in: container, at: management.root)
                } catch {
                    MigrationTrace.event(
                        "management-volume.create.failed",
                        details: "container=\(container.id) error=\(error.localizedDescription)"
                    )
                }
            }
            let refreshed = found.map { self.model.container(identifiedBy: $0.id) ?? $0 }
            await self.discoverManagedApps(matching: refreshed)
            await self.loadManagedMetadata(in: refreshed)
            // Reconciliation may take long enough for the user to change the
            // sidebar selection. Never restore the selection captured when the
            // task began and never automatically select the first container.
            // Only repair a container selection that is no longer available.
            if case let .container(selectedID) = self.viewModel.sidebarSelection,
               !self.containers.contains(where: { $0.id == selectedID }) {
                self.viewModel.selectSidebar(.allApps)
            }
            self.refreshInProgress = false
            let completions = self.refreshCompletions
            self.refreshCompletions.removeAll()
            completions.forEach { $0() }
            if self.refreshRequested {
                self.refreshRequested = false
                self.synchronizeManagedAppsWithStorage()
            }
        }
    }

    /// Used after filesystem-changing operations and storage notifications.
    /// Updating AppModel's storage revision causes ManagedAppListView to run
    /// the managed-app reconciliation phase.
    func rescanExternalStorage() {
        Task {
            let snapshot = await storageService.scanSnapshot()
            model.replaceStorage(with: snapshot)
        }
    }

    func localDataPath(for bundleID: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    func removeExternalDataInfo(bundleID: String) async throws {
        for container in containers {
            let alreadyManaged = container.volumes.contains {
                $0.name == ExStorageLayout.managementVolumeName
            }
            guard alreadyManaged else { continue }
            var management: ManagementVolumeContext?
            do {
                management = try await migrationStorage.prepareManagementVolume(for: container)
                guard let management else { continue }
                try await metadataStore.deleteAppInfo(bundleID: bundleID, at: management.root)
                try await migrationStorage.releaseManagementVolumeIfNeeded(management)
            } catch {
                if let management { try? await migrationStorage.releaseManagementVolumeIfNeeded(management) }
                throw error
            }
        }
        model.clearAppInfo(for: bundleID)
    }

    func loadManagedMetadata(in discoveredContainers: [ExternalAPFSContainer]) async {
        var loadedInfo: [String: ExStorageAppInfo] = [:]
        var loadedContainers: [String: UUID] = [:]
        for container in discoveredContainers.sorted(by: { $0.containerReference < $1.containerReference })
            where container.volumes.contains(where: { $0.name == ExStorageLayout.managementVolumeName }) {
            var management: ManagementVolumeContext?
            do {
                management = try await migrationStorage.prepareManagementVolume(for: container)
                guard let management else { continue }
                for storedInfo in try await metadataStore.loadAllAppInfo(at: management.root) {
                    let dataVolumeUUID = storedInfo.dataVolumeUUID
                    guard let dataVolume = container.volumes.first(where: {
                        $0.volumeUUID?.caseInsensitiveCompare(dataVolumeUUID) == .orderedSame
                    }) else {
                        MigrationTrace.event(
                            "management-metadata.data-volume-missing",
                            bundleID: storedInfo.bundleID,
                            details: "container=\(container.id) volumeUUID=\(dataVolumeUUID)"
                        )
                        continue
                    }
                    if dataVolume.name != storedInfo.bundleID {
                        MigrationTrace.event(
                            "management-metadata.data-volume-name-mismatch",
                            bundleID: storedInfo.bundleID,
                            details: "actualName=\(dataVolume.name) volumeUUID=\(dataVolumeUUID)"
                        )
                    }
                    if model.app(identifiedBy: storedInfo.bundleID) == nil {
                        model.insertOrUpdateApp(
                            bundleIdentifier: storedInfo.bundleID,
                            name: storedInfo.bundleID,
                            applicationPath: "",
                            persistence: .managed
                        )
                    }
                    loadedInfo[storedInfo.bundleID] = storedInfo
                    loadedContainers[storedInfo.bundleID] = container.id
                }
                try await migrationStorage.releaseManagementVolumeIfNeeded(management)
            } catch {
                MigrationTrace.event(
                    "management-metadata.load.failed",
                    details: "container=\(container.id) error=\(error.localizedDescription)"
                )
                if let management { try? await migrationStorage.releaseManagementVolumeIfNeeded(management) }
            }
        }
        for (bundleID, info) in loadedInfo {
            guard let containerID = loadedContainers[bundleID] else { continue }
            model.setAppInfo(info, containerID: containerID)
        }
        persistManagedApps()
        await migrationService.resumeInterruptedMigration()
    }

    private func rebuildAppInfo(in container: ExternalAPFSContainer, at managementRoot: URL) async {
        for volume in container.volumes where volume.name != ExStorageLayout.managementVolumeName {
            guard let volumeUUID = volume.volumeUUID,
                  let appURL = verifiedReconstructionAppURL(bundleID: volume.name) else { continue }
            do {
                try await metadataStore.saveAppInfo(
                    ExStorageAppInfo(
                        bundleID: volume.name,
                        dataVolumeUUID: volumeUUID,
                        localAppPathHint: ExStorageLayout.portableLocalPath(appURL)
                    ),
                    at: managementRoot
                )
            } catch {
                MigrationTrace.event(
                    "management-volume.app-info-rebuild.failed",
                    bundleID: volume.name,
                    details: "container=\(container.id) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func verifiedReconstructionAppURL(bundleID: String) -> URL? {
        var candidates: [URL] = []
        if let app = model.app(identifiedBy: bundleID), !app.applicationPath.isEmpty {
            candidates.append(app.applicationURL)
        }
        candidates.append(contentsOf: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID))
        return candidates.first { url in
            url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                && storageService.itemKind(at: url) == .directory
                && Bundle(url: url)?.bundleIdentifier == bundleID
        }
    }

}
