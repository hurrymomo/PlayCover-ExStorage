import Foundation
import os

/// Application workflow trace. App events and unprivileged copy diagnostics
/// append here in chronological order; Helper calls use a separate log joined
/// to this one by operation identifiers. Capacity responses are saved nearby.
/// Shared in-process diagnostics. Library targets run in this same process;
/// the privileged helper writes its own file and is joined by operation ID.
nonisolated enum MigrationTrace {
    private static let lock = NSLock()
    private static let maximumLogSize: Int64 = 8_000_000
    private static let retainedHistoryCount = 1
    static let sessionID = UUID()
    @TaskLocal static var migrationID: UUID? = nil
    private static let logger = Logger(
        subsystem: "momo.PlayCover-ExStorage",
        category: "MigrationWorkflow"
    )

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PlayCover ExStorage", isDirectory: true)
            .appendingPathComponent("workflow.log")
    }

    static var helperLogURL: URL {
        logURL.deletingLastPathComponent().appendingPathComponent("helper.log")
    }

    static func prepareCommandLog(kind: String) -> URL {
        event("app.command-log.attached", details: "kind=\(kind) path=\(logURL.path)")
        return logURL
    }

    static func event(
        _ name: String,
        bundleID: String? = nil,
        details: @autoclosure () -> String = ""
    ) {
        let detail = details()
        let bundle = bundleID.map { " bundle=\($0)" } ?? ""
        let suffix = detail.isEmpty ? "" : " \(detail)"
        let message = contextualized("event=\(name)\(bundle)\(suffix)")
        logger.info("\(message, privacy: .public)")

        appendToFile(message)
    }

    /// App-owned command output uses the same serialization and context as
    /// workflow events without duplicating large output in Unified Logging.
    static func command(_ message: String) {
        appendToFile(contextualized(message))
    }

    private static func contextualized(_ message: String) -> String {
        let migration = migrationID.map { " migration=\($0.uuidString)" } ?? ""
        let prefix = "session=\(sessionID.uuidString)\(migration)"
        return message.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(prefix) \($0)" }
            .joined(separator: "\n")
    }

    private static func appendToFile(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
            let rendered = lines.map { "[\(timestamp)] \($0)\n" }.joined()
            try handle.write(contentsOf: Data(rendered.utf8))
        } catch {
            logger.error("workflow log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keep a bounded history of the exact responses used by migration checks.
    /// This runs before parsing, rather than from a crash/signal handler.
    static func saveCapacityQuery(_ data: Data, queryID: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let directory = logURL.deletingLastPathComponent()
            .appendingPathComponent("CapacityQueries", isDirectory: true)
        let url = directory.appendingPathComponent("\(queryID.uuidString).plist")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("capacity query log write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            let previous = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter { $0.pathExtension == "plist" && $0.lastPathComponent != url.lastPathComponent }
                .map { file in
                    (file, try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
                }
                .sorted { $0.1 > $1.1 }
            for (file, _) in previous.dropFirst(9) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            logger.error("capacity query log cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
        return url
    }

    private static func rotateIfNeeded() throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > maximumLogSize else { return }
        let fileManager = FileManager.default
        for index in stride(from: retainedHistoryCount, through: 1, by: -1) {
            let destination = logURL.appendingPathExtension(String(index))
            let source = index == 1 ? logURL : logURL.appendingPathExtension(String(index - 1))
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }
}
