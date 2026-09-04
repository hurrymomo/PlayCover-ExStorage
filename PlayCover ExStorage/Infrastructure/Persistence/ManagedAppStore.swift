// Managed App registry persistence. This is not part of StorageService: it
// stores the app library selection in UserDefaults and never touches disks.

import Foundation

/// Owns the persistence policy for the App registry. Session-only drops stay in
/// memory; kept and migrated records survive relaunches.
protocol ManagedAppPersisting {
    func load() -> [AppSnapshot]
    func save(_ apps: [AppSnapshot])
}

struct ManagedAppStore: ManagedAppPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "ManagedApps") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [AppSnapshot] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AppSnapshot].self, from: data)) ?? []
    }

    func save(_ apps: [AppSnapshot]) {
        let persistentApps = apps.filter { $0.persistence != .sessionOnly }
        guard let data = try? JSONEncoder().encode(persistentApps) else { return }
        defaults.set(data, forKey: key)
    }
}
