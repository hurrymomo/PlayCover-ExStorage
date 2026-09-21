import Combine
import Foundation

private struct ManagedAppRecord {
    let bundleIdentifier: String
    var name: String
    var applicationPath: String
    var persistence: ManagedAppPersistence
    var appSize: ManagedAppSizeState = .unknown
    var dataSize: ManagedAppSizeState = .unknown
    var appInfo: ExStorageAppInfo?
    var appInfoContainerID: UUID?

    var snapshot: AppSnapshot {
        AppSnapshot(
            bundleIdentifier: bundleIdentifier,
            name: name,
            applicationPath: applicationPath,
            persistence: persistence,
            appSize: appSize,
            dataSize: dataSize,
            appInfo: appInfo,
            appInfoContainerID: appInfoContainerID
        )
    }
}

/// The single in-process source of truth for business state.
///
/// Views and ViewModels may observe or derive presentation from this model, but
/// StorageService, persistence adapters, and the privileged helper do not keep
/// competing authoritative copies.
@MainActor
final class AppModel: ObservableObject {
    @Published private var containersByID: [UUID: ExternalAPFSContainer] = [:]
    @Published private(set) var storageRevision = 0
    @Published private var managedAppRecords: [ManagedAppRecord] = []
    private var managedAppIndexByBundleID: [String: Int] = [:]

    private var storedOperation: AppOperation = .idle
    private var storedOperationMessage = "Drop an app and select an external APFS SSD to begin."
    private var storedOperationProgress: Double?
    @Published private var storedAppOperationStates: [String: AppOperationState] = [:]
    @Published private var storedAppFailureMessages: [String: String] = [:]

    var operation: AppOperation { storedOperation }
    var operationMessage: String { storedOperationMessage }
    var operationProgress: Double? { storedOperationProgress }

    func allContainers() -> [ExternalAPFSContainer] {
        Array(containersByID.values)
    }

    func container(identifiedBy id: UUID) -> ExternalAPFSContainer? {
        containersByID[id]
    }

    func replaceContainers(_ containers: [ExternalAPFSContainer]) {
        containersByID = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
    }

    func replaceStorage(with snapshot: StorageSnapshot) {
        containersByID = snapshot.containersByID
        storageRevision += 1
    }

    func insertOrUpdateContainers(_ containers: [ExternalAPFSContainer]) {
        for container in containers {
            containersByID[container.id] = container
        }
    }

    /// Applies a capacity query without replacing newer volume information or
    /// recreating a container removed while the query was in flight.
    func updateContainerFreeCapacity(
        _ bytes: Int64,
        for id: UUID,
        expectedContainerReference: String
    ) {
        guard bytes >= 0,
              let container = containersByID[id],
              container.containerReference == expectedContainerReference else { return }
        containersByID[id] = ExternalAPFSContainer(
            containerUUID: container.containerUUID,
            containerReference: container.containerReference,
            physicalStoreDeviceIdentifiers: container.physicalStoreDeviceIdentifiers,
            displayName: container.displayName,
            connectionType: container.connectionType,
            capacityTotalBytes: container.capacityTotalBytes,
            capacityFreeBytes: bytes,
            volumes: container.volumes
        )
    }

    /// Invalidates only in-memory state for a detached physical device.
    /// Persistent app registry and on-disk AppInfo are intentionally untouched.
    @discardableResult
    func invalidateContainers(onPhysicalDevice device: String) -> Set<UUID> {
        let removedIDs = Set(containersByID.values.compactMap { container in
            container.physicalStoreDeviceIdentifiers.contains(where: {
                $0 == device || $0.hasPrefix("\(device)s")
            }) ? container.id : nil
        })
        guard !removedIDs.isEmpty else { return [] }
        for id in removedIDs { containersByID.removeValue(forKey: id) }
        for index in managedAppRecords.indices
            where managedAppRecords[index].appInfoContainerID.map(removedIDs.contains) == true {
            managedAppRecords[index].appInfo = nil
            managedAppRecords[index].appInfoContainerID = nil
        }
        return removedIDs
    }

    // MARK: - App Operation Presentation

    func setOperation(_ operation: AppOperation, message: String, progress: Double?) {
        storedOperation = operation
        storedOperationMessage = message
        storedOperationProgress = progress
    }

    func updateOperationProgress(_ progress: Double?) {
        storedOperationProgress = progress
    }

    func updateOperation(_ operation: AppOperation) {
        storedOperation = operation
    }

    func updateOperationMessage(_ message: String) {
        storedOperationMessage = message
    }

    func setAppFailureMessage(_ message: String, for bundleID: String) {
        storedAppFailureMessages[bundleID] = message
    }

    @discardableResult
    func clearAppFailureMessage(for bundleID: String) -> Bool {
        storedAppFailureMessages.removeValue(forKey: bundleID) != nil
    }

    func setAppOperationState(_ state: AppOperationState, for bundleID: String) {
        storedAppOperationStates[bundleID] = state
    }

    func clearAppOperationState(for bundleID: String) {
        storedAppOperationStates.removeValue(forKey: bundleID)
    }

    // MARK: - Managed App Queries

    var apps: [AppSnapshot] {
        managedAppRecords.map(\.snapshot)
    }

    func app(identifiedBy bundleID: String) -> AppSnapshot? {
        guard let index = managedAppIndexByBundleID[bundleID],
              managedAppRecords.indices.contains(index),
              managedAppRecords[index].bundleIdentifier == bundleID else { return nil }
        return managedAppRecords[index].snapshot
    }

    func appInfo(for bundleID: String) -> ExStorageAppInfo? {
        app(identifiedBy: bundleID)?.appInfo
    }

