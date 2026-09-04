import AppKit
import Foundation

/// Stateless deletion primitives. The caller decides what should be deleted;
/// StorageService remains the only object that mutates filesystem storage.
enum ManagedAppDeletion {
    static func deleteVerifiedVolume(
        device: String,
        expectedUUID: String,
        expectedContainerReference: String,
        using storage: any StorageServicing
    ) async throws {
        let identity = await Task.detached(priority: .userInitiated) {
            DiskUtilDiscovery.volumeIdentity(for: device)
        }.value
        guard identity?.volumeUUID == expectedUUID,
              identity?.containerReference == expectedContainerReference else {
            throw error("Refusing to delete a Volume whose UUID or APFS Container changed.")
        }
        try await Task.detached(priority: .userInitiated) {
            try storage.deleteAPFSVolume(byDevice: device)
        }.value
    }

    static func moveApplicationToTrash(
        _ applicationURL: URL,
        using storage: any StorageServicing
    ) async throws {
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            throw error("Refusing to trash a path that is not an App bundle.")
        }
        guard storage.itemExists(at: applicationURL) else {
            throw error("The App no longer exists at its recorded path.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([applicationURL]) { _, recycleError in
                if let recycleError {
                    continuation.resume(throwing: recycleError)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "PlayCoverExStorage.Deletion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
