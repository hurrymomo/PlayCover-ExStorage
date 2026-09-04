import SwiftUI

/// The single status-area entry point. It observes shared View state, resolves
/// the latest business data from AppModel, and selects the appropriate content.
struct StatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateController: UpdateController
    @ObservedObject var viewModel: AppViewModel
    let migrationStatus: MigrationStatus
    let isInstalledApp: (AppSnapshot) -> Bool

    var body: some View {
        GeometryReader { geometry in
            statusContent
                .padding(.leading, toolbarClearance(in: geometry))
        }
        .frame(height: 82)
    }

    @ViewBuilder
    private var statusContent: some View {
        if let selectedApp {
            AppSelectionStatusView(isInstalledApp: isInstalledApp, app: selectedApp)
        } else if let selectedOtherVolume {
            OtherVolumeStatusView(volume: selectedOtherVolume)
        } else if let selectedContainer {
            DriveStatusView(
                isInstalledApp: isInstalledApp,
                container: selectedContainer,
                managedApps: model.apps
            )
        } else if viewModel.sidebarSelection == .allApps {
            AllAppsStatusView(isInstalledApp: isInstalledApp)
        } else if viewModel.sidebarSelection == .local {
            LocalAppsStatusView(isInstalledApp: isInstalledApp)
        } else {
            MigrationProgressView(status: migrationStatus)
        }
    }

    private var selectedContainer: ExternalAPFSContainer? {
        guard let sidebarSelection = viewModel.sidebarSelection,
              case let .container(id) = sidebarSelection else { return nil }
        return model.container(identifiedBy: id)
    }

    private var selectedApp: AppSnapshot? {
        guard let bundleID = viewModel.selectedAppBundleID else { return nil }
        return model.app(identifiedBy: bundleID)
    }

    private var selectedOtherVolume: ExternalVolume? {
        guard let selectedOtherVolumeID = viewModel.selectedOtherVolumeID,
              let selectedContainer else { return nil }
        return selectedContainer.volumes.first { $0.id == selectedOtherVolumeID }
    }

    private func toolbarClearance(in geometry: GeometryProxy) -> CGFloat {
        let toolbarTrailingEdge: CGFloat = updateController.isUpdateAvailable ? 170 : 138
        return max(0, toolbarTrailingEdge - geometry.frame(in: .global).minX)
    }
}
