import AppKit
import Foundation

/// Stateless operating-system actions for launching and revealing Apps.
enum AppLauncher {
    static func openApplication(
        at url: URL,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true
        configuration.environment = sanitizedEnvironment()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            Task { @MainActor in completion(error) }
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func sanitizedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let prefixes = ["DYLD_", "__XPC_DYLD_", "XCODE_", "XCInjectBundle", "MTL_"]
        for key in environment.keys where prefixes.contains(where: { key.hasPrefix($0) }) {
            environment.removeValue(forKey: key)
        }
        environment["DYLD_INSERT_LIBRARIES"] = ""
        return environment
    }
}
