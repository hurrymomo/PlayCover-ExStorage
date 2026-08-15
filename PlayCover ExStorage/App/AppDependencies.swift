import Foundation

/// Composition root for live dependencies. Concrete infrastructure is assembled
/// here instead of being created throughout the presentation layer.
struct AppDependencies {
    let storageDiscovery: any ExternalStorageDiscovering
    let appStore: any ManagedAppPersisting
    let privilegedClient: XPCPrivilegedClient

    static let live = AppDependencies(
        storageDiscovery: DiskUtilStorageDiscovery(),
        appStore: ManagedAppStore(),
        privilegedClient: .shared
    )

    @MainActor
    func makeAppViewModel() -> AppViewModel {
        AppViewModel(
            storageDiscovery: storageDiscovery,
            appStore: appStore,
            privilegedClient: privilegedClient
        )
    }
}
