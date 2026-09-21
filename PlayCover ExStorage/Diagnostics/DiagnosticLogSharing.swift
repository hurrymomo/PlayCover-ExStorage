import AppKit
import Foundation

@MainActor
final class DiagnosticLogSharingController: NSObject, NSSharingServiceDelegate {
    static let shared = DiagnosticLogSharingController()

    private let recipient = "guagua4response@gmail.com"
    private var activeService: NSSharingService?
    private var activeArchiveURL: URL?

    func shareLogs() {
        let confirmation = NSAlert()
        confirmation.messageText = "Share Diagnostic Logs?"
        confirmation.informativeText = "PlayCover ExStorage will package its workflow log, privileged Helper log, recent capacity-query responses, and basic App/macOS version information. Logs may contain App Bundle IDs, file paths, disk identifiers, and command output.\n\nYour mail app will open with the archive attached and an email addressed to the developer. Nothing is sent until you review the email and click Send. You may need to sign in to your email account."
        confirmation.alertStyle = .informational
        confirmation.addButton(withTitle: "Package and Continue")
        confirmation.addButton(withTitle: "Cancel")

        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            let package = try makeArchive()
            guard let service = NSSharingService(named: .composeEmail) else {
                showArchiveInFinder(
                    package.archiveURL,
                    message: "No email sharing service is available. The diagnostic archive has been created so you can attach it using webmail or another service."
                )
                return
            }

            let body = """
            Hello,

            I encountered a problem while using PlayCover ExStorage.

            App version: \(package.appVersion) (\(package.buildNumber))
            Report ID: \(package.reportID)

            What I was doing:
            [Please describe what happened here.]

            Expected result:
            [Please describe what you expected.]

            The diagnostic log archive is attached.
            """
            let items: [Any] = [body as NSString, package.archiveURL]
            guard service.canPerform(withItems: items) else {
                showArchiveInFinder(
                    package.archiveURL,
                    message: "Your email app could not create a message with this attachment. The diagnostic archive has been created so you can attach it manually."
                )
                return
            }

            service.recipients = [recipient]
            service.subject = "PlayCover ExStorage Diagnostic Logs – \(package.appVersion)"
            service.delegate = self
            activeService = service
            activeArchiveURL = package.archiveURL
            service.perform(withItems: items)
        } catch {
            showError("The diagnostic logs could not be packaged.\n\n\(error.localizedDescription)")
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        // NSSharingService reports success when Mail accepts the compose request,
        // before Mail necessarily reads the attachment. Keep the temporary ZIP
        // available so it remains attached until the user sends the message.
        activeService = nil
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        activeService = nil
        if let archiveURL = activeArchiveURL {
            showArchiveInFinder(
                archiveURL,
                message: "The email could not be prepared. The diagnostic archive is available in Finder so you can attach it manually.\n\n\(error.localizedDescription)"
            )
        } else {
            showError("The email could not be prepared.\n\n\(error.localizedDescription)")
        }
    }

    private func makeArchive() throws -> DiagnosticPackage {
        let fileManager = FileManager.default
        let reportID = UUID().uuidString
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PlayCover-ExStorage-Diagnostics-\(reportID)", isDirectory: true)
        let packageDirectory = temporaryDirectory
            .appendingPathComponent("PlayCover ExStorage Diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)

        let logsDirectory = MigrationTrace.logURL.deletingLastPathComponent()
        for name in ["workflow.log", "workflow.log.1", "helper.log", "helper.log.1"] {
            let source = logsDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: packageDirectory.appendingPathComponent(name))
        }

        let capacityQueries = logsDirectory.appendingPathComponent("CapacityQueries", isDirectory: true)
        if fileManager.fileExists(atPath: capacityQueries.path) {
            try fileManager.copyItem(
                at: capacityQueries,
                to: packageDirectory.appendingPathComponent("CapacityQueries", isDirectory: true)
            )
        }

        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let summary = """
        PlayCover ExStorage diagnostic package
        Report ID: \(reportID)
        Generated: \(generatedAt)
        App version: \(version)
        Build: \(build)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        try summary.write(
            to: packageDirectory.appendingPathComponent("diagnostic-summary.txt"),
            atomically: true,
            encoding: .utf8
        )

        let archiveName = "PlayCover-ExStorage-Logs-\(reportID.prefix(8)).zip"
        let archiveURL = temporaryDirectory.appendingPathComponent(archiveName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            packageDirectory.path,
            archiveURL.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8) ?? "ditto exited with status \(process.terminationStatus)"
            throw DiagnosticLogSharingError.archiveFailed(details.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return DiagnosticPackage(
            reportID: reportID,
            appVersion: version,
            buildNumber: build,
            archiveURL: archiveURL
        )
    }

    private func showArchiveInFinder(_ archiveURL: URL, message: String) {
        activeArchiveURL = archiveURL
        let alert = NSAlert()
        alert.messageText = "Diagnostic Archive Created"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Show in Finder")
        alert.runModal()
        NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Unable to Share Diagnostic Logs"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

}

private struct DiagnosticPackage {
    let reportID: String
    let appVersion: String
    let buildNumber: String
    let archiveURL: URL
}

private enum DiagnosticLogSharingError: LocalizedError {
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case let .archiveFailed(details):
            return "Archive creation failed: \(details)"
        }
    }
}
