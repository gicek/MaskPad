import Combine
import Foundation
import IOKit

/// Engages the mask automatically after the Mac has been idle for `MaskSettings.autoEngageMinutes`
/// (0 = never), like the screen saver's idle trigger.
///
/// There's no idle notification, so it polls `IOHIDSystem`'s `HIDIdleTime`. It engages when the
/// threshold is reached, a passcode is set, the mask is off, the screen isn't locked, no Screen
/// Sharing session is connected, and nobody is watching the screen.
///
/// **Someone watching counts as activity** (unless turned off in Settings): like the system's own idle
/// lock, it waits while an app keeps the display awake for video, a call, a presentation, a game or
/// screen recording (`DisplaySleepBlockers`). The idle time starts over when that ends.
///
/// **HID idle time doesn't see remote input** (Screen Sharing, Computer Use tools), so these also count as activity:
/// - the moment the mask is dismissed (a remote unlock doesn't reset HID idle);
/// - the moment the screen unlocks (Apple Watch / Touch ID don't go through HID);
/// - a Screen Sharing session, or someone watching, detected when the threshold is hit (restarts the timer).
/// Otherwise the mask would re-engage on the next poll after every remote unlock.
///
/// While auto-engage can actually happen (threshold set, passcode set, Accessibility granted, not locked),
/// a sleep assertion is held: a shorter system lock/display-sleep timeout would otherwise lock first and
/// auto-engage would never fire. See `updateSleepAssertion()`.
///
/// **Doesn't engage while the screen is locked**: the lock already protects privacy, and a mask hidden
/// under the lock screen would just greet the user with a second passcode prompt. The assertion is released too.
@MainActor
final class MaskAutoEngage {
    static let shared = MaskAutoEngage()

    private var timer: Timer?
    private var thresholdSeconds: TimeInterval = 0
    private var observation: AnyCancellable?
    private var passcodeObserver: NSObjectProtocol?
    private var disengageObservation: AnyCancellable?

    /// Lock state from the previous poll, to detect the moment of unlock.
    private var wasScreenLocked = false
    /// Last unlock, mask dismissal, and detection of Screen Sharing or of someone watching; each counts
    /// as user activity.
    private var unlockedAt: Date?
    private var disengagedAt: Date?
    private var presenceSeenAt: Date?
    private var presenceProbeInFlight = false

    /// A failure has already been reported. Auto-engage runs unattended, so reopening Settings every poll
    /// would be spam; reset by settings/passcode changes or a success.
    private var didReportFailure = false

    /// Prevents idle display sleep/system sleep while auto-mask is armed.
    private let sleepAssertion = SleepAssertion(name: "MaskPad auto mask armed")

    /// Called once at launch; reconfigures on settings, passcode, and mask state changes.
    func start() {
        apply(minutes: MaskSettings.shared.autoEngageMinutes)
        observation = MaskSettings.shared.$autoEngageMinutes
            .removeDuplicates()
            .sink { [weak self] minutes in self?.apply(minutes: minutes) }
        passcodeObserver = NotificationCenter.default.addObserver(
            forName: MaskPasscodeStore.didChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MaskAutoEngage.shared.reconfigure() }
        }
        disengageObservation = MaskController.shared.$isEngaged
            .removeDuplicates()
            .dropFirst()
            .filter { $0 == false }
            .sink { [weak self] _ in self?.disengagedAt = Date() }
    }

    private func apply(minutes: Int) {
        thresholdSeconds = TimeInterval(max(0, minutes) * 60)
        reconfigure()
    }

    /// The only place the poll timer is started or stopped: it runs only with a threshold **and a passcode**,
    /// otherwise it would spin uselessly. Also refreshes the sleep assertion.
    private func reconfigure() {
        timer?.invalidate()
        timer = nil
        didReportFailure = false
        updateSleepAssertion()
        guard thresholdSeconds > 0, MaskPasscodeStore.shared.hasPasscode else { return }
        // A quarter of the threshold, clamped to 5–30 s.
        let interval = min(30, max(5, thresholdSeconds / 4))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        // Lock state is polled here too, updating the sleep assertion within one interval (≤ 30 s).
        let isLocked = MaskController.isSystemScreenLocked()
        if wasScreenLocked, isLocked == false {
            unlockedAt = Date()
        }
        wasScreenLocked = isLocked
        updateSleepAssertion()

        guard thresholdSeconds > 0,
              isLocked == false,
              MaskController.shared.isEngaged == false,
              MaskPasscodeStore.shared.hasPasscode,
              presenceProbeInFlight == false,
              Self.effectiveIdleSeconds(
                  hidIdle: Self.systemIdleSeconds(), now: Date(),
                  activity: [unlockedAt, disengagedAt, presenceSeenAt]
              ) >= thresholdSeconds
        else { return }

        // Threshold reached: check in the background for Screen Sharing (spawns a process) and for
        // someone watching the screen. Either one is treated as activity.
        presenceProbeInFlight = true
        let waitsForMedia = MaskSettings.shared.autoEngageWaitsForMedia
        Task {
            let present = await Task.detached {
                (waitsForMedia && DisplaySleepBlockers.isSomeoneWatching())
                    || ScreenSharingRelock.isScreenSharingActive()
            }.value
            presenceProbeInFlight = false
            if present {
                presenceSeenAt = Date()
            } else {
                engage()
            }
        }
    }

    private func engage() {
        guard MaskController.shared.isEngaged == false, MaskController.isSystemScreenLocked() == false else { return }
        // Same permission precheck as the hotkey path: without Accessibility `engage()` always fails,
        // and would recreate the event tap every poll.
        guard MaskController.canBlockLocalInput else {
            report(.inputBlockerUnavailable)
            return
        }
        report(MaskController.shared.engage())
    }

    /// Reports the auto-engage result. Success is silent (the mask itself is the feedback). Failure opens
    /// Settings, whose banner explains what's missing, so the user doesn't assume they're protected. Reported once per state.
    private func report(_ error: MaskController.EngageError?) {
        guard error != nil else {
            didReportFailure = false
            return
        }
        guard didReportFailure == false else { return }
        didReportFailure = true
        SettingsWindowController.shared.show()
    }

    /// Effective idle time: the smaller of HID idle time and time since the latest activity.
    nonisolated static func effectiveIdleSeconds(hidIdle: TimeInterval, now: Date, activity: [Date?]) -> TimeInterval {
        activity.compactMap { $0 }.reduce(hidIdle) { min($0, now.timeIntervalSince($1)) }
    }

    /// Holds the assertion under exactly the conditions where auto-engage can happen. **Missing permission
    /// matters most**: otherwise the Mac could neither mask nor sleep/auto-lock, leaving the screen on unprotected.
    private func updateSleepAssertion() {
        if thresholdSeconds > 0,
           MaskPasscodeStore.shared.hasPasscode,
           MaskController.canBlockLocalInput,
           MaskController.isSystemScreenLocked() == false {
            sleepAssertion.hold()
        } else {
            sleepAssertion.release()
        }
    }

    /// Seconds since the last local HID input (`IOHIDSystem` `HIDIdleTime`, in ns). Returns 0 on failure,
    /// so it never engages by mistake.
    private static func systemIdleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              let idleNanoseconds = (properties["HIDIdleTime"] as? NSNumber)?.doubleValue
        else { return 0 }
        return idleNanoseconds / 1_000_000_000
    }
}
