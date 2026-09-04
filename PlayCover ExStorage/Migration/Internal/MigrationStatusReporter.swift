import Combine
import Foundation

/// The write side of MigrationStatus. It remains inside the Migration feature.
@MainActor
final class MigrationStatusReporter {
    private let subject = CurrentValueSubject<MigrationSnapshot, Never>(.idle)

    var updates: AnyPublisher<MigrationSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    private var snapshot: MigrationSnapshot { subject.value }

    func begin(_ request: PendingMigration) {
        publish(MigrationSnapshot(
            active: request,
            phase: .preparing,
            progress: nil,
            message: "Preparing migration…",
            queued: snapshot.queued,
            error: nil
        ))
    }

    func updateSchedule(
        active: PendingMigration?,
        queued: [PendingMigration],
        phase: MigrationExecutionPhase,
        errors: [String: String]
    ) {
        publish(MigrationSnapshot(
            active: active,
            phase: phase,
            progress: snapshot.progress,
            message: snapshot.message,
            queued: queued,
            error: active.flatMap { errors[$0.bundleIdentifier] }
        ))
    }

    func update(message: String? = nil, progress: Double? = nil) {
        publish(MigrationSnapshot(
            active: snapshot.active,
            phase: snapshot.phase,
            progress: progress,
            message: message ?? snapshot.message,
            queued: snapshot.queued,
            error: snapshot.error
        ))
    }

    func updateProgress(_ progress: Double) {
        guard snapshot.progress != progress else { return }
        publish(MigrationSnapshot(
            active: snapshot.active,
            phase: snapshot.phase,
            progress: progress,
            message: snapshot.message,
            queued: snapshot.queued,
            error: snapshot.error
        ))
    }

    func updatePhase(_ phase: MigrationExecutionPhase) {
        guard snapshot.phase != phase else { return }
        publish(MigrationSnapshot(
            active: snapshot.active,
            phase: phase,
            progress: snapshot.progress,
            message: snapshot.message,
            queued: snapshot.queued,
            error: snapshot.error
        ))
    }

    func finish(success: Bool, error: String?) {
        publish(MigrationSnapshot(
            active: nil,
            phase: success ? .completed : .failed,
            progress: success ? 1 : nil,
            message: error ?? snapshot.message,
            queued: snapshot.queued,
            error: error
        ))
    }

    private func publish(_ snapshot: MigrationSnapshot) {
        subject.send(snapshot)
    }
}
