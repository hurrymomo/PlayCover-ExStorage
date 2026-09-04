import Foundation

/// Mutable scheduling and execution state owned by MigrationService. AppModel
/// contains committed application/storage facts and never stores this state.
@MainActor
final class MigrationRuntimeState {
    private let reporter: MigrationStatusReporter
    private(set) var activeRequest: PendingMigration?
    private(set) var queuedRequests: [PendingMigration] = []
    private(set) var phase: MigrationExecutionPhase = .idle
    private(set) var isExecuting = false
    private(set) var errors: [String: String] = [:]

    init(reporter: MigrationStatusReporter) {
        self.reporter = reporter
        publish()
    }

    func enqueue(_ request: PendingMigration, atFront: Bool = false) {
        if atFront { queuedRequests.insert(request, at: 0) }
        else { queuedRequests.append(request) }
        if activeRequest == nil { phase = .queued }
        publish()
    }

    func beginNext() -> PendingMigration? {
        guard activeRequest == nil, !isExecuting, !queuedRequests.isEmpty else { return nil }
        let request = queuedRequests.removeFirst()
        activeRequest = request
        isExecuting = true
        phase = .preparing
        errors.removeValue(forKey: request.bundleIdentifier)
        publish()
        return request
    }

    func finish(success: Bool, error: String?) {
        if let bundleID = activeRequest?.bundleIdentifier, let error {
            errors[bundleID] = error
        }
        activeRequest = nil
        isExecuting = false
        phase = success ? .completed : .failed
        publish()
    }

    func setPhase(_ value: MigrationExecutionPhase) {
        phase = value
        publish()
    }

    func recordError(_ message: String, for bundleIdentifier: String) {
        errors[bundleIdentifier] = message
        publish()
    }

    @discardableResult
    func clearError(for bundleIdentifier: String) -> Bool {
        guard errors.removeValue(forKey: bundleIdentifier) != nil else { return false }
        publish()
        return true
    }

    func isLocked(bundleIdentifier: String) -> Bool {
        activeRequest?.bundleIdentifier == bundleIdentifier
            || queuedRequests.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func publish() {
        reporter.updateSchedule(
            active: activeRequest,
            queued: queuedRequests,
            phase: phase,
            errors: errors
        )
    }
}

struct LocalMigrationRecord: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var request: PendingMigration
    var appInfo: ManagedApplicationInfo
    var phase: MigrationExecutionPhase
    var lastError: String?
}

nonisolated enum MigrationTransactionStage: String, Codable, Equatable, Sendable {
    case app
    case data
}

nonisolated struct MigrationTransactionState: Codable, Equatable, Sendable {
    var request: PendingMigration
    var nextStage: MigrationTransactionStage
    /// Authoritative locations before an App & Data transaction began. They
    /// remain in the local migration record until both components commit, so
    /// a later component failure can compensate the earlier committed move.
    var originalAppLocation: ManagedLocation? = nil
    var originalDataLocation: ManagedLocation? = nil
}
