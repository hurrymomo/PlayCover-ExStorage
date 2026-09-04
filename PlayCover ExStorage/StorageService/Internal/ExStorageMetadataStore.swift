import Foundation

/// Internal metadata persistence used by storage workflows.
actor ExStorageMetadataStore {
    enum StoreError: LocalizedError {
        case unsupportedSchema(Int)
        case missingRequiredField(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(version):
                "This ExStorage metadata uses unsupported schema version \(version)."
            case let .missingRequiredField(field):
                "AppInfo is missing required field \(field)."
            }
        }
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let decoder = JSONDecoder()

    func initialize(
        at root: URL,
        managementVolumeUUID: String,
        containerUUID: UUID
    ) throws -> ExternalStorageMetadata {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: root.appendingPathComponent(ExStorageLayout.applicationsDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent(ExStorageLayout.appInfoDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )

        if let existing = try loadMetadata(at: root) {
            guard existing.schemaVersion == ExternalStorageMetadata.currentSchemaVersion else {
                throw StoreError.unsupportedSchema(existing.schemaVersion)
            }
            guard existing.managementVolumeUUID.caseInsensitiveCompare(managementVolumeUUID) == .orderedSame,
                  existing.containerUUID.caseInsensitiveCompare(containerUUID.uuidString) == .orderedSame else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Rewrites older metadata without deprecated migration indexes.
            try saveMetadata(existing, at: root)
            return existing
        }

        let metadata = ExternalStorageMetadata(
            managementVolumeUUID: managementVolumeUUID,
            containerUUID: containerUUID.uuidString
        )
        try saveMetadata(metadata, at: root)
        return metadata
    }

    func loadMetadata(at root: URL) throws -> ExternalStorageMetadata? {
        let url = root.appendingPathComponent(ExStorageLayout.metadataFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ExternalStorageMetadata.self, from: Data(contentsOf: url))
    }

    func loadAppInfo(bundleID: String, at root: URL) throws -> ExStorageAppInfo? {
        let url = try appInfoURL(bundleID: bundleID, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decodeAppInfo(at: url, expectedBundleID: bundleID)
    }

    @discardableResult
    func saveAppInfo(_ info: ExStorageAppInfo, at root: URL) throws -> ExStorageAppInfo {
        var normalized = info
        normalized.schemaVersion = ExStorageAppInfo.currentSchemaVersion
        guard !normalized.dataVolumeUUID.isEmpty else {
            throw StoreError.missingRequiredField("dataVolumeUUID")
        }
        guard !normalized.localAppPathHint.isEmpty else {
            throw StoreError.missingRequiredField("localAppPathHint")
        }
        try atomicWrite(
            try encoder.encode(normalized),
            to: appInfoURL(bundleID: normalized.bundleID, root: root)
        )
        return normalized
    }

    /// Migration keeps richer state in its local journal. AppInfo only keeps
    /// the committed Data identity and the non-authoritative local App hint.
    @discardableResult
    func saveAppInfo(_ state: ManagedApplicationInfo, at root: URL) throws -> ExStorageAppInfo {
        let existing = try loadAppInfo(bundleID: state.bundleID, at: root)
        guard case let .dataVolume(dataVolumeUUID) = state.data.location else {
            try deleteAppInfo(bundleID: state.bundleID, at: root)
            throw StoreError.missingRequiredField("dataVolumeUUID")
        }
        guard let hint = state.localAppPathHint ?? existing?.localAppPathHint,
              !hint.isEmpty else {
            throw StoreError.missingRequiredField("localAppPathHint")
        }
        return try saveAppInfo(
            ExStorageAppInfo(
                bundleID: state.bundleID,
                dataVolumeUUID: dataVolumeUUID,
                localAppPathHint: hint
            ),
            at: root
        )
    }

    @discardableResult
    func upsertAppInfo(
        bundleID: String,
        dataVolumeUUID: String,
        localAppPathHint: String?,
        at root: URL
    ) throws -> ExStorageAppInfo {
        let existing = try loadAppInfo(bundleID: bundleID, at: root)
        guard let hint = localAppPathHint ?? existing?.localAppPathHint,
              !hint.isEmpty else {
            throw StoreError.missingRequiredField("localAppPathHint")
        }
        return try saveAppInfo(
            ExStorageAppInfo(
                bundleID: bundleID,
                dataVolumeUUID: dataVolumeUUID,
                localAppPathHint: hint
            ),
            at: root
        )
    }

    @discardableResult
    func updateLocalAppPathHint(
        bundleID: String,
        localAppPathHint: String,
        at root: URL
    ) throws -> ExStorageAppInfo? {
        guard !localAppPathHint.isEmpty else {
            throw StoreError.missingRequiredField("localAppPathHint")
        }
        guard var info = try loadAppInfo(bundleID: bundleID, at: root) else { return nil }
        info.localAppPathHint = localAppPathHint
        return try saveAppInfo(info, at: root)
    }

    func deleteAppInfo(bundleID: String, at root: URL) throws {
        let url = try appInfoURL(bundleID: bundleID, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func loadAllAppInfo(at root: URL) throws -> [ExStorageAppInfo] {
        let directory = root.appendingPathComponent(ExStorageLayout.appInfoDirectoryName, isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        return urls.compactMap {
            try? decodeAppInfo(
                at: $0,
                expectedBundleID: $0.deletingPathExtension().lastPathComponent
            )
        }
    }

    func applicationBundleURLs(at root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent(
            ExStorageLayout.applicationsDirectoryName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame }
    }

    private func saveMetadata(_ metadata: ExternalStorageMetadata, at root: URL) throws {
        try atomicWrite(
            try encoder.encode(metadata),
            to: root.appendingPathComponent(ExStorageLayout.metadataFileName)
        )
    }

    private func decodeAppInfo(at url: URL, expectedBundleID: String) throws -> ExStorageAppInfo? {
        let data = try Data(contentsOf: url)
        let info = try decoder.decode(ExStorageAppInfo.self, from: data)
        guard info.schemaVersion == ExStorageAppInfo.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(info.schemaVersion)
        }
        guard info.bundleID == expectedBundleID else { throw CocoaError(.fileReadCorruptFile) }
        guard !info.dataVolumeUUID.isEmpty else {
            throw StoreError.missingRequiredField("dataVolumeUUID")
        }
        guard !info.localAppPathHint.isEmpty else {
            throw StoreError.missingRequiredField("localAppPathHint")
        }
        return info
    }

    private func appInfoURL(bundleID: String, root: URL) throws -> URL {
        guard !bundleID.isEmpty,
              !bundleID.contains("/"),
              bundleID != ".",
              bundleID != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return root
            .appendingPathComponent(ExStorageLayout.appInfoDirectoryName, isDirectory: true)
            .appendingPathComponent(bundleID)
            .appendingPathExtension("json")
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}
