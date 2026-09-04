import SwiftUI

struct ManagedAppRow: View {
    @EnvironmentObject private var model: AppModel
    let actions: ManagedAppActions
    let app: AppSnapshot
    @Binding var selectedAppBundleID: String?
    @Binding var selectedAppBundleIDs: Set<String>
    @Binding var selectedOtherVolumeID: String?

    private var matchingVolume: ExternalVolume? {
        model.managedDataVolume(for: app.bundleIdentifier)
    }

    private var matchingContainer: ExternalAPFSContainer? {
        model.managedDataContainer(for: app.bundleIdentifier)
    }

    private var migrationError: String? {
        actions.appFailureMessage(bundleID: app.bundleIdentifier)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if actions.isInstalledApp(app) {
                        let icon = NSWorkspace.shared.icon(forFile: app.applicationPath)
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64).cornerRadius(14)
                    } else {
                        Image(systemName: "app.dashed").font(.system(size: 38)).frame(width: 64, height: 64)
                    }
                }
                if migrationError != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .offset(x: 5, y: -5)
                }
            }
            HStack(alignment: .top, spacing: 5) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(app.name)
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                }
                RightClickSelectionDetector(
                    isEnabled: true,
                    onLeftMouseDown: selectApp,
                    onRightClick: {
                        selectedOtherVolumeID = nil
                        selectedAppBundleIDs = [app.bundleIdentifier]
                        selectedAppBundleID = app.bundleIdentifier
                    }
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            actions.selectManagedApp(app)
            actions.requestOpenSelectedApp()
        }
        .accessibilityAction(.default) {
            actions.selectManagedApp(app)
            actions.requestOpenSelectedApp()
        }
        .migrationDrag(enabled: true) {
            let bundleIDs = selectedAppBundleIDs.contains(app.bundleIdentifier)
                ? selectedAppBundleIDs.sorted()
                : [app.bundleIdentifier]
            return NSItemProvider(object: appDragPayload(bundleIDs) as NSString)
        }
        .contextMenu {
            Button("Connect & Open") {
                actions.selectManagedApp(app)
                actions.requestOpenSelectedApp()
            }
            .disabled(model.appOperationState(for: app.bundleIdentifier).operation.isRunning)
                Button("Open App Data") {
                    actions.openAppData(for: app)
                }
                Button("Show in Finder") {
                    actions.showAppInFinder(app)
                }
                Divider()
                Menu("Migrate") {
                    Menu("Migrate Data to") {
                        componentMigrationTargetButton(title: "Local", target: .local, content: .data)
                        ForEach(ViewUtilities.sortedContainers(model.allContainers())) { container in
                            componentMigrationTargetButton(
                                title: "\(container.displayName ?? "External APFS Storage") · \(container.containerReference)",
                                target: .container(container.id),
                                content: .data
                            )
                        }
                    }
                    Menu("Migrate App to") {
                        componentMigrationTargetButton(title: "Local", target: .local, content: .app)
                        if currentTarget != .local {
                            componentMigrationTargetButton(
                                title: matchingContainer.map(containerMenuTitle) ?? "External Storage",
                                target: currentTarget,
                                content: .app
                            )
                        }
                    }
                    Menu("Migrate App & Data to") {
                        componentMigrationTargetButton(title: "Local", target: .local, content: .appAndData)
                        ForEach(ViewUtilities.sortedContainers(model.allContainers())) { container in
                            componentMigrationTargetButton(
                                title: "\(container.displayName ?? "External APFS Storage") · \(container.containerReference)",
                                target: .container(container.id),
                                content: .appAndData
                            )
                        }
                    }
                }
                Divider()
                Button("Connect") {
                    actions.selectManagedApp(app)
                    actions.requestReconnectAppData()
                }
                .disabled(model.appOperationState(for: app.bundleIdentifier).operation.isRunning || matchingVolume == nil || statusText == "Connected")
                Button("Disconnect") {
                    actions.selectManagedApp(app)
                    actions.disconnectAppData()
                }
                .disabled(model.appOperationState(for: app.bundleIdentifier).operation.isRunning || statusText != "Connected")
                Divider()
                if app.persistence == .sessionOnly, matchingVolume == nil {
                    Button("Keep in Library") {
                        actions.keepInLibrary(bundleID: app.bundleIdentifier)
                    }
                }
                if matchingVolume == nil {
                    Button("Remove from Library") {
                        selectedAppBundleID = nil
                        selectedAppBundleIDs.remove(app.bundleIdentifier)
                        actions.removeFromLibrary(bundleID: app.bundleIdentifier)
                    }
                }
                Divider()
            Button("Delete…", role: .destructive) {
                actions.requestDelete(app)
            }
        }
    }

    private var statusText: String {
        guard let volume = matchingVolume else { return "Offline" }
        return connectionState(for: volume, bundleID: app.bundleIdentifier) == .connected ? "Connected" : "Disconnected"
    }
    private var currentTarget: MigrationTarget {
        matchingContainer.map { .container($0.id) } ?? .local
    }

    private var currentAppTarget: MigrationTarget {
        model.managedAppTarget(for: app.bundleIdentifier)
    }

    private func containerMenuTitle(_ container: ExternalAPFSContainer) -> String {
        "\(container.displayName ?? "External APFS Storage") · \(container.containerReference)"
    }

    @ViewBuilder
    private func componentMigrationTargetButton(
        title: String,
        target: MigrationTarget,
        content: MigrationContent
    ) -> some View {
        let isCurrent = content == .data
            ? target == currentTarget
            : (content == .app ? target == currentAppTarget : target == currentTarget && target == currentAppTarget)
        let externalAppBlocksData = content == .data && currentAppTarget != .local && target != currentTarget
        Button {
            switch content {
            case .data:
                actions.requestMigration(of: app, from: currentTarget, to: target)
            case .app:
                actions.requestAppMigration(of: app, to: target)
            case .appAndData:
                actions.requestAppAndDataMigration(of: app, to: target)
            }
        } label: {
            Text(isCurrent ? "✓  \(title)" : "    \(title)")
        }
        .disabled(isCurrent || externalAppBlocksData)
        .help(externalAppBlocksData ? "The App is on external storage, so App and Data must migrate together." : "")
    }
    private var isSelected: Bool {
        selectedAppBundleIDs.contains(app.bundleIdentifier)
    }

    private func selectApp() {
        selectedOtherVolumeID = nil
        if NSEvent.modifierFlags.contains(.command) {
            if selectedAppBundleIDs.contains(app.bundleIdentifier) {
                selectedAppBundleIDs.remove(app.bundleIdentifier)
                if selectedAppBundleID == app.bundleIdentifier {
                    selectedAppBundleID = selectedAppBundleIDs.first
                }
            } else {
                selectedAppBundleIDs.insert(app.bundleIdentifier)
                selectedAppBundleID = app.bundleIdentifier
                actions.selectManagedApp(app)
            }
        } else {
            selectedAppBundleIDs = [app.bundleIdentifier]
            selectedAppBundleID = app.bundleIdentifier
            actions.selectManagedApp(app)
        }
    }

    private var statusDotColor: Color {
        guard matchingVolume != nil else { return StorageStatusColors.local }
        return statusText == "Connected" ? StorageStatusColors.connected : StorageStatusColors.disconnected
    }
}

private extension View {
    @ViewBuilder
    func migrationDrag(
        enabled: Bool,
        provider: @escaping () -> NSItemProvider
    ) -> some View {
        if enabled {
            onDrag(provider)
        } else {
            self
        }
    }
}
