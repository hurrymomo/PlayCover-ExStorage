import Foundation

/// Long-running copy and verification primitives owned by Migration. Worker
/// tasks report progress without retaining a View or ViewModel.
enum MigrationFileOperations {
    nonisolated static func allocatedSize(of root: URL) throws -> Int64 {
        try FileSystemUtilities.allocatedSize(
            of: root,
            excludingRootItem: VolumeMetadataPolicy.isExcludedRootItem
        )
    }

    static func copyApplication(from source: URL, to destination: URL, logURL: URL) async throws {
        let migrationID = MigrationTrace.migrationID
        try await Task.detached(priority: .userInitiated) {
            try MigrationTrace.$migrationID.withValue(migrationID) {
                try MigrationCommandRunner.copyWithDitto(from: source, to: destination, logURL: logURL)
            }
        }.value
    }

    static func copyData(
        from source: URL,
        to destination: URL,
        logURL: URL,
        sourceManifest: MigrationVerifier.Manifest,
        progressRange: ClosedRange<Double>,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let migrationID = MigrationTrace.migrationID
        let baseline = try await Task.detached(priority: .utility) {
            try MigrationTrace.$migrationID.withValue(migrationID) {
                try MigrationVerifier.progressBaseline(
                    sourceManifest: sourceManifest,
                    destination: destination
                )
            }
        }.value
        let accumulator = RsyncByteProgressAccumulator(manifest: sourceManifest, baseline: baseline)
        let lowerBound = progressRange.lowerBound
        let span = progressRange.upperBound - lowerBound
        try await Task.detached(priority: .userInitiated) {
            try MigrationTrace.$migrationID.withValue(migrationID) {
                try MigrationCommandRunner.copyDataWithRsync(from: source, to: destination, logURL: logURL) { event in
                    guard let fraction = accumulator.update(event) else { return }
                    Task { @MainActor in onProgress(lowerBound + fraction * span) }
                }
            }
        }.value
    }

    static func manifest(at source: URL) async throws -> MigrationVerifier.Manifest {
        let migrationID = MigrationTrace.migrationID
        return try await Task.detached(priority: .utility) {
            try MigrationTrace.$migrationID.withValue(migrationID) {
                try MigrationVerifier.makeManifest(at: source)
            }
        }.value
    }

    static func verifyApplication(from source: URL, to destination: URL) async throws {
        let migrationID = MigrationTrace.migrationID
        try await Task.detached(priority: .utility) {
            try MigrationTrace.$migrationID.withValue(migrationID) {
                try MigrationVerifier.verifyCopy(from: source, to: destination)
            }
        }.value
    }

    static func verifyData(
        sourceManifest: MigrationVerifier.Manifest,
        destination: URL
    ) async throws {
        let migrationID = MigrationTrace.migrationID
        try await Task.detached(priority: .utility) {
            try MigrationTrace.$migrationID.withValue(migrationID) {
                try MigrationVerifier.verifyCopy(sourceManifest: sourceManifest, destination: destination)
            }
        }.value
    }
}
