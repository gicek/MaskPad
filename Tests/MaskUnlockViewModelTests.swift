import Foundation
import XCTest
@testable import MaskPad

@MainActor
final class MaskUnlockViewModelTests: XCTestCase {
    private func makeModel(
        message: String? = nil, onLockSystem: @escaping () -> Void = {}, onUnlock: @escaping () -> Void = {}
    ) -> MaskUnlockViewModel {
        let model = MaskUnlockViewModel(
            message: message, onLockSystem: onLockSystem, verify: { $0 == "123456" }, onUnlock: onUnlock
        )
        addTeardownBlock { model.stopTimers() }
        return model
    }

    // MARK: - Message page

    func testStartsOnMessageWhenSet() {
        XCTAssertEqual(makeModel(message: "AI task running 🤖").page, .message)
        XCTAssertEqual(makeModel().page, .keypad)
    }

    /// On the message page, only Unlock leads on: physical digit and Delete keys are ignored.
    func testKeyboardIsIgnoredOnMessagePage() {
        let model = makeModel(message: "Hi")
        model.tap(digit: "1")
        model.deleteDigit()
        XCTAssertEqual(model.page, .message)
        XCTAssertEqual(model.enteredCount, 0)

        model.unlock()
        model.tap(digit: "1")
        XCTAssertEqual(model.page, .keypad)
        XCTAssertEqual(model.enteredCount, 1)
    }

    /// Without a message the keyboard works from the start, as before.
    func testKeyboardWorksWithoutMessage() {
        let model = makeModel()
        model.tap(digit: "1")
        XCTAssertEqual(model.enteredCount, 1)
    }

    func testReturnsToMessageAfterIdleAndClearsDigits() {
        let model = makeModel(message: "Hi")
        let start = Date()
        model.unlock()
        model.tap(digit: "1")
        model.restartIfIdle(now: start.addingTimeInterval(MaskUnlockFlow.returnDelay - 5))
        XCTAssertEqual(model.page, .keypad)
        model.restartIfIdle(now: Date().addingTimeInterval(MaskUnlockFlow.returnDelay + 1))
        XCTAssertEqual(model.page, .message)
        XCTAssertEqual(model.enteredCount, 0)
    }

    /// Each input restarts the wait, on the keypad and on the "Forgot passcode" page.
    func testInputRestartsTheWait() {
        let model = makeModel(message: "Hi")
        model.unlock()
        model.showForgotPasscode()
        model.restartIfIdle(now: Date().addingTimeInterval(MaskUnlockFlow.returnDelay - 1))
        XCTAssertEqual(model.page, .forgotPasscode)
        model.restartIfIdle(now: Date().addingTimeInterval(MaskUnlockFlow.returnDelay + 1))
        XCTAssertEqual(model.page, .message)
    }

    /// Without a message the first page is the keypad: idle input is cleared, and "Forgot Passcode"
    /// goes back to the keypad too.
    func testIdleReturnWithoutMessage() {
        let model = makeModel()
        model.tap(digit: "1")
        model.restartIfIdle(now: Date().addingTimeInterval(MaskUnlockFlow.returnDelay - 1))
        XCTAssertEqual(model.enteredCount, 1)
        model.restartIfIdle(now: Date().addingTimeInterval(MaskUnlockFlow.returnDelay + 1))
        XCTAssertEqual(model.page, .keypad)
        XCTAssertEqual(model.enteredCount, 0)

        model.showForgotPasscode()
        model.restartIfIdle(now: Date().addingTimeInterval(MaskUnlockFlow.returnDelay + 1))
        XCTAssertEqual(model.page, .keypad)
    }

    /// Waking from dimming shows the first page with the digits cleared.
    func testStartPage() {
        let withMessage = makeModel(message: "Hi")
        withMessage.unlock()
        withMessage.tap(digit: "1")
        withMessage.showStartPage()
        XCTAssertEqual(withMessage.page, .message)
        XCTAssertEqual(withMessage.enteredCount, 0)

        let without = makeModel()
        without.showForgotPasscode()
        without.showStartPage()
        XCTAssertEqual(without.page, .keypad)
    }

