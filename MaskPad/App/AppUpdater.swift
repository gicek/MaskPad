import AppKit
import Combine
import Sparkle

/// In-app updates through Sparkle. The feed URL and EdDSA public key are in Info.plist (`project.yml`).
///
/// The mask comes first:
/// - **No checks while masked.** A scheduled check is refused, so no update alert appears behind the mask.
///   (User checks can't happen: the menu is unreachable.) Sparkle counts a refused check as done and waits
///   a whole interval (a day) for the next one, so a Mac that is masked at the same time every day would
///   never check; the refused check is made up when the mask turns off.
/// - **No relaunch while masked.** Relaunching ends the process, which would remove the mask. An install
///   that is about to relaunch waits until the mask is turned off.
///
/// MaskPad is a menu bar app, so a scheduled update can appear behind other apps. To keep it noticeable
/// the status menu shows "Update Available" until the user looks at the update (gentle reminders).
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// Sparkle's own preference (stored in MaskPad's defaults); mirrored here so SwiftUI can bind to it.
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// False while a check or install is already in progress, or before the updater has started.
    @Published private(set) var canCheckForUpdates = false
    /// A scheduled check found an update the user hasn't looked at yet.
    @Published private(set) var hasPendingUpdate = false

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }
    private var postponedRelaunch: (() -> Void)?
    /// A scheduled check was refused because the mask was on; made up when it turns off.
    private var skippedScheduledCheck = false
    private var cancellables: Set<AnyCancellable> = []

    /// Starts the updater. Not called in tests: the test host must never check for or install updates.
    func start() {
        guard AppIdentity.isDebug == false, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
        MaskController.shared.$isEngaged
            .removeDuplicates()
            .filter { $0 == false }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resumePostponedRelaunch()
                self?.makeUpSkippedCheck()
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        guard MaskController.shared.isEngaged == false else { return }
        // Bring the app forward first: as an LSUIElement app it isn't active when chosen from the menu.
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    private func resumePostponedRelaunch() {
        guard let relaunch = postponedRelaunch else { return }
        postponedRelaunch = nil
        Log.update.info("Mask turned off; continuing the postponed update relaunch")
        relaunch()
    }

    /// Runs the scheduled check that was refused while masked, as a background check like the original:
    /// it shows something only if there is an update.
    private func makeUpSkippedCheck() {
        guard skippedScheduledCheck else { return }
        skippedScheduledCheck = false
        // Not if checks were turned off meanwhile, or while another check or an install is under way.
        guard let updater, updater.automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
        Log.update.info("Mask turned off; running the update check skipped while it was on")
        updater.checkForUpdatesInBackground()
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if MaskController.shared.isEngaged {
            // Only scheduled checks are made up; a check asked for by the user is theirs to repeat.
            if updateCheck == .updatesInBackground { skippedScheduledCheck = true }
            throw NSError(domain: "com.gicek.maskpad.update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Update checks are paused while the mask is on."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard MaskController.shared.isEngaged else { return false }
        Log.update.info("Postponing the update relaunch until the mask is turned off")
        postponedRelaunch = installHandler
        return true
    }
}

// Not annotated as main-actor in Sparkle, but the standard user driver only calls it on the main thread.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if state.userInitiated == false {
            hasPendingUpdate = true
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasPendingUpdate = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        hasPendingUpdate = false
    }
}
