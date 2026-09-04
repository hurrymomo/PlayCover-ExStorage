import AppKit
import Foundation

@MainActor
extension ManagedAppActions {
    func requestDelete(_ app: AppSnapshot) {
        let dataLocation: AppDataDeletionLocation
        if let container = managedDataContainer(for: app.bundleIdentifier) {
            guard let volume = managedDataVolume(for: app.bundleIdentifier),
                  let device = volume.bsdDevice,
                  let uuid = volume.volumeUUID else {
                activeDialog = .message(
                    title: "Cannot Delete Data",
                    message: "The external Data does not currently have a verifiable APFS device and UUID. Refresh the drive and try again."
                )
                return
            }
            dataLocation = .external(ExternalDataDeletionTarget(
                device: device,
                volumeUUID: uuid,
                containerReference: container.containerReference
            ))
        } else {
            dataLocation = .local
        }
        appDeletionRequest = AppDeletionRequest(
            app: app,
            dataLocation: dataLocation
        )
    }

    func delete(_ request: AppDeletionRequest, selection: AppDeletionSelection) {
        switch (request.dataLocation, selection) {
        case (.local, .app):
            deleteLocalApp(request.app, includingData: false)
        case (.local, .data):
            deleteLocalData(for: request.app)
        case (.local, .appAndData):
            deleteLocalApp(request.app, includingData: true)
        case let (.external(target), .app):
            deleteExternalApp(request.app, target: target, includingData: false)
        case let (.external(target), .data):
            deleteExternalData(for: request.app, target: target)
        case let (.external(target), .appAndData):
            deleteExternalApp(request.app, target: target, includingData: true)
        }
    }

    private func deleteExternalApp(
        _ app: AppSnapshot,
        target: ExternalDataDeletionTarget,
        includingData: Bool
    ) {
        guard !operation.isRunning else { return }
        guard isInstalledApp(app), app.applicationURL.pathExtension == "app" else {
            activeDialog = .message(
                title: "Cannot Delete App",
                message: "The recorded App path is no longer a valid application bundle."
            )
            return
        }
        let applicationURL = app.applicationURL

        operationMessage = includingData
            ? "Deleting \(app.name) and its external data…"
            : "Deleting \(app.name)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                if includingData {
                    let identity = await Task.detached(priority: .userInitiated) {
                        DiskUtilDiscovery.volumeIdentity(for: target.device)
                    }.value
                    guard identity?.volumeUUID == target.volumeUUID,
                          identity?.containerReference == target.containerReference else {
                        throw self.operationError("Refusing to delete external Data because its storage identity changed.")
                    }
                }

