import AppKit
import Foundation

@MainActor
extension ManagedAppActions {
    func disconnectAppData() {
        guard let bundleID = bundleIdentifier,
              !isAppOperationRunning(bundleID: bundleID),
              let volume = managedDataVolume(for: bundleID),
              connectionState(for: volume, bundleID: bundleID) == .connected else { return }
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
            do {
                try await self.storageService.unmountVolume(at: dataPath)
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
                self.model.setAppFailureMessage(error.localizedDescription, for: bundleID)
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
              FileSystemUtilities.itemExists(at: applicationURL) else {
            activeDialog = .message(title: "App Not Found", message: "Locate or add the app again before opening it.")
            return
        }

        guard let bundleID = bundleIdentifier,
              let container = managedDataContainer(for: bundleID),
              let volume = managedDataVolume(for: bundleID),
              container.volumes.contains(where: { $0.id == volume.id }) else {
            openApplication(at: applicationURL)
            return
        }
        if connectionState(for: volume, bundleID: bundleID) == .connected {
            openApplication(at: applicationURL)
            return
        }
        guard !isAppOperationRunning(bundleID: bundleID) else { return }
        pendingOpenAfterConnectURL = applicationURL
        requestReconnectAppData()
    }

    func openAppData(for app: AppSnapshot) {
        let containerURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(app.bundleIdentifier, isDirectory: true)
        guard FileSystemUtilities.itemExists(at: containerURL) else {
            activeDialog = .message(
                title: "App Data Not Found",
                message: "No container exists at \(containerURL.path). Launch the App once, then try again."
            )
            return
        }
        AppLauncher.reveal(containerURL)
    }

    func showAppInFinder(_ app: AppSnapshot) {
        let applicationURL = app.applicationURL
        guard FileSystemUtilities.itemExists(at: applicationURL) else {
            activeDialog = .message(
                title: "App Not Found",
                message: "The recorded App no longer exists at \(applicationURL.path)."
            )
            return
        }
        AppLauncher.reveal(applicationURL)
    }

    func cancelPendingOpenAfterConnect() {
        pendingOpenAfterConnectURL = nil
    }

    func openPendingAppIfNeeded() {
        guard let url = pendingOpenAfterConnectURL else { return }
        pendingOpenAfterConnectURL = nil
        openApplication(at: url)
    }

    func openApplication(at applicationURL: URL) {
        let openedBundleID = Bundle(url: applicationURL)?.bundleIdentifier
        AppLauncher.openApplication(at: applicationURL) { [weak self] error in
            guard let self else { return }
            if let error {
                if let openedBundleID {
                    self.model.setAppFailureMessage(error.localizedDescription, for: openedBundleID)
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
        guard let bundleID = bundleIdentifier else { return }
        guard let applicationName,
              let applicationURL,
              FileSystemUtilities.itemExists(at: applicationURL) else {
            setAppOperation(
                bundleID: bundleID,
                operation: .failed,
                message: "Locate or install the matching app before changing its data location."
            )
            return
        }
        guard let selected = managedDataContainer(for: bundleID) else {
            setAppOperation(
                bundleID: bundleID,
                operation: .failed,
                message: "The external storage recorded for \(applicationName) is not available."
            )
            return
        }
        guard !isAppOperationRunning(bundleID: bundleID) else { return }

        setAppOperation(
            bundleID: bundleID,
            operation: .reconnecting,
            message: "Looking for \(bundleID) on \(selected.displayName ?? selected.containerReference)…"
        )

        Task { [weak self] in
            guard let self else { return }
            var mountAttempted = false
            var localDataWillBeHidden = false
            do {
                _ = MigrationTrace.prepareCommandLog(kind: "reconnect")
                guard let match = self.managedDataVolume(for: bundleID),
                      selected.volumes.contains(where: { $0.id == match.id }),
                      let device = match.bsdDevice else {
                    throw NSError(domain: "Reconnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Data Volume recorded for \(bundleID) was not found on the selected SSD."])
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
                    try await self.storageService.unmountVolume(
                        at: URL(fileURLWithPath: currentMount)
                    )
                    self.updateMountPoint(for: device, to: nil)
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
                    try await self.storageService.deletePrivilegedItem(at: dataPath)
                    localDataWillBeHidden = false
                } else if localDataWillBeHidden {
                    self.setAppOperation(
                        bundleID: bundleID,
                        operation: .reconnecting,
                        message: "The local Data directory is not empty. Reconnecting will temporarily hide its contents without deleting them…"
                    )
                }
                try self.ensureLocalDataDirectory(for: bundleID)
                mountAttempted = true
                try await self.storageService.mountAPFSVolume(
                    device: device,
                    at: dataPath,
                    options: ["noowners", "nobrowse"]
                )
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

    func ensureLocalDataDirectory(for bundleID: String) throws {
        let dataPath = localDataPath(for: bundleID)
        switch FileSystemUtilities.itemKind(at: dataPath) {
        case .directory:
            return
        case .file:
            throw operationError("The App Data path exists but is not a directory: \(dataPath.path)")
        case .missing:
            break
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

}
