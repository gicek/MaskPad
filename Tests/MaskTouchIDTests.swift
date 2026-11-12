import Foundation
import LocalAuthentication
import Testing
@testable import MaskPad

/// The rules only; no test asks the system for Touch ID.
@MainActor
struct MaskTouchIDTests {
    private static let suiteName = "com.gicek.maskpad.tests.touchid"

    @Test func waitsAgainAfterUnrecognizedFingersOrASystemInterruption() {
        #expect(MaskTouchID.next(afterFailure: LAError.Code.authenticationFailed.rawValue) == .retry)
        #expect(MaskTouchID.next(afterFailure: LAError.Code.systemCancel.rawValue) == .retry)
    }

    /// Its own cancel, Touch ID locked or unavailable, and unknown errors don't start another wait.
    @Test func stopsOnEverythingElse() {
        let codes: [LAError.Code] = [
            .appCancel, .userCancel, .userFallback, .biometryLockout, .biometryNotAvailable,
            .biometryNotEnrolled, .notInteractive, .invalidContext, .passcodeNotSet,
        ]
        for code in codes {
            #expect(MaskTouchID.next(afterFailure: code.rawValue) == .stop)
        }
        #expect(MaskTouchID.next(afterFailure: nil) == .stop)
        #expect(MaskTouchID.next(afterFailure: 12345) == .stop)
    }

    /// Off in Settings: the session never prepares a wait, so the keypad shows no Touch ID.
    @Test func disabledSessionNeverWaits() {
        let session = MaskTouchIDSession(isEnabled: false) {}
        session.start()
        #expect(session.context == nil)
        session.stop()
    }

    @Test func settingIsOnByDefaultAndStored() {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }

        let settings = MaskSettings(defaults: defaults)
        #expect(settings.touchIDUnlock)
        settings.touchIDUnlock = false
        #expect(MaskSettings(defaults: defaults).touchIDUnlock == false)
    }
}
