//
//  ContentView.swift
//  PlayCover ExStorage
//

import SwiftUI
import Combine

// MARK: - Storage Discovery (read-only, using diskutil -plist)
nonisolated struct DiskUtilDiscovery {
    struct VolumeInfo {
        let name: String
        let filesystem: String
        let mountPoint: String?
        let isAPFS: Bool
        let bsdDevice: String?
        let isExternal: Bool
        let totalSizeBytes: Int64?
        let availableBytes: Int64?
    }

    private static func byteCount(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    static func discoverExternalAPFSContainers() -> [ExternalAPFSContainer] {
        guard let apfsPlist = runDiskutil(args: ["apfs", "list", "-plist"]),
              let apfsDict = try? PropertyListSerialization.propertyList(from: apfsPlist, options: [], format: nil) as? [String: Any],
              let containers = apfsDict["Containers"] as? [[String: Any]] else {
            return []
        }
        var result: [ExternalAPFSContainer] = []
        for container in containers {
            guard let cref = container["ContainerReference"] as? String else { continue }
            guard let cuuidStr = container["APFSContainerUUID"] as? String, let cuuid = UUID(uuidString: cuuidStr) else { continue }
            let capacityTotalBytes = byteCount(container["CapacityCeiling"])
            let capacityFreeBytes = byteCount(container["CapacityFree"])
            // Only keep external containers based on ContainerReference's Internal flag
            var isExternal = false
            var mediaName: String? = nil
            if let infoData = runDiskutil(args: ["info", "-plist", "/dev/\(cref)"]),
               let info = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] {
                let internalFlag = (info["Internal"] as? Bool) ?? true // missing treated as internal
                isExternal = !internalFlag
                mediaName = info["MediaName"] as? String
            }
            guard isExternal else { continue }
            var vols: [ExternalVolume] = []
            if let volsArr = container["Volumes"] as? [[String: Any]] {
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: volsArr.count) { index in
                    let v = volsArr[index]
                    if let dev = v["DeviceIdentifier"] as? String, let vi = infoForDevice(dev) {
                        let mapped = ExternalVolume(name: vi.name,
                                                    filesystem: vi.filesystem,
                                                    mountPoint: vi.mountPoint,
                                                    isAPFS: vi.isAPFS,
                                                    bsdDevice: vi.bsdDevice,
                                                    totalSizeBytes: vi.totalSizeBytes,
                                                    availableBytes: vi.availableBytes,
                                                    usedBytes: byteCount(v["CapacityInUse"]),
                                                    isSelectable: vi.isAPFS,
                                                    isExternal: true)
                        lock.lock()
                        vols.append(mapped)
                        lock.unlock()
                    }
                }
                vols.sort { ($0.bsdDevice ?? $0.name) < ($1.bsdDevice ?? $1.name) }
            }
            result.append(ExternalAPFSContainer(containerUUID: cuuid, containerReference: cref, displayName: mediaName, capacityTotalBytes: capacityTotalBytes, capacityFreeBytes: capacityFreeBytes, volumes: vols))
        }
        return result
    }

    private static func infoForDevice(_ device: String) -> VolumeInfo? {
        guard let data = runDiskutil(args: ["info", "-plist", "/dev/\(device)"]),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        let content = dict["Content"] as? String
        let isAPFS = (content == "apfs" || content == "AppleAPFS") || (dict["FilesystemType"] as? String == "apfs")
        let fsType = (dict["FilesystemType"] as? String) ?? (isAPFS ? "APFS" : (dict["Content"] as? String) ?? "Unknown")
        let name = (dict["VolumeName"] as? String) ?? (dict["MediaName"] as? String) ?? device
        let mountPoint = dict["MountPoint"] as? String
        let bsd = dict["DeviceIdentifier"] as? String ?? device
        let isInternal = (dict["Internal"] as? Bool) ?? false
        let isExternal = !isInternal
        var total: Int64? = nil
        var free: Int64? = nil
        if let sizeDict = dict["TotalSize"] as? [String: Any], let size = sizeDict["Size"] as? Int64 { total = size }
        if let freeDict = dict["FreeSpace"] as? [String: Any], let size = freeDict["Size"] as? Int64 { free = size }
        return VolumeInfo(name: name, filesystem: fsType, mountPoint: mountPoint, isAPFS: isAPFS, bsdDevice: bsd, isExternal: isExternal, totalSizeBytes: total, availableBytes: free)
    }

    private static func runDiskutil(args: [String]) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = args
        let out = Pipe(); task.standardOutput = out
        let err = Pipe(); task.standardError = err
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        guard task.terminationStatus == 0 else { return nil }
        return out.fileHandleForReading.readDataToEndOfFile()
    }
}

// MARK: - Core Models
nonisolated struct ExternalAPFSContainer: Identifiable, Hashable {
    let containerUUID: UUID
    let containerReference: String
    let displayName: String?
    let capacityTotalBytes: Int64?
    let capacityFreeBytes: Int64?
    let volumes: [ExternalVolume]

    var id: UUID { containerUUID }

    init(containerUUID: UUID, containerReference: String, displayName: String?, capacityTotalBytes: Int64?, capacityFreeBytes: Int64?, volumes: [ExternalVolume]) {
        self.containerUUID = containerUUID
        self.containerReference = containerReference
        self.displayName = displayName
        self.capacityTotalBytes = capacityTotalBytes
        self.capacityFreeBytes = capacityFreeBytes
        self.volumes = volumes
    }
}

