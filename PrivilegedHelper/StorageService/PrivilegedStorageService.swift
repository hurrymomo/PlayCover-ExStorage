import Foundation

// MARK: - Privileged StorageService implementation
// This target is the root execution boundary. It validates every request again
// before performing filesystem or APFS changes.
import Darwin

private struct CommandResult {
    let output: String
}

private struct HelperOperationContext {
    let operationID: String
    let logPath: String
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
    private let logLock = NSLock()
    private let maximumLogSize: Int64 = 8_000_000
    private let retainedLogHistoryCount = 1
    private let devicePattern = try! NSRegularExpression(pattern: #"^disk[0-9]+s[0-9]+$"#)
    private let containerPattern = try! NSRegularExpression(pattern: #"^disk[0-9]+$"#)
    private let bundleIDPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#)
    private let containerPathPattern = try! NSRegularExpression(
        pattern: #"^/Users/[^/]+/Library/Containers/[A-Za-z0-9][A-Za-z0-9.-]{0,254}/Data(?:\.backup|\.restore-in-progress|\.overwrite-backup)?$"#
    )
    private let volumePathPattern = try! NSRegularExpression(pattern: #"^/Volumes/[^/]+$"#)
    private let logPathPattern = try! NSRegularExpression(
        pattern: #"^/Users/[^/]+/Library/Logs/PlayCover ExStorage/helper\.log$"#
    )

    func createAPFSVolume(containerReference: String, name: String, operationID: String, logPath: String, reply: @escaping (String?, String?, String?, NSError?) -> Void) {
        var createdDevice: String?
        do {
            let context = try operationContext(operationID: operationID, logPath: logPath)
            appendLog("CALL createAPFSVolume(containerReference: \(containerReference), name: \(name))", context: context)
            try requireMatch(containerReference, pattern: containerPattern, description: "APFS container")
            try requireMatch(name, pattern: bundleIDPattern, description: "volume name")
            try requireExternalAPFSContainer(identifier: containerReference, context: context)

            let devicesBefore = try volumeDevices(in: containerReference, context: context)
            _ = try run("/usr/sbin/diskutil", ["apfs", "addVolume", containerReference, "APFS", name, "-nomount"], context: context)
            let newDevices = try volumeDevices(in: containerReference, context: context).subtracting(devicesBefore)
            guard newDevices.count == 1, let device = newDevices.first else {
                throw HelperFailure.error("The newly created APFS volume could not be identified safely.")
            }
            createdDevice = device
            let info = try plist("/usr/sbin/diskutil", ["info", "-plist", device], context: context)
            guard (info["VolumeName"] as? String) == name else {
                throw HelperFailure.error("The new APFS volume name could not be verified.")
            }
            appendLog("SUCCESS Created unmounted APFS volume \(device).", context: context)
            reply(device, nil, "Created unmounted APFS volume \(device).", nil)
        } catch let error as NSError {
            let context = try? operationContext(operationID: operationID, logPath: logPath)
            if let context { appendLog("ERROR \(error.localizedDescription)", context: context) }
            if let createdDevice {
                if let context {
                    appendLog("ROLLBACK deleting newly created volume \(createdDevice)", context: context)
                    _ = try? run("/usr/sbin/diskutil", ["apfs", "deleteVolume", createdDevice], context: context)
                }
            }
            reply(nil, nil, nil, error)
        }
    }

    func deleteAPFSVolume(device: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(operationID: operationID, logPath: logPath, reply: reply) { context in
            self.appendLog("CALL deleteAPFSVolume(device: \(device))", context: context)
            try self.requireMatch(device, pattern: self.devicePattern, description: "APFS volume device")
            try self.requireExternalAPFSVolume(identifier: device, context: context)
            _ = try self.run("/usr/sbin/diskutil", ["apfs", "deleteVolume", device], context: context)
            return "Deleted APFS volume \(device)."
        }
    }

    func mountAPFSVolume(device: String, atPath: String, options: [String], operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(operationID: operationID, logPath: logPath, reply: reply) { context in
            self.appendLog("CALL mountAPFSVolume(device: \(device), atPath: \(atPath), options: \(options))", context: context)
            try self.requireMatch(device, pattern: self.devicePattern, description: "APFS volume device")
            try self.requireAllowedPath(atPath)
            try self.requireExternalAPFSVolume(identifier: device, context: context)

            if !self.fileManager.fileExists(atPath: atPath) {
                try self.fileManager.createDirectory(atPath: atPath, withIntermediateDirectories: false)
                try self.copyParentOwnership(to: atPath)
            }
            var mountArguments = ["mount"]
            if options.contains("nobrowse") {
                mountArguments.append("nobrowse")
            }
            mountArguments.append(contentsOf: ["-mountPoint", atPath, device])
            _ = try self.run("/usr/sbin/diskutil", mountArguments, context: context)
            if options.contains("noowners") {
                _ = try self.run("/usr/sbin/diskutil", ["disableOwnership", device], context: context)
            }
            return "Mounted \(device) at \(atPath)."
        }
    }

    func unmountVolume(atPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(operationID: operationID, logPath: logPath, reply: reply) { context in
            self.appendLog("CALL unmountVolume(atPath: \(atPath))", context: context)
            try self.requireAllowedPath(atPath)
            _ = try self.run("/usr/sbin/diskutil", ["unmount", atPath], context: context)
            return "Unmounted \(atPath)."
        }
    }

    func renameItem(fromPath: String, toPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(operationID: operationID, logPath: logPath, reply: reply) { context in
            self.appendLog("CALL renameItem(fromPath: \(fromPath), toPath: \(toPath))", context: context)
            if self.isRecoveryPath(fromPath) {
                try self.requireRecoveryDestination(fromPath: fromPath, toPath: toPath)
            } else {
                try self.requireContainerDataPath(fromPath)
                try self.requireContainerDataPath(toPath)
                try self.requireSameContainer(fromPath, toPath)
            }
            guard self.fileManager.fileExists(atPath: fromPath) else {
                throw HelperFailure.error("Source does not exist: \(fromPath)")
            }
            guard !self.fileManager.fileExists(atPath: toPath) else {
                throw HelperFailure.error("Destination already exists: \(toPath)")
            }
            self.appendLog("FILE MOVE \(fromPath) -> \(toPath)", context: context)
            try self.fileManager.moveItem(atPath: fromPath, toPath: toPath)
            return "Renamed \(fromPath) to \(toPath)."
        }
    }

    func deleteItem(atPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void) {
        perform(operationID: operationID, logPath: logPath, reply: reply) { context in
            self.appendLog("CALL deleteItem(atPath: \(atPath))", context: context)
            if self.isTemporaryMountPath(atPath) {
                try self.requireSafeUnmountedTemporaryDirectory(atPath)
            } else if self.isRecoveryPath(atPath) {
                try self.requireRecoveryPath(atPath)
            } else {
                try self.requireContainerDataPath(atPath)
            }
            guard self.fileManager.fileExists(atPath: atPath) else {
                throw HelperFailure.error("Item does not exist: \(atPath)")
            }
            self.appendLog("FILE DELETE \(atPath)", context: context)
            try self.fileManager.removeItem(atPath: atPath)
            return "Deleted \(atPath)."
        }
    }

    func shutdown(operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void) {
        do {
            let context = try operationContext(operationID: operationID, logPath: logPath)
            appendLog("CALL shutdown()", context: context)
            reply("Privileged helper is shutting down.", nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(EXIT_SUCCESS) }
        } catch let error as NSError {
            reply(nil, error)
        }
    }

    private func perform(
        operationID: String,
        logPath: String,
        reply: @escaping (String?, NSError?) -> Void,
        operation: (HelperOperationContext) throws -> String
    ) {
        do {
            let context = try operationContext(operationID: operationID, logPath: logPath)
            let message = try operation(context)
            appendLog("SUCCESS \(message)", context: context)
            reply(message, nil)
        } catch let error as NSError {
            if let context = try? operationContext(operationID: operationID, logPath: logPath) {
                appendLog("ERROR \(error.localizedDescription)", context: context)
            }
            reply(nil, error)
        }
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 120,
        context: HelperOperationContext
    ) throws -> CommandResult {
        appendLog("EXEC \(([executable] + arguments).map(shellQuoted).joined(separator: " "))", context: context)
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
            appendLog("LAUNCH ERROR \(error.localizedDescription)", context: context)
            throw error
        }

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
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = readers.wait(timeout: .now() + 1)
            appendLog("TIMEOUT after \(timeout) seconds", context: context)
            throw HelperFailure.error("Command timed out: \(executable)", code: 2)
        }
        readers.wait()
        let stdout = String(data: stdoutCapture.load(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrCapture.load(), encoding: .utf8) ?? ""
        appendLog("EXIT \(process.terminationStatus)", context: context)
        appendCommandOutput(label: "STDOUT", value: stdout, context: context)
        appendCommandOutput(label: "STDERR", value: stderr, context: context)
        guard process.terminationStatus == 0 else {
            throw HelperFailure.error(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Command failed with status \(process.terminationStatus)."
                : stderr.trimmingCharacters(in: .whitespacesAndNewlines), code: Int(process.terminationStatus))
        }
        return CommandResult(output: stdout)
    }

    private func appendCommandOutput(label: String, value: String, context: HelperOperationContext) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let limit = 32_000
        let content = trimmed.count > limit
            ? String(trimmed.prefix(limit)) + "\n… output truncated in log …"
            : trimmed
        appendLog("\(label):\n\(content)", context: context)
    }

    private func operationContext(operationID: String, logPath: String) throws -> HelperOperationContext {
        guard let id = UUID(uuidString: operationID) else {
            throw HelperFailure.error("Invalid operation identifier.")
        }
        let standardized = URL(fileURLWithPath: logPath).standardizedFileURL.path
        let range = NSRange(standardized.startIndex..., in: standardized)
        guard logPathPattern.firstMatch(in: standardized, range: range) != nil else {
            throw HelperFailure.error("Invalid helper log path.")
        }
        let descriptor = open(
            standardized,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW,
            mode_t(0o644)
        )
        guard descriptor >= 0 else {
            throw HelperFailure.error(
                "The helper log could not be opened safely: \(String(cString: strerror(errno)))"
            )
        }
        close(descriptor)
        return HelperOperationContext(operationID: id.uuidString, logPath: standardized)
    }

    private func appendLog(_ message: String, context: HelperOperationContext) {
        let entry = "operation=\(context.operationID) \(message)"
        print("[PrivilegedHelper] \(entry)")
        logLock.lock()
        defer { logLock.unlock() }
        rotateLogIfNeeded(atPath: context.logPath)
        let descriptor = open(
            context.logPath,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW,
            mode_t(0o644)
        )
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("[\(timestamp)] \(entry)\n".utf8)
        do {
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    private func rotateLogIfNeeded(atPath path: String) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > maximumLogSize else { return }
        let url = URL(fileURLWithPath: path)
        for index in stride(from: retainedLogHistoryCount, through: 1, by: -1) {
            let destination = url.appendingPathExtension(String(index))
            let source = index == 1 ? url : url.appendingPathExtension(String(index - 1))
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    private func shellQuoted(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func plist(
        _ executable: String,
        _ arguments: [String],
        context: HelperOperationContext
    ) throws -> [String: Any] {
        let result = try run(executable, arguments, context: context)
        guard let data = result.output.data(using: .utf8),
              let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HelperFailure.error("Could not parse disk information.")
        }
        return value
    }

    private func requireExternalAPFSContainer(identifier: String, context: HelperOperationContext) throws {
        let info = try plist("/usr/sbin/diskutil", ["info", "-plist", identifier], context: context)
        guard (info["Internal"] as? Bool) == false else {
            throw HelperFailure.error("Refusing to modify a disk that is not external.")
        }
        guard (info["Writable"] as? Bool) == true else {
            throw HelperFailure.error("The selected APFS container is not writable.")
        }
        guard (info["APFSContainerReference"] as? String) == identifier,
              let stores = info["APFSPhysicalStores"] as? [[String: Any]],
              !stores.isEmpty else {
            throw HelperFailure.error("The selected device is not an APFS container.")
        }
        let root = try plist("/usr/sbin/diskutil", ["apfs", "list", "-plist", identifier], context: context)
        guard let containers = root["Containers"] as? [[String: Any]],
              containers.contains(where: { ($0["ContainerReference"] as? String) == identifier }) else {
            throw HelperFailure.error("The selected APFS container could not be verified.")
        }
        for store in stores {
            guard let physicalStore = store["APFSPhysicalStore"] as? String else {
                throw HelperFailure.error("The APFS physical store could not be verified.")
            }
            let storeInfo = try plist("/usr/sbin/diskutil", ["info", "-plist", physicalStore], context: context)
            guard (storeInfo["Internal"] as? Bool) == false,
                  !isDiskImage(storeInfo),
                  ((storeInfo["Content"] as? String)?.lowercased().contains("apfs") == true) else {
                throw HelperFailure.error("The APFS container is not backed by an external APFS store.")
            }
        }
    }

    private func isDiskImage(_ info: [String: Any]) -> Bool {
        let protocolName = (info["BusProtocol"] as? String)
            ?? (info["DeviceProtocol"] as? String)
            ?? ""
        return protocolName.localizedCaseInsensitiveContains("disk image")
            || (info["DiskImage"] as? Bool) == true
    }

    private func requireExternalAPFSVolume(identifier: String, context: HelperOperationContext) throws {
        let info = try plist("/usr/sbin/diskutil", ["info", "-plist", identifier], context: context)
        guard (info["Internal"] as? Bool) == false else {
            throw HelperFailure.error("Refusing to modify a volume that is not external.")
        }
        guard (info["FilesystemType"] as? String)?.lowercased() == "apfs" else {
            throw HelperFailure.error("The selected device is not an APFS volume.")
        }
        guard (info["Writable"] as? Bool) == true else {
            throw HelperFailure.error("The selected APFS volume is not writable.")
        }
        guard let container = info["APFSContainerReference"] as? String else {
            throw HelperFailure.error("The APFS volume container could not be verified.")
        }
        try requireExternalAPFSContainer(identifier: container, context: context)
    }

    private func volumeDevices(in container: String, context: HelperOperationContext) throws -> Set<String> {
        let root = try plist("/usr/sbin/diskutil", ["apfs", "list", "-plist", container], context: context)
        guard let containers = root["Containers"] as? [[String: Any]],
              let selected = containers.first(where: { ($0["ContainerReference"] as? String) == container }),
              let volumes = selected["Volumes"] as? [[String: Any]] else { return [] }
        return Set(volumes.compactMap { $0["DeviceIdentifier"] as? String })
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

    private func isRecoveryPath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count == 9,
              components[0] == "/",
              components[1] == "Users",
              !components[2].isEmpty,
              components[3] == "Library",
              components[4] == "Application Support",
              components[5] == "PlayCover ExStorage",
              components[6] == "Recovery",
              components[8] == "Data.restore-in-progress" else { return false }
        let range = NSRange(components[7].startIndex..., in: components[7])
        return bundleIDPattern.firstMatch(in: components[7], range: range) != nil
    }

    private func requireRecoveryPath(_ path: String) throws {
        guard isRecoveryPath(path) else {
            throw HelperFailure.error("Refusing path outside the ExStorage recovery directory: \(path)")
        }
    }

    private func requireRecoveryDestination(fromPath: String, toPath: String) throws {
        try requireRecoveryPath(fromPath)
        try requireContainerDataPath(toPath)
        let source = URL(fileURLWithPath: fromPath).standardizedFileURL.pathComponents
        let destination = URL(fileURLWithPath: toPath).standardizedFileURL.pathComponents
        guard source.count == 9, destination.count >= 4,
              source[7] == destination[destination.count - 2],
              source[2] == destination[2],
              destination.last == "Data" else {
            throw HelperFailure.error("Recovery source and destination do not belong to the same user and App container.")
        }
    }

    private func isTemporaryMountPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent().path == "/Volumes"
            && url.lastPathComponent.hasPrefix(".PlayCover-ExStorage-")
    }

    private func requireSafeUnmountedTemporaryDirectory(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw HelperFailure.error("Refusing to delete a temporary mount path that is not a directory: \(path)")
        }

        var directoryStat = stat()
        var parentStat = stat()
        guard lstat(url.path, &directoryStat) == 0,
              lstat(url.deletingLastPathComponent().path, &parentStat) == 0,
              directoryStat.st_dev == parentStat.st_dev else {
            throw HelperFailure.error("Refusing to delete a temporary mount path that may still be mounted: \(path)")
        }

        guard try fileManager.contentsOfDirectory(atPath: url.path).isEmpty else {
            throw HelperFailure.error("Refusing to delete a non-empty temporary mount directory: \(path)")
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
