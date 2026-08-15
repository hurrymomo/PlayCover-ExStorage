//
//  StorageServices.swift
//  PlayCover ExStorage
//

import Foundation

/// Boundary around disk discovery. A lightweight protocol keeps `AppViewModel`
/// independent from `diskutil` and makes future event-driven refreshes testable.
nonisolated protocol ExternalStorageDiscovering: Sendable {
    func discoverProgressively(
        onContainer: @escaping @MainActor @Sendable (ExternalAPFSContainer) -> Void,
        onVolume: @escaping @MainActor @Sendable (UUID, ExternalVolume) -> Void
    ) async
}

nonisolated struct DiskUtilStorageDiscovery: ExternalStorageDiscovering {
    func discoverProgressively(
        onContainer: @escaping @MainActor @Sendable (ExternalAPFSContainer) -> Void,
        onVolume: @escaping @MainActor @Sendable (UUID, ExternalVolume) -> Void
    ) async {
        await DiskUtilDiscovery.discoverExternalAPFSContainersProgressively(
            onContainer: onContainer,
            onVolume: onVolume
        )
    }
}

/// Owns the persistence policy for the App registry. Session-only drops stay in
/// memory; kept and migrated records survive relaunches.
protocol ManagedAppPersisting {
    func load() -> [ManagedApp]
    func save(_ apps: [ManagedApp])
}

struct ManagedAppStore: ManagedAppPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "ManagedApps") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [ManagedApp] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ManagedApp].self, from: data)) ?? []
    }

    func save(_ apps: [ManagedApp]) {
        let persistentApps = apps.filter { $0.persistence != .sessionOnly }
        guard let data = try? JSONEncoder().encode(persistentApps) else { return }
        defaults.set(data, forKey: key)
    }
}
