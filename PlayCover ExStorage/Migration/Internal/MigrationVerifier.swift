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
        ".metadata_never_index",
        ".ExStoragePartial"
    ]

    /// Archive metadata directories are packaging artifacts rather than App
    /// business data. Exclude them wherever they occur in a migration tree.
    static let excludedDirectoryNamesAtAnyDepth: Set<String> = [
        "__MACOSX",
        ".ExStoragePartial"
    ]

    /// Finder may create these while a destination volume is mounted. They
    /// are not App data and must not make an otherwise complete resumed copy
    /// fail strict verification.
    static let excludedFileNamesAtAnyDepth: Set<String> = [".DS_Store"]

    static func isExcludedRootItem(_ url: URL) -> Bool {
        excludedRootItemNames.contains(url.lastPathComponent)
    }

    static func isExcludedAtAnyDepth(_ url: URL) -> Bool {
        excludedDirectoryNamesAtAnyDepth.contains(url.lastPathComponent)
            || excludedFileNamesAtAnyDepth.contains(url.lastPathComponent)
    }
}
/// Internal filesystem verification support for storage migrations.
nonisolated enum MigrationVerifier {
    struct Manifest {
        fileprivate let entries: [String: Entry]

        var regularFileSizes: [String: Int64] {
            entries.compactMapValues { entry in
                if case .file = entry.kind { return entry.logicalSize }
                return nil
            }
        }

        var totalRegularFileBytes: Int64 {
            regularFileSizes.values.reduce(0, +)
        }
    }

    struct ProgressBaseline {
        let completedPaths: Set<String>
        let completedBytes: Int64
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
            let missingPaths = sourceManifest.keys.filter { destinationManifest[$0] == nil }.sorted()
            let unexpectedPaths = destinationManifest.keys.filter { sourceManifest[$0] == nil }.sorted()
            let changedPaths = sourceManifest.keys.filter {
                guard let destinationEntry = destinationManifest[$0] else { return false }
                return destinationEntry != sourceManifest[$0]
            }.sorted()
            let examples = [
                pathSummary("missing", missingPaths),
                pathSummary("unexpected", unexpectedPaths),
                pathSummary("changed", changedPaths)
            ].compactMap { $0 }.joined(separator: "; ")
            throw verificationError(
                "Copy verification failed (missing: \(missingPaths.count), unexpected: \(unexpectedPaths.count), changed: \(changedPaths.count))."
                    + (examples.isEmpty ? "" : " \(examples)")
            )
        }
    }

    static func progressBaseline(sourceManifest: Manifest, destination: URL) throws -> ProgressBaseline {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return ProgressBaseline(completedPaths: [], completedBytes: 0)
        }
        let destinationEntries = try manifest(at: destination)
        let completedPaths: Set<String> = Set(sourceManifest.entries.compactMap { path, sourceEntry -> String? in
            guard case .file = sourceEntry.kind,
                  destinationEntries[path] == sourceEntry else { return nil }
            return path
        })
        let completedBytes = completedPaths.reduce(Int64(0)) {
            $0 + (sourceManifest.entries[$1]?.logicalSize ?? 0)
        }
        return ProgressBaseline(completedPaths: completedPaths, completedBytes: completedBytes)
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
        ).filter {
            !VolumeMetadataPolicy.isExcludedRootItem($0)
                && !VolumeMetadataPolicy.isExcludedAtAnyDepth($0)
        }

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
                if VolumeMetadataPolicy.isExcludedAtAnyDepth(item) {
                    enumerator.skipDescendants()
                    continue
                }
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

    private static func pathSummary(_ label: String, _ paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        let sample = paths.prefix(3).joined(separator: ", ")
        return "\(label): [\(sample)\(paths.count > 3 ? ", …" : "")]"
    }
}
