import Foundation

@MainActor
final class StorageSnapshotBuilder {
    private var containersByID: [UUID: ExternalAPFSContainer] = [:]

    func add(_ container: ExternalAPFSContainer) {
        containersByID[container.id] = container
    }

    func add(_ volume: ExternalVolume, to containerID: UUID) {
        guard let container = containersByID[containerID] else { return }
        var volumes = container.volumes
        volumes.removeAll { $0.id == volume.id }
        volumes.append(volume)
        containersByID[containerID] = ExternalAPFSContainer(
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

    func snapshot() -> StorageSnapshot {
        StorageSnapshot(containersByID: containersByID, capturedAt: Date())
    }
}
