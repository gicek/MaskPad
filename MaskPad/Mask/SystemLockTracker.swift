import Foundation

/// Decides whether a system lock is real (requires the login password), and thus whether to dismiss the mask.
///
/// Locking alone isn't enough: closing the lid, display sleep, or the screen saver lock the session
/// **immediately** (`CGSSessionScreenIsLocked`, `com.apple.screenIsLocked`), but waking within the
/// "require password after N minutes" grace period auto-unlocks within ~30 ms. Trusting the lock
/// bit would let a quick lid close bypass the passcode.
///
/// Rules (**when unsure, keep the mask**: a false keep costs one passcode entry, a false dismiss is a bypass):
/// - **MaskPad's own lock request** (`explicitLockRequested`, from "Forgot passcode"): trusted immediately.
/// - **Doze-related lock** (sleep/display off/screen saver within `dozeGrace`): real if the doze lasted
///   at least the password delay (plus margin), or it's still locked `stillLockedAfterWake` s after waking.
/// - **Other locks** (hot corner, fast user switching, …): real only after `stillLockedAfterWake` s.
///   Lock and doze notifications come from different centers with no ordering guarantee, so waiting
///   lets a late doze notification switch to the doze rule.
struct SystemLockTracker {
    /// Lock and doze notifications within this window are treated as one event.
    static let dozeGrace: TimeInterval = 10
    /// Margin when comparing doze duration with the password delay, since their start times differ slightly.
    static let delayMargin: TimeInterval = 10
    /// Still locked this long (after wake, for doze locks) means the system is asking for a password.
    static let stillLockedAfterWake: TimeInterval = 3
    /// A lock seen within this window after our request counts as MaskPad's own.
    static let explicitRequestWindow: TimeInterval = 10

    private(set) var dozeStart: Date?
    private(set) var dozeEnd: Date?
    /// When an undecided lock was first seen; nil if none is pending.
    private(set) var lockedAt: Date?
    private var explicitRequestAt: Date?

    var lockPending: Bool { lockedAt != nil }

    /// MaskPad requested a lock; the next lock seen is trusted immediately.
    mutating func explicitLockRequested(at now: Date) {
        explicitRequestAt = now
    }

    /// Sleep, display off, or screen saver start. Only the first notification per doze counts; returns whether a new doze began.
    @discardableResult
    mutating func dozeBegan(at now: Date) -> Bool {
        guard dozeStart == nil || dozeEnd != nil else { return false }
        dozeStart = now
        dozeEnd = nil
        return true
    }

    /// Wake, display on, or screen saver end. Only the first notification per doze counts.
    mutating func dozeEnded(at now: Date) {
        guard dozeStart != nil, dozeEnd == nil else { return }
        dozeEnd = now
    }

    /// Feeds the current lock state (on notifications and every second while pending).
    /// Returns true if the lock is deemed real and the mask should be dismissed.
    /// - Parameter passwordDelay: The system's password delay after sleep: 0 = immediate,
    ///   `.infinity` = never, nil = unknown.
    mutating func observe(isLocked: Bool, at now: Date, passwordDelay: TimeInterval?) -> Bool {
        guard isLocked else {
            // Unlocked without a password (grace-period lock) or never locked: keep the mask.
            lockedAt = nil
            return false
        }
        let lockedAt = self.lockedAt ?? now
        self.lockedAt = lockedAt

        if let request = explicitRequestAt, now.timeIntervalSince(request) < Self.explicitRequestWindow {
            return decide(true)
        }
        if let start = relevantDozeStart(lockedAt: lockedAt) {
            let dozedFor = (dozeEnd ?? now).timeIntervalSince(start)
            if Self.requiresPassword(dozedFor: dozedFor, passwordDelay: passwordDelay) {
                return decide(true)
            }
            if let end = dozeEnd, now.timeIntervalSince(end) >= Self.stillLockedAfterWake {
                return decide(true)
            }
            return false
        }
        return now.timeIntervalSince(lockedAt) >= Self.stillLockedAfterWake ? decide(true) : false
    }

    /// Start of a doze related to this lock: ongoing, or within `dozeGrace` of the lock.
    private func relevantDozeStart(lockedAt: Date) -> Date? {
        guard let start = dozeStart, start.timeIntervalSince(lockedAt) <= Self.dozeGrace else { return nil }
        if let end = dozeEnd, lockedAt.timeIntervalSince(end) > Self.dozeGrace { return nil }
        return start
    }

    private mutating func decide(_ isRealLock: Bool) -> Bool {
        lockedAt = nil
        explicitRequestAt = nil
        return isRealLock
    }

    static func requiresPassword(dozedFor: TimeInterval, passwordDelay: TimeInterval?) -> Bool {
        guard let delay = passwordDelay, delay.isFinite else { return false }
        return delay <= 0 || dozedFor >= delay + delayMargin
    }

    /// Parses `sysadminctl -screenLock status` output (written to stderr):
    /// `screenLock delay is immediate` / `screenLock delay is 300 seconds` / `screenLock is off`.
    static func parsePasswordDelay(_ output: String) -> TimeInterval? {
        let text = output.lowercased()
        if text.contains("screenlock is off") { return .infinity }
        if text.contains("delay is immediate") { return 0 }
        guard let range = text.range(of: #"delay is (\d+) seconds"#, options: .regularExpression) else { return nil }
        return TimeInterval(text[range].filter(\.isNumber))
    }

    /// Reads the system's password delay after sleep, or nil. Spawns a process; avoid the main thread.
    static func readPasswordDelay() -> TimeInterval? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        process.arguments = ["-screenLock", "status"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parsePasswordDelay(String(decoding: data, as: UTF8.self))
    }
}
