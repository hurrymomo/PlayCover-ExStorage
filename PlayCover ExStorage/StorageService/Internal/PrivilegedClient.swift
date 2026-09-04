import Foundation
import ServiceManagement
import Security

nonisolated struct RsyncFileProgress: Sendable {
    let relativePath: String
    let transferredBytes: Int64
    let isComplete: Bool
}

nonisolated private let helperMachServiceName = "momo.PlayCover-ExStorage.PrivilegedHelper"
nonisolated private let helperPlistName = "momo.PlayCover-ExStorage.PrivilegedHelper.plist"
nonisolated private func signingTeamIdentifier() -> String? {
    guard let executableURL = Bundle.main.executableURL else { return nil }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [String: Any] else { return nil }
    return values[kSecCodeInfoTeamIdentifier as String] as? String
}

@objc nonisolated private protocol PrivilegedHelperXPCProtocol {
    func beginOperationLog(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func createAPFSVolume(containerReference: String, name: String, reply: @escaping (String?, String?, String?, NSError?) -> Void)
    func deleteAPFSVolume(device: String, reply: @escaping (String?, NSError?) -> Void)
    func mountAPFSVolume(device: String, atPath: String, options: [String], reply: @escaping (String?, NSError?) -> Void)
    func unmountVolume(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func renameItem(fromPath: String, toPath: String, reply: @escaping (String?, NSError?) -> Void)
    func deleteItem(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func shutdown(reply: @escaping (String?, NSError?) -> Void)
}

nonisolated private final class StandardReplyBox: @unchecked Sendable {
    private var storedValue: (String?, NSError?)?

    func store(_ value: (String?, NSError?)) {
        storedValue = value
    }

    func load() -> (String?, NSError?)? {
        storedValue
    }
}

nonisolated private final class CreateVolumeReplyBox: @unchecked Sendable {
    private var storedValue: (String?, String?, String?, NSError?)?

    func store(_ value: (String?, String?, String?, NSError?)) {
        storedValue = value
    }

    func load() -> (String?, String?, String?, NSError?)? {
        return storedValue
    }
}

/// Internal transport to the privileged storage executor. Application code
/// reaches this only through `StorageServicing`.
nonisolated final class XPCPrivilegedClient: @unchecked Sendable {
    static let shared = XPCPrivilegedClient()

    private let service = SMAppService.daemon(plistName: helperPlistName)
    private var connection: NSXPCConnection?

    private var authorizedHelperRequirement: String? {
        guard let teamID = signingTeamIdentifier() else { return nil }
        return "anchor apple generic and identifier \"momo.PlayCover-ExStorage.PrivilegedHelper\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    deinit {
        connection?.invalidate()
    }

    func ensureHelperAvailable() throws {
        do {
            try ensureHelperRegistered()
        } catch {
            printHelperError(error, context: "registration")
            throw error
        }
    }

    private func ensureHelperRegistered() throws {
        switch service.status {
        case .enabled:
            return

        case .notRegistered, .notFound:
            do {
                try service.register()
            } catch let registrationError as NSError {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    throw helperError("Helper was registered but needs approval in System Settings > General > Login Items.")
                }
                throw helperError(
                    "Helper registration failed: \(registrationError.domain) code \(registrationError.code): \(registrationError.localizedDescription)",
                    code: registrationError.code
                )
            }
            guard service.status == .enabled else {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                throw helperError("Helper registration is waiting for administrator approval in System Settings > General > Login Items.")
            }

        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw helperError("Enable PlayCover ExStorage in System Settings > General > Login Items, then try again.")

        @unknown default:
            throw helperError("Unknown privileged helper registration status.")
        }
    }

    private func helperError(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "PrivilegedHelper", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func printHelperError(_ error: Error, context: String? = nil) {
        let nsError = error as NSError
        let heading = context.map { "[PrivilegedHelper] ERROR (\($0))" }
            ?? "[PrivilegedHelper] ERROR"
        print("\(heading)\nDomain: \(nsError.domain)\nCode: \(nsError.code)\n\(nsError.localizedDescription)")
    }

    private func proxy() throws -> PrivilegedHelperXPCProtocol {
        try ensureHelperAvailable()

        if connection == nil {
            guard let authorizedHelperRequirement else {
                throw helperError("The app must be signed with an Apple Development or Developer ID certificate before the privileged helper can be used.")
            }
            let newConnection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
            newConnection.setCodeSigningRequirement(authorizedHelperRequirement)
            newConnection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
            newConnection.interruptionHandler = { print("[PrivilegedHelper] XPC connection interrupted") }
            newConnection.invalidationHandler = { print("[PrivilegedHelper] XPC connection invalidated") }
            newConnection.resume()
            connection = newConnection
        }

        let proxy = connection!.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.printHelperError(error, context: "XPC")
        }
        guard let typedProxy = proxy as? PrivilegedHelperXPCProtocol else {
            throw helperError("Unable to create the privileged helper XPC proxy.")
        }
        return typedProxy
    }

    private func waitForReply(
        timeout: TimeInterval = 15,
        invoke: (_ proxy: PrivilegedHelperXPCProtocol, _ finish: @escaping (String?, NSError?) -> Void) throws -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = StandardReplyBox()
        try invoke(proxy()) { message, error in
            box.store((message, error))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            connection?.invalidate()
            connection = nil
            let error = helperError("Timed out waiting for the privileged helper.", code: 2)
            printHelperError(error, context: "timeout")
            throw error
        }
        guard let (message, error) = box.load() else {
            let error = helperError("The privileged helper returned no reply.", code: 3)
            printHelperError(error, context: "missing reply")
            throw error
        }
        if let error {
            printHelperError(error)
            throw error
        }
        if let message { print("[PrivilegedHelper]\n\(message)") }
    }

    func beginOperationLog(at url: URL) throws {
        try waitForReply { proxy, finish in
            proxy.beginOperationLog(atPath: url.path, reply: finish)
        }
    }

    func createAPFSVolume(containerRef: String, name: String) throws -> CreatedAPFSVolume {
        let semaphore = DispatchSemaphore(value: 0)
        let box = CreateVolumeReplyBox()
        try proxy().createAPFSVolume(containerReference: containerRef, name: name) { device, mountPath, message, error in
            box.store((device, mountPath, message, error))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 120) == .success,
              let (device, mountPath, message, error) = box.load() else {
            let error = helperError("Timed out waiting for create-volume.", code: 2)
            printHelperError(error, context: "createAPFSVolume")
            throw error
        }
        if let error {
            printHelperError(error, context: "createAPFSVolume")
            throw error
        }
        guard let device else {
            let error = helperError("The helper returned an invalid create-volume result.", code: 3)
            printHelperError(error, context: "createAPFSVolume")
            throw error
        }
        if let message { print("[PrivilegedHelper]\n\(message)") }
        return CreatedAPFSVolume(
            bsdDevice: device,
            mountPoint: mountPath.map { URL(fileURLWithPath: $0) }
        )
    }

    func unmount(byMountPoint: URL) throws {
        try waitForReply { proxy, finish in
            proxy.unmountVolume(atPath: byMountPoint.path, reply: finish)
        }
    }

    func mountAPFS(byDevice: String, at mountPoint: URL, options: [String]) throws {
        try waitForReply { proxy, finish in
            proxy.mountAPFSVolume(device: byDevice, atPath: mountPoint.path, options: options, reply: finish)
        }
    }

    func deleteAPFSVolume(byDevice: String) throws {
        try waitForReply { proxy, finish in
            proxy.deleteAPFSVolume(device: byDevice, reply: finish)
        }
    }

    func renameItem(from source: URL, to destination: URL) throws {
        try waitForReply { proxy, finish in
            proxy.renameItem(fromPath: source.path, toPath: destination.path, reply: finish)
        }
    }

    func deleteItem(at url: URL) throws {
        try waitForReply { proxy, finish in
            proxy.deleteItem(atPath: url.path, reply: finish)
        }
    }

    func shutdownHelper() {
        guard let connection else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            print("[PrivilegedHelper] shutdown error: \(error.localizedDescription)")
            semaphore.signal()
        }
        if let typedProxy = proxy as? PrivilegedHelperXPCProtocol {
            typedProxy.shutdown { message, error in
                if let message { print("[PrivilegedHelper]\n\(message)") }
                if let error { self.printHelperError(error, context: "shutdown") }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        connection.invalidate()
        self.connection = nil
    }
}

enum OperationLog {
    private static let allowedNames = Set(["migrate", "reconnect", "restore", "remove"])

    static func prepare(named name: String) throws -> URL {
        guard allowedNames.contains(name) else {
            throw NSError(domain: "OperationLog", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid operation log name."])
        }
        if name == "migrate" {
            MigrationTrace.event("migration.command-log.attached", details: "path=\(MigrationTrace.logURL.path)")
            return MigrationTrace.logURL
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PlayCover ExStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).log")
        let formatter = ISO8601DateFormatter()
        let header = "PlayCover ExStorage \(name) log\nStarted: \(formatter.string(from: Date()))\n\n"
        try Data(header.utf8).write(to: url, options: .atomic)
        return url
    }

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
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("[\(timestamp)] \(message)\n".utf8))
        } catch {
            return
        }
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
