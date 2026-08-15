import Foundation
import os

/// Unified migration trace that starts before privileged logging is available.
/// App workflow events, copy diagnostics, Helper calls, and diskutil output all
/// append to this file in chronological order.
nonisolated enum MigrationTrace {
    private static let lock = NSLock()
    private static let logger = Logger(
        subsystem: "momo.PlayCover-ExStorage",
        category: "MigrationWorkflow"
    )

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PlayCover ExStorage", isDirectory: true)
            .appendingPathComponent("workflow.log")
    }

    static func event(
        _ name: String,
        bundleID: String? = nil,
        details: @autoclosure () -> String = ""
    ) {
        let detail = details()
        let bundle = bundleID.map { " bundle=\($0)" } ?? ""
        let suffix = detail.isEmpty ? "" : " \(detail)"
        let message = "\(name)\(bundle)\(suffix)"
        logger.info("\(message, privacy: .public)")

        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try handle.write(contentsOf: Data("[\(timestamp)] \(message)\n".utf8))
        } catch {
            logger.error("workflow log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 2_000_000 else { return }
        try? FileManager.default.removeItem(at: logURL)
    }
}
