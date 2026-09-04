import Foundation

enum MigrationRecoveryPlanningError: LocalizedError {
    case appUnavailable(String)
    case locationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .appUnavailable(bundleID):
            "The App required to resume \(bundleID) is unavailable."
        case let .locationUnavailable(description):
            "A migration location is unavailable: \(description)."
        }
    }
}

/// Reconstructs a typed request from the local durable migration journal. It
/// validates stable container identities against the fresh storage snapshot.
enum MigrationRecoveryPlanner {
    static func request(
        from record: LocalMigrationRecord,
        containers: [ExternalAPFSContainer],
        managedApps: [AppSnapshot]
    ) throws -> PendingMigration {
        let info = record.appInfo
        guard let app = managedApps.first(where: { $0.bundleIdentifier == info.bundleID }),
              !app.applicationPath.isEmpty else {
            throw MigrationRecoveryPlanningError.appUnavailable(info.bundleID)
        }

        var request = info.migrationTransaction?.request ?? record.request
        try validate(request.source, containers: containers)
        try validate(request.target, containers: containers)
        let activeState = info.bundle.migration ?? info.data.migration
        request.overwriteExisting = request.overwriteExisting || activeState != nil
        request.recoveryDestinationVolumeUUID = activeState.flatMap {
            volumeUUID(in: $0.destination)
        } ?? request.recoveryDestinationVolumeUUID
        request.recoveryPhase = activeState?.phase ?? request.recoveryPhase
        return request
    }

    private static func validate(
        _ target: MigrationTarget,
        containers: [ExternalAPFSContainer]
    ) throws {
        guard case let .container(id) = target else { return }
        guard containers.contains(where: { $0.id == id }) else {
            throw MigrationRecoveryPlanningError.locationUnavailable(id.uuidString)
        }
    }

    private static func volumeUUID(in location: ManagedLocation) -> String? {
        switch location {
        case .local: nil
        case let .managementVolume(volumeUUID, _), let .dataVolume(volumeUUID): volumeUUID
        }
    }
}
