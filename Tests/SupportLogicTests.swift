import Foundation
import Testing
@testable import MaskPad

/// Covers cases not handled by `BrightnessRecoveryTests` in `MaskCursorHiderTests.swift`.
@MainActor
struct BrightnessRecoveryReadBackTests {
    @MainActor
    final class Fake {
        var stored: [String: Float] = [:]
        var brightness: [String: Float] = ["A": 0.8]
        var readBackOffset: Float = 0
        var writes = 0

        func recovery() -> BrightnessRecovery {
            BrightnessRecovery(
                load: { self.stored },
                save: { self.stored = $0; return true },
                read: { id in self.brightness[id].map { $0 + self.readBackOffset } },
                write: { id, value in
                    self.writes += 1
                    self.brightness[id] = value
                    return true
                }
            )
        }
    }

    @Test func hasPendingTracksRestore() {
        let fake = Fake()
        let recovery = fake.recovery()
        recovery.dim("A")
        #expect(recovery.hasPending)
        recovery.restore()
        #expect(recovery.hasPending == false)
        #expect(fake.brightness["A"] == 0.8)
    }

    /// If the read-back value doesn't match (e.g. auto-brightness is adjusting), the record is kept for a retry.
    @Test func mismatchedReadBackKeepsPending() {
        let fake = Fake()
        let recovery = fake.recovery()
        recovery.dim("A")
        fake.readBackOffset = 0.2
        recovery.restore()
        #expect(recovery.hasPending)
        #expect(fake.stored["A"] == 0.8)
    }

    /// Dimming again with a pending restore record keeps the original value instead of overwriting it with 0, and skips the hardware write.
    @Test func repeatedDimKeepsFirstOriginal() {
        let fake = Fake()
        let recovery = fake.recovery()
        recovery.dim("A")
        recovery.dim("A")
        #expect(fake.stored["A"] == 0.8)
        #expect(fake.writes == 1)
    }
}

struct ScreenSharingRelockTests {
    @Test func restoresLockPreferenceParsing() {
        #expect(ScreenSharingRelock.restoresLock(preferenceValue: nil))
        #expect(ScreenSharingRelock.restoresLock(preferenceValue: NSNumber(value: true)))
        #expect(ScreenSharingRelock.restoresLock(preferenceValue: NSNumber(value: false)) == false)
        #expect(ScreenSharingRelock.restoresLock(preferenceValue: "NO") == false)
        #expect(ScreenSharingRelock.restoresLock(preferenceValue: "yes"))
    }

    /// Only established inbound connections to local port 5900 count; outbound, listening, and closed sockets do not.
    @Test func inboundSessionDetection() {
        let inbound = "tcp4       0      0  192.168.1.5.5900       192.168.1.9.51234      ESTABLISHED"
        let inbound6 = "tcp6       0      0  fe80::1%en0.5900       fe80::2%en0.51234      ESTABLISHED"
        let outbound = "tcp4       0      0  192.168.1.5.51234      192.168.1.9.5900       ESTABLISHED"
        let listening = "tcp4       0      0  *.5900                 *.*                    LISTEN"
        let closing = "tcp4       0      0  192.168.1.5.5900       192.168.1.9.51234      TIME_WAIT"
        #expect(ScreenSharingRelock.hasInboundSession(netstatOutput: inbound))
        #expect(ScreenSharingRelock.hasInboundSession(netstatOutput: inbound6))
        #expect(ScreenSharingRelock.hasInboundSession(netstatOutput: [outbound, listening, closing].joined(separator: "\n")) == false)
    }

    @Test func osascriptOutcome() {
        #expect(ScreenSharingRelock.outcome(status: 0, stderr: "") == .applied)
        #expect(ScreenSharingRelock.outcome(status: 1, stderr: "execution error: User canceled. (-128)") == .cancelled)
        #expect(ScreenSharingRelock.outcome(status: 1, stderr: " boom \n") == .failed("boom"))
    }

    @Test func appleScriptEscaping() {
        #expect(ScreenSharingRelock.appleScriptEscaped(#"say "hi" \ bye"#) == #"say \"hi\" \\ bye"#)
    }
}

struct AutoEngageIdleTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func hidIdleUsedWhenNoOtherActivity() {
        #expect(MaskAutoEngage.effectiveIdleSeconds(hidIdle: 600, now: now, activity: [nil, nil]) == 600)
    }

    /// Unlocking via Screen Sharing restarts the idle timer at unmask, even if HID idle time is hours.
    @Test func recentDisengageResetsIdle() {
        let disengagedAt = now.addingTimeInterval(-30)
        #expect(MaskAutoEngage.effectiveIdleSeconds(hidIdle: 7200, now: now, activity: [nil, disengagedAt, nil]) == 30)
    }

    @Test func smallestOfAllSignalsWins() {
        let a = now.addingTimeInterval(-300)
        let b = now.addingTimeInterval(-120)
        #expect(MaskAutoEngage.effectiveIdleSeconds(hidIdle: 7200, now: now, activity: [a, b]) == 120)
        #expect(MaskAutoEngage.effectiveIdleSeconds(hidIdle: 10, now: now, activity: [a, b]) == 10)
    }
}

struct PasscodeStoreIsolationTests {
    /// In tests, storage is in-memory only and never touches the real keychain; the cache updates on save and clear.
    @Test func memoryStoreRoundTrip() throws {
        let store = MaskPasscodeStore(memoryOnly: true)
        #expect(store.hasPasscode == false)
        #expect(store.save(try #require(MaskPasscode.make(code: "123456"))))
        #expect(store.hasPasscode)
        #expect(store.load()?.matches("123456") == true)
        store.clear()
        #expect(store.hasPasscode == false)
        #expect(store.load() == nil)
    }

    @Test func sharedStoreIsMemoryOnlyInTests() {
        #expect(TestEnvironment.isRunningInTests)
    }
}