nonisolated struct ExternalVolume: Identifiable, Hashable {
    let name: String
    let filesystem: String
    let mountPoint: String?
    let isAPFS: Bool
    let bsdDevice: String?
    let totalSizeBytes: Int64?
    let availableBytes: Int64?
    let usedBytes: Int64?
    let isSelectable: Bool
    let isExternal: Bool

    var id: String { bsdDevice ?? "\(name)-\(mountPoint ?? "unmounted")" }

    init(name: String, filesystem: String, mountPoint: String?, isAPFS: Bool, bsdDevice: String?, totalSizeBytes: Int64?, availableBytes: Int64?, usedBytes: Int64?, isSelectable: Bool, isExternal: Bool) {
        self.name = name
        self.filesystem = filesystem
        self.mountPoint = mountPoint
        self.isAPFS = isAPFS
        self.bsdDevice = bsdDevice
        self.totalSizeBytes = totalSizeBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.isSelectable = isSelectable
        self.isExternal = isExternal
    }

    func replacingMountPoint(_ newMountPoint: String?) -> ExternalVolume {
        ExternalVolume(
            name: name,
            filesystem: filesystem,
            mountPoint: newMountPoint,
            isAPFS: isAPFS,
            bsdDevice: bsdDevice,
            totalSizeBytes: totalSizeBytes,
            availableBytes: availableBytes,
            usedBytes: usedBytes,
            isSelectable: isSelectable,
            isExternal: isExternal
        )
    }
}

enum VolumeConnectionState {
    case unrelated
    case disconnected
    case connected

    var color: Color? {
        switch self {
        case .unrelated: nil
        case .disconnected: .yellow
        case .connected: .green
        }
    }
}

func connectionState(for volume: ExternalVolume, bundleID: String?) -> VolumeConnectionState {
    guard let bundleID, volume.name == bundleID else { return .unrelated }
    guard let mountPoint = volume.mountPoint?.trimmingCharacters(in: .whitespacesAndNewlines),
          !mountPoint.isEmpty else { return .disconnected }

    let expectedDataPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers", isDirectory: true)
        .appendingPathComponent(bundleID, isDirectory: true)
        .appendingPathComponent("Data", isDirectory: true)
        .standardizedFileURL.path
    let actualMountPath = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
    return actualMountPath == expectedDataPath ? .connected : .disconnected
}

enum MigrationStage: String, Identifiable, CaseIterable {
    case apfsContainerIdentified = "APFS container identified"
    case applicationVolumeCreated = "Application APFS volume created"
    case dataCopied = "Data copied"
    case copyVerified = "Copy verified"
    case temporaryUnmount = "External volume unmounted"
    case localBackupCreated = "Local backup created"
    case mountPointPrepared = "Mount point prepared"
    case applicationVolumeMounted = "External volume mounted"
    case mountVerified = "Mount verified"

    var id: String { rawValue }
}

struct CreatedAPFSVolume {
    let bsdDevice: String
    let mountPoint: URL?
}

enum AppOperation {
    case idle
    case migrating
    case reconnecting
    case restoring
    case deletingBackup
    case succeeded
    case failed

    var title: String {
        switch self {
        case .idle: "Ready"
        case .migrating: "Migrating App Data"
        case .reconnecting: "Reconnecting App Data"
        case .restoring: "Restoring Local Data"
        case .deletingBackup: "Deleting Local Backup"
        case .succeeded: "Operation Complete"
        case .failed: "Operation Failed"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "circle.dashed"
        case .migrating: "externaldrive.badge.plus"
        case .reconnecting: "link"
        case .restoring: "arrow.uturn.backward.circle"
        case .deletingBackup: "trash"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var isRunning: Bool {
        switch self {
        case .migrating, .reconnecting, .restoring, .deletingBackup: true
        default: false
        }
    }
}

enum AppDialog: Identifiable {
    case confirmRestore
    case confirmDeleteBackup
    case migrationSucceeded
    case migrationRolledBackForFullDiskAccess(error: String)
    case reconnectFailedForFullDiskAccess(error: String)
    case message(title: String, message: String)

    var id: String {
        switch self {
        case .confirmRestore: "confirmRestore"
        case .confirmDeleteBackup: "confirmDeleteBackup"
        case .migrationSucceeded: "migrationSucceeded"
        case .migrationRolledBackForFullDiskAccess: "migrationRolledBackForFullDiskAccess"
        case .reconnectFailedForFullDiskAccess: "reconnectFailedForFullDiskAccess"
        case let .message(title, message): "message-\(title)-\(message)"
        }
    }
}

struct MigrationReconnectChoice: Identifiable {
    let id = UUID()
    let containerID: ExternalAPFSContainer.ID
    let diskName: String
    let volumeName: String
    let device: String
    let mountPoint: String?
}

// MARK: - View Models (UI-only scaffolding)
@MainActor
final class AppViewModel: ObservableObject {
    private static let lastAppPathKey = "LastDroppedApplicationPath"

    // External containers list
    @Published var containers: [ExternalAPFSContainer] = []
    @Published var selectedContainerID: ExternalAPFSContainer.ID? = nil

    // Dropped app metadata
    @Published var appIcon: NSImage? = nil
    @Published var applicationName: String? = nil
    @Published var bundleIdentifier: String? = nil

    @Published var migrationStagesCompleted: Set<MigrationStage> = []

    @Published var operation: AppOperation = .idle
    @Published var operationMessage: String = "Drop an app and select an external APFS SSD to begin."
    @Published var operationProgress: Double? = nil
    @Published var activeDialog: AppDialog? = nil
    @Published var migrationReconnectChoice: MigrationReconnectChoice? = nil

    private var refreshInProgress = false
    private var refreshRequested = false

    var connectedVolumeCount: Int {
        containers.flatMap(\.volumes).filter {
            connectionState(for: $0, bundleID: bundleIdentifier) == .connected
        }.count
    }

    var disconnectedVolumeCount: Int {
        containers.flatMap(\.volumes).filter {
            connectionState(for: $0, bundleID: bundleIdentifier) == .disconnected
        }.count
    }

    init() {
        restoreLastDroppedApp()
    }

    func refreshExternalVolumes() {
        if refreshInProgress {
            refreshRequested = true
            return
        }
        refreshInProgress = true
        let selectedReference = containers
            .first(where: { $0.id == selectedContainerID })?
            .containerReference
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DiskUtilDiscovery.discoverExternalAPFSContainers()
            }.value
            self.containers = found
            self.selectedContainerID = found.first(where: { $0.containerReference == selectedReference })?.id
                ?? found.first?.id
            self.refreshInProgress = false
            if self.refreshRequested {
                self.refreshRequested = false
                self.refreshExternalVolumes()
            }
        }
    }

