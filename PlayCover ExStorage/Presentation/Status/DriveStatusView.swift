import SwiftUI

struct DriveStatusView: View {
    @EnvironmentObject private var model: AppModel
    let isInstalledApp: (AppSnapshot) -> Bool
    let container: ExternalAPFSContainer
    let managedApps: [AppSnapshot]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.fill")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 5) {
                Text(container.displayName ?? "External APFS Storage")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 14) {
                    detail("Capacity", container.capacityTotalBytes.map(StorageByteFormatter.string) ?? "Unknown")
                    detail("Available", container.capacityFreeBytes.map(StorageByteFormatter.string) ?? "Unknown")
                    detail("Device", container.containerReference)
                    detail("Connection", container.connectionType ?? "Unknown")
                    detail("UUID", shortUUID)
                    if managedAppCount > 0 {
                        detail("Connected Apps", "\(connectedAppCount)", color: StorageStatusColors.connected)
                        detail("Disconnected Apps", "\(disconnectedAppCount)", color: .secondary)
                    }
                    detail("Errors", "\(errorCount)", color: errorCount > 0 ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 82, alignment: .center)
        .help(container.containerUUID.uuidString)
    }

    private var shortUUID: String {
        String(container.containerUUID.uuidString.prefix(8)).uppercased()
    }

    private var managedAppCount: Int {
        managedMatches.count
    }

    private var connectedAppCount: Int {
        managedMatches.filter {
            connectionState(for: $0.volume, bundleID: $0.app.bundleIdentifier) == .connected
        }.count
    }

    private var disconnectedAppCount: Int { managedAppCount - connectedAppCount }

    private var errorCount: Int {
        managedMatches.filter {
            model.appFailureMessage(for: $0.app.bundleIdentifier) != nil
        }.count
    }

    private var managedMatches: [(app: AppSnapshot, volume: ExternalVolume)] {
        managedApps.filter(isInstalledApp).compactMap { app in
            guard model.managedDataContainer(for: app.bundleIdentifier)?.id == container.id,
                  let volume = model.managedDataVolume(for: app.bundleIdentifier) else { return nil }
            return (app, volume)
        }
    }

    private func detail(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
