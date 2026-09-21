import Foundation

nonisolated enum FileSystemItemKind: Sendable {
    case missing
    case file
    case directory
}

/// Process-local filesystem primitives shared by application workflows.
/// They do not require APFS discovery or the privileged StorageService API.
nonisolated enum FileSystemUtilities {
    static func itemExists(at url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    static func itemKind(at url: URL, fileManager: FileManager = .default) -> FileSystemItemKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    static func directoryIsEmptyOrMissing(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard itemExists(at: url, fileManager: fileManager) else { return true }
        return (try? fileManager.contentsOfDirectory(atPath: url.path).isEmpty) ?? false
    }

    static func allocatedSize(
        of root: URL,
        fileManager: FileManager = .default,
        excludingRootItem: (URL) -> Bool = { _ in false }
    ) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .isDirectoryKey]
        var total = Int64((try? root.resourceValues(forKeys: keys).fileAllocatedSize) ?? 0)
        let rootItems = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).filter { !excludingRootItem($0) }

        for rootItem in rootItems {
            let rootValues = try rootItem.resourceValues(forKeys: keys)
            total += Int64(rootValues.fileAllocatedSize ?? 0)
            guard rootValues.isDirectory == true else { continue }
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: rootItem,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw NSError(
                    domain: "PlayCoverExStorage.FileSystem",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not inspect \(rootItem.path)."]
                )
            }
            for case let item as URL in enumerator {
                total += Int64(try item.resourceValues(forKeys: keys).fileAllocatedSize ?? 0)
            }
            if let enumerationError { throw enumerationError }
        }
        return total
    }
}
