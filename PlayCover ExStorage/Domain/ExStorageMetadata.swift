import Foundation

nonisolated enum ManagedLocation: Equatable, Sendable {
    case local(path: String)
    case managementVolume(volumeUUID: String, relativePath: String)
    case dataVolume(volumeUUID: String)
}

extension ManagedLocation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case volumeUUID
    }

    private enum Kind: String, Codable {
        case local
        case external
        case management
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local(path: try container.decode(String.self, forKey: .path))
        case .external:
            self = .dataVolume(
                volumeUUID: try container.decode(String.self, forKey: .volumeUUID)
            )
        case .management:
            let path = try container.decode(String.self, forKey: .path)
            self = .managementVolume(
                volumeUUID: try container.decode(String.self, forKey: .volumeUUID),
                relativePath: Self.volumeRelativePath(path)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .local(path):
            try container.encode(Kind.local, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .dataVolume(volumeUUID):
            try container.encode(Kind.external, forKey: .kind)
            try container.encode(volumeUUID, forKey: .volumeUUID)
        case let .managementVolume(volumeUUID, relativePath):
            try container.encode(Kind.management, forKey: .kind)
            try container.encode(volumeUUID, forKey: .volumeUUID)
            try container.encode("/" + Self.volumeRelativePath(relativePath), forKey: .path)
        }
    }

    private static func volumeRelativePath(_ path: String) -> String {
        String(path.drop(while: { $0 == "/" }))
    }
}

nonisolated enum MigrationCheckpointPhase: String, Codable, Equatable, Sendable {
    case preparing
    case copying
    case verifying
    case committing
}

nonisolated struct ComponentMigrationState: Codable, Equatable, Sendable {
    var destination: ManagedLocation
    var verified: Bool
    /// Optional for backward compatibility with AppInfo written before
    /// resumable phase checkpoints were introduced.
    var phase: MigrationCheckpointPhase? = nil
    var stagingRelativePath: String? = nil
}

nonisolated struct ManagedBundleState: Codable, Equatable, Sendable {
    var location: ManagedLocation
    var migration: ComponentMigrationState?
}

nonisolated struct ManagedDataState: Codable, Equatable, Sendable {
    var location: ManagedLocation
    var migration: ComponentMigrationState?
}

nonisolated struct ManagedApplicationInfo: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var bundleID: String
    var version: String?
    /// Last verified local location of the App before it moved to managed storage.
    /// This is a hint only; callers must verify the bundle before using it.
    var localAppPathHint: String? = nil
    var bundle: ManagedBundleState
    var data: ManagedDataState
    /// Durable orchestration state for a multi-component migration. Component
    /// checkpoints remain responsible for resuming an in-progress copy.
    var migrationTransaction: MigrationTransactionState? = nil
}

/// The complete AppInfo representation stored on an ExStorage management
/// volume. Bundle and migration locations are derived from live storage.
nonisolated struct ExStorageAppInfo: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var bundleID: String
    /// The Data Volume owned by this container. An AppInfo record is invalid
    /// without it because managed Apps are never stored without their Data.
    var dataVolumeUUID: String
    /// Portable (`~/...` when possible) last-known local App path. It is a
    /// required hint, but callers still verify existence and Bundle ID.
    var localAppPathHint: String
}

nonisolated struct ExternalStorageMetadata: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var managementVolumeUUID: String
    var containerUUID: String
}

nonisolated enum ExStorageLayout {
    static let managementVolumeName = "ExStorage"
    static let metadataFileName = ".ExternalStorage.json"
    static let applicationsDirectoryName = "Applications"
    static let appInfoDirectoryName = "AppInfo"

    static func portableLocalPath(_ url: URL) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    static func resolveLocalPath(_ path: String) -> URL {
        guard path == "~" || path.hasPrefix("~/") else {
            return URL(fileURLWithPath: path)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if path == "~" { return home }
        return home
            .appendingPathComponent(String(path.dropFirst(2)))
    }
}
