import SwiftUI

// MARK: - Main ContentView
struct ContentView: View {
    @StateObject private var actions: ManagedAppActions
    let viewModel: AppViewModel
    let migrationStatus: MigrationStatus

    @MainActor
    init(
        model: AppModel,
        viewModel: AppViewModel,
        appStore: any ManagedAppPersisting,
        storageService: any StorageServicing,
        migrationService: any MigrationServicing
    ) {
        _actions = StateObject(
            wrappedValue: ManagedAppActions(
                model: model,
                viewModel: viewModel,
                appStore: appStore,
                storageService: storageService,
                migrationService: migrationService
            )
        )
        self.viewModel = viewModel
        self.migrationStatus = migrationService.status
    }

    var body: some View {
        GeometryReader { _ in
            NavigationView {
                GeometryReader { _ in
                    StorageSidebarView(
                        viewModel: viewModel,
                        storageService: actions.storageService,
                        onPrepareDroppedAppBatch: { urls, target in
                            actions.prepareDroppedAppBatch(urls: urls, to: target)
                        },
                        onPrepareExistingAppBatch: { apps, target in
                            actions.prepareExistingAppBatch(apps, to: target)
                        }
                    )
                }
                .frame(minWidth: 220)

                GeometryReader { _ in
                    VStack(spacing: 0) {
                        StatusView(
                            viewModel: viewModel,
                            migrationStatus: migrationStatus,
                            isInstalledApp: actions.isInstalledApp
                        )
                        Divider()
                        ManagedAppListView(
                            viewModel: viewModel,
                            migrationStatus: migrationStatus,
                            actions: actions
                        )
                    }
                    .ignoresSafeArea(.container, edges: .top)
                }
            }
        }
        .padding(0)
        .frame(minWidth: 900, minHeight: 600)
        .appDialogs(
            viewModel: viewModel,
            actions: actions
        )
    }

}

struct ContentView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        let viewModel = AppViewModel()
        let model = AppModel()
        let appStore = ManagedAppStore()
        let storageService = StorageServiceFactory.live
        ContentView(
            model: model,
            viewModel: viewModel,
            appStore: appStore,
            storageService: storageService,
            migrationService: MigrationService(
                model: model,
                storageService: storageService,
                appStore: appStore
            )
        )
        .environmentObject(model)
        .environmentObject(UpdateController())
    }
}
