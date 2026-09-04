import Foundation

nonisolated enum StorageFileSystem {
    static func allocatedSize(of root: URL, fileManager: FileManager) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .isDirectoryKey]
        var total = Int64((try? root.resourceValues(forKeys: keys).fileAllocatedSize) ?? 0)
        let rootItems = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).filter { !VolumeMetadataPolicy.isExcludedRootItem($0) }

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
                    domain: "StorageService.Size",
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
