import SwiftUI

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

enum AppOperation {
    case idle
    case migrating
    case reconnecting
    case succeeded
    case failed

    var title: String {
        switch self {
        case .idle: "Ready"
        case .migrating: "Migrating App Data"
        case .reconnecting: "Reconnecting App Data"
        case .succeeded: "Operation Complete"
        case .failed: "Operation Failed"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "circle.dashed"
        case .migrating: "externaldrive.badge.plus"
        case .reconnecting: "link"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var isRunning: Bool {
        switch self {
        case .migrating, .reconnecting: true
        default: false
        }
    }
}

struct AppOperationState: Equatable {
    var operation: AppOperation = .idle
    var message: String = "Ready"
    var progress: Double?
}

enum AppDialog: Identifiable {
    case localDataMountFailed(error: String)
    case confirmMigrationOverwrite(PendingMigration, appToAdd: AppSnapshot?)
    case confirmMigrationBatch(MigrationBatchRequest)
    case message(title: String, message: String)

    var id: String {
        switch self {
        case .localDataMountFailed: "localDataMountFailed"
        case let .confirmMigrationOverwrite(pending, _): "confirmMigrationOverwrite-\(pending.id)"
        case let .confirmMigrationBatch(request): "confirmMigrationBatch-\(request.apps.map(\.bundleIdentifier).joined(separator: ","))"
        case let .message(title, message): "message-\(title)-\(message)"
        }
    }
}

struct ExternalDataDeletionTarget {
    let device: String
    let volumeUUID: String
    let containerReference: String
}

enum AppDataDeletionLocation {
    case local
    case external(ExternalDataDeletionTarget)
}

struct AppDeletionRequest: Identifiable {
    let app: AppSnapshot
    let dataLocation: AppDataDeletionLocation
    var id: String { app.bundleIdentifier }
}

enum AppDeletionSelection: Equatable {
    case app
    case data
    case appAndData
}

struct VolumeDeletionRequest: Identifiable {
    let name: String
    let device: String
    let volumeUUID: String
    let containerReference: String
    var id: String { "\(device)-\(volumeUUID)" }
}

nonisolated enum MigrationTarget: Hashable, Codable, Sendable {
    case local
    case container(UUID)
}

nonisolated enum MigrationContent: String, Hashable, Codable, Sendable {
    case data
    case app
    case appAndData
}

nonisolated struct PendingMigration: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let batchID: UUID
    let bundleIdentifier: String
    let appName: String
    let source: MigrationTarget
    let target: MigrationTarget
    var content: MigrationContent = .data
    var overwriteExisting = false
    var recoveryDestinationVolumeUUID: String?
    var recoveryPhase: MigrationCheckpointPhase?

    init(
        id: UUID = UUID(),
        batchID: UUID,
        bundleIdentifier: String,
        appName: String,
        source: MigrationTarget,
        target: MigrationTarget,
        content: MigrationContent = .data,
        overwriteExisting: Bool = false,
        recoveryDestinationVolumeUUID: String? = nil,
        recoveryPhase: MigrationCheckpointPhase? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.source = source
        self.target = target
        self.content = content
        self.overwriteExisting = overwriteExisting
        self.recoveryDestinationVolumeUUID = recoveryDestinationVolumeUUID
        self.recoveryPhase = recoveryPhase
    }
}

struct MigrationBatchRequest {
    let apps: [AppSnapshot]
    let migrations: [PendingMigration]
    let target: MigrationTarget
    let addsToLibrary: Bool

    var conflictingMigrations: [PendingMigration] {
        migrations.filter(\.overwriteExisting)
    }
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

enum ManagedAppSizeState: Hashable {
    case unknown
    case calculating
    case available(Int64)
}

struct AppSnapshot: Identifiable, Codable, Hashable {
    let bundleIdentifier: String
    let name: String
    let applicationPath: String
    let persistence: ManagedAppPersistence
    let appSize: ManagedAppSizeState
    let dataSize: ManagedAppSizeState
    let appInfo: ExStorageAppInfo?
    let appInfoContainerID: UUID?

    var id: String { bundleIdentifier }
    var applicationURL: URL { URL(fileURLWithPath: applicationPath) }

    init(
        bundleIdentifier: String,
        name: String,
        applicationPath: String,
        persistence: ManagedAppPersistence,
        appSize: ManagedAppSizeState = .unknown,
        dataSize: ManagedAppSizeState = .unknown,
        appInfo: ExStorageAppInfo? = nil,
        appInfoContainerID: UUID? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.applicationPath = applicationPath
        self.persistence = persistence
        self.appSize = appSize
        self.dataSize = dataSize
        self.appInfo = appInfo
        self.appInfoContainerID = appInfoContainerID
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
        appSize = .unknown
        dataSize = .unknown
        appInfo = nil
        appInfoContainerID = nil
    }

    static func == (lhs: AppSnapshot, rhs: AppSnapshot) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.name == rhs.name
            && lhs.applicationPath == rhs.applicationPath
            && lhs.persistence == rhs.persistence
            && lhs.appSize == rhs.appSize
            && lhs.dataSize == rhs.dataSize
            && lhs.appInfo == rhs.appInfo
            && lhs.appInfoContainerID == rhs.appInfoContainerID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }
}