    func selectContainer(_ container: ExternalAPFSContainer) {
        selectedContainerID = container.id
        if let applicationName {
            operation = .idle
            operationMessage = "\(applicationName) and \(container.displayName ?? container.containerReference) are ready."
        }
    }

    func handleAppDrop(url: URL) {
        guard url.pathExtension == "app" else {
            activeDialog = .message(title: "Invalid App", message: "Only .app bundles are accepted.")
            return
        }

        loadAppMetadata(from: url, remember: true)
    }

    private func restoreLastDroppedApp() {
        guard let path = UserDefaults.standard.string(forKey: Self.lastAppPathKey) else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path), url.pathExtension == "app" else {
            UserDefaults.standard.removeObject(forKey: Self.lastAppPathKey)
            return
        }
        loadAppMetadata(from: url, remember: false)
    }

    private func loadAppMetadata(from url: URL, remember: Bool) {
        if remember {
            UserDefaults.standard.set(url.path, forKey: Self.lastAppPathKey)
        }

        // Try to load the dropped app as a Bundle to read Info.plist metadata
        if let appBundle = Bundle(url: url) {
            // Application display name
            let displayName = appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? appBundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            self.applicationName = displayName

            // CFBundleIdentifier
            if let bundleID = appBundle.bundleIdentifier, !bundleID.isEmpty {
                self.bundleIdentifier = bundleID
            } else if let rawID = appBundle.object(forInfoDictionaryKey: kCFBundleIdentifierKey as String) as? String, !rawID.isEmpty {
                self.bundleIdentifier = rawID
            } else {
                self.bundleIdentifier = nil
            }

            // App icon via NSWorkspace (best-effort)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            self.appIcon = icon
        } else {
            // Fallbacks if Bundle(url:) fails
            self.applicationName = url.deletingPathExtension().lastPathComponent
            self.bundleIdentifier = nil
            self.appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }

        // Reset progress when a new app is dropped
        migrationStagesCompleted = []
        if let name = applicationName {
            operationMessage = bundleIdentifier == nil
                ? "The app does not provide a Bundle ID."
                : "\(name) is ready. Select an external APFS SSD."
        }
    }

    private func validateMigrationInputs() -> Bool {
        guard bundleIdentifier != nil, applicationName != nil else {
            operation = .failed
            operationMessage = "Drop a valid .app with a Bundle ID first."
            return false
        }
        guard let _ = containers.first(where: { $0.id == selectedContainerID }) else {
            operation = .failed
            operationMessage = "Select an external APFS SSD first."
            return false
        }

        return true
    }

    func requestMigration() {
        guard validateMigrationInputs(), let bundleID = bundleIdentifier else { return }

        if containers.flatMap(\.volumes).contains(where: {
            connectionState(for: $0, bundleID: bundleID) == .connected
        }) {
            activeDialog = .message(
                title: "App Data Already Connected",
                message: "The matching external volume is already mounted at this app's Data directory. There is nothing to migrate."
            )
            return
        }

        if let match = containers.lazy.compactMap({ container -> MigrationReconnectChoice? in
            guard let volume = container.volumes.first(where: {
                $0.name == bundleID
                    && $0.bsdDevice != nil
                    && connectionState(for: $0, bundleID: bundleID) == .disconnected
            }), let device = volume.bsdDevice else { return nil }
            return MigrationReconnectChoice(
                containerID: container.id,
                diskName: container.displayName ?? container.containerReference,
                volumeName: bundleID,
                device: device,
                mountPoint: volume.mountPoint
            )
        }).first {
            migrationReconnectChoice = match
            return
        }

        startMigration()
    }

    func reconnectFromMigrationChoice(_ choice: MigrationReconnectChoice) {
        guard let container = containers.first(where: { $0.id == choice.containerID }) else {
            refreshExternalVolumes()
            operation = .failed
            operationMessage = "The external disk changed. Select it again and retry reconnecting."
            return
        }
        selectContainer(container)
        reconnectAppData()
    }

    func startMigration(replacing existingVolume: MigrationReconnectChoice? = nil) {
        guard validateMigrationInputs(), let bundleID = bundleIdentifier,
              let selected = containers.first(where: { $0.id == selectedContainerID }) else { return }

        let dataPath = localDataPath(for: bundleID)
        let backupPath = dataPath.deletingLastPathComponent().appendingPathComponent("Data.backup", isDirectory: true)
        let dataExists = FileManager.default.fileExists(atPath: dataPath.path)
        let backupExists = FileManager.default.fileExists(atPath: backupPath.path)
        guard dataExists || (existingVolume != nil && backupExists) else {
            operation = .failed
            operationMessage = "No local Data directory exists for \(bundleID). Launch the app once, then try again."
            return
        }
        guard existingVolume != nil || !backupExists else {
            operation = .failed
            operationMessage = "Data.backup already exists. Restore or remove that backup before migrating again."
            return
        }
        let selectedMatches = selected.volumes.filter { $0.name == bundleID }
        guard selectedMatches.isEmpty
                || (selectedMatches.count == 1 && selectedMatches.first?.bsdDevice == existingVolume?.device) else {
            operation = .failed
            operationMessage = "The selected SSD already contains a volume named \(bundleID). Reconnect it, or select a different SSD for a new migration."
            return
        }

        migrationStagesCompleted = []
        operation = .migrating
        operationProgress = 0
        operationMessage = "Preparing the selected APFS container…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshExternalVolumes() }
            var createdVolume: CreatedAPFSVolume?
            var localDataRenamed = false
            var dataMountAttempted = false
            var dataMountPreflightSucceeded = false
            do {
                let logURL = try OperationLog.prepare(named: "migrate")
                try await self.runPrivileged { try $0.beginOperationLog(at: logURL) }
                try await self.runPrivileged { try $0.ensureHelperAvailable() }

                if let existingVolume {
                    self.operationMessage = "Removing the existing \(bundleID) volume before migration…"
                    if let mountPoint = self.usableMountPoint(existingVolume.mountPoint) {
                        try await self.runPrivileged {
                            try $0.unmount(byMountPoint: URL(fileURLWithPath: mountPoint))
                        }
                    }
                    try await self.runPrivileged {
                        try $0.deleteAPFSVolume(byDevice: existingVolume.device)
                    }
                    self.removeVolume(device: existingVolume.device)

                    if FileManager.default.fileExists(atPath: backupPath.path) {
                        if self.isDirectoryEmptyOrMissing(dataPath) {
                            if FileManager.default.fileExists(atPath: dataPath.path) {
                                try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                            }
                            try await self.runPrivileged {
                                try $0.renameItem(from: backupPath, to: dataPath)
                            }
                        } else {
                            try await self.runPrivileged { try $0.deleteItem(at: backupPath) }
                        }
                    }
                }

                self.migrationStagesCompleted.insert(.apfsContainerIdentified)
                self.operationProgress = 0.12
                self.operationMessage = "Creating a dedicated volume for \(bundleID)…"

                let created = try await self.runPrivileged {
                    try $0.createAPFSVolume(containerRef: selected.containerReference, name: bundleID)
                }
                createdVolume = created
                self.migrationStagesCompleted.insert(.applicationVolumeCreated)
                self.operationProgress = 0.28
                self.operationMessage = "Copying app data to the external volume…"

                guard let volumeRoot = created.mountPoint else {
                    throw self.operationError("The new APFS volume did not provide a mount point.")
                }
                try await self.runPrivileged { try $0.unmount(byMountPoint: volumeRoot) }
                self.migrationStagesCompleted.insert(.temporaryUnmount)
                self.operationProgress = 0.36
                self.operationMessage = "Testing access to the app Data mount point before copying…"

                try await self.runPrivileged { try $0.renameItem(from: dataPath, to: backupPath) }
                localDataRenamed = true
                self.migrationStagesCompleted.insert(.localBackupCreated)
                self.migrationStagesCompleted.insert(.mountPointPrepared)
                dataMountAttempted = true
                try await self.runPrivileged {
                    try $0.mountAPFS(byDevice: created.bsdDevice, at: dataPath, options: ["noowners"])
                }
                dataMountPreflightSucceeded = true
                try await self.runPrivileged { try $0.unmount(byMountPoint: dataPath) }

                self.operationProgress = 0.48
                self.operationMessage = "Mount access verified. Copying app data to the external volume…"
                try await self.runPrivileged {
                    try $0.mountAPFS(byDevice: created.bsdDevice, at: volumeRoot, options: ["noowners"])
                }
                try await self.copyAsCurrentUser(from: backupPath, to: volumeRoot, logURL: logURL)
                self.migrationStagesCompleted.insert(.dataCopied)
                self.migrationStagesCompleted.insert(.copyVerified)

                self.operationProgress = 0.8
                self.operationMessage = "Data copy completed. Mounting the external volume at the app Data folder…"
                try await self.runPrivileged { try $0.unmount(byMountPoint: volumeRoot) }
                try await self.runPrivileged {
                    try $0.mountAPFS(byDevice: created.bsdDevice, at: dataPath, options: ["noowners"])
                }
                self.migrationStagesCompleted.insert(.applicationVolumeMounted)
                self.migrationStagesCompleted.insert(.mountVerified)

                self.addOrUpdateVolume(
                    containerID: selected.id,
                    volume: ExternalVolume(
                        name: bundleID,
                        filesystem: "APFS",
                        mountPoint: dataPath.path,
                        isAPFS: true,
                        bsdDevice: created.bsdDevice,
                        totalSizeBytes: nil,
                        availableBytes: nil,
                        usedBytes: nil,
                        isSelectable: true,
                        isExternal: true
                    )
                )

                self.operation = .succeeded
                self.operationProgress = 1
                self.operationMessage = "App data is now stored on and connected from the external APFS volume."
                self.activeDialog = .migrationSucceeded
            } catch {
                let migrationError = error
                var rollbackSucceeded = true
                if localDataRenamed {
                    try? await self.runPrivileged { try $0.unmount(byMountPoint: dataPath) }
                    if let volumeRoot = createdVolume?.mountPoint {
                        try? await self.runPrivileged { try $0.unmount(byMountPoint: volumeRoot) }
                    }
                    if FileManager.default.fileExists(atPath: dataPath.path) {
                        if self.isDirectoryEmptyOrMissing(dataPath) {
                            do {
                                try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                            } catch {
                                rollbackSucceeded = false
                            }
                        } else {
                            rollbackSucceeded = false
                        }
                    }
                    if FileManager.default.fileExists(atPath: backupPath.path) {
                        do {
                            try await self.runPrivileged { try $0.renameItem(from: backupPath, to: dataPath) }
                        } catch {
                            rollbackSucceeded = false
                        }
                    }
                }
                if let createdVolume {
                    do {
                        try await self.runPrivileged { try $0.deleteAPFSVolume(byDevice: createdVolume.bsdDevice) }
                    } catch {
                        rollbackSucceeded = false
                    }
                }
                self.operation = .failed
                self.operationProgress = nil
                if dataMountAttempted && !dataMountPreflightSucceeded && rollbackSucceeded {
                    self.operationMessage = "Migration was rolled back and local app data was restored. Enable Full Disk Access, then try again."
                    self.activeDialog = .migrationRolledBackForFullDiskAccess(
                        error: migrationError.localizedDescription
                    )
                } else if !rollbackSucceeded {
                    self.operationMessage = "Migration failed and rollback could not be fully verified. Do not retry until the migration log is reviewed. Original error: \(migrationError.localizedDescription)"
                } else {
                    self.operationMessage = migrationError.localizedDescription
                }
            }
        }
    }

    func reconnectAppData() {
        guard validateMigrationInputs(), let bundleID = bundleIdentifier,
              let selected = containers.first(where: { $0.id == selectedContainerID }) else { return }

        operation = .reconnecting
        operationProgress = nil
        operationMessage = "Looking for \(bundleID) on \(selected.displayName ?? selected.containerReference)…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshExternalVolumes() }
            var mountAttempted = false
            do {
                let logURL = try OperationLog.prepare(named: "reconnect")
                try await self.runPrivileged { try $0.beginOperationLog(at: logURL) }
                let matches = selected.volumes.filter { $0.name == bundleID && $0.bsdDevice != nil }
                guard matches.count <= 1 else {
                    throw NSError(domain: "Reconnect", code: 2, userInfo: [NSLocalizedDescriptionKey: "More than one volume named \(bundleID) exists on the selected SSD."])
                }
                guard let match = matches.first, let device = match.bsdDevice else {
                    throw NSError(domain: "Reconnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "No volume named \(bundleID) was found on the selected SSD."])
                }

                let dataPath = self.localDataPath(for: bundleID)
                if connectionState(for: match, bundleID: bundleID) == .connected {
                    self.operation = .succeeded
                    self.operationMessage = "\(bundleID) is already connected."
                    return
                }
                if let currentMount = self.usableMountPoint(match.mountPoint) {
                    try await self.runPrivileged {
                        try $0.unmount(byMountPoint: URL(fileURLWithPath: currentMount))
                    }
                }
                guard self.isSafeReconnectMountPoint(dataPath) else {
                    throw self.operationError("The local Data directory is not empty and no Data.backup exists. Reconnecting here could hide local data.")
                }
                mountAttempted = true
                try await self.runPrivileged {
                    try $0.mountAPFS(byDevice: device, at: dataPath, options: ["noowners"])
                }
                self.updateMountPoint(for: device, to: dataPath.path)
                self.operation = .succeeded
                self.operationMessage = "\(bundleID) is connected to \(dataPath.path)."
            } catch {
                self.operation = .failed
                if mountAttempted {
                    self.operationMessage = "Reconnect could not mount the external volume. No local backup was modified. Enable Full Disk Access, then try again."
                    self.activeDialog = .reconnectFailedForFullDiskAccess(error: error.localizedDescription)
                } else {
                    self.operationMessage = error.localizedDescription
                }
            }
        }
    }

    func requestRestore() {
        guard validateMigrationInputs() else { return }
        activeDialog = .confirmRestore
    }

    func restore() {
        guard validateMigrationInputs(), let bundleID = bundleIdentifier else { return }
        operation = .restoring
        operationProgress = nil
        operationMessage = "Preparing to restore local app data…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshExternalVolumes() }
            do {
                let logURL = try OperationLog.prepare(named: "restore")
                try await self.runPrivileged { try $0.beginOperationLog(at: logURL) }
                let dataPath = self.localDataPath(for: bundleID)
                let backupPath = dataPath.deletingLastPathComponent().appendingPathComponent("Data.backup", isDirectory: true)
                let recoveryPath = dataPath.deletingLastPathComponent().appendingPathComponent("Data.restore-in-progress", isDirectory: true)
                let volume = try self.resolveVolume(for: bundleID)
                var mountedPath = self.usableMountPoint(volume.mountPoint).map { URL(fileURLWithPath: $0) }

                if FileManager.default.fileExists(atPath: backupPath.path) {
                    self.operationMessage = "Restoring the existing Data.backup…"
                } else {
                    self.operationMessage = "No local backup was found. Copying data back from the external volume…"
                    if mountedPath == nil {
                        guard self.isDirectoryEmptyOrMissing(dataPath) else {
                            throw self.operationError("The local Data directory is not empty, so the external volume cannot be mounted there safely for recovery.")
                        }
                        try await self.runPrivileged {
                            try $0.mountAPFS(byDevice: volume.device, at: dataPath, options: ["noowners"])
                        }
                        mountedPath = dataPath
                    }
                    if FileManager.default.fileExists(atPath: recoveryPath.path) {
                        try await self.runPrivileged { try $0.deleteItem(at: recoveryPath) }
                    }
                    do {
                        try await self.copyVolumeContentsAsCurrentUser(
                            from: mountedPath!,
                            to: recoveryPath,
                            logURL: logURL
                        )
                        try await self.runPrivileged {
                            try $0.renameItem(from: recoveryPath, to: backupPath)
                        }
                    } catch {
                        if FileManager.default.fileExists(atPath: recoveryPath.path) {
                            try? await self.runPrivileged { try $0.deleteItem(at: recoveryPath) }
                        }
                        throw error
                    }
                }

                if let mountedPath {
                    try await self.runPrivileged { try $0.unmount(byMountPoint: mountedPath) }
                }
                if FileManager.default.fileExists(atPath: dataPath.path) {
                    try await self.runPrivileged { try $0.deleteItem(at: dataPath) }
                }
                try await self.runPrivileged { try $0.deleteAPFSVolume(byDevice: volume.device) }
                try await self.runPrivileged { try $0.renameItem(from: backupPath, to: dataPath) }
                self.removeVolume(device: volume.device)
                self.operation = .succeeded
                self.operationMessage = "Local data was restored and the external app volume was removed."
            } catch {
                self.operation = .failed
                self.operationMessage = error.localizedDescription
            }
        }
    }

    func requestDeleteBackup() {
        guard let bundleID = bundleIdentifier else {
            operation = .failed
            operationMessage = "Drop the app whose backup you want to delete."
            return
        }
        let backupPath = localDataPath(for: bundleID).deletingLastPathComponent().appendingPathComponent("Data.backup")
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            activeDialog = .message(title: "No Backup Found", message: "There is no Data.backup for \(bundleID).")
            return
        }
        activeDialog = .confirmDeleteBackup
    }

    func deleteBackup() {
        guard let bundleID = bundleIdentifier else { return }
        operation = .deletingBackup
        operationProgress = nil
        operationMessage = "Deleting the local Data.backup…"
        let backupPath = localDataPath(for: bundleID).deletingLastPathComponent().appendingPathComponent("Data.backup")
        Task { [weak self] in
            guard let self else { return }
            do {
                let logURL = try OperationLog.prepare(named: "remove")
                try await self.runPrivileged { try $0.beginOperationLog(at: logURL) }
                let backupSize = try? await Task.detached(priority: .utility) {
                    try Self.allocatedSize(of: backupPath)
                }.value
                try await self.runPrivileged { try $0.deleteItem(at: backupPath) }
                self.operation = .succeeded
                let released = backupSize.map(StorageSizeFormatter.string)
                self.operationMessage = released.map {
                    "The local backup was deleted, releasing approximately \($0) of disk space."
                } ?? "The local backup was deleted and its disk space was released."
                self.activeDialog = .message(
                    title: "Local Backup Deleted",
                    message: released.map {
                        "Data.backup was permanently deleted. Approximately \($0) of local disk space was released."
                    } ?? "Data.backup was permanently deleted and its local disk space was released."
                )
            } catch {
                self.operation = .failed
                self.operationMessage = error.localizedDescription
            }
        }
    }

    private func localDataPath(for bundleID: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    nonisolated private static func allocatedSize(of root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .isDirectoryKey]
        let fileManager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw NSError(domain: "BackupSize", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not inspect Data.backup."])
        }

        var total = Int64((try? root.resourceValues(forKeys: keys).fileAllocatedSize) ?? 0)
        for case let item as URL in enumerator {
            let allocated = try item.resourceValues(forKeys: keys).fileAllocatedSize ?? 0
            total += Int64(allocated)
        }
        if let enumerationError { throw enumerationError }
        return total
    }

    private func resolveVolume(for bundleID: String) throws -> (device: String, mountPoint: String?) {
        guard let selected = containers.first(where: { $0.id == selectedContainerID }) else {
            throw NSError(domain: "Restore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select the SSD containing the migrated volume."])
        }
        let matches = selected.volumes.filter { $0.name == bundleID && $0.bsdDevice != nil }
        if matches.count > 1 {
            throw NSError(domain: "Restore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Multiple matching volumes were found on the selected SSD."])
        }
        if let match = matches.first, let device = match.bsdDevice {
            return (device, match.mountPoint)
        }
        throw NSError(domain: "Restore", code: 3, userInfo: [NSLocalizedDescriptionKey: "No migrated volume named \(bundleID) was found on the selected SSD."])
    }

    private func runPrivileged<T: Sendable>(
        _ operation: @escaping @Sendable (XPCPrivilegedClient) throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try operation(XPCPrivilegedClient.shared)
        }.value
    }

    private func copyAsCurrentUser(from source: URL, to destination: URL, logURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OperationLog.copyWithDitto(from: source, to: destination, logURL: logURL)
        }.value
    }

    private func copyVolumeContentsAsCurrentUser(from source: URL, to destination: URL, logURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OperationLog.copyVolumeContentsWithDitto(from: source, to: destination, logURL: logURL)
        }.value
    }

    private func usableMountPoint(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }

    private func isDirectoryEmptyOrMissing(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty) ?? false
    }

    private func isSafeReconnectMountPoint(_ dataPath: URL) -> Bool {
        let backupPath = dataPath.deletingLastPathComponent().appendingPathComponent("Data.backup", isDirectory: true)
        return FileManager.default.fileExists(atPath: backupPath.path) || isDirectoryEmptyOrMissing(dataPath)
    }

    private func operationError(_ message: String) -> NSError {
        NSError(domain: "PlayCoverExStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func updateMountPoint(for device: String, to mountPoint: String?) {
        containers = containers.map { container in
            ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                displayName: container.displayName,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: container.volumes.map {
                    $0.bsdDevice == device ? $0.replacingMountPoint(mountPoint) : $0
                }
            )
        }
    }

    private func addOrUpdateVolume(containerID: ExternalAPFSContainer.ID, volume: ExternalVolume) {
        containers = containers.map { container in
            guard container.id == containerID else { return container }
            var volumes = container.volumes.filter { $0.bsdDevice != volume.bsdDevice }
            volumes.append(volume)
            return ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                displayName: container.displayName,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: volumes
            )
        }
    }

    private func removeVolume(device: String) {
        containers = containers.map { container in
            ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                displayName: container.displayName,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: container.volumes.filter { $0.bsdDevice != device }
            )
        }
    }
}

