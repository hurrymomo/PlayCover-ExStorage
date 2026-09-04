//
//  PlayCover_ExStorageApp.swift
//  PlayCover ExStorage
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserStorageService.shared.shutdownPrivilegedHelper()
    }
}

@main
struct PlayCover_ExStorageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updateController = UpdateController()
    @StateObject private var viewModel: AppViewModel
    private let model: AppModel
    private let appStore: any ManagedAppPersisting
    private let storageService: any StorageServicing
    private let migrationService: MigrationService

    init() {
        let model = AppModel()
        let viewModel = AppViewModel()
        self.model = model
        _viewModel = StateObject(wrappedValue: viewModel)
        appStore = ManagedAppStore()
        storageService = UserStorageService.shared
        migrationService = MigrationService(
            model: model,
            storageService: storageService,
            appStore: appStore
        )
        MigrationTrace.event(
            "app.session.started",
            details: "pid=\(ProcessInfo.processInfo.processIdentifier)"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                viewModel: viewModel,
                appStore: appStore,
                storageService: storageService,
                migrationService: migrationService
            )
                .environmentObject(model)
                .environmentObject(updateController)
                .task {
                    guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
                        return
                    }
                    let snapshot = await storageService.scanSnapshot()
                    model.replaceStorage(with: snapshot)
                    updateController.checkForUpdates(.silent)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateController.checkForUpdates(.interactive)
                }
                .disabled(!updateController.canCheckForUpdates)
            }
        }
    }
}
