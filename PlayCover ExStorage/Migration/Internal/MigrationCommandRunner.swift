import Foundation

nonisolated struct RsyncFileProgress: Sendable {
    let relativePath: String
    let transferredBytes: Int64
    let isComplete: Bool
}

nonisolated enum MigrationCommandRunner {
    nonisolated static func copyWithDitto(from source: URL, to destination: URL, logURL: URL) throws {
        let executable = "/usr/bin/ditto"
        let arguments = ["--rsrc", "--extattr", source.path, destination.path]
        append("EXEC \(([executable] + arguments).map(shellQuoted).joined(separator: " "))", to: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            append("LAUNCH ERROR \(error.localizedDescription)", to: logURL)
            throw error
        }

        let readers = DispatchGroup()
        let stdoutCapture = UserCommandPipeCapture()
        let stderrCapture = UserCommandPipeCapture()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutCapture.store(output.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrCapture.store(error.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()

        let stdout = String(data: stdoutCapture.load(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrCapture.load(), encoding: .utf8) ?? ""
        append("EXIT \(process.terminationStatus)", to: logURL)
        appendOutput("STDOUT", stdout, to: logURL)
        appendOutput("STDERR", stderr, to: logURL)

        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = NSError(
                domain: "PlayCoverExStorage.Ditto",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty
                    ? "ditto failed with status \(process.terminationStatus)."
                    : message]
            )
            print("[AppCommand] ERROR (ditto)\nDomain: \(error.domain)\nCode: \(error.code)\n\(error.localizedDescription)")
            throw error
        }
    }

    /// Data-volume copy engine. Unlike the bundle-oriented ditto path, rsync
    /// can reuse completed destination files and retains interrupted files for
    /// a later invocation. The partial directory deliberately lives on the
    /// destination volume.
    nonisolated static func copyDataWithRsync(
        from source: URL,
        to destination: URL,
        logURL: URL,
        progressHandler: (@Sendable (RsyncFileProgress) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) {
            guard destinationIsDirectory.boolValue else {
                throw NSError(
                    domain: "PlayCoverExStorage.Copy",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The copy destination is not a directory: \(destination.path)"]
                )
            }
        } else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        }

        var copyArguments = [
            "-a",
            "--progress",
            "--partial",
            "--partial-dir=.ExStoragePartial",
            // Migration verifies an exact source/destination manifest. Delete
            // stale destination entries only after the transfer finishes so an
            // overwrite or resumed copy can satisfy that invariant without
            // removing reusable files before rsync has completed its pass.
            "--delete-after"
        ]
        for name in VolumeMetadataPolicy.excludedRootItemNames.sorted() {
            copyArguments.append(contentsOf: ["--exclude", "/\(name)"])
        }
        for name in VolumeMetadataPolicy.excludedDirectoryNamesAtAnyDepth.sorted() {
            copyArguments.append(contentsOf: ["--exclude", "\(name)/"])
        }
        for name in VolumeMetadataPolicy.excludedFileNamesAtAnyDepth.sorted() {
            copyArguments.append(contentsOf: ["--exclude", name])
        }
        let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
        let destinationPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        copyArguments.append(sourcePath)
        copyArguments.append(destinationPath)
        try runRsync(arguments: copyArguments, logURL: logURL, progressHandler: progressHandler)

        // openrsync 2.6.9 applies nested-file modes before extended attributes,
        // even when --chmod is supplied. Make the completed destination tree
        // writable, copy xattrs without applying permissions, then restore the
        // source's final POSIX modes in a metadata-only archive pass.
        try runCommand(
            executable: "/bin/chmod",
            arguments: ["-R", "u+w", destination.path],
            logURL: logURL,
            errorDomain: "PlayCoverExStorage.Chmod"
        )

        var extendedAttributeArguments = ["-rltE"]
        for name in VolumeMetadataPolicy.excludedRootItemNames.sorted() {
            extendedAttributeArguments.append(contentsOf: ["--exclude", "/\(name)"])
        }
        for name in VolumeMetadataPolicy.excludedDirectoryNamesAtAnyDepth.sorted() {
            extendedAttributeArguments.append(contentsOf: ["--exclude", "\(name)/"])
        }
        for name in VolumeMetadataPolicy.excludedFileNamesAtAnyDepth.sorted() {
            extendedAttributeArguments.append(contentsOf: ["--exclude", name])
        }
        extendedAttributeArguments.append(sourcePath)
        extendedAttributeArguments.append(destinationPath)
        try runRsync(arguments: extendedAttributeArguments, logURL: logURL)

        var permissionArguments = ["-a"]
        for name in VolumeMetadataPolicy.excludedRootItemNames.sorted() {
            permissionArguments.append(contentsOf: ["--exclude", "/\(name)"])
        }
        for name in VolumeMetadataPolicy.excludedDirectoryNamesAtAnyDepth.sorted() {
            permissionArguments.append(contentsOf: ["--exclude", "\(name)/"])
        }
        for name in VolumeMetadataPolicy.excludedFileNamesAtAnyDepth.sorted() {
            permissionArguments.append(contentsOf: ["--exclude", name])
        }
        permissionArguments.append(sourcePath)
        permissionArguments.append(destinationPath)
        try runRsync(arguments: permissionArguments, logURL: logURL)

        // A terminated rsync can leave an empty partial directory nested next
        // to the file it was copying. It is Migration-owned scratch data, not
        // App data, so remove any remnants before strict verification.
        try removePartialDirectories(in: destination, logURL: logURL)
    }

    nonisolated private static func removePartialDirectories(in destination: URL, logURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        var partialDirectories: [URL] = []
        for case let item as URL in enumerator {
            guard item.lastPathComponent == ".ExStoragePartial" else { continue }
            partialDirectories.append(item)
            enumerator.skipDescendants()
        }
        for directory in partialDirectories.sorted(by: { $0.path.count > $1.path.count }) {
            try fileManager.removeItem(at: directory)
            append("REMOVED PARTIAL \(shellQuoted(directory.path))", to: logURL)
        }
    }

    nonisolated private static func runRsync(
        arguments: [String],
        logURL: URL,
        progressHandler: (@Sendable (RsyncFileProgress) -> Void)? = nil
    ) throws {
        try runCommand(
            executable: "/usr/bin/rsync",
            arguments: arguments,
            logURL: logURL,
            errorDomain: "PlayCoverExStorage.Rsync",
            progressHandler: progressHandler
        )
    }

    nonisolated private static func runCommand(
        executable: String,
        arguments: [String],
        logURL: URL,
        errorDomain: String,
        progressHandler: (@Sendable (RsyncFileProgress) -> Void)? = nil
    ) throws {
        append("EXEC \(([executable] + arguments).map(shellQuoted).joined(separator: " "))", to: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            append("LAUNCH ERROR \(error.localizedDescription)", to: logURL)
            throw error
        }

        let readers = DispatchGroup()
        let stdoutCapture = UserCommandPipeCapture()
        let stderrCapture = UserCommandPipeCapture()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let parser = RsyncProgressParser(handler: progressHandler)
            while true {
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                stdoutCapture.append(data)
                parser.feed(data)
            }
            parser.finish()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrCapture.store(error.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()

        let stdout = String(data: stdoutCapture.load(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrCapture.load(), encoding: .utf8) ?? ""
        append("EXIT \(process.terminationStatus)", to: logURL)
        appendOutput("STDOUT", stdout, to: logURL)
        appendOutput("STDERR", stderr, to: logURL)
        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: errorDomain,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty
                    ? "rsync failed with status \(process.terminationStatus)."
                    : message]
            )
        }
    }

    nonisolated private static func appendOutput(_ label: String, _ value: String, to url: URL) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let limit = 32_000
        let content = trimmed.count > limit
            ? String(trimmed.prefix(limit)) + "\n… output truncated in log …"
            : trimmed
        append("\(label):\n\(content)", to: url)
    }

    nonisolated private static func append(_ message: String, to url: URL) {
        guard url.standardizedFileURL == MigrationTrace.logURL.standardizedFileURL else { return }
        MigrationTrace.command(message)
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

nonisolated private final class UserCommandPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

nonisolated private final class RsyncProgressParser {
    private let handler: (@Sendable (RsyncFileProgress) -> Void)?
    private var buffer = Data()
    private var currentPath: String?

    init(handler: (@Sendable (RsyncFileProgress) -> Void)?) {
        self.handler = handler
    }

    func feed(_ data: Data) {
        guard handler != nil else { return }
        buffer.append(data)
        consumeCompleteLines()
    }

    func finish() {
        guard !buffer.isEmpty else { return }
        consume(buffer)
        buffer.removeAll()
    }

    private func consumeCompleteLines() {
        while let separator = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = buffer[..<separator]
            buffer.removeSubrange(...separator)
            consume(Data(line))
        }
    }

    private func consume(_ data: Data) {
        guard let raw = String(data: data, encoding: .utf8) else { return }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.count >= 2,
           fields[1].hasSuffix("%"),
           let bytes = Int64(fields[0].replacingOccurrences(of: ",", with: "")),
           let percent = Int(fields[1].dropLast()),
           let currentPath {
            handler?(RsyncFileProgress(
                relativePath: currentPath,
                transferredBytes: bytes,
                isComplete: percent >= 100
            ))
        } else if !line.hasPrefix("sending "), !line.hasPrefix("receiving ") {
            currentPath = line
        }
    }
}
