import XCTest
@testable import MaskPad

@MainActor
final class MaskUnlockViewModelTests: XCTestCase {
    private func makeModel(
        onLockSystem: @escaping () -> Void = {}, onUnlock: @escaping () -> Void = {}
    ) -> MaskUnlockViewModel {
        MaskUnlockViewModel(onLockSystem: onLockSystem, verify: { $0 == "123456" }, onUnlock: onUnlock)
    }

    func testStartsOnKeypadAndTogglesPages() {
        let model = makeModel()
        XCTAssertEqual(model.page, .keypad)
        model.showForgotPasscode()
        XCTAssertEqual(model.page, .forgotPasscode)
        model.showKeypad()
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
