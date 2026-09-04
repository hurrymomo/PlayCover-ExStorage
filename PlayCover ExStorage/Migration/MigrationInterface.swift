import Combine
import Foundation

enum MigrationExecutionPhase: String, Codable, Sendable {
    case idle
    case queued
    case preparing
    case copying
    case verifying
    case committing
    case rollingBack
    case needsAttention
    case completed
    case failed
}

struct MigrationSnapshot: Sendable {
    let active: PendingMigration?
    let phase: MigrationExecutionPhase
    let progress: Double?
    let message: String
    let queued: [PendingMigration]
    let error: String?

    static let idle = MigrationSnapshot(
        active: nil,
        phase: .idle,
        progress: nil,
        message: "Ready",
        queued: [],
        error: nil
    )
}

/// Observable, read-only migration status exposed to presentation.
@MainActor
final class MigrationStatus: ObservableObject {
    @Published private(set) var snapshot: MigrationSnapshot = .idle
    private var observation: AnyCancellable?

    init(updates: AnyPublisher<MigrationSnapshot, Never>) {
        observation = updates.sink { [weak self] snapshot in
            self?.snapshot = snapshot
        }
    }
}

@MainActor
protocol MigrationServicing: AnyObject {
    @discardableResult
    func startMigration(_ request: PendingMigration) throws -> UUID
    var status: MigrationStatus { get }
    func resumeInterruptedMigration() async
}
