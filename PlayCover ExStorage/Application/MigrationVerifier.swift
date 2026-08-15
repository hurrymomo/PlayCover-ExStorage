//
//  MigrationVerifier.swift
//  PlayCover ExStorage
//

import Foundation

nonisolated enum VolumeMetadataPolicy {
    static let excludedRootItemNames: Set<String> = [
        ".TemporaryItems",
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".DocumentRevisions-V100",
        ".metadata_never_index"
    ]

    static func isExcludedRootItem(_ url: URL) -> Bool {
        excludedRootItemNames.contains(url.lastPathComponent)
    }
}
nonisolated enum MigrationVerifier {
    struct Manifest {
        fileprivate let entries: [String: Entry]
    }

    fileprivate struct Entry: Equatable {
        enum Kind: Equatable { case file, directory, symbolicLink(String), other }
        let kind: Kind
        let logicalSize: Int64
    }

    static func verifyCopy(from source: URL, to destination: URL) throws {
        try verifyCopy(sourceManifest: makeManifest(at: source), destination: destination)
    }

    static func makeManifest(at source: URL) throws -> Manifest {
        Manifest(entries: try manifest(at: source))
    }

    static func verifyCopy(sourceManifest: Manifest, destination: URL) throws {
        let sourceManifest = sourceManifest.entries
        let destinationManifest = try manifest(at: destination)
        guard sourceManifest == destinationManifest else {
            let missing = sourceManifest.keys.filter { destinationManifest[$0] == nil }.count
            let unexpected = destinationManifest.keys.filter { sourceManifest[$0] == nil }.count
            let changed = sourceManifest.keys.filter {
                guard let destinationEntry = destinationManifest[$0] else { return false }
                return destinationEntry != sourceManifest[$0]
            }.count
            throw verificationError(
                "Copy verification failed (missing: \(missing), unexpected: \(unexpected), changed: \(changed))."
            )
        }
    }

    private static func manifest(at root: URL) throws -> [String: Entry] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        let fileManager = FileManager.default
        var result: [String: Entry] = [:]
        let prefix = root.standardizedFileURL.path + "/"
        let rootItems = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ).filter { !VolumeMetadataPolicy.isExcludedRootItem($0) }

        func record(_ item: URL) throws {
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return }
            let relativePath = String(path.dropFirst(prefix.count))
            let values = try item.resourceValues(forKeys: Set(keys))
            let kind: Entry.Kind
            if values.isSymbolicLink == true {
                kind = .symbolicLink(try fileManager.destinationOfSymbolicLink(atPath: item.path))
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                kind = .other
            }
            result[relativePath] = Entry(
                kind: kind,
                logicalSize: values.isRegularFile == true ? Int64(values.fileSize ?? 0) : 0
            )
        }

        for rootItem in rootItems {
            try record(rootItem)
            let rootValues = try rootItem.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { continue }
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: rootItem,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else { throw verificationError("Could not scan \(rootItem.path).") }
            for case let item as URL in enumerator {
                try record(item)
            }
            if let enumerationError { throw enumerationError }
        }
        return result
    }

    private static func verificationError(_ message: String) -> NSError {
        NSError(
            domain: "PlayCoverExStorage.CopyVerification",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
