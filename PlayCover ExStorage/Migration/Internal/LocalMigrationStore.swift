import Foundation

/// Durable local journal for every in-progress migration. Container metadata
/// describes committed ownership only and never stores recovery state.
@MainActor
final class LocalMigrationStore {
    enum StoreError: LocalizedError {
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(version):
                "This migration record uses unsupported schema version \(version)."
            }
        }
    }

    private let root: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(homeDirectory: URL) {
        root = homeDirectory
            .appendingPathComponent("Library/Application Support/PlayCover ExStorage/Migrations", isDirectory: true)
    }

    func save(_ record: LocalMigrationRecord) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url(for: record.request.id), options: [.atomic])
    }

    func record(for id: UUID) throws -> LocalMigrationRecord? {
        let recordURL = url(for: id)
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        return try decode(recordURL)
    }

    func records() throws -> [LocalMigrationRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .map(decode)
    }

    func delete(id: UUID) throws {
        let recordURL = url(for: id)
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return }
        try FileManager.default.removeItem(at: recordURL)
    }

    func markNeedsAttention(id: UUID, error: String) throws {
        guard var record = try record(for: id) else { return }
        record.phase = .needsAttention
        record.lastError = error
        try save(record)
    }

    private func decode(_ url: URL) throws -> LocalMigrationRecord {
        let record = try decoder.decode(LocalMigrationRecord.self, from: Data(contentsOf: url))
        guard record.schemaVersion == LocalMigrationRecord.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(record.schemaVersion)
        }
        return record
    }

    private func url(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
