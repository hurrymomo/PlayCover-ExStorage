import Foundation
import ServiceManagement
import Security

private let helperMachServiceName = "momo.PlayCover-ExStorage.PrivilegedHelper"
private let helperPlistName = "momo.PlayCover-ExStorage.PrivilegedHelper.plist"
private func signingTeamIdentifier() -> String? {
    guard let executableURL = Bundle.main.executableURL else { return nil }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [String: Any] else { return nil }
    return values[kSecCodeInfoTeamIdentifier as String] as? String
}

@objc private protocol PrivilegedHelperXPCProtocol {
    func createAPFSVolume(containerReference: String, name: String, reply: @escaping (String?, String?, String?, NSError?) -> Void)
    func deleteAPFSVolume(device: String, reply: @escaping (String?, NSError?) -> Void)
    func mountAPFSVolume(device: String, atPath: String, options: [String], reply: @escaping (String?, NSError?) -> Void)
    func unmountVolume(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func renameItem(fromPath: String, toPath: String, reply: @escaping (String?, NSError?) -> Void)
    func copyItem(fromPath: String, toPath: String, reply: @escaping (String?, NSError?) -> Void)
    func deleteItem(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func shutdown(reply: @escaping (String?, NSError?) -> Void)
}

private final class StandardReplyBox: @unchecked Sendable {
    private var storedValue: (String?, NSError?)?

    func store(_ value: (String?, NSError?)) {
        storedValue = value
    }

    func load() -> (String?, NSError?)? {
        storedValue
    }
}

private final class CreateVolumeReplyBox: @unchecked Sendable {
    private var storedValue: (String?, String?, String?, NSError?)?

    func store(_ value: (String?, String?, String?, NSError?)) {
        storedValue = value
    }

    func load() -> (String?, String?, String?, NSError?)? {
        return storedValue
    }
}

final class XPCPrivilegedClient: @unchecked Sendable {
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

        let proxy = connection!.remoteObjectProxyWithErrorHandler { error in
            print("[PrivilegedHelper] XPC error: \(error.localizedDescription)")
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
            throw helperError("Timed out waiting for the privileged helper.", code: 2)
        }
        guard let (message, error) = box.load() else {
            throw helperError("The privileged helper returned no reply.", code: 3)
        }
        if let error { throw error }
        if let message { print("[PrivilegedHelper]\n\(message)") }
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
            throw helperError("Timed out waiting for create-volume.", code: 2)
        }
        if let error { throw error }
        guard let device, let mountPath else {
            throw helperError("The helper returned an invalid create-volume result.", code: 3)
        }
        if let message { print("[PrivilegedHelper]\n\(message)") }
        return CreatedAPFSVolume(bsdDevice: device, mountPoint: URL(fileURLWithPath: mountPath))
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

    func copyItem(from source: URL, to destination: URL) throws {
        try waitForReply(timeout: 24 * 60 * 60) { proxy, finish in
            proxy.copyItem(fromPath: source.path, toPath: destination.path, reply: finish)
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
                if let error { print("[PrivilegedHelper] shutdown error: \(error.localizedDescription)") }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        connection.invalidate()
        self.connection = nil
    }
}
