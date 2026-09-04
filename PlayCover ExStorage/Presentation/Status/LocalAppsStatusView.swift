import SwiftUI

struct LocalAppsStatusView: View {
    @EnvironmentObject private var model: AppModel
    let isInstalledApp: (AppSnapshot) -> Bool

    private var localApps: [AppSnapshot] {
        model.apps.filter(isInstalledApp).filter { app in
            model.managedDataContainer(for: app.bundleIdentifier) == nil
        }
    }

    private var localCount: Int { localApps.count }

    private var errorCount: Int {
        localApps.filter {
            model.appFailureMessage(for: $0.bundleIdentifier) != nil
        }.count
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "macbook")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("Local").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 18) {
                    detail("Apps", "\(localCount)")
                    detail("Available", availableStorage)
                    detail("Errors", "\(errorCount)", color: errorCount > 0 ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private var availableStorage: String {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let bytes = values.volumeAvailableCapacity else {
            return "Unknown"
        }
        return StorageByteFormatter.string(Int64(bytes))
    }

    private func detail(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
