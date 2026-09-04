import Foundation

/// Live application-facing implementation. Operations that need additional
/// privileges are forwarded across the existing helper boundary.
nonisolated final class UserStorageService: StorageServicing, @unchecked Sendable {
    static let shared = UserStorageService(privilegedClient: .shared)

    private let fileManager: FileManager
    private let privilegedClient: XPCPrivilegedClient
    private let changeMonitor = StorageChangeMonitor()

    init(
        fileManager: FileManager = .default,
        privilegedClient: XPCPrivilegedClient
    ) {
        self.fileManager = fileManager
        self.privilegedClient = privilegedClient
        changeMonitor.start()
    }

    var homeDirectory: URL { fileManager.homeDirectoryForCurrentUser }

    func scanSnapshot() async -> StorageSnapshot {
        let builder = await MainActor.run { StorageSnapshotBuilder() }
        await DiskUtilDiscovery.discoverExternalAPFSContainersProgressively { container in
            builder.add(container)
        } onVolume: { containerID, volume in
            builder.add(volume, to: containerID)
        }
        let discovered = await MainActor.run { builder.snapshot() }
        let snapshot = await mountingManagementVolumes(in: discovered)
        changeMonitor.establishBaseline(
            devices: Set(snapshot.containers.flatMap(\.physicalStoreDeviceIdentifiers).map(Self.wholeDisk))
        )
        return snapshot
    }

    func scanContainers(onPhysicalDevice device: String) async -> [ExternalAPFSContainer] {
        let builder = await MainActor.run { StorageSnapshotBuilder() }
        await DiskUtilDiscovery.discoverExternalAPFSContainersProgressively(
            onPhysicalDevice: device,
            onContainer: { builder.add($0) },
            onVolume: { containerID, volume in builder.add(volume, to: containerID) }
        )
        let discovered = await MainActor.run { builder.snapshot() }
        return await mountingManagementVolumes(in: discovered).containers
    }

    func setStorageChangeHandler(
        _ handler: @escaping @MainActor @Sendable (StorageDeviceChange) -> Void
    ) {
        changeMonitor.setChangeHandler(handler)
    }

    private static func wholeDisk(_ device: String) -> String {
        guard let partition = device.range(of: #"s\d+$"#, options: .regularExpression) else {
            return device
        }
        return String(device[..<partition.lowerBound])
    }

    /// Storage discovery guarantees that every discovered ExStorage management
    /// volume is available at its stable UUID-based mount point. Mount failures
    /// do not discard the container from the snapshot; later access retries the
    /// same operation through ManagementVolumeAccess.
    private func mountingManagementVolumes(in snapshot: StorageSnapshot) async -> StorageSnapshot {
        var containersByID = snapshot.containersByID
        for container in snapshot.containers {
            var updatedVolumes = container.volumes
            var changed = false
            for index in updatedVolumes.indices {
                let volume = updatedVolumes[index]
                guard volume.name == ExStorageLayout.managementVolumeName,
                      volume.mountPoint?.isEmpty != false,
                      let device = volume.bsdDevice,
                      let volumeUUID = volume.volumeUUID else { continue }
                let mountPoint = Self.managementVolumeMountPoint(volumeUUID: volumeUUID)
                do {
                    try await mountAPFSVolume(
                        device: device,
                        at: mountPoint,
                        options: ["noowners", "nobrowse"]
                    )
                    updatedVolumes[index] = volume.replacingMountPoint(mountPoint.path)
                    changed = true
                    MigrationTrace.event(
                        "management-volume.scan-mounted",
                        details: "container=\(container.id) volume=\(volumeUUID) path=\(mountPoint.path)"
                    )
                } catch {
                    MigrationTrace.event(
                        "management-volume.scan-mount-failed",
                        details: "container=\(container.id) volume=\(volumeUUID) error=\(error.localizedDescription)"
                    )
                }
            }
            guard changed else { continue }
            containersByID[container.id] = ExternalAPFSContainer(
                containerUUID: container.containerUUID,
                containerReference: container.containerReference,
                physicalStoreDeviceIdentifiers: container.physicalStoreDeviceIdentifiers,
                displayName: container.displayName,
                connectionType: container.connectionType,
                capacityTotalBytes: container.capacityTotalBytes,
                capacityFreeBytes: container.capacityFreeBytes,
                volumes: updatedVolumes
            )
        }
        return StorageSnapshot(containersByID: containersByID, capturedAt: snapshot.capturedAt)
    }

    private static func managementVolumeMountPoint(volumeUUID: String) -> URL {
        let stableID = volumeUUID.uppercased().filter {
            $0.isLetter || $0.isNumber || $0 == "-"
        }
        return URL(fileURLWithPath: "/Volumes/ExStorage-\(stableID)", isDirectory: true)
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func itemKind(at url: URL) -> StorageItemKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    func directoryIsEmptyOrMissing(at url: URL) -> Bool {
        guard itemExists(at: url) else { return true }
        return (try? fileManager.contentsOfDirectory(atPath: url.path).isEmpty) ?? false
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool = true) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func moveItem(from source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func allocatedSize(of root: URL) throws -> Int64 {
        try StorageFileSystem.allocatedSize(of: root, fileManager: fileManager)
    }

    func beginPrivilegedOperationLog(at url: URL) async throws {
        try await privileged { try $0.beginOperationLog(at: url) }
    }

    func ensurePrivilegedHelperAvailable() async throws {
        try await privileged { try $0.ensureHelperAvailable() }
    }

    func createAPFSVolume(containerReference: String, name: String) async throws -> CreatedAPFSVolume {
        try await privileged { try $0.createAPFSVolume(containerRef: containerReference, name: name) }
    }

    func mountAPFSVolume(device: String, at mountPoint: URL, options: [String]) async throws {
        try await privileged { try $0.mountAPFS(byDevice: device, at: mountPoint, options: options) }
    }

    func unmountVolume(at mountPoint: URL) async throws {
        try await privileged { try $0.unmount(byMountPoint: mountPoint) }
    }

    func deleteAPFSVolume(device: String) async throws {
        try await privileged { try $0.deleteAPFSVolume(byDevice: device) }
    }

    func movePrivilegedItem(from source: URL, to destination: URL) async throws {
        try await privileged { try $0.renameItem(from: source, to: destination) }
    }

    func deletePrivilegedItem(at url: URL) async throws {
        try await privileged { try $0.deleteItem(at: url) }
    }

    func shutdownPrivilegedHelper() {
        privilegedClient.shutdownHelper()
    }

    func beginOperationLog(at url: URL) throws {
        try privilegedClient.beginOperationLog(at: url)
    }

    func ensureHelperAvailable() throws {
        try privilegedClient.ensureHelperAvailable()
    }

    func createAPFSVolume(containerRef: String, name: String) throws -> CreatedAPFSVolume {
        try privilegedClient.createAPFSVolume(containerRef: containerRef, name: name)
    }

    func mountAPFS(byDevice device: String, at mountPoint: URL, options: [String]) throws {
        try privilegedClient.mountAPFS(byDevice: device, at: mountPoint, options: options)
    }

    func unmount(byMountPoint mountPoint: URL) throws {
        try privilegedClient.unmount(byMountPoint: mountPoint)
    }

    func deleteAPFSVolume(byDevice device: String) throws {
        try privilegedClient.deleteAPFSVolume(byDevice: device)
    }

    func renameItem(from source: URL, to destination: URL) throws {
        try privilegedClient.renameItem(from: source, to: destination)
    }

    func deleteItem(at url: URL) throws {
        try privilegedClient.deleteItem(at: url)
    }

    private func privileged<T: Sendable>(
        _ operation: @escaping @Sendable (XPCPrivilegedClient) throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try operation(self.privilegedClient)
        }.value
    }
}
