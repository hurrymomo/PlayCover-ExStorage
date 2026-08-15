import SwiftUI

// MARK: - Core Models
nonisolated struct ExternalAPFSContainer: Identifiable, Hashable, Sendable {
    let containerUUID: UUID
    let containerReference: String
    let displayName: String?
    let connectionType: String?
    let capacityTotalBytes: Int64?
    let capacityFreeBytes: Int64?
    let volumes: [ExternalVolume]

    var id: UUID { containerUUID }

    init(containerUUID: UUID, containerReference: String, displayName: String?, connectionType: String? = nil, capacityTotalBytes: Int64?, capacityFreeBytes: Int64?, volumes: [ExternalVolume]) {
        self.containerUUID = containerUUID
        self.containerReference = containerReference
        self.displayName = displayName
        self.connectionType = connectionType
        self.capacityTotalBytes = capacityTotalBytes
        self.capacityFreeBytes = capacityFreeBytes
        self.volumes = volumes
    }
}

nonisolated struct ExternalVolume: Identifiable, Hashable, Sendable {
    let name: String
    let mountPoint: String?
    let bsdDevice: String?
    let volumeUUID: String?
    let availableBytes: Int64?
    let usedBytes: Int64?

    var id: String { volumeUUID ?? bsdDevice ?? "\(name)-\(mountPoint ?? "unmounted")" }

    init(name: String, mountPoint: String?, bsdDevice: String?, volumeUUID: String? = nil, availableBytes: Int64?, usedBytes: Int64?) {
        self.name = name
        self.mountPoint = mountPoint
        self.bsdDevice = bsdDevice
        self.volumeUUID = volumeUUID
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
    }

    func replacingMountPoint(_ newMountPoint: String?) -> ExternalVolume {
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

enum VolumeConnectionState {
    case unrelated
    case disconnected
    case connected

    var color: Color? {
        switch self {
        case .unrelated: nil
        case .disconnected: StorageStatusColors.disconnected
        case .connected: StorageStatusColors.connected
        }
    }
}

enum StorageStatusColors {
    static let connected = Color(red: 0.18, green: 0.92, blue: 0.34)
    static let disconnected = Color(red: 1.0, green: 0.72, blue: 0.08)
    static let local = Color.secondary
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
    case succeeded
    case failed

    var title: String {
        switch self {
        case .idle: "Ready"
        case .migrating: "Migrating App Data"
        case .reconnecting: "Reconnecting App Data"
        case .restoring: "Restoring Local Data"
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
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var isRunning: Bool {
        switch self {
        case .migrating, .reconnecting, .restoring: true
        default: false
        }
    }
}

enum AppDialog: Identifiable {
    case confirmRestore
    case migrationRolledBackForFullDiskAccess(error: String)
    case reconnectFailedForFullDiskAccess(error: String)
    case confirmExternalOverwrite(PendingMigration)
    case confirmLocalOverwrite(PendingMigration)
    case confirmConnectAndOpen(appName: String, containerID: UUID)
    case confirmMigrationBatch(MigrationBatchRequest)
    case message(title: String, message: String)

    var id: String {
        switch self {
        case .confirmRestore: "confirmRestore"
        case .migrationRolledBackForFullDiskAccess: "migrationRolledBackForFullDiskAccess"
        case .reconnectFailedForFullDiskAccess: "reconnectFailedForFullDiskAccess"
        case let .confirmExternalOverwrite(pending): "confirmExternalOverwrite-\(pending.id)"
        case let .confirmLocalOverwrite(pending): "confirmLocalOverwrite-\(pending.id)"
        case let .confirmConnectAndOpen(appName, containerID): "confirmConnectAndOpen-\(appName)-\(containerID)"
        case let .confirmMigrationBatch(request): "confirmMigrationBatch-\(request.apps.map(\.bundleIdentifier).joined(separator: ","))"
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

struct LocalAppDeletionRequest: Identifiable {
    let app: ManagedApp
    var id: String { app.bundleIdentifier }
}

struct ExternalAppDeletionRequest: Identifiable {
    let app: ManagedApp
    let volumeName: String
    let device: String
    let volumeUUID: String
    let containerReference: String
    var id: String { "\(app.bundleIdentifier)-\(volumeUUID)" }
}

struct VolumeDeletionRequest: Identifiable {
    let name: String
    let device: String
    let volumeUUID: String
    let containerReference: String
    var id: String { "\(device)-\(volumeUUID)" }
}

enum MigrationTarget: Hashable {
    case local
    case container(UUID)
}

struct PendingMigration: Identifiable {
    let id = UUID()
    let batchID: UUID
    let bundleIdentifier: String
    let appName: String
    let source: MigrationTarget
    let target: MigrationTarget
    var overwriteExisting = false
    var focusesSourceOnSuccess = false
}

struct MigrationBatchRequest {
    let apps: [ManagedApp]
    let target: MigrationTarget
    let addsToLibrary: Bool
}

struct MigrationPresentation: Identifiable, Hashable {
    let id = UUID()
    let batchID: UUID
    let bundleIdentifier: String
    let source: MigrationTarget
    let target: MigrationTarget
    let targetContainerID: UUID
    var targetVolumeUUID: String? = nil
}

struct MigrationHistoryRecord: Identifiable {
    let id = UUID()
    let completedAt = Date()
    let migration: MigrationPresentation
    let appName: String
    let succeeded: Bool
    let message: String
    let sourceAvailableBytes: Int64?
    let targetAvailableBytes: Int64?
}

struct ConnectionConflict: Identifiable {
    let bundleIdentifier: String
    var id: String { bundleIdentifier }
}

enum LocalDataConnectionPolicy: Equatable {
    case requireEmpty
    case remove
    case hide
}

let appDragPayloadPrefix = "exstorage-apps:"

func appDragPayload(_ bundleIDs: some Sequence<String>) -> String {
    appDragPayloadPrefix + bundleIDs.joined(separator: "\n")
}

func draggedBundleIDs(from payload: String) -> [String] {
    guard payload.hasPrefix(appDragPayloadPrefix) else { return [] }
    return payload.dropFirst(appDragPayloadPrefix.count)
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.isEmpty }
}

func dragPayloadString(_ item: NSSecureCoding?) -> String? {
    if let string = item as? String { return string }
    if let string = item as? NSString { return string as String }
    if let data = item as? Data { return String(data: data, encoding: .utf8) }
    return nil
}

func droppedFileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            continuation.resume(returning: url)
        }
    }
}

enum ManagedAppPersistence: String, Codable, Hashable {
    case sessionOnly
    case kept
    case managed
}

struct ManagedApp: Identifiable, Codable, Hashable {
    let bundleIdentifier: String
    var name: String
    var applicationPath: String
    var persistence: ManagedAppPersistence

    var id: String { bundleIdentifier }
    var applicationURL: URL { URL(fileURLWithPath: applicationPath) }

    init(bundleIdentifier: String, name: String, applicationPath: String, persistence: ManagedAppPersistence) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.applicationPath = applicationPath
        self.persistence = persistence
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name, applicationPath, persistence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        name = try values.decode(String.self, forKey: .name)
        applicationPath = try values.decode(String.self, forKey: .applicationPath)
        // Records created by the first multi-App prototype were persisted automatically,
        // so treat them as session candidates until a migration is discovered or the user keeps them.
        persistence = try values.decodeIfPresent(ManagedAppPersistence.self, forKey: .persistence) ?? .sessionOnly
    }
}
