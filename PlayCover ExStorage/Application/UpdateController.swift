import Combine
import Sparkle

enum UpdateCheckMode {
    /// Checks the feed and updates UI state without presenting a window.
    case silent
    /// Presents Sparkle's standard result or update window.
    case interactive
}

/// Owns Sparkle and exposes only the update state used by SwiftUI.
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var isUpdateAvailable = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheckForUpdates = false

    private var observations = Set<AnyCancellable>()
    private var performedLaunchProbe = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    override init() {
        super.init()
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
                self?.performLaunchProbeIfPossible()
            }
            .store(in: &observations)
    }

    /// The single entry point for every update check in the app.
    func checkForUpdates(_ mode: UpdateCheckMode) {
        switch mode {
        case .silent:
            performLaunchProbeIfPossible()
        case .interactive:
            updaterController.checkForUpdates(nil)
        }
    }

    private func performLaunchProbeIfPossible() {
        guard !performedLaunchProbe, updaterController.updater.canCheckForUpdates else { return }
        performedLaunchProbe = true
        updaterController.updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async { [weak self] in
            self?.isUpdateAvailable = true
            self?.availableVersion = item.displayVersionString
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { [weak self] in
            self?.isUpdateAvailable = false
            self?.availableVersion = nil
        }
    }
}
