import Foundation
import Testing
@testable import MaskPad

/// Timelines follow macOS behavior with a 300 s "require password" delay.
struct SystemLockTrackerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// 3 s lid close: locks right after sleep, still locked on wake, auto-unlocks 30 ms later; the mask must stay.
    @Test func shortLidCloseWithinGraceKeepsMask() {
        var tracker = SystemLockTracker()
        tracker.dozeBegan(at: at(0))                         // willSleep
        tracker.dozeBegan(at: at(0.07))                      // screensDidSleep (ignored)
        do { let r = tracker.observe(isLocked: true, at: at(0.15), passwordDelay: 300); #expect(r == false) }
        tracker.dozeEnded(at: at(3.6))                       // screensDidWake
        do { let r = tracker.observe(isLocked: true, at: at(3.66), passwordDelay: 300); #expect(r == false) }
        do { let r = tracker.observe(isLocked: false, at: at(3.69), passwordDelay: 300); #expect(r == false) }
        #expect(tracker.lockPending == false)
    }

    /// Lock notification arriving before the doze notification is still judged by the doze rules.
    @Test func lockBeforeDozeNotificationIsJudgedAsDoze() {
        var tracker = SystemLockTracker()
        do { let r = tracker.observe(isLocked: true, at: at(0), passwordDelay: 300); #expect(r == false) }
        tracker.dozeBegan(at: at(0.1))
        do { let r = tracker.observe(isLocked: true, at: at(0.2), passwordDelay: 300); #expect(r == false) }
        tracker.dozeEnded(at: at(3))
        do { let r = tracker.observe(isLocked: true, at: at(3.05), passwordDelay: 300); #expect(r == false) }
        do { let r = tracker.observe(isLocked: false, at: at(3.08), passwordDelay: 300); #expect(r == false) }
    }

    /// A lock requested by the "Unlock with system password" button is confirmed immediately.
    @Test func explicitLockRequestDisengagesImmediately() {
        var tracker = SystemLockTracker()
        tracker.explicitLockRequested(at: at(0))
        do { let r = tracker.observe(isLocked: true, at: at(0.3), passwordDelay: 300); #expect(r == true) }
    }

    /// A stale lock request is ignored.
    @Test func staleExplicitRequestIsIgnored() {
        var tracker = SystemLockTracker()
        tracker.explicitLockRequested(at: at(0))
        do { let r = tracker.observe(isLocked: true, at: at(SystemLockTracker.explicitRequestWindow + 1), passwordDelay: 300); #expect(r == false) }
    }

    /// A lock without doze (hot corner, fast user switching) is confirmed after 3 s locked.
    @Test func lockWithoutDozeNeedsToPersist() {
        var tracker = SystemLockTracker()
        do { let r = tracker.observe(isLocked: true, at: at(0), passwordDelay: 300); #expect(r == false) }
        do { let r = tracker.observe(isLocked: true, at: at(1), passwordDelay: 300); #expect(r == false) }
        do { let r = tracker.observe(isLocked: true, at: at(3), passwordDelay: 300); #expect(r == true) }
    }

    /// A lock long after a past doze and wake is not judged by the doze rules.
    @Test func oldDozeIsNotRelevant() {
        var tracker = SystemLockTracker()
        tracker.dozeBegan(at: at(0))
        tracker.dozeEnded(at: at(5))
        let lockAt = 5 + SystemLockTracker.dozeGrace + 1
        do { let r = tracker.observe(isLocked: true, at: at(lockAt), passwordDelay: 300); #expect(r == false) }
        do { let r = tracker.observe(isLocked: true, at: at(lockAt + 3), passwordDelay: 300); #expect(r == true) }
    }

    /// Lid closed longer than the password delay plus margin is confirmed as a real lock on wake.
    @Test func longLidCloseBeyondDelayDisengagesOnWake() {
        var tracker = SystemLockTracker()
        tracker.dozeBegan(at: at(0))
        do { let r = tracker.observe(isLocked: true, at: at(0.1), passwordDelay: 300); #expect(r == false) }
        tracker.dozeEnded(at: at(400))
        do { let r = tracker.observe(isLocked: true, at: at(400.05), passwordDelay: 300); #expect(r == true) }
    }

    /// Doze just past the delay but within the margin is ambiguous, so the mask stays.
    @Test func durationWithinMarginIsNotTrusted() {
        var tracker = SystemLockTracker()
        tracker.dozeBegan(at: at(0))
        _ = tracker.observe(isLocked: true, at: at(0.1), passwordDelay: 300)
        tracker.dozeEnded(at: at(305))
        do { let r = tracker.observe(isLocked: true, at: at(305.05), passwordDelay: 300); #expect(r == false) }
    }

    /// Still locked over 3 s after wake means the system wants a password (e.g. delay misread), so it's a real lock.
    @Test func stillLockedAfterWakeMeansPasswordRequired() {
        var tracker = SystemLockTracker()
        tracker.dozeBegan(at: at(0))
        _ = tracker.observe(isLocked: true, at: at(0.1), passwordDelay: nil)
        tracker.dozeEnded(at: at(10))
        do { let r = tracker.observe(isLocked: true, at: at(11), passwordDelay: nil); #expect(r == false) }
        do { let r = tracker.observe(isLocked: true, at: at(13), passwordDelay: nil); #expect(r == true) }
    }

    /// No confirmation by elapsed time during doze; timers stall while asleep, so judgment waits for wake.
    @Test func dozingLockWaitsForWake() {
        var tracker = SystemLockTracker()
        tracker.dozeBegan(at: at(0))
        do { let r = tracker.observe(isLocked: true, at: at(0.1), passwordDelay: 300); #expect(r == false) }
        do { let r = tracker.observe(isLocked: true, at: at(5), passwordDelay: 300); #expect(r == false) }
    }

    /// With "Require password immediately", a doze lock is a real lock.
    @Test func immediatePasswordMakesDozeLockReal() {
        var tracker = SystemLockTracker()
        tracker.dozeBegan(at: at(0))
        do { let r = tracker.observe(isLocked: true, at: at(0.1), passwordDelay: 0); #expect(r == true) }
    }

    /// With password requirement disabled, a lock that auto-unlocks on wake is never real, however long the doze.
    @Test func passwordNeverRequiredKeepsMask() {
        var tracker = SystemLockTracker()
        tracker.dozeBegan(at: at(0))
        _ = tracker.observe(isLocked: true, at: at(0.1), passwordDelay: .infinity)
        tracker.dozeEnded(at: at(10_000))
        do { let r = tracker.observe(isLocked: false, at: at(10_000.05), passwordDelay: .infinity); #expect(r == false) }
    }

    @Test func dozeBeganReportsOnlyNewDoze() {
        var tracker = SystemLockTracker()
        let first = tracker.dozeBegan(at: at(0))
        let repeated = tracker.dozeBegan(at: at(0.1))
        tracker.dozeEnded(at: at(1))
        let next = tracker.dozeBegan(at: at(2))
        #expect(first && repeated == false && next)
    }

    @Test func parsesSysadminctlOutput() {
        let prefix = "2026-11-09 13:26:17.391 sysadminctl[27075:257897] "
        #expect(SystemLockTracker.parsePasswordDelay(prefix + "screenLock delay is 300 seconds") == 300)
        #expect(SystemLockTracker.parsePasswordDelay(prefix + "screenLock delay is immediate") == 0)
        #expect(SystemLockTracker.parsePasswordDelay(prefix + "screenLock is off") == .infinity)
        #expect(SystemLockTracker.parsePasswordDelay("garbage") == nil)
    }
}
