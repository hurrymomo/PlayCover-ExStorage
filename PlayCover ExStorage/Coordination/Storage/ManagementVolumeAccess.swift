import Foundation

struct ManagementVolumeContext: Sendable {
    let root: URL
    let volumeUUID: String
}

/// Application-level coordination for the product-specific ExStorage
/// management volume. It combines the StorageService API, AppModel, and the
/// metadata store without making any of them depend on each other.
@MainActor
final class ManagementVolumeAccess {
    private let model: AppModel
    private let storage: any StorageServicing
    private let metadata: ExStorageMetadataStore

    init(
        model: AppModel,
        storage: any StorageServicing,
        metadata: ExStorageMetadataStore
    ) {
        self.model = model
        self.storage = storage
        self.metadata = metadata
    }

    func prepareManagementVolume(
        for container: ExternalAPFSContainer
    ) async throws -> ManagementVolumeContext {
        let matches = container.volumes.filter { $0.name == ExStorageLayout.managementVolumeName }
        guard matches.count <= 1 else {
            throw error("Multiple ExStorage management volumes were found in this APFS container.")
        }

        let device: String
        let expectedUUID: String?
        let existingMountPoint: String?
        if let existing = matches.first {
            guard let existingDevice = existing.bsdDevice else {
                throw error("The ExStorage management volume has no resolvable device.")
            }
            device = existingDevice
            expectedUUID = existing.volumeUUID
            existingMountPoint = usableMountPoint(existing.mountPoint)
        } else {
            let created = try await storage.createAPFSVolume(
                containerReference: container.containerReference,
                name: ExStorageLayout.managementVolumeName
            )
            device = created.bsdDevice
            expectedUUID = nil
            existingMountPoint = nil
        }

        guard let identity = await storage.volumeIdentity(for: device),
        identity.containerReference == container.containerReference else {
            throw error("The ExStorage management volume identity could not be verified.")
        }
        if let expectedUUID,
           expectedUUID.caseInsensitiveCompare(identity.volumeUUID) != .orderedSame {
            throw error("The ExStorage management volume UUID changed unexpectedly.")
        }

        let root: URL
        if let existingMountPoint {
            root = URL(fileURLWithPath: existingMountPoint, isDirectory: true)
        } else {
            root = managementVolumeMountPoint(volumeUUID: identity.volumeUUID)
            try await storage.mountAPFSVolume(
                device: device,
                at: root,
                options: ["noowners", "nobrowse"]
            )
        }

        _ = try await metadata.initialize(
            at: root,
            managementVolumeUUID: identity.volumeUUID,
            containerUUID: container.containerUUID
        )
        addOrUpdateVolume(
            containerID: container.id,
            volume: ExternalVolume(
                name: ExStorageLayout.managementVolumeName,
                mountPoint: root.path,
                bsdDevice: device,
                volumeUUID: identity.volumeUUID,
                availableBytes: nil,
                usedBytes: nil
            )
        )
        return ManagementVolumeContext(
            root: root,
            volumeUUID: identity.volumeUUID
        )
    }

    private func managementVolumeMountPoint(volumeUUID: String) -> URL {
        let stableID = volumeUUID.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return URL(fileURLWithPath: "/Volumes/ExStorage-\(stableID)", isDirectory: true)
    }

    private func usableMountPoint(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }

    private func addOrUpdateVolume(containerID: UUID, volume: ExternalVolume) {
        model.replaceContainers(model.allContainers().map { container in
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

    private func error(_ message: String) -> NSError {
        NSError(
            domain: "PlayCoverExStorage.Migration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
