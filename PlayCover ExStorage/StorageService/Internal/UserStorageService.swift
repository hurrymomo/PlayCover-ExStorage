import Foundation

/// Live application-facing implementation. Operations that need additional
/// privileges are forwarded across the existing helper boundary.
nonisolated final class UserStorageService: StorageServicing, @unchecked Sendable {
    static let shared = UserStorageService(privilegedClient: .shared)

    private let privilegedClient: XPCPrivilegedClient
    private let changeMonitor = StorageChangeMonitor()

    init(privilegedClient: XPCPrivilegedClient) {
        self.privilegedClient = privilegedClient
        changeMonitor.start()
    }

    func scanSnapshot(onPhysicalDevice device: String?) async -> StorageSnapshot {
        let builder = await MainActor.run { StorageSnapshotBuilder() }
        await DiskUtilDiscovery.discoverExternalAPFSContainersProgressively(
            onPhysicalDevice: device,
            onContainer: { builder.add($0) },
            onVolume: { containerID, volume in builder.add(volume, to: containerID) }
        )
        let snapshot = await MainActor.run { builder.snapshot() }
        if device == nil {
            changeMonitor.establishBaseline(
                devices: Set(
                    snapshot.containers
                        .flatMap(\.physicalStoreDeviceIdentifiers)
                        .map(Self.wholeDisk)
                )
            )
        }
        return snapshot
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

    func volumeIdentity(for device: String) async -> StorageVolumeIdentity? {
        let migrationID = MigrationTrace.migrationID
        return await Task.detached(priority: .userInitiated) {
            MigrationTrace.$migrationID.withValue(migrationID) {
                guard let identity = DiskUtilDiscovery.volumeIdentity(for: device),
                      let containerReference = identity.containerReference else { return nil }
                return StorageVolumeIdentity(
                    volumeUUID: identity.volumeUUID,
                    containerReference: containerReference,
                    mountPoint: identity.mountPoint
                )
            }
        }.value
    }

    func availableCapacity(for container: ExternalAPFSContainer) async -> Int64? {
        let migrationID = MigrationTrace.migrationID
        return await Task.detached(priority: .utility) {
            MigrationTrace.$migrationID.withValue(migrationID) {
                DiskUtilDiscovery.containerFreeCapacity(for: container)
            }
        }.value
    }

    func createAPFSVolume(containerReference: String, name: String) async throws -> CreatedAPFSVolume {
        try await privileged(action: "create-volume") { client, operationID in
            try client.createAPFSVolume(
                containerRef: containerReference,
                name: name,
                operationID: operationID,
                logURL: MigrationTrace.helperLogURL
            )
        }
    }

    func mountAPFSVolume(device: String, at mountPoint: URL, options: [String]) async throws {
        try await privileged(action: "mount-volume") { client, operationID in
            try client.mountAPFS(
                byDevice: device,
                at: mountPoint,
                options: options,
                operationID: operationID,
                logURL: MigrationTrace.helperLogURL
            )
        }
    }

    func unmountVolume(at mountPoint: URL) async throws {
        try await privileged(action: "unmount-volume") { client, operationID in
            try client.unmount(
                byMountPoint: mountPoint,
                operationID: operationID,
                logURL: MigrationTrace.helperLogURL
            )
        }
    }

    func deleteAPFSVolume(device: String) async throws {
        try await privileged(action: "delete-volume") { client, operationID in
            try client.deleteAPFSVolume(
                byDevice: device,
                operationID: operationID,
                logURL: MigrationTrace.helperLogURL
            )
        }
    }

    func movePrivilegedItem(from source: URL, to destination: URL) async throws {
        try await privileged(action: "move-item") { client, operationID in
            try client.renameItem(
                from: source,
                to: destination,
                operationID: operationID,
                logURL: MigrationTrace.helperLogURL
            )
        }
    }

    func deletePrivilegedItem(at url: URL) async throws {
        try await privileged(action: "delete-item") { client, operationID in
            try client.deleteItem(
                at: url,
                operationID: operationID,
                logURL: MigrationTrace.helperLogURL
            )
        }
    }

    func shutdownPrivilegedHelper() {
        let operationID = UUID().uuidString
        MigrationTrace.event(
            "helper.call.begin",
            details: "operation=\(operationID) action=shutdown"
        )
        privilegedClient.shutdownHelper(operationID: operationID, logURL: MigrationTrace.helperLogURL)
        MigrationTrace.event(
            "helper.call.completed",
            details: "operation=\(operationID) action=shutdown"
        )
    }

    private func privileged<T: Sendable>(
        action: String,
        _ operation: @escaping @Sendable (XPCPrivilegedClient, String) throws -> T
    ) async throws -> T {
        let operationID = UUID().uuidString
        MigrationTrace.event(
            "helper.call.begin",
            details: "operation=\(operationID) action=\(action)"
        )
        let migrationID = MigrationTrace.migrationID
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try MigrationTrace.$migrationID.withValue(migrationID) {
                    try operation(self.privilegedClient, operationID)
                }
            }.value
            MigrationTrace.event(
                "helper.call.succeeded",
                details: "operation=\(operationID) action=\(action)"
            )
            return result
        } catch {
            MigrationTrace.event(
                "helper.call.failed",
                details: "operation=\(operationID) action=\(action) error=\(error.localizedDescription)"
            )
            throw error
        }
    }
}
