import Foundation

/// An APFS container discovered on external physical storage.
nonisolated public struct ExternalAPFSContainer: Identifiable, Hashable, Sendable {
    public let containerUUID: UUID
    public let containerReference: String
    public let physicalStoreDeviceIdentifiers: [String]
    public let displayName: String?
    public let connectionType: String?
    public let capacityTotalBytes: Int64?
    public let capacityFreeBytes: Int64?
    public let volumes: [ExternalVolume]

    public var id: UUID { containerUUID }

    public init(
        containerUUID: UUID,
        containerReference: String,
        physicalStoreDeviceIdentifiers: [String] = [],
        displayName: String?,
        connectionType: String? = nil,
        capacityTotalBytes: Int64?,
        capacityFreeBytes: Int64?,
        volumes: [ExternalVolume]
    ) {
        self.containerUUID = containerUUID
        self.containerReference = containerReference
        self.physicalStoreDeviceIdentifiers = physicalStoreDeviceIdentifiers
        self.displayName = displayName
        self.connectionType = connectionType
        self.capacityTotalBytes = capacityTotalBytes
        self.capacityFreeBytes = capacityFreeBytes
        self.volumes = volumes
    }
}

/// A volume contained by a discovered external APFS container.
nonisolated public struct ExternalVolume: Identifiable, Hashable, Sendable {
    public let name: String
    public let mountPoint: String?
    public let bsdDevice: String?
    public let volumeUUID: String?
    public let availableBytes: Int64?
    public let usedBytes: Int64?

    public var id: String { volumeUUID ?? bsdDevice ?? "\(name)-\(mountPoint ?? "unmounted")" }

    public init(
        name: String,
        mountPoint: String?,
        bsdDevice: String?,
        volumeUUID: String? = nil,
        availableBytes: Int64?,
        usedBytes: Int64?
    ) {
        self.name = name
        self.mountPoint = mountPoint
        self.bsdDevice = bsdDevice
        self.volumeUUID = volumeUUID
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
    }

    public func replacingMountPoint(_ newMountPoint: String?) -> ExternalVolume {
        ExternalVolume(
            name: name,
            mountPoint: newMountPoint,
            bsdDevice: bsdDevice,
            volumeUUID: volumeUUID,
            availableBytes: availableBytes,
            usedBytes: usedBytes
        )
    }
}

/// The result returned after the helper creates an APFS volume.
nonisolated public struct CreatedAPFSVolume: Sendable {
    public let bsdDevice: String
    public let mountPoint: URL?

    public init(bsdDevice: String, mountPoint: URL?) {
        self.bsdDevice = bsdDevice
        self.mountPoint = mountPoint
    }
}

/// Stable identity read from diskutil for a single APFS volume.
nonisolated public struct StorageVolumeIdentity: Hashable, Sendable {
    public let volumeUUID: String
    public let containerReference: String
    public let mountPoint: String?

    public init(volumeUUID: String, containerReference: String, mountPoint: String?) {
        self.volumeUUID = volumeUUID
        self.containerReference = containerReference
        self.mountPoint = mountPoint
    }
}

nonisolated public struct StorageSnapshot: Sendable {
    public let containersByID: [UUID: ExternalAPFSContainer]
    public let capturedAt: Date

    public var containers: [ExternalAPFSContainer] {
        containersByID.values.sorted {
            (($0.displayName ?? ""), $0.containerReference)
                < (($1.displayName ?? ""), $1.containerReference)
        }
    }

    public init(containersByID: [UUID: ExternalAPFSContainer], capturedAt: Date) {
        self.containersByID = containersByID
        self.capturedAt = capturedAt
    }
}

nonisolated public enum StorageDeviceChange: Sendable {
    case inserted(device: String)
    case removed(device: String)
}