// MARK: - Subviews
struct ExternalDriveListView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var expandedContainers: Set<ExternalAPFSContainer.ID> = []

    var body: some View {
        List {
            ForEach(viewModel.containers) { container in
                DisclosureGroup(isExpanded: expansionBinding(for: container.id)) {
                    VStack(alignment: .leading, spacing: 8) {
                        if container.volumes.isEmpty {
                            Label("No APFS volumes", systemImage: "externaldrive.badge.questionmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(container.volumes) { volume in
                                VolumeSummaryRow(volume: volume, selectedBundleID: viewModel.bundleIdentifier)
                            }
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.vertical, 6)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(
                                matchIndicatorColor(for: container)
                                    ?? .secondary
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(container.displayName ?? "External APFS Storage")
                                .font(.headline.weight(isSelected(container) ? .semibold : .regular))
                            Text(containerSummary(container))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(container.containerReference)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background {
                        if isSelected(container) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                        }
                    }
                    .overlay(alignment: .leading) {
                        if isSelected(container) {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 4)
                                .padding(.vertical, 5)
                        }
                    }
                    .onTapGesture {
                        viewModel.selectContainer(container)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func expansionBinding(for id: ExternalAPFSContainer.ID) -> Binding<Bool> {
        Binding(
            get: { expandedContainers.contains(id) },
            set: { expanded in
                if expanded {
                    expandedContainers.insert(id)
                } else {
                    expandedContainers.remove(id)
                }
            }
        )
    }

    private func matchIndicatorColor(for container: ExternalAPFSContainer) -> Color? {
        let states = container.volumes.map {
            connectionState(for: $0, bundleID: viewModel.bundleIdentifier)
        }
        if states.contains(.connected) { return .green }
        if states.contains(.disconnected) { return .yellow }
        return nil
    }

    private func isSelected(_ container: ExternalAPFSContainer) -> Bool {
        viewModel.selectedContainerID == container.id
    }

    private func containerSummary(_ container: ExternalAPFSContainer) -> String {
        var summary = "\(container.volumes.count) volume\(container.volumes.count == 1 ? "" : "s")"
        if let free = container.capacityFreeBytes {
            summary += " • \(StorageSizeFormatter.string(free)) free"
        }
        return summary
    }
}

struct VolumeSummaryRow: View {
    let volume: ExternalVolume
    let selectedBundleID: String?

    private var connection: VolumeConnectionState {
        connectionState(for: volume, bundleID: selectedBundleID)
    }

    private var usableMountPoint: String? {
        guard let mountPoint = volume.mountPoint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mountPoint.isEmpty else { return nil }
        return mountPoint
    }

    private var mountDescription: String {
        guard let usableMountPoint else { return "Unmounted" }
        if connection == .disconnected {
            return "Mounted elsewhere: \(usableMountPoint)"
        }
        return "Mounted at \(usableMountPoint)"
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: usableMountPoint == nil ? "internaldrive" : "internaldrive.fill")
                .foregroundStyle(connection.color ?? .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .lineLimit(1)
                    if connection != .unrelated {
                        Text(connection == .connected ? "CONNECTED" : "DISCONNECTED")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(connection.color ?? .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((connection.color ?? .secondary).opacity(0.12), in: Capsule())
                    }
                }
                Text(volumeDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let device = volume.bsdDevice {
                Text(device)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .help(usableMountPoint ?? "This volume is unmounted")
    }

    private var volumeDescription: String {
        guard let used = volume.usedBytes else { return mountDescription }
        return "\(mountDescription) • \(StorageSizeFormatter.string(used)) used"
    }
}

private enum StorageSizeFormatter {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

struct AppDropAreaView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                if let icon = viewModel.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .cornerRadius(12)
                } else {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
                if let name = viewModel.applicationName, let bundle = viewModel.bundleIdentifier {
                    Text(name).font(.headline)
                    Text("Bundle ID:\n\(bundle)")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        Text("Drop an App Here")
                            .font(.headline)
                        Text(".app bundles only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .frame(minHeight: 150)
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    viewModel.handleAppDrop(url: url)
                }
            }
            return true
        }
    }
}

struct MigrationProgressView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: viewModel.operation.symbol)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(viewModel.operation.title)
                        .font(.headline)
                    Spacer()
                    if viewModel.operation == .migrating {
                        Text("\(viewModel.migrationStagesCompleted.count) of \(MigrationStage.allCases.count) steps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(viewModel.operationMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(viewModel.operationMessage)

                if let progress = viewModel.operationProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else if viewModel.operation.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(height: 82, alignment: .top)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch viewModel.operation {
        case .succeeded: .green
        case .failed: .red
        case .idle: .secondary
        default: .accentColor
        }
    }
}

struct ActionBarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button("Reconnect Volume", systemImage: "link") { viewModel.reconnectAppData() }
                .help("Mount the matching app volume from the selected SSD")
                .disabled(!hasAppAndDrive || viewModel.operation.isRunning)
            Button("Restore Local Data", systemImage: "arrow.uturn.backward") { viewModel.requestRestore() }
                .help("Remove the migrated volume and restore local app data")
                .disabled(!hasAppAndDrive || viewModel.operation.isRunning)
            Button("Remove Local Backup", systemImage: "trash") { viewModel.requestDeleteBackup() }
                .help("Permanently delete Data.backup from this Mac")
                .disabled(viewModel.bundleIdentifier == nil || viewModel.operation.isRunning)
            Spacer()
            Button("Migrate App Data", systemImage: "arrow.right.circle.fill") { viewModel.requestMigration() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(canMigrate ? Color.accentColor : .gray)
                .disabled(!canMigrate)
        }
    }

    private var hasAppAndDrive: Bool {
        viewModel.bundleIdentifier != nil && viewModel.selectedContainerID != nil
    }

    private var canMigrate: Bool {
        hasAppAndDrive && !viewModel.operation.isRunning
    }
}

// MARK: - Main ContentView
struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Left panel: External Drives
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("External Drives")
                            .font(.headline)
                        if viewModel.connectedVolumeCount > 0 {
                            ConnectionCountBadge(
                                count: viewModel.connectedVolumeCount,
                                color: .green,
                                help: "Connected matching volumes"
                            )
                        }
                        if viewModel.disconnectedVolumeCount > 0 {
                            ConnectionCountBadge(
                                count: viewModel.disconnectedVolumeCount,
                                color: .yellow,
                                help: "Disconnected matching volumes"
                            )
                        }
                        Spacer()
                        Button {
                            viewModel.refreshExternalVolumes()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh external drives")
                    }
                    .padding([.top, .horizontal])
                    ExternalDriveListView(viewModel: viewModel)
                        .padding([.horizontal, .bottom])
                }
                .task {
                    if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                        viewModel.refreshExternalVolumes()
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity)
                .background(.quaternary.opacity(0.1))

                Divider()

                // Right panel: App Drop Area
                VStack(alignment: .center, spacing: 12) {
                    AppDropAreaView(viewModel: viewModel)
                        .padding()
                }
                .frame(width: 360)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom: status shared by migration, reconnect, restore, and backup removal.
            VStack(alignment: .leading, spacing: 0) {
                MigrationProgressView(viewModel: viewModel)
                    .padding()
                Divider()
                ActionBarView(viewModel: viewModel)
                    .padding()
            }
        }
        .padding(0)
        .frame(minWidth: 760, minHeight: 440)
        .alert(item: $viewModel.activeDialog) { dialog in
            switch dialog {
            case .confirmRestore:
                Alert(
                    title: Text("Restore Local App Data?"),
                    message: Text("This will unmount and delete the migrated APFS volume, remove the current Data mount point, and restore local data. If Data.backup is missing, data will first be copied back from the external volume."),
                    primaryButton: .destructive(Text("Restore")) { viewModel.restore() },
                    secondaryButton: .cancel()
                )
            case .confirmDeleteBackup:
                Alert(
                    title: Text("Delete Local Backup?"),
                    message: Text("Data.backup will be permanently deleted from this Mac. This releases local disk space, but removes the quickest recovery option."),
                    primaryButton: .destructive(Text("Delete Backup")) { viewModel.deleteBackup() },
                    secondaryButton: .cancel()
                )
            case .migrationSucceeded:
                Alert(
                    title: Text("Migration Complete"),
                    message: Text("App data was migrated to the external APFS volume. The local Data.backup is still available: remove it when you no longer need it, or restore it if the migrated app has problems."),
                    dismissButton: .default(Text("Done"))
                )
            case let .migrationRolledBackForFullDiskAccess(error):
                Alert(
                    title: Text("Migration Rolled Back"),
                    message: Text("The external volume could not be mounted at the app Data folder. The new volume was removed and the original local Data directory was restored.\n\nThis may be caused by missing Full Disk Access. Enable PlayCover ExStorage in Privacy & Security, then reopen the app and try again.\n\nError: \(error)"),
                    primaryButton: .default(Text("Open Settings & Quit")) {
                        openFullDiskAccessSettingsAndQuit()
                    },
                    secondaryButton: .cancel(Text("Not Now"))
                )
            case let .reconnectFailedForFullDiskAccess(error):
                Alert(
                    title: Text("Reconnect Failed"),
                    message: Text("The external volume could not be mounted at the app Data folder. No local backup was modified, and the external volume remains available.\n\nThis may be caused by missing Full Disk Access. Enable PlayCover ExStorage in Privacy & Security, then reopen the app and try again.\n\nError: \(error)"),
                    primaryButton: .default(Text("Open Settings & Quit")) {
                        openFullDiskAccessSettingsAndQuit()
                    },
                    secondaryButton: .cancel(Text("Not Now"))
                )
            case let .message(title, message):
                Alert(title: Text(title), message: Text(message), dismissButton: .default(Text("OK")))
            }
        }
        .alert("Existing App Volume Found", isPresented: migrationReconnectAlertPresented) {
            Button("Reconnect") {
                if let choice = viewModel.migrationReconnectChoice {
                    viewModel.reconnectFromMigrationChoice(choice)
                }
            }
            Button("Replace & Migrate", role: .destructive) {
                if let choice = viewModel.migrationReconnectChoice {
                    viewModel.startMigration(replacing: choice)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let choice = viewModel.migrationReconnectChoice {
                Text("A disconnected volume named \(choice.volumeName) already exists on \(choice.diskName). Reconnect it, or replace it by deleting the existing volume and starting a new migration.")
            }
        }
    }

    private var migrationReconnectAlertPresented: Binding<Bool> {
        Binding(
            get: { viewModel.migrationReconnectChoice != nil },
            set: { presented in
                if !presented {
                    viewModel.migrationReconnectChoice = nil
                }
            }
        )
    }

    private func openFullDiskAccessSettingsAndQuit() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}

struct ConnectionCountBadge: View {
    let count: Int
    let color: Color
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.2), in: Capsule())
        .help(help)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
