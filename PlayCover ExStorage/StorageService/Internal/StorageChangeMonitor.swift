import DiskArbitration
import Foundation

nonisolated enum StorageDeviceChange: Sendable {
    case inserted(device: String)
    case removed(device: String)
}

/// Watches physical external disks rather than volume mount state. Existing
/// devices establish a baseline after the startup scan; only later arrivals
/// and removals are delivered to the application.
nonisolated final class StorageChangeMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var session: DASession?
    private var handler: (@MainActor @Sendable (StorageDeviceChange) -> Void)?
    private var baselineEstablished = false
    private var connectedDevices: Set<String> = []
    private var pendingInsertions: [String: DispatchWorkItem] = [:]

    func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, storageDiskAppeared, context)
        DARegisterDiskDisappearedCallback(session, nil, storageDiskDisappeared, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func setChangeHandler(
        _ handler: @escaping @MainActor @Sendable (StorageDeviceChange) -> Void
    ) {
        lock.withLock { self.handler = handler }
    }

    func establishBaseline(devices: Set<String>) {
        lock.withLock {
            connectedDevices = devices
            baselineEstablished = true
        }
    }

    fileprivate func appeared(_ disk: DADisk) {
        guard let device = externalWholeDiskIdentifier(disk) else { return }
        let shouldDeliver = lock.withLock { () -> Bool in
            guard baselineEstablished else {
                connectedDevices.insert(device)
                return false
            }
            return connectedDevices.insert(device).inserted
        }
        guard shouldDeliver else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.deliver(.inserted(device: device))
        }
        lock.withLock {
            pendingInsertions[device]?.cancel()
            pendingInsertions[device] = work
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    fileprivate func disappeared(_ disk: DADisk) {
        guard let device = wholeDiskIdentifier(disk) else { return }
        let shouldDeliver = lock.withLock { () -> Bool in
            pendingInsertions.removeValue(forKey: device)?.cancel()
            guard baselineEstablished else {
                connectedDevices.remove(device)
                return false
            }
            return connectedDevices.remove(device) != nil
        }
        if shouldDeliver { deliver(.removed(device: device)) }
    }

    private func deliver(_ change: StorageDeviceChange) {
        let handler = lock.withLock { self.handler }
        guard let handler else { return }
        Task { @MainActor in handler(change) }
    }

    private func externalWholeDiskIdentifier(_ disk: DADisk) -> String? {
        guard let description = DADiskCopyDescription(disk) as? [CFString: Any],
              description[kDADiskDescriptionMediaWholeKey] as? Bool == true,
              description[kDADiskDescriptionDeviceInternalKey] as? Bool == false else {
            return nil
        }
        return wholeDiskIdentifier(disk)
    }

    private func wholeDiskIdentifier(_ disk: DADisk) -> String? {
        guard let name = DADiskGetBSDName(disk) else { return nil }
        return String(cString: name)
    }
}

nonisolated(unsafe) private let storageDiskAppeared: DADiskAppearedCallback = { disk, context in
    guard let context else { return }
    Unmanaged<StorageChangeMonitor>.fromOpaque(context).takeUnretainedValue().appeared(disk)
}

nonisolated(unsafe) private let storageDiskDisappeared: DADiskDisappearedCallback = { disk, context in
    guard let context else { return }
    Unmanaged<StorageChangeMonitor>.fromOpaque(context).takeUnretainedValue().disappeared(disk)
}
