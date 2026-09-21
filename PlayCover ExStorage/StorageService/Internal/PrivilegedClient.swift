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
    func createAPFSVolume(containerReference: String, name: String, operationID: String, logPath: String, reply: @escaping (String?, String?, String?, NSError?) -> Void)
    func deleteAPFSVolume(device: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func mountAPFSVolume(device: String, atPath: String, options: [String], operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func unmountVolume(atPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func renameItem(fromPath: String, toPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func deleteItem(atPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func shutdown(operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
}

nonisolated private final class StandardReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: (String?, NSError?)?

    @discardableResult
    func storeIfEmpty(_ value: (String?, NSError?)) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedValue == nil else { return false }
        storedValue = value
        return true
    }

    func load() -> (String?, NSError?)? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

nonisolated private final class CreateVolumeReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: (String?, String?, String?, NSError?)?

    @discardableResult
    func storeIfEmpty(_ value: (String?, String?, String?, NSError?)) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedValue == nil else { return false }
        storedValue = value
        return true
    }

    func load() -> (String?, String?, String?, NSError?)? {
        lock.lock()
        defer { lock.unlock() }
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

    private func proxy(
        onError: (@Sendable (Error) -> Void)? = nil
    ) throws -> PrivilegedHelperXPCProtocol {
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
            onError?(error)
        }
        guard let typedProxy = proxy as? PrivilegedHelperXPCProtocol else {
            throw helperError("Unable to create the privileged helper XPC proxy.")
        }
        return typedProxy
    }

    private func waitForReply(
        invoke: (_ proxy: PrivilegedHelperXPCProtocol, _ finish: @escaping (String?, NSError?) -> Void) throws -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = StandardReplyBox()
        let finish: @Sendable (String?, NSError?) -> Void = { message, error in
            if box.storeIfEmpty((message, error)) {
                semaphore.signal()
            }
        }
        let remote = try proxy { error in
            finish(nil, error as NSError)
        }
        try invoke(remote, finish)
        semaphore.wait()
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

    func createAPFSVolume(containerRef: String, name: String, operationID: String, logURL: URL) throws -> CreatedAPFSVolume {
        let semaphore = DispatchSemaphore(value: 0)
        let box = CreateVolumeReplyBox()
        let finish: @Sendable (String?, String?, String?, NSError?) -> Void = { device, mountPath, message, error in
            if box.storeIfEmpty((device, mountPath, message, error)) {
                semaphore.signal()
            }
        }
        let remote = try proxy { error in
            finish(nil, nil, nil, error as NSError)
        }
        remote.createAPFSVolume(
            containerReference: containerRef,
            name: name,
            operationID: operationID,
            logPath: logURL.path,
            reply: finish
        )
        semaphore.wait()
        guard let (device, mountPath, message, error) = box.load() else {
            throw helperError("The privileged helper returned no create-volume reply.", code: 3)
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

    func unmount(byMountPoint: URL, operationID: String, logURL: URL) throws {
        try waitForReply { proxy, finish in
            proxy.unmountVolume(atPath: byMountPoint.path, operationID: operationID, logPath: logURL.path, reply: finish)
        }
    }

    func mountAPFS(byDevice: String, at mountPoint: URL, options: [String], operationID: String, logURL: URL) throws {
        try waitForReply { proxy, finish in
            proxy.mountAPFSVolume(
                device: byDevice,
                atPath: mountPoint.path,
                options: options,
                operationID: operationID,
                logPath: logURL.path,
                reply: finish
            )
        }
    }

    func deleteAPFSVolume(byDevice: String, operationID: String, logURL: URL) throws {
        try waitForReply { proxy, finish in
            proxy.deleteAPFSVolume(device: byDevice, operationID: operationID, logPath: logURL.path, reply: finish)
        }
    }

    func renameItem(from source: URL, to destination: URL, operationID: String, logURL: URL) throws {
        try waitForReply { proxy, finish in
            proxy.renameItem(
                fromPath: source.path,
                toPath: destination.path,
                operationID: operationID,
                logPath: logURL.path,
                reply: finish
            )
        }
    }

    func deleteItem(at url: URL, operationID: String, logURL: URL) throws {
        try waitForReply { proxy, finish in
            proxy.deleteItem(atPath: url.path, operationID: operationID, logPath: logURL.path, reply: finish)
        }
    }

    func shutdownHelper(operationID: String, logURL: URL) {
        guard let connection else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            print("[PrivilegedHelper] shutdown error: \(error.localizedDescription)")
            semaphore.signal()
        }
        if let typedProxy = proxy as? PrivilegedHelperXPCProtocol {
            typedProxy.shutdown(operationID: operationID, logPath: logURL.path) { message, error in
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
