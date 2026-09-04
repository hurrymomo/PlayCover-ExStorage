import Combine
import Foundation

/// The single source of truth for UI state shared by Views in the main window.
///
/// This is intentionally kept beside the Views. It describes what the user
/// has selected and which presentation request is active; it is not business
/// data and is not another source of truth for storage or managed Apps.
@MainActor
final class AppViewModel: ObservableObject {
    @Published private var storedSidebarSelection: StorageSidebarSelection? = .allApps
    @Published private var storedDetailSelection: DetailSelection?
    @Published private var storedActiveDialog: AppDialog?
    @Published private var storedAppDeletionRequest: AppDeletionRequest?
    @Published private var storedVolumeDeletionRequest: VolumeDeletionRequest?
    @Published private var storedConnectionConflict: ConnectionConflict?

    // MARK: - Queries

    var sidebarSelection: StorageSidebarSelection? { storedSidebarSelection }
    var activeDialog: AppDialog? { storedActiveDialog }
    var appDeletionRequest: AppDeletionRequest? { storedAppDeletionRequest }
    var volumeDeletionRequest: VolumeDeletionRequest? { storedVolumeDeletionRequest }
    var connectionConflict: ConnectionConflict? { storedConnectionConflict }

    var selectedAppBundleID: String? {
        get {
            guard case let .app(bundleID) = storedDetailSelection else { return nil }
            return bundleID
        }
    }

    var selectedOtherVolumeID: String? {
        get {
            guard case let .volume(_, volumeID) = storedDetailSelection else { return nil }
            return volumeID
        }
    }

    // MARK: - Mutations

    func selectSidebar(_ selection: StorageSidebarSelection?) {
        guard storedSidebarSelection != selection else { return }
        storedSidebarSelection = selection
    }

    func selectApp(identifiedBy bundleID: String?) {
        if let bundleID {
            storedDetailSelection = .app(bundleID: bundleID)
        } else if case .app = storedDetailSelection {
            storedDetailSelection = nil
        }
    }

    func selectOtherVolume(identifiedBy volumeID: String?) {
        if let volumeID,
           case let .container(containerID) = storedSidebarSelection {
            storedDetailSelection = .volume(containerID: containerID, volumeID: volumeID)
        } else if case .volume = storedDetailSelection {
            storedDetailSelection = nil
        }
    }

    func clearDetailSelection() {
        guard storedDetailSelection != nil else { return }
        storedDetailSelection = nil
    }

    func presentDialog(_ dialog: AppDialog?) { storedActiveDialog = dialog }
    func setAppDeletionRequest(_ request: AppDeletionRequest?) {
        storedAppDeletionRequest = request
    }
    func setVolumeDeletionRequest(_ request: VolumeDeletionRequest?) {
        storedVolumeDeletionRequest = request
    }
    func setConnectionConflict(_ conflict: ConnectionConflict?) {
        storedConnectionConflict = conflict
    }
}

enum StorageSidebarSelection: Hashable {
    case allApps
    case local
    case container(UUID)
}

private enum DetailSelection: Hashable {
    case app(bundleID: String)
    case volume(containerID: UUID, volumeID: String)
}
