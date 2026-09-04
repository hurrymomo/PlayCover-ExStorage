import SwiftUI

struct AllAppsStatusView: View {
    @EnvironmentObject private var model: AppModel
    let isInstalledApp: (AppSnapshot) -> Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("All Apps").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 22) {
                    detail("Apps", totalCount, color: .primary)
                    detail("Connected", connectedCount, color: StorageStatusColors.connected)
                    detail("Disconnected", disconnectedCount, color: disconnectedCount > 0 ? StorageStatusColors.disconnected : .secondary)
                    detail("Local", localCount, color: .secondary)
                    detail("Errors", errorCount, color: errorCount > 0 ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private var validApps: [AppSnapshot] {
        model.apps.filter(isInstalledApp)
    }

    private var totalCount: Int { validApps.count }

    private var connectedCount: Int {
        validApps.filter { app in
            guard let volume = matchingVolume(for: app) else { return false }
            return connectionState(for: volume, bundleID: app.bundleIdentifier) == .connected
        }.count
    }

    private var disconnectedCount: Int {
        validApps.filter { app in
            guard let volume = matchingVolume(for: app) else { return false }
            return connectionState(for: volume, bundleID: app.bundleIdentifier) != .connected
        }.count
    }

    private var localCount: Int {
        validApps.filter { matchingVolume(for: $0) == nil }.count
    }

    private var errorCount: Int {
        validApps.filter {
            model.appFailureMessage(for: $0.bundleIdentifier) != nil
        }.count
    }

    private func matchingVolume(for app: AppSnapshot) -> ExternalVolume? {
        model.managedDataVolume(for: app.bundleIdentifier)
    }

    private func detail(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
