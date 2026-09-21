import Foundation

/// The only application-facing boundary of the StorageService module.
nonisolated public protocol StorageServicing: Sendable {
    /// Pass `nil` for a full external-storage snapshot, or a whole-disk BSD
    /// identifier such as `disk4` for an incremental device snapshot.
    func scanSnapshot(onPhysicalDevice device: String?) async -> StorageSnapshot
    func setStorageChangeHandler(
        _ handler: @escaping @MainActor @Sendable (StorageDeviceChange) -> Void
    )

    /// Reads the current identity of one APFS volume without exposing diskutil.
    func volumeIdentity(for device: String) async -> StorageVolumeIdentity?

    /// Refreshes the free capacity of one already-discovered APFS container.
    func availableCapacity(for container: ExternalAPFSContainer) async -> Int64?

    func createAPFSVolume(containerReference: String, name: String) async throws -> CreatedAPFSVolume
    func mountAPFSVolume(device: String, at mountPoint: URL, options: [String]) async throws
    func unmountVolume(at mountPoint: URL) async throws
    func deleteAPFSVolume(device: String) async throws
    func movePrivilegedItem(from source: URL, to destination: URL) async throws
    func deletePrivilegedItem(at url: URL) async throws
    func shutdownPrivilegedHelper()
}

/// Public construction point. The concrete implementation stays internal.
nonisolated public enum StorageServiceFactory {
    public static var live: any StorageServicing { UserStorageService.shared }
}
