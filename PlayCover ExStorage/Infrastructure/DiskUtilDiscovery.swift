import Foundation
import Darwin

nonisolated private final class DiskUtilPipeCapture: @unchecked Sendable {
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


nonisolated private struct VolumeScanJob: Sendable {
    let containerID: UUID
    let device: String
    let volumeUUID: String?
    let usedBytes: Int64?
}

nonisolated private struct ContainerScanSeed: Sendable {
    let id: UUID
    let reference: String
    let physicalStores: [String]
    let capacityTotalBytes: Int64?
    let capacityFreeBytes: Int64?
    let volumes: [VolumeScanJob]
}

nonisolated private struct ValidatedContainerScan: Sendable {
    let container: ExternalAPFSContainer
    let volumeJobs: [VolumeScanJob]
}

private actor VolumeRoundRobinScheduler {
    private struct Queue {
        let containerID: UUID
        var jobs: [VolumeScanJob]
    }

    private var queues: [Queue] = []
    private var nextQueueIndex = 0
    private var validationFinished = false
    private var waitingWorkers: [CheckedContinuation<VolumeScanJob?, Never>] = []

    func addContainer(id: UUID, jobs: [VolumeScanJob]) {
        guard !jobs.isEmpty else { return }
        queues.append(Queue(containerID: id, jobs: jobs))
        dispatchWaitingWorkers()
    }

    func finishValidation() {
        validationFinished = true
        dispatchWaitingWorkers()
    }

    func nextJob() async -> VolumeScanJob? {
        if let job = dequeue() { return job }
        if validationFinished { return nil }
        return await withCheckedContinuation { continuation in
            waitingWorkers.append(continuation)
        }
    }

    private func dispatchWaitingWorkers() {
        while !waitingWorkers.isEmpty, let job = dequeue() {
            waitingWorkers.removeFirst().resume(returning: job)
        }
        if validationFinished && queues.isEmpty {
            let waiters = waitingWorkers
            waitingWorkers.removeAll()
            waiters.forEach { $0.resume(returning: nil) }
        }
    }

    private func dequeue() -> VolumeScanJob? {
        while !queues.isEmpty {
            if nextQueueIndex >= queues.count { nextQueueIndex = 0 }
            if queues[nextQueueIndex].jobs.isEmpty {
                queues.remove(at: nextQueueIndex)
                continue
            }
            let job = queues[nextQueueIndex].jobs.removeFirst()
            if queues[nextQueueIndex].jobs.isEmpty {
                queues.remove(at: nextQueueIndex)
                if nextQueueIndex >= queues.count { nextQueueIndex = 0 }
            } else {
                nextQueueIndex = (nextQueueIndex + 1) % queues.count
            }
            return job
        }
        return nil
    }
}

// MARK: - Storage Discovery (read-only, using diskutil -plist)
nonisolated struct DiskUtilDiscovery {
    struct VolumeIdentity {
        let volumeUUID: String
        let containerReference: String?
        let mountPoint: String?
    }
    struct VolumeInfo {
        let name: String
        let mountPoint: String?
        let bsdDevice: String?
        let availableBytes: Int64?
    }

    private static func byteCount(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    static func containerFreeCapacitySnapshots() -> [UUID: Int64] {
        guard let plist = runDiskutil(args: ["apfs", "list", "-plist"]),
              let dictionary = try? PropertyListSerialization.propertyList(
                from: plist, options: [], format: nil
              ) as? [String: Any],
              let containers = dictionary["Containers"] as? [[String: Any]] else { return [:] }
        return Dictionary(uniqueKeysWithValues: containers.compactMap { container in
            guard let uuidString = container["APFSContainerUUID"] as? String,
                  let uuid = UUID(uuidString: uuidString),
                  let freeBytes = byteCount(container["CapacityFree"]) else { return nil }
            return (uuid, freeBytes)
        })
    }

    static func discoverExternalAPFSContainersProgressively(
        onContainer: @escaping @MainActor @Sendable (ExternalAPFSContainer) -> Void,
        onVolume: @escaping @MainActor @Sendable (UUID, ExternalVolume) -> Void
    ) async {
        guard let apfsPlist = runDiskutil(args: ["apfs", "list", "-plist"]),
              let apfsDict = try? PropertyListSerialization.propertyList(from: apfsPlist, options: [], format: nil) as? [String: Any],
              let rawContainers = apfsDict["Containers"] as? [[String: Any]] else { return }

        let seeds: [ContainerScanSeed] = rawContainers.compactMap { container in
            guard let reference = container["ContainerReference"] as? String,
                  let uuidString = container["APFSContainerUUID"] as? String,
                  let id = UUID(uuidString: uuidString),
                  let rawStores = container["PhysicalStores"] as? [[String: Any]] else { return nil }
            let stores = rawStores.compactMap { $0["DeviceIdentifier"] as? String }
            guard !stores.isEmpty, stores.count == rawStores.count else { return nil }
            let jobs = (container["Volumes"] as? [[String: Any]] ?? []).compactMap { volume -> VolumeScanJob? in
                guard let device = volume["DeviceIdentifier"] as? String else { return nil }
                return VolumeScanJob(
                    containerID: id,
                    device: device,
                    volumeUUID: volume["APFSVolumeUUID"] as? String,
                    usedBytes: byteCount(volume["CapacityInUse"])
                )
            }
            return ContainerScanSeed(
                id: id,
                reference: reference,
                physicalStores: stores,
                capacityTotalBytes: byteCount(container["CapacityCeiling"]),
                capacityFreeBytes: byteCount(container["CapacityFree"]),
                volumes: jobs
            )
        }

        let scheduler = VolumeRoundRobinScheduler()
        async let volumeWorkers: Void = runVolumeWorkers(
            scheduler: scheduler,
            workerCount: 6,
            onVolume: onVolume
        )

        await withTaskGroup(of: ValidatedContainerScan?.self) { group in
            var iterator = seeds.makeIterator()
            let validatorCount = min(3, seeds.count)
            for _ in 0..<validatorCount {
                if let seed = iterator.next() {
                    group.addTask { validateContainer(seed) }
                }
            }
            while let validated = await group.next() {
                if let validated {
                    await onContainer(validated.container)
                    await scheduler.addContainer(id: validated.container.id, jobs: validated.volumeJobs)
                }
                if let seed = iterator.next() {
                    group.addTask { validateContainer(seed) }
                }
            }
        }
        await scheduler.finishValidation()
        await volumeWorkers
    }

    private static func validateContainer(_ seed: ContainerScanSeed) -> ValidatedContainerScan? {
        let storeInfo = seed.physicalStores.compactMap { device -> [String: Any]? in
            guard let data = runDiskutil(args: ["info", "-plist", "/dev/\(device)"]) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        }
        guard storeInfo.count == seed.physicalStores.count,
              storeInfo.allSatisfy({ ($0["Internal"] as? Bool) == false && !isDiskImage($0) }),
              let infoData = runDiskutil(args: ["info", "-plist", "/dev/\(seed.reference)"]),
              let info = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              (info["Internal"] as? Bool) == false else { return nil }
        let connectionType = storeInfo.lazy.compactMap {
            $0["BusProtocol"] as? String ?? $0["DeviceProtocol"] as? String
        }.first
        let container = ExternalAPFSContainer(
            containerUUID: seed.id,
            containerReference: seed.reference,
            displayName: info["MediaName"] as? String,
            connectionType: connectionType,
            capacityTotalBytes: seed.capacityTotalBytes,
            capacityFreeBytes: seed.capacityFreeBytes,
            volumes: []
        )
        return ValidatedContainerScan(container: container, volumeJobs: seed.volumes)
    }

    private static func runVolumeWorkers(
        scheduler: VolumeRoundRobinScheduler,
        workerCount: Int,
        onVolume: @escaping @MainActor @Sendable (UUID, ExternalVolume) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while let job = await scheduler.nextJob() {
                        guard let info = infoForDevice(job.device) else { continue }
                        let volume = ExternalVolume(
                            name: info.name,
                            mountPoint: info.mountPoint,
                            bsdDevice: info.bsdDevice,
                            volumeUUID: job.volumeUUID,
                            availableBytes: info.availableBytes,
                            usedBytes: job.usedBytes
                        )
                        await onVolume(job.containerID, volume)
                    }
                }
            }
        }
    }

    private static func infoForDevice(_ device: String) -> VolumeInfo? {
        guard let data = runDiskutil(args: ["info", "-plist", "/dev/\(device)"]),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        let content = dict["Content"] as? String
        let isAPFS = (content == "apfs" || content == "AppleAPFS") || (dict["FilesystemType"] as? String == "apfs")
        let name = (dict["VolumeName"] as? String) ?? (dict["MediaName"] as? String) ?? device
        let mountPoint = dict["MountPoint"] as? String
        let bsd = dict["DeviceIdentifier"] as? String ?? device
        var free: Int64? = nil
        if let freeDict = dict["FreeSpace"] as? [String: Any], let size = freeDict["Size"] as? Int64 { free = size }
        guard isAPFS else { return nil }
        return VolumeInfo(name: name, mountPoint: mountPoint, bsdDevice: bsd, availableBytes: free)
    }

    private static func runDiskutil(args: [String], timeout: TimeInterval = 15) -> Data? {
        MigrationTrace.event("diskutil.begin", details: "args=\(args.joined(separator: " ")) timeout=\(timeout)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        // No caller consumes stderr. Sending it to another unread Pipe can
        // deadlock for the same reason as stdout when diskutil is verbose.
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch {
            MigrationTrace.event("diskutil.launch-failed", details: "args=\(args.joined(separator: " ")) error=\(error.localizedDescription)")
            return nil
        }

        let capture = DiskUtilPipeCapture()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            capture.store(out.fileHandleForReading.readDataToEndOfFile())
            reader.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while task.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
            // A child process or system service can keep the pipe open even
            // after diskutil exits. Never let diagnostic pipe cleanup turn a
            // bounded disk query back into an unbounded wait.
            _ = reader.wait(timeout: .now() + 1)
            MigrationTrace.event("diskutil.timeout", details: "pid=\(task.processIdentifier) args=\(args.joined(separator: " "))")
            return nil
        }

        reader.wait()
        guard task.terminationStatus == 0 else {
            MigrationTrace.event("diskutil.failed", details: "status=\(task.terminationStatus) args=\(args.joined(separator: " "))")
            return nil
        }
        MigrationTrace.event("diskutil.completed", details: "args=\(args.joined(separator: " ")) bytes=\(capture.load().count)")
        return capture.load()
    }

    static func volumeIdentity(for identifierOrPath: String) -> VolumeIdentity? {
        guard let data = runDiskutil(args: ["info", "-plist", identifierOrPath]),
              let info = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let uuid = info["VolumeUUID"] as? String else { return nil }
        return VolumeIdentity(
            volumeUUID: uuid,
            containerReference: info["APFSContainerReference"] as? String,
            mountPoint: info["MountPoint"] as? String
        )
    }

    private static func isDiskImage(_ info: [String: Any]) -> Bool {
        let protocolName = (info["BusProtocol"] as? String)
            ?? (info["DeviceProtocol"] as? String)
            ?? ""
        if protocolName.localizedCaseInsensitiveContains("disk image") { return true }
        if (info["DiskImage"] as? Bool) == true { return true }
        return false
    }
}
