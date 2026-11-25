import AppKit
import Observation
import Sparkle

/// Sparkle 2 updates from the appcast on GitHub Releases (SUFeedURL and SUPublicEDKey come from Info.plist, written by
/// scripts/build-app.sh). Off for `swift run`, snapshots and self-tests, which have no feed or must not touch the network.
@MainActor @Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// False until Sparkle is ready, and while a check or an update is already in progress.
    private(set) var canCheckForUpdates = false
    /// A scheduled check found this version; shown in the menu bar panel until the user looks at it.
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return Bundle.main.bundleURL.pathExtension == "app"
            && !((info["SUFeedURL"] as? String) ?? "").isEmpty
            && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
    }

    func start() {
        guard controller == nil, Self.isConfigured, DebugSnapshot.directory == nil, SelfTest.seconds == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        // SPUUpdater lives on the main thread, so its KVO changes arrive there.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Chrupio lives in the menu bar, so Sparkle's alert can land behind other windows; the panel shows a reminder too.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}
