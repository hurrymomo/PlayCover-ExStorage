import Foundation

/// Calculates byte progress for a resumable rsync transfer. Files already
/// verified at the destination form the baseline after an interrupted run.
nonisolated final class RsyncByteProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let fileSizes: [String: Int64]
    private let totalBytes: Int64
    private var completedPaths: Set<String>
    private var completedBytes: Int64
    private var currentPath: String?
    private var currentBytes: Int64 = 0

    init(manifest: MigrationVerifier.Manifest, baseline: MigrationVerifier.ProgressBaseline) {
        fileSizes = manifest.regularFileSizes
        totalBytes = manifest.totalRegularFileBytes
        completedPaths = baseline.completedPaths
        completedBytes = baseline.completedBytes
    }

    func update(_ event: RsyncFileProgress) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard totalBytes > 0 else { return nil }
        let path = event.relativePath.hasPrefix("./")
            ? String(event.relativePath.dropFirst(2))
            : event.relativePath
        guard let fileSize = fileSizes[path] else { return nil }
        if completedPaths.contains(path) {
            currentPath = nil
            currentBytes = 0
        } else if event.isComplete {
            completedPaths.insert(path)
            completedBytes += fileSize
            currentPath = nil
            currentBytes = 0
        } else {
            currentPath = path
            currentBytes = min(fileSize, max(0, event.transferredBytes))
        }
        let activeBytes = currentPath == nil ? 0 : currentBytes
        return min(1, max(0, Double(completedBytes + activeBytes) / Double(totalBytes)))
    }
}

@MainActor
final class MigrationSleepPreventer {
    private var activity: NSObjectProtocol?

    func setMigrationActive(_ isActive: Bool) {
        if isActive {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Migrating PlayCover app data"
            )
            MigrationTrace.event("migration.sleep-prevention.started")
        } else {
            guard let activity else { return }
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            MigrationTrace.event("migration.sleep-prevention.ended")
        }
    }
}