                try await ManagedAppDeletion.moveApplicationToTrash(
                    applicationURL,
                    using: self.storageService
                )
                if includingData {
                    try await ManagedAppDeletion.deleteVerifiedVolume(
                        device: target.device,
                        expectedUUID: target.volumeUUID,
                        expectedContainerReference: target.containerReference,
                        using: self.storageService
                    )
                    self.removeVolume(device: target.device)
                    try await self.removeExternalDataInfo(bundleID: app.bundleIdentifier)
                }
                self.model.removeApp(bundleIdentifier: app.bundleIdentifier)
                self.persistManagedApps()
                self.selectedAppBundleID = nil
                self.operation = .idle
                self.operationMessage = includingData
                    ? "Moved \(app.name) to Trash and deleted its external Data."
                    : "Moved \(app.name) to Trash. Its external Data was kept."
            } catch {
                self.operation = .failed
                self.operationMessage = error.localizedDescription
                self.activeDialog = .message(title: "Delete Failed", message: error.localizedDescription)
            }
        }
    }

    private func deleteLocalApp(_ app: AppSnapshot, includingData: Bool) {
        guard !operation.isRunning else { return }
        guard isInstalledApp(app), app.applicationURL.pathExtension == "app" else {
            activeDialog = .message(
                title: "Cannot Delete App",
                message: "The recorded App path is no longer a valid application bundle."
            )
            return
        }
        let applicationURL = app.applicationURL
        guard managedDataContainer(for: app.bundleIdentifier) == nil else {
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
                try await ManagedAppDeletion.moveApplicationToTrash(
                    applicationURL,
                    using: self.storageService
                )
                if includingData, self.storageService.itemExists(at: dataPath) {
                    try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                }
                self.model.removeApp(bundleIdentifier: app.bundleIdentifier)
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

    private func deleteLocalData(for app: AppSnapshot) {
        guard !operation.isRunning else { return }
        let dataPath = localDataPath(for: app.bundleIdentifier)
        let mountedExternally = containers.flatMap(\.volumes).contains { volume in
            guard let mountPoint = volume.mountPoint else { return false }
            return URL(fileURLWithPath: mountPoint).standardizedFileURL.path
                == dataPath.standardizedFileURL.path
        }
        guard !mountedExternally else {
            activeDialog = .message(
                title: "External Data Is Connected",
                message: "Disconnect the external App data before deleting local App data."
            )
            return
        }

        operationMessage = "Deleting \(app.name) data…"
        Task { [weak self] in
            guard let self else { return }
            do {
                if self.storageService.itemExists(at: dataPath) {
                    try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                }
                self.operation = .idle
                self.operationMessage = "Deleted \(app.name) data. The App was kept."
            } catch {
                self.operation = .failed
                self.operationMessage = error.localizedDescription
                self.activeDialog = .message(title: "Delete Failed", message: error.localizedDescription)
            }
        }
    }

    private func deleteExternalData(
        for app: AppSnapshot,
        target: ExternalDataDeletionTarget
    ) {
        guard !operation.isRunning else { return }
        operationMessage = "Deleting \(app.name) data…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ManagedAppDeletion.deleteVerifiedVolume(
                    device: target.device,
                    expectedUUID: target.volumeUUID,
                    expectedContainerReference: target.containerReference,
                    using: self.storageService
                )
                self.removeVolume(device: target.device)
                try await self.removeExternalDataInfo(bundleID: app.bundleIdentifier)
                self.operation = .idle
                self.operationMessage = "Deleted \(app.name) data. The App was kept."
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
                try await ManagedAppDeletion.deleteVerifiedVolume(
                    device: device,
                    expectedUUID: uuid,
                    expectedContainerReference: containerReference,
                    using: self.storageService
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

    func usableMountPoint(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }

    func isDirectoryEmptyOrMissing(_ url: URL) -> Bool {
        storageService.directoryIsEmptyOrMissing(at: url)
    }

    func operationError(_ message: String) -> NSError {
        NSError(domain: "PlayCoverExStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func updateMountPoint(for device: String, to mountPoint: String?) {
        model.replaceContainers(containers.map { container in
            ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                physicalStoreDeviceIdentifiers: container.physicalStoreDeviceIdentifiers,
                displayName: container.displayName,
                connectionType: container.connectionType,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: container.volumes.map {
                    $0.bsdDevice == device ? $0.replacingMountPoint(mountPoint) : $0
                }
            )
        })
    }

    func addOrUpdateVolume(containerID: ExternalAPFSContainer.ID, volume: ExternalVolume) {
        model.replaceContainers(containers.map { container in
            guard container.id == containerID else { return container }
            var volumes = container.volumes.filter { $0.bsdDevice != volume.bsdDevice }
            volumes.append(volume)
            return ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                physicalStoreDeviceIdentifiers: container.physicalStoreDeviceIdentifiers,
                displayName: container.displayName,
                connectionType: container.connectionType,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: volumes
            )
        })
    }

    func removeVolume(device: String) {
        model.replaceContainers(containers.map { container in
            ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                physicalStoreDeviceIdentifiers: container.physicalStoreDeviceIdentifiers,
                displayName: container.displayName,
                connectionType: container.connectionType,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: container.volumes.filter { $0.bsdDevice != device }
            )
        })
    }}
