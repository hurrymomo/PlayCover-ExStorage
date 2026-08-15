import Foundation
import ServiceManagement
import Security

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

    nonisolated static func copyVolumeContentsWithDitto(from source: URL, to destination: URL, logURL: URL) throws {
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
        let items = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if VolumeMetadataPolicy.isExcludedRootItem(item) {
                append("SKIP volume metadata \(item.path)", to: logURL)
                continue
            }
            let destinationItem = destination.appendingPathComponent(item.lastPathComponent)
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: item.path)
                guard !fileManager.fileExists(atPath: destinationItem.path) else {
                    throw NSError(
                        domain: "PlayCoverExStorage.Ditto",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Refusing to replace an existing symbolic-link destination: \(destinationItem.path)"]
                    )
                }
                append("SYMLINK \(destinationItem.path) -> \(linkTarget)", to: logURL)
                try fileManager.createSymbolicLink(
                    atPath: destinationItem.path,
                    withDestinationPath: linkTarget
                )
            } else {
                try copyWithDitto(from: item, to: destinationItem, logURL: logURL)
            }
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

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