    func appInfoContainerID(for bundleID: String) -> UUID? {
        app(identifiedBy: bundleID)?.appInfoContainerID
    }

    // MARK: - Managed App Mutations

    /// The single raw-data insert/update boundary. Callers do not construct or
    /// mutate the Model's internal record type.
    @discardableResult
    func insertOrUpdateApp(
        bundleIdentifier: String,
        name: String,
        applicationPath: String,
        persistence: ManagedAppPersistence
    ) -> Bool {
        if let index = managedAppIndexByBundleID[bundleIdentifier],
           managedAppRecords.indices.contains(index) {
            let existing = managedAppRecords[index]
            guard existing.name != name
                    || existing.applicationPath != applicationPath
                    || existing.persistence != persistence else { return false }
            managedAppRecords[index].name = name
            managedAppRecords[index].applicationPath = applicationPath
            managedAppRecords[index].persistence = persistence
            return true
        }
        let index = managedAppRecords.endIndex
        managedAppRecords.append(
            ManagedAppRecord(
                bundleIdentifier: bundleIdentifier,
                name: name,
                applicationPath: applicationPath,
                persistence: persistence
            )
        )
        managedAppIndexByBundleID[bundleIdentifier] = index
        return true
    }

    /// The single removal boundary for AppSnapshot records. Removing an array
    /// element shifts every following index, so only that suffix is repaired.
    @discardableResult
    func removeApp(bundleIdentifier: String) -> Bool {
        guard let index = managedAppIndexByBundleID.removeValue(forKey: bundleIdentifier),
              managedAppRecords.indices.contains(index) else { return false }
        managedAppRecords.remove(at: index)
        for shiftedIndex in index..<managedAppRecords.endIndex {
            managedAppIndexByBundleID[managedAppRecords[shiftedIndex].bundleIdentifier] = shiftedIndex
        }
        return true
    }

    func restoreApps(_ apps: [AppSnapshot]) {
        managedAppRecords.removeAll(keepingCapacity: true)
        managedAppIndexByBundleID.removeAll(keepingCapacity: true)
        for app in apps {
            insertOrUpdateApp(
                bundleIdentifier: app.bundleIdentifier,
                name: app.name,
                applicationPath: app.applicationPath,
                persistence: app.persistence
            )
        }
    }

    func setAppInfo(
        _ info: ExStorageAppInfo,
        containerID: UUID
    ) {
        guard let index = managedAppIndexByBundleID[info.bundleID],
              managedAppRecords.indices.contains(index) else { return }
        managedAppRecords[index].appInfo = info
        managedAppRecords[index].appInfoContainerID = containerID
    }

    func clearAppInfo(for bundleID: String) {
        guard let index = managedAppIndexByBundleID[bundleID],
              managedAppRecords.indices.contains(index) else { return }
        managedAppRecords[index].appInfo = nil
        managedAppRecords[index].appInfoContainerID = nil
    }

    func updateAppSize(_ size: ManagedAppSizeState, for bundleID: String) {
        guard let index = managedAppIndexByBundleID[bundleID],
              managedAppRecords.indices.contains(index) else { return }
        managedAppRecords[index].appSize = size
    }

    func updateDataSize(_ size: ManagedAppSizeState, for bundleID: String) {
        guard let index = managedAppIndexByBundleID[bundleID],
              managedAppRecords.indices.contains(index) else { return }
        managedAppRecords[index].dataSize = size
    }

    func updateAppPersistence(_ persistence: ManagedAppPersistence, for bundleID: String) {
        guard let index = managedAppIndexByBundleID[bundleID],
              managedAppRecords.indices.contains(index) else { return }
        managedAppRecords[index].persistence = persistence
    }

    func updateAppLocation(
        path: String,
        persistence: ManagedAppPersistence,
        for bundleID: String
    ) {
        guard let index = managedAppIndexByBundleID[bundleID],
              managedAppRecords.indices.contains(index) else { return }
        managedAppRecords[index].applicationPath = path
        managedAppRecords[index].persistence = persistence
    }

    func appOperationState(for bundleID: String) -> AppOperationState {
        storedAppOperationStates[bundleID] ?? AppOperationState()
    }

    func appFailureMessage(for bundleID: String) -> String? {
        storedAppFailureMessages[bundleID]
    }

    func managedDataVolume(for bundleID: String) -> ExternalVolume? {
        guard let info = appInfo(for: bundleID) else { return nil }
        return allContainers().flatMap(\.volumes).first {
            $0.volumeUUID?.caseInsensitiveCompare(info.dataVolumeUUID) == .orderedSame
        }
    }

    func managedDataContainer(for bundleID: String) -> ExternalAPFSContainer? {
        guard let info = appInfo(for: bundleID) else { return nil }
        return allContainers().first { container in
            container.volumes.contains {
                $0.volumeUUID?.caseInsensitiveCompare(info.dataVolumeUUID) == .orderedSame
            }
        }
    }

    func managedAppContainer(for bundleID: String) -> ExternalAPFSContainer? {
        guard let app = app(identifiedBy: bundleID), !app.applicationPath.isEmpty else { return nil }
        let appPath = app.applicationURL.standardizedFileURL.path
        return allContainers().first { container in
            container.volumes.contains { volume in
                guard volume.name == ExStorageLayout.managementVolumeName,
                      let mountPoint = volume.mountPoint else { return false }
                let root = URL(fileURLWithPath: mountPoint, isDirectory: true).standardizedFileURL.path
                return appPath.hasPrefix(root + "/")
            }
        }
    }

    func managedAppTarget(for bundleID: String) -> MigrationTarget {
        managedAppContainer(for: bundleID).map { .container($0.id) } ?? .local
    }

}
