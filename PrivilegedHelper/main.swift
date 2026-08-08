import Foundation
import Security

private let helperMachServiceName = "momo.PlayCover-ExStorage.PrivilegedHelper"

private func authorizedAppRequirement() -> String? {
    guard let executableURL = Bundle.main.executableURL else { return nil }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [String: Any],
          let teamID = values[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
    return "anchor apple generic and identifier \"momo.PlayCover-ExStorage\" and certificate leaf[subject.OU] = \"\(teamID)\""
}

@objc protocol PrivilegedHelperXPCProtocol {
    func createAPFSVolume(containerReference: String, name: String, reply: @escaping (String?, String?, String?, NSError?) -> Void)
    func deleteAPFSVolume(device: String, reply: @escaping (String?, NSError?) -> Void)
    func mountAPFSVolume(device: String, atPath: String, options: [String], reply: @escaping (String?, NSError?) -> Void)
    func unmountVolume(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func renameItem(fromPath: String, toPath: String, reply: @escaping (String?, NSError?) -> Void)
    func copyItem(fromPath: String, toPath: String, reply: @escaping (String?, NSError?) -> Void)
    func deleteItem(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func shutdown(reply: @escaping (String?, NSError?) -> Void)
}

private struct CommandResult {
    let output: String
    let errorOutput: String
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    func store(_ data: Data) {
        lock.lock()
        storedData = data
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }
}

private enum HelperFailure {
    static func error(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "PlayCoverExStorage.PrivilegedHelper", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class PrivilegedHelperService: NSObject, PrivilegedHelperXPCProtocol {
    private let fileManager = FileManager.default
    private let devicePattern = try! NSRegularExpression(pattern: #"^disk[0-9]+s[0-9]+$"#)
    private let containerPattern = try! NSRegularExpression(pattern: #"^disk[0-9]+$"#)
    private let bundleIDPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#)
    private let containerPathPattern = try! NSRegularExpression(
        pattern: #"^/Users/[^/]+/Library/Containers/[A-Za-z0-9][A-Za-z0-9.-]{0,254}/Data(?:\.backup)?$"#
    )
    private let volumePathPattern = try! NSRegularExpression(pattern: #"^/Volumes/[^/]+$"#)

    func createAPFSVolume(containerReference: String, name: String, reply: @escaping (String?, String?, String?, NSError?) -> Void) {
        var createdDevice: String?
        do {
            try requireMatch(containerReference, pattern: containerPattern, description: "APFS container")
            try requireMatch(name, pattern: bundleIDPattern, description: "volume name")
            try requireExternalAPFS(identifier: containerReference)

            let devicesBefore = try volumeDevices(in: containerReference)
            _ = try run("/usr/sbin/diskutil", ["apfs", "addVolume", containerReference, "APFS", name])
            let newDevices = try volumeDevices(in: containerReference).subtracting(devicesBefore)
            guard newDevices.count == 1, let device = newDevices.first else {
                throw HelperFailure.error("The newly created APFS volume could not be identified safely.")
            }
            createdDevice = device
            let info = try plist("/usr/sbin/diskutil", ["info", "-plist", device])
            guard (info["VolumeName"] as? String) == name else {
                throw HelperFailure.error("The new APFS volume name could not be verified.")
            }
            let mountPath = try mountedPath(for: device)
            reply(device, mountPath, "Created APFS volume \(device).", nil)
        } catch let error as NSError {
            if let createdDevice {
                _ = try? run("/usr/sbin/diskutil", ["apfs", "deleteVolume", createdDevice])
            }
            reply(nil, nil, nil, error)
        }
    }

    func deleteAPFSVolume(device: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(reply) {
            try self.requireMatch(device, pattern: self.devicePattern, description: "APFS volume device")
            try self.requireExternalAPFS(identifier: device)
            _ = try self.run("/usr/sbin/diskutil", ["apfs", "deleteVolume", device])
            return "Deleted APFS volume \(device)."
        }
    }

    func mountAPFSVolume(device: String, atPath: String, options: [String], reply: @escaping (String?, NSError?) -> Void) {
        perform(reply) {
            try self.requireMatch(device, pattern: self.devicePattern, description: "APFS volume device")
            try self.requireContainerDataPath(atPath)
            try self.requireExternalAPFS(identifier: device)

            if !self.fileManager.fileExists(atPath: atPath) {
                try self.fileManager.createDirectory(atPath: atPath, withIntermediateDirectories: false)
                try self.copyParentOwnership(to: atPath)
            }
            _ = try self.run("/usr/sbin/diskutil", ["mount", "-mountPoint", atPath, device])
            if options.contains("noowners") {
                _ = try self.run("/usr/sbin/diskutil", ["disableOwnership", device])
            }
            return "Mounted \(device) at \(atPath)."
        }
    }

    func unmountVolume(atPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(reply) {
            try self.requireAllowedPath(atPath)
            _ = try self.run("/usr/sbin/diskutil", ["unmount", atPath])
            return "Unmounted \(atPath)."
        }
    }

    func renameItem(fromPath: String, toPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(reply) {
            try self.requireContainerDataPath(fromPath)
            try self.requireContainerDataPath(toPath)
            try self.requireSameContainer(fromPath, toPath)
            guard self.fileManager.fileExists(atPath: fromPath) else {
                throw HelperFailure.error("Source does not exist: \(fromPath)")
            }
            guard !self.fileManager.fileExists(atPath: toPath) else {
                throw HelperFailure.error("Destination already exists: \(toPath)")
            }
            try self.fileManager.moveItem(atPath: fromPath, toPath: toPath)
            return "Renamed \(fromPath) to \(toPath)."
        }
    }

    func copyItem(fromPath: String, toPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(reply) {
            try self.requireAllowedPath(fromPath)
            try self.requireAllowedPath(toPath)
            guard self.fileManager.fileExists(atPath: fromPath) else {
                throw HelperFailure.error("Source does not exist: \(fromPath)")
            }
            _ = try self.run("/usr/bin/ditto", ["--rsrc", "--extattr", fromPath, toPath], timeout: 24 * 60 * 60)
            return "Copied \(fromPath) to \(toPath)."
        }
    }

    func deleteItem(atPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(reply) {
            try self.requireContainerDataPath(atPath)
            guard self.fileManager.fileExists(atPath: atPath) else {
                throw HelperFailure.error("Item does not exist: \(atPath)")
            }
            try self.fileManager.removeItem(atPath: atPath)
            return "Deleted \(atPath)."
        }
    }

    func shutdown(reply: @escaping (String?, NSError?) -> Void) {
        reply("Privileged helper is shutting down.", nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(EXIT_SUCCESS) }
    }

    private func perform(_ reply: @escaping (String?, NSError?) -> Void, operation: () throws -> String) {
        do { reply(try operation(), nil) }
        catch let error as NSError { reply(nil, error) }
    }

    private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let readers = DispatchGroup()
        let stdoutCapture = PipeCapture()
        let stderrCapture = PipeCapture()
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

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            readers.wait()
            throw HelperFailure.error("Command timed out: \(executable)", code: 2)
        }
        readers.wait()
        let stdout = String(data: stdoutCapture.load(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrCapture.load(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw HelperFailure.error(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Command failed with status \(process.terminationStatus)."
                : stderr.trimmingCharacters(in: .whitespacesAndNewlines), code: Int(process.terminationStatus))
        }
        return CommandResult(output: stdout, errorOutput: stderr)
    }

    private func plist(_ executable: String, _ arguments: [String]) throws -> [String: Any] {
        let result = try run(executable, arguments)
        guard let data = result.output.data(using: .utf8),
              let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HelperFailure.error("Could not parse disk information.")
        }
        return value
    }

    private func requireExternalAPFS(identifier: String) throws {
        let info = try plist("/usr/sbin/diskutil", ["info", "-plist", identifier])
        guard (info["Internal"] as? Bool) == false else {
            throw HelperFailure.error("Refusing to modify a disk that is not external.")
        }
        let content = (info["Content"] as? String)?.lowercased() ?? ""
        let filesystem = (info["FilesystemType"] as? String)?.lowercased() ?? ""
        guard content.contains("apfs") || filesystem == "apfs" else {
            throw HelperFailure.error("The selected device is not APFS.")
        }
    }

    private func volumeDevices(in container: String) throws -> Set<String> {
        let root = try plist("/usr/sbin/diskutil", ["apfs", "list", "-plist", container])
        guard let containers = root["Containers"] as? [[String: Any]],
              let selected = containers.first(where: { ($0["ContainerReference"] as? String) == container }),
              let volumes = selected["Volumes"] as? [[String: Any]] else { return [] }
        return Set(volumes.compactMap { $0["DeviceIdentifier"] as? String })
    }

    private func mountedPath(for device: String) throws -> String {
        let info = try plist("/usr/sbin/diskutil", ["info", "-plist", device])
        guard let path = info["MountPoint"] as? String, !path.isEmpty else {
            throw HelperFailure.error("The new APFS volume was created but was not mounted.")
        }
        return path
    }

    private func requireAllowedPath(_ path: String) throws {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let range = NSRange(standardized.startIndex..., in: standardized)
        guard containerPathPattern.firstMatch(in: standardized, range: range) != nil
                || volumePathPattern.firstMatch(in: standardized, range: range) != nil else {
            throw HelperFailure.error("Refusing path outside the supported app-data locations: \(path)")
        }
    }

    private func requireContainerDataPath(_ path: String) throws {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let range = NSRange(standardized.startIndex..., in: standardized)
        guard containerPathPattern.firstMatch(in: standardized, range: range) != nil else {
            throw HelperFailure.error("Refusing path outside an app container Data directory: \(path)")
        }
    }

    private func requireSameContainer(_ first: String, _ second: String) throws {
        let firstParent = URL(fileURLWithPath: first).deletingLastPathComponent().standardizedFileURL.path
        let secondParent = URL(fileURLWithPath: second).deletingLastPathComponent().standardizedFileURL.path
        guard firstParent == secondParent else {
            throw HelperFailure.error("Source and destination must belong to the same app container.")
        }
    }

    private func requireMatch(_ value: String, pattern: NSRegularExpression, description: String) throws {
        let range = NSRange(value.startIndex..., in: value)
        guard pattern.firstMatch(in: value, range: range) != nil else {
            throw HelperFailure.error("Invalid \(description): \(value)")
        }
    }

    private func copyParentOwnership(to path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let attributes = try fileManager.attributesOfItem(atPath: parent)
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              let group = attributes[.groupOwnerAccountID] as? NSNumber else { return }
        guard chown(path, owner.uint32Value, group.uint32Value) == 0 else {
            throw HelperFailure.error("Could not set mount-point ownership: \(String(cString: strerror(errno)))")
        }
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PrivilegedHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = authorizedAppRequirement() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { DispatchQueue.main.async { exit(EXIT_SUCCESS) } }
        connection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
