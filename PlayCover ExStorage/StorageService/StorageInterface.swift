import Foundation

nonisolated enum StorageItemKind: Sendable {
    case missing
    case file
    case directory
}

nonisolated struct StorageSnapshot: Sendable {
    let containersByID: [UUID: ExternalAPFSContainer]
    let capturedAt: Date

    var containers: [ExternalAPFSContainer] {
        containersByID.values.sorted {
            (($0.displayName ?? ""), $0.containerReference)
                < (($1.displayName ?? ""), $1.containerReference)
        }
    }
}

/// The only filesystem and privileged-storage entry point available to the
/// application layer. Implementations and mutable state live in `Internal/`.
nonisolated protocol StorageServicing: Sendable {
    var homeDirectory: URL { get }

    func scanSnapshot() async -> StorageSnapshot
    func scanContainers(onPhysicalDevice device: String) async -> [ExternalAPFSContainer]
    func setStorageChangeHandler(
        _ handler: @escaping @MainActor @Sendable (StorageDeviceChange) -> Void
    )

    func itemExists(at url: URL) -> Bool
    func itemKind(at url: URL) -> StorageItemKind
    func directoryIsEmptyOrMissing(at url: URL) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func moveItem(from source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func allocatedSize(of root: URL) throws -> Int64

    func beginPrivilegedOperationLog(at url: URL) async throws
    func ensurePrivilegedHelperAvailable() async throws
    func createAPFSVolume(containerReference: String, name: String) async throws -> CreatedAPFSVolume
    func mountAPFSVolume(device: String, at mountPoint: URL, options: [String]) async throws
    func unmountVolume(at mountPoint: URL) async throws
    func deleteAPFSVolume(device: String) async throws
    func movePrivilegedItem(from source: URL, to destination: URL) async throws
    func deletePrivilegedItem(at url: URL) async throws
    func shutdownPrivilegedHelper()

    // Temporary compatibility surface for application workflows that have not
    // yet moved to the async privileged API above.
    func beginOperationLog(at url: URL) throws
    func ensureHelperAvailable() throws
    func createAPFSVolume(containerRef: String, name: String) throws -> CreatedAPFSVolume
    func mountAPFS(byDevice device: String, at mountPoint: URL, options: [String]) throws
    func unmount(byMountPoint mountPoint: URL) throws
    func deleteAPFSVolume(byDevice device: String) throws
    func renameItem(from source: URL, to destination: URL) throws
    func deleteItem(at url: URL) throws
}
