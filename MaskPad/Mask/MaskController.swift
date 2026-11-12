import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Screen mask: full-screen cover, local input blocking, and unlock by passcode or Touch ID. Hides the screen and
/// prevents local input without locking the system.
///
/// - **The mask window uses alpha 0.99 with isOpaque = false** so WindowServer doesn't treat covered
///   windows as occluded (Chromium-based apps stop rendering when occluded). Covered apps keep rendering,
///   so Computer Use tools that capture windows and post events per process keep working; full-screen
///   remote desktops (e.g. Screen Sharing) see the mask and can unlock via the keypad.
/// - **Mask state isn't persisted**: it disappears if MaskPad quits, crashes, or the Mac restarts, leaving
///   the login password in charge. For a forgotten passcode, the "Forgot passcode" button locks the Mac
///   and the mask is dismissed after login (see `SystemLockTracker`); ⌃⌘Q and the power key are blocked.
@MainActor
final class MaskController: ObservableObject {
    static let shared = MaskController()

    enum EngageError: Equatable {
        /// No passcode has been set.
        case passcodeMissing
        /// The input tap couldn't be created (no Accessibility permission). A screen mask that
        /// doesn't block the keyboard is worse than none, so engaging is refused.
        case inputBlockerUnavailable
    }

    @Published private(set) var isEngaged = false

    /// Whether local input can be blocked, i.e. Accessibility is granted. Checked by every engage path.
    ///
    /// Read live, not cached: idle auto-engage happens when nobody's around, so a cache could be hours old.
    /// `AXIsProcessTrusted()` has no side effects and never prompts.
    static var canBlockLocalInput: Bool { AXIsProcessTrusted() }

    /// Whether the session is locked (including fast user switching to the login window).
    /// `CGSSessionScreenIsLocked` has no public constant, so it's read by key name; if unavailable,
    /// assumes unlocked to avoid spurious engage/disengage. Shared by the mask and `MaskAutoEngage`.
    static func isSystemScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    private var windows: [NSWindow] = []
    private let blocker = MaskInputBlocker()
    private var unlockModel: MaskUnlockViewModel?
    /// Touch ID while the keypad shows (`MaskTouchIDSession`); does nothing when off in Settings.
    private var touchID: MaskTouchIDSession?
    private var previousPresentationOptions: NSApplication.PresentationOptions?
    private var screenObserver: NSObjectProtocol?

    /// System lock observers (see `startSystemLockMonitoring()`), one list per notification center.
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    /// Decides real vs. grace-period locks (see `startSystemLockMonitoring()`).
    private var lockTracker = SystemLockTracker()
    private var lockCheckTimer: Timer?
    /// The system's password delay after sleep, read in the background on engage and each doze; nil if unknown.
    private var passwordDelay: TimeInterval?

    /// Auto-dim: after `dimDelay` s without local activity, dims each display and covers it in black.
    /// Only while masked and enabled in settings; any move, click, scroll, or key wakes it.
    private let dimmer = MaskScreenDimmer()
    private var idleTimer: Timer?
    private var lastActivity = Date()
    private var autoDimEnabled = false
    private static let dimDelay: TimeInterval = 20

    /// No auto-dim during Screen Sharing: its mouse input bypasses HID, so the tap never sees it and
    /// the remote user would be stuck with a black screen. Probing spawns a process, so it only runs
    /// when due to dim or already dimmed, rate-limited and in the background.
    private var screenSharingProbeInFlight = false
    /// Incremented on each engage so a stale probe from a previous session is ignored.
    private var engageGeneration = 0
    private var lastScreenSharingProbe = Date.distantPast
    private static let screenSharingProbeInterval: TimeInterval = 3

    /// Frontmost-app changes: re-hide the cursor while dimmed (see `MaskCursorHider`).
    private var activationObserver: NSObjectProtocol?

    /// Prevents idle display sleep, system sleep, and screen-saver auto-lock while masked; the mask replaces the lock.
    private let sleepAssertion = SleepAssertion(name: "MaskPad screen mask")

