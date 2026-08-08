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
        XPCPrivilegedClient.shared.shutdownHelper()
    }
}

@main
struct PlayCover_ExStorageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)
    }
}