    /// Clearing the entry keeps the failure count and cooldown.
    func testStartPageKeepsCooldown() {
        let model = makeModel(message: "Hi")
        model.unlock()
        for _ in 0 ..< MaskUnlockState.maxAttempts {
            for digit in "000000" { model.tap(digit: digit) }
        }
        XCTAssertNotNil(model.cooldownRemaining)
        model.showStartPage()
        XCTAssertNotNil(model.cooldownRemaining)
        XCTAssertTrue(model.state.isThrottled(at: Date()))
    }

    // MARK: - Touch ID

    /// Touch ID waits for a finger only while the keypad shows: the model reports each time the keypad
    /// comes up or goes away, and nothing for the page it starts on or for input on the keypad.
    func testReportsWhenTheKeypadShows() {
        var reports: [Bool] = []
        let model = MaskUnlockViewModel(
            message: "Hi", onLockSystem: {}, verify: { $0 == "123456" }, onUnlock: {},
            onKeypadShown: { reports.append($0) }
        )
        addTeardownBlock { model.stopTimers() }
        XCTAssertEqual(reports, [])

        model.unlock()
        XCTAssertEqual(reports, [true])
        model.tap(digit: "1")
        model.deleteDigit()
        XCTAssertEqual(reports, [true])

        model.showForgotPasscode()
        XCTAssertEqual(reports, [true, false])
        // A digit typed on "Forgot Passcode" switches back to the keypad.
        model.tap(digit: "1")
        XCTAssertEqual(reports, [true, false, true])

        model.showStartPage()
        XCTAssertEqual(reports, [true, false, true, false])
    }

    /// Without a message the keypad stays up through an idle restart: no report, Touch ID keeps waiting.
    func testIdleRestartOnKeypadReportsNothing() {
        var reports: [Bool] = []
        let model = MaskUnlockViewModel(
            onLockSystem: {}, verify: { $0 == "123456" }, onUnlock: {}, onKeypadShown: { reports.append($0) }
        )
        addTeardownBlock { model.stopTimers() }
        model.restartIfIdle(now: Date().addingTimeInterval(MaskUnlockFlow.returnDelay + 1))
        model.showStartPage()
        XCTAssertEqual(reports, [])
    }

    // MARK: - Keypad

    func testStartsOnKeypadAndTogglesPages() {
        let model = makeModel()
        XCTAssertEqual(model.page, .keypad)
        model.showForgotPasscode()
        XCTAssertEqual(model.page, .forgotPasscode)
        model.back()
        XCTAssertEqual(model.page, .keypad)
    }

    /// Typing digits on the physical keyboard from the "Forgot passcode" page enters them and flips back to the keypad.
    func testTypingDigitOnHelpPageReturnsToKeypadAndKeepsDigit() {
        let model = makeModel()
        model.showForgotPasscode()
        model.tap(digit: "1")
        XCTAssertEqual(model.page, .keypad)
        XCTAssertEqual(model.enteredCount, 1)
    }

    func testDeleteOnHelpPageReturnsToKeypad() {
        let model = makeModel()
        model.tap(digit: "1")
        model.showForgotPasscode()
        model.deleteDigit()
        XCTAssertEqual(model.page, .keypad)
        XCTAssertEqual(model.enteredCount, 0)
    }

    func testCorrectCodeUnlocks() {
        var unlocked = false
        let model = makeModel(onUnlock: { unlocked = true })
        "123456".forEach { model.tap(digit: $0) }
        XCTAssertTrue(unlocked)
    }

    func testLockButtonCallsSystemLock() {
        var locked = 0
        let model = makeModel(onLockSystem: { locked += 1 })
        model.showForgotPasscode()
        model.lockSystem()
        XCTAssertEqual(locked, 1)
    }
}