    func engage() -> EngageError? {
        guard isEngaged == false else { return nil }
        guard let passcode = MaskPasscodeStore.shared.load() else { return .passcodeMissing }
        // The hotkey fires on key down, so its keys are still physically held. Let each held main key
        // (e.g. L in ⌃⌘L) pass one physical keyUp; if it's swallowed, the session thinks L stays down and
        // later presses are dropped as auto-repeat. A synthetic keyUp doesn't help because key state is
        // tracked per event source.
        blocker.releasePassThroughKeys = Self.heldMainKeys(
            isKeyDown: { CGEventSource.keyState(.combinedSessionState, key: $0) }
        )
        // Keep the pointer out of the screen corners so hot corners can't fire (see `HotCornerGuard`).
        blocker.hotCornerDisplays = HotCornerGuard.activeDisplayBounds()
        guard blocker.start() else {
            blocker.releasePassThroughKeys = []
            return .inputBlockerUnavailable
        }

        // Modifiers would also get stuck (the release flagsChanged is swallowed), giving other tools'
        // synthetic clicks phantom Cmd/Ctrl. Synthetic releases work here because global modifier state is combined.
        releaseHeldModifiers()

        sleepAssertion.hold()

        // Kiosk options: hide Dock and menu bar; disable Cmd-Tab, Force Quit, logout, and Cmd-H.
        // Mission Control gestures have no option; the tap swallows gesture events and the mask covers all Spaces.
        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [
            .hideDock, .hideMenuBar, .disableProcessSwitching,
            .disableForceQuit, .disableSessionTermination, .disableHideApplication,
        ]

        let touchID = MaskTouchIDSession(isEnabled: MaskSettings.shared.touchIDUnlock) { [weak self] in
            Log.mask.notice("unlocked with Touch ID")
            self?.disengage()
        }
        self.touchID = touchID
        let model = MaskUnlockViewModel(
            message: MaskSettings.shared.maskMessage,
            onLockSystem: { [weak self] in self?.lockSystem() },
            verify: { passcode.matches($0) },
            onUnlock: { [weak self] in self?.disengage() },
            onKeypadShown: { shown in
                if shown { touchID.start() } else { touchID.stop() }
            }
        )
        unlockModel = model
        buildWindows(model: model, touchID: touchID)

        // Rebuild windows when displays are added/removed or change resolution.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEngaged, let model = self.unlockModel, let touchID = self.touchID
                else { return }
                self.blocker.hotCornerDisplays = HotCornerGuard.activeDisplayBounds()
                self.buildWindows(model: model, touchID: touchID)
                // Dim overlays were built for the old screen set; wake and restart the timer.
                // Connecting a display also implies someone is present.
                self.lastActivity = Date()
                self.dimmer.wake()
            }
        }

        // Physical keyboard passcode entry: the tap forwards digits and Delete; the events are swallowed.
        blocker.setUnlockKeyHandler { [weak self] key in
            // The tap callback runs on the main run loop.
            MainActor.assumeIsolated {
                guard let model = self?.unlockModel else { return }
                switch key {
                case .digit(let digit): model.tap(digit: digit)
                case .delete: model.deleteDigit()
                }
            }
        }

        // The system re-shows the hidden cursor when another tool switches the frontmost app.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MaskCursorHider.shared.reassert() }
        }

        NSApp.activate(ignoringOtherApps: true)
        engageGeneration += 1
        isEngaged = true
        Log.mask.notice("engaged")
        startAutoDimIfEnabled()
        startSystemLockMonitoring()
        return nil
    }

    /// Posts tagged synthetic keyUps at `.cghidEventTap` for modifiers the system thinks are held,
    /// passing through the mask's tap to reset global modifier state. Called once after the tap starts.
    private func releaseHeldModifiers() {
        let keyCodes = Self.modifierKeysToRelease(heldFlags: CGEventSource.flagsState(.combinedSessionState))
        guard keyCodes.isEmpty == false else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for code in keyCodes {
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { continue }
            up.flags = []
            up.postTagged(tap: .cghidEventTap)
        }
    }

    /// Key codes for modifiers (left/right Command, Shift, Option, Control, Fn) and Caps Lock.
    private static let modifierKeyCodes: Set<CGKeyCode> = Set([
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_Function, kVK_CapsLock,
    ].map(CGKeyCode.init))

    /// Non-modifier keys currently held (checks key codes 0–127).
    static func heldMainKeys(isKeyDown: (CGKeyCode) -> Bool) -> Set<Int64> {
        Set((0 ..< 128).map(CGKeyCode.init).filter {
            modifierKeyCodes.contains($0) == false && isKeyDown($0)
        }.map(Int64.init))
    }

    /// Modifier keys to release for the held flags (both sides). Caps Lock is a toggle and is left alone.
    static func modifierKeysToRelease(heldFlags: CGEventFlags) -> [CGKeyCode] {
        var keyCodes: [Int] = []
        if heldFlags.contains(.maskCommand) { keyCodes += [kVK_Command, kVK_RightCommand] }
        if heldFlags.contains(.maskControl) { keyCodes += [kVK_Control, kVK_RightControl] }
        if heldFlags.contains(.maskAlternate) { keyCodes += [kVK_Option, kVK_RightOption] }
        if heldFlags.contains(.maskShift) { keyCodes += [kVK_Shift, kVK_RightShift] }
        if heldFlags.contains(.maskSecondaryFn) { keyCodes += [kVK_Function] }
        return keyCodes.map(CGKeyCode.init)
    }

    // MARK: - Dismiss on system lock

    /// Dismisses the mask when the system is **really** locked (login password required): nobody can see
    /// the mask under the lock screen, and the login password is stronger. Mirrors auto-engage skipping when locked.
    ///
    /// **Real locks only**: lid close or display sleep locks immediately, but waking within the password
    /// grace period auto-unlocks, so trusting the lock bit would bypass the passcode. `SystemLockTracker`
    /// decides; this just feeds it events:
    /// - Doze start: `willSleep`, `screensDidSleep`, screen saver start. `willSleep` also restores brightness,
    ///   since input on the lock screen never reaches the mask's tap.
    /// - Doze end: `didWake`, `screensDidWake`, screen saver stop.
    /// - Lock/unlock: `com.apple.screenIsLocked` / `screenIsUnlocked`. Any process can post distributed
    ///   notifications, so the real CGS session lock bit is always re-checked.
    /// - While pending, re-checks every second: notifications may be lost during sleep, and "still locked after wake" is time-based.
    private func startSystemLockMonitoring() {
        lockTracker = SystemLockTracker()
        refreshPasswordDelay()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let distributedCenter = DistributedNotificationCenter.default()

        func onWorkspace(_ name: Notification.Name, _ handler: @escaping @MainActor (MaskController) -> Void) {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if let self, self.isEngaged { handler(self) } }
            })
        }
        func onDistributed(_ name: String, _ handler: @escaping @MainActor (MaskController) -> Void) {
            distributedObservers.append(distributedCenter.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if let self, self.isEngaged { handler(self) } }
            })
        }

        onWorkspace(NSWorkspace.willSleepNotification) { mask in
            mask.lastActivity = Date()
            mask.dimmer.wake()
            mask.dozeBegan()
        }
        onWorkspace(NSWorkspace.screensDidSleepNotification) { $0.dozeBegan() }
        onDistributed("com.apple.screensaver.didstart") { $0.dozeBegan() }
        onWorkspace(NSWorkspace.didWakeNotification) { $0.dozeEnded() }
        onWorkspace(NSWorkspace.screensDidWakeNotification) { $0.dozeEnded() }
        onDistributed("com.apple.screensaver.didstop") { $0.dozeEnded() }
        onDistributed("com.apple.screenIsLocked") { $0.checkSystemLock() }
        onDistributed("com.apple.screenIsUnlocked") { $0.checkSystemLock() }
    }

    private func stopSystemLockMonitoring() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers = []
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers = []
        lockCheckTimer?.invalidate()
        lockCheckTimer = nil
    }

    private func dozeBegan() {
        // One doze sends several notifications; re-read the password delay (a subprocess) only once
        // per doze, since the user may have just changed it.
        if lockTracker.dozeBegan(at: Date()) {
            refreshPasswordDelay()
        }
    }

    private func dozeEnded() {
        lockTracker.dozeEnded(at: Date())
        checkSystemLock()
    }

    /// Feeds the real lock bit to `SystemLockTracker`; dismisses the mask on a real lock.
    private func checkSystemLock() {
        guard isEngaged else { return }
        let isRealLock = lockTracker.observe(
            isLocked: Self.isSystemScreenLocked(), at: Date(), passwordDelay: passwordDelay
        )
        if isRealLock {
            Log.mask.notice("real system lock detected")
            disengage()
            return
        }
        updateLockCheckTimer()
    }

    private func updateLockCheckTimer() {
        guard lockTracker.lockPending else {
            lockCheckTimer?.invalidate()
            lockCheckTimer = nil
            return
        }
        guard lockCheckTimer == nil else { return }
        lockCheckTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSystemLock() }
        }
    }

    /// "Unlock with Mac Password". Records the request first so the resulting lock is trusted
    /// immediately and the mask is dismissed (see `SystemLockTracker`).
    private func lockSystem() {
        guard isEngaged else { return }
        lockTracker.explicitLockRequested(at: Date())
        SystemLock.lockNow()
    }

    private func refreshPasswordDelay() {
        Task {
            let delay = await Task.detached { SystemLockTracker.readPasswordDelay() }.value
            passwordDelay = delay
        }
    }

    /// Starts auto-dim if enabled: routes local activity to wake and starts a 1 s idle heartbeat.
    private func startAutoDimIfEnabled() {
        autoDimEnabled = MaskSettings.shared.autoDim
        guard autoDimEnabled else { return }
        blocker.setLocalActivityHandler { [weak self] in
            // The tap callback runs on the main run loop, so main-actor isolation holds.
            MainActor.assumeIsolated { self?.handleLocalActivity() ?? false }
        }
        lastActivity = Date()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoDimTick() }
        }
    }

    /// When idle, dims only if no Screen Sharing session is connected; while dimmed, wakes if one connects.
    /// Also retries unconfirmed brightness restores here rather than on every mouse event.
    private func autoDimTick() {
        guard isEngaged else { return }
        dimmer.retryPendingRestore()
        let idle = Date().timeIntervalSince(lastActivity) >= Self.dimDelay
        guard idle || dimmer.isDimmed,
              screenSharingProbeInFlight == false,
              Date().timeIntervalSince(lastScreenSharingProbe) >= Self.screenSharingProbeInterval
        else { return }
        screenSharingProbeInFlight = true
        lastScreenSharingProbe = Date()
        let generation = engageGeneration
        Task {
            let sharing = await Task.detached { ScreenSharingRelock.isScreenSharingActive() }.value
            guard generation == engageGeneration else { return }
            screenSharingProbeInFlight = false
            guard isEngaged, autoDimEnabled else { return }
            if sharing {
                // Treat as local activity: wake and restart the timer, so it re-probes every 20 s while sharing.
                lastActivity = Date()
                dimmer.wake()
            } else if Date().timeIntervalSince(lastActivity) >= Self.dimDelay {
                // Wake to the first page (the message if set, else the keypad), never "Forgot passcode".
                unlockModel?.showStartPage()
                dimmer.dim()
            }
        }
    }

    /// Records local activity and wakes the display if dimmed. Returns whether it woke the display, so the
    /// tap swallows that event. Called for every local event; `dimmer.wake()` is a no-op when not dimmed.
    private func handleLocalActivity() -> Bool {
        guard isEngaged, autoDimEnabled else { return false }
        lastActivity = Date()
        let wasDimmed = dimmer.isDimmed
        dimmer.wake()
        return wasDimmed
    }

    func disengage() {
        guard isEngaged else { return }
        isEngaged = false
        Log.mask.notice("disengaged")
        stopSystemLockMonitoring()
        idleTimer?.invalidate()
        idleTimer = nil
        blocker.setLocalActivityHandler(nil)
        blocker.setUnlockKeyHandler(nil)
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        dimmer.wake()
        dimmer.retryPendingRestore()
        autoDimEnabled = false
        screenSharingProbeInFlight = false
        sleepAssertion.release()
        blocker.stop()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        // The run loop retains the model's timers; stop them explicitly or they outlive the model.
        unlockModel?.stopTimers()
        unlockModel = nil
        touchID?.stop()
        touchID = nil
        if let previousPresentationOptions {
            NSApp.presentationOptions = previousPresentationOptions
        }
        previousPresentationOptions = nil
    }

    private func buildWindows(model: MaskUnlockViewModel, touchID: MaskTouchIDSession) {
        // The Touch ID view lives in one of the windows; a wait can't move to a new one.
        touchID.stop()
        for window in windows {
            window.orderOut(nil)
        }
        windows = NSScreen.screens.enumerated().map { index, screen in
            let window = MaskWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            // Key requirement: non-opaque with alpha 0.99 so WindowServer doesn't treat covered windows as occluded.
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.99)
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            // Shielding level covers everything (menu bar, Dock, notifications, full-screen apps),
            // on all Spaces and outside the window cycle.
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [
                .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
            ]
            // The Touch ID view goes on the main screen (the first one).
            window.contentView = MaskHostingView(rootView: MaskUnlockView(
                model: model, touchID: touchID, hostsTouchIDSensor: index == 0
            ))
            // Exactly the screen, whatever the content asks for (see `MaskHostingView`).
            window.setFrame(screen.frame, display: false)
            window.makeKeyAndOrderFront(nil)
            return window
        }
        // An external display unplugged while dimmed won't restore its brightness on its own, so show a hint.
        model.showsExternalDisplayHint = MaskSettings.shared.autoDim && Self.hasExternalDisplay()
        if model.page == .keypad {
            touchID.start()
        }
    }

    private static func hasExternalDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            screen.displayID.map { CGDisplayIsBuiltin($0) == 0 } ?? false
        }
    }
}

/// The mask window's content view.
///
/// - Never sizes the window: by default an NSHostingView resizes its window to fit the SwiftUI content's
///   minimum size. A wrapping message once made the mask window much taller than the screen, pushing the
///   keypad down, and other content could as well shrink it and uncover part of the screen. The mask
///   window is always exactly its screen (`MaskController.buildWindows`).
/// - Takes the first click even when MaskPad isn't the active app. Other apps can come to the front while
///   masked (automation tools, a hot corner opening Quick Note); without this, the first click on the
///   keypad only activates MaskPad and its digit is lost, so a correct passcode fails once.
private final class MaskHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless windows can't become key by default, which breaks focus and button highlighting.
/// Close and minimize are ignored because remote keyboards (e.g. Screen Sharing) bypass the HID tap
/// and could still send ⌘W / ⌘M.
private final class MaskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) {}
    override func performMiniaturize(_ sender: Any?) {}
}
