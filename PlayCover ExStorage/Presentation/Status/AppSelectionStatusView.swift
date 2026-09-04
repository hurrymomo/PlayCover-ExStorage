import SwiftUI

struct AppSelectionStatusView: View {
    private enum LocationKind: Hashable {
        case data
        case app
    }

    @EnvironmentObject private var model: AppModel
    let isInstalledApp: (AppSnapshot) -> Bool
    let app: AppSnapshot
    @State private var presentedLocation: LocationKind?
    @State private var locationHoverTask: Task<Void, Never>?

    private var matchingVolume: ExternalVolume? {
        model.managedDataVolume(for: app.bundleIdentifier)
    }

    private var matchingContainer: ExternalAPFSContainer? {
        model.managedDataContainer(for: app.bundleIdentifier)
    }

    private var dataLocationText: String {
        guard let matchingContainer else { return "Local" }
        return matchingContainer.displayName ?? "External APFS Storage"
    }

    private var appLocationText: String {
        let applicationPath = URL(fileURLWithPath: app.applicationPath).standardizedFileURL.path
        for container in model.allContainers() {
            for volume in container.volumes {
                guard let mountPoint = volume.mountPoint else { continue }
                let root = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
                guard applicationPath == root || applicationPath.hasPrefix(root + "/") else { continue }
                return container.displayName ?? "External APFS Storage"
            }
        }
        return "Local"
    }

    private var deviceText: String {
        matchingContainer?.containerReference ?? "Local"
    }

    var body: some View {
        HStack(spacing: 14) {
            if isInstalledApp(app) {
                let icon = NSWorkspace.shared.icon(forFile: app.applicationPath)
                Image(nsImage: icon).resizable().frame(width: 48, height: 48).cornerRadius(10)
            } else {
                Image(systemName: "app.dashed").font(.title).frame(width: 48)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(app.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(app.bundleIdentifier)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 18) {
                    detail("Status", statusText, color: statusColor, symbol: statusSymbol)
                        .frame(width: 112, alignment: .leading)
                    detail("Data Size", dataSizeText)
                    detail("App Size", appSizeText)
                    detail("Device", deviceText)
                        .frame(width: 58, alignment: .leading)
                    locationDetail("Data Location", dataLocationText, kind: .data)
                    locationDetail("App Location", appLocationText, kind: .app)
                }
            }
            .frame(width: 730, alignment: .leading)
            if let errorMessage = model.appFailureMessage(for: app.bundleIdentifier) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OPERATION ERROR")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(errorMessage)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private var statusText: String {
        guard let volume = matchingVolume else { return "Offline" }
        return connectionState(for: volume, bundleID: app.bundleIdentifier) == .connected ? "Connected" : "Disconnected"
    }
    private var statusSymbol: String { "circle.fill" }
    private var statusColor: Color { matchingVolume == nil ? StorageStatusColors.local : (statusText == "Connected" ? StorageStatusColors.connected : StorageStatusColors.disconnected) }

    private func locationDetail(
        _ title: String,
        _ value: String,
        kind: LocationKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 140, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
        }
        .onHover { hovering in
            locationHoverTask?.cancel()
            if hovering {
                locationHoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    presentedLocation = kind
                }
            } else if presentedLocation == kind {
                presentedLocation = nil
            }
        }
        .popover(isPresented: Binding(
            get: { presentedLocation == kind },
            set: { if !$0, presentedLocation == kind { presentedLocation = nil } }
        ), arrowEdge: .bottom) {
            Text(value)
                .font(.system(size: 12, weight: .medium))
            .padding(10)
        }
    }

    private func detail(_ title: String, _ value: String, color: Color = .secondary, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            if let symbol {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .semibold))
                    Text(value)
                        .font(.system(size: 13))
                }
                .foregroundStyle(color)
                .lineLimit(1)
            } else {
                Text(value)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }

    private var dataSizeText: String {
        if let usedBytes = matchingVolume?.usedBytes {
            return StorageByteFormatter.string(usedBytes)
        }
        switch app.dataSize {
        case .unknown: return "Unknown"
        case .calculating: return "Calculating…"
        case let .available(size): return StorageByteFormatter.string(size)
        }
    }

    private var appSizeText: String {
        switch app.appSize {
        case .unknown: return "Unknown"
        case .calculating: return "Calculating…"
        case let .available(size): return StorageByteFormatter.string(size)
        }
    }
}
