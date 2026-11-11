import XCTest
@testable import MaskPad

final class MaskUnlockStateTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    /// Enters digits one by one and returns the last result.
    private func type(
        _ code: String, into state: inout MaskUnlockState,
        now: Date, verify: (String) -> Bool
    ) -> MaskUnlockState.Outcome {
        var outcome = MaskUnlockState.Outcome.pending
        for digit in code {
            outcome = state.appendDigit(digit, now: now, verify: verify)
        }
        return outcome
    }

    func testPendingUntilSixDigitsThenUnlocks() {
        var state = MaskUnlockState()
        for digit in "12345" {
            XCTAssertEqual(state.appendDigit(digit, now: epoch) { _ in true }, .pending)
        }
        XCTAssertEqual(state.entered.count, 5)
        XCTAssertEqual(state.appendDigit("6", now: epoch) { $0 == "123456" }, .unlocked)
        XCTAssertTrue(state.entered.isEmpty)
    }

    func testRejectionClearsEntryAndCounts() {
        var state = MaskUnlockState()
        XCTAssertEqual(type("000000", into: &state, now: epoch) { _ in false }, .rejected)
        XCTAssertTrue(state.entered.isEmpty)
        XCTAssertEqual(state.failedAttempts, 1)
        XCTAssertFalse(state.isThrottled(at: epoch))
    }

    func testFiveFailuresStartCooldownAndInputIsIgnored() {
        var state = MaskUnlockState()
        for _ in 0..<MaskUnlockState.maxAttempts {
            _ = type("000000", into: &state, now: epoch) { _ in false }
        }
        XCTAssertTrue(state.isThrottled(at: epoch))
        XCTAssertEqual(state.appendDigit("1", now: epoch) { _ in true }, .throttled)
        XCTAssertTrue(state.entered.isEmpty)
    }

    func testCooldownExpiryResetsAttempts() {
        var state = MaskUnlockState()
        for _ in 0..<MaskUnlockState.maxAttempts {
            _ = type("000000", into: &state, now: epoch) { _ in false }
        }
        let later = epoch.addingTimeInterval(MaskUnlockState.cooldown + 1)
        XCTAssertFalse(state.isThrottled(at: later))
        XCTAssertEqual(type("123456", into: &state, now: later) { $0 == "123456" }, .unlocked)
        XCTAssertEqual(state.failedAttempts, 0)
    }

    func testDeleteDigitAndNonDigitInput() {
        var state = MaskUnlockState()
        _ = state.appendDigit("1", now: epoch) { _ in false }
        _ = state.appendDigit("a", now: epoch) { _ in false }
        XCTAssertEqual(state.entered, "1")
        state.deleteDigit()
        XCTAssertTrue(state.entered.isEmpty)
        state.deleteDigit()
        XCTAssertTrue(state.entered.isEmpty)
    }

    /// The total keeps counting across cooldowns and correct entry of digits, for the notice on the keypad.
    func testTotalFailedAttemptsIsNeverReset() {
        var state = MaskUnlockState()
        for _ in 0 ..< MaskUnlockState.maxAttempts {
            XCTAssertEqual(type("000000", into: &state, now: epoch) { _ in false }, .rejected)
        }
        XCTAssertEqual(state.totalFailedAttempts, MaskUnlockState.maxAttempts)
        // Ignored while cooling down.
        XCTAssertEqual(type("000000", into: &state, now: epoch) { _ in false }, .throttled)
        XCTAssertEqual(state.totalFailedAttempts, MaskUnlockState.maxAttempts)
        // After the cooldown the per-round count starts over; the total goes on.
        let later = epoch.addingTimeInterval(MaskUnlockState.cooldown + 1)
        XCTAssertEqual(type("000000", into: &state, now: later) { _ in false }, .rejected)
        XCTAssertEqual(state.failedAttempts, 1)
        XCTAssertEqual(state.totalFailedAttempts, MaskUnlockState.maxAttempts + 1)
        state.clearEntry()
        XCTAssertEqual(state.totalFailedAttempts, MaskUnlockState.maxAttempts + 1)
    }
}
