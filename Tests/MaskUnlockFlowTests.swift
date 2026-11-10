import Foundation
import Testing
@testable import MaskPad

struct MaskUnlockFlowTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func firstPage() {
        #expect(MaskUnlockFlow(hasMessage: true, now: t0).page == .message)
        #expect(MaskUnlockFlow(hasMessage: false, now: t0).page == .keypad)
    }

    @Test func forwardAndBack() {
        var flow = MaskUnlockFlow(hasMessage: true, now: t0)
        flow.unlock(now: at(1))
        #expect(flow.page == .keypad)
        flow.showForgotPasscode(now: at(2))
        #expect(flow.page == .forgotPasscode)
        flow.back(now: at(3))
        #expect(flow.page == .keypad)
    }

    /// Each move works only from its own page, so a click on a page that's fading out does nothing.
    @Test func movesOnlyFromTheirOwnPage() {
        var flow = MaskUnlockFlow(hasMessage: true, now: t0)
        flow.showForgotPasscode(now: at(1))   // From the message: no
        #expect(flow.page == .message)
        flow.back(now: at(1))                 // From the message: no
        #expect(flow.page == .message)

        flow.unlock(now: at(2))
        flow.unlock(now: at(3))               // Already past the message
        #expect(flow.page == .keypad)
        flow.back(now: at(3))                 // From the keypad: no
        #expect(flow.page == .keypad)

        flow.showForgotPasscode(now: at(4))
        flow.unlock(now: at(5))               // From "Forgot Passcode": no
        #expect(flow.page == .forgotPasscode)
    }

    // `#expect` can't call mutating methods, so results are taken first.

    @Test func inputCountsOnlyPastTheMessage() {
        var flow = MaskUnlockFlow(hasMessage: true, now: t0)
        let onMessage = flow.input(now: at(1))
        #expect(onMessage == false)
        #expect(flow.page == .message)

        flow.unlock(now: at(2))
        let onKeypad = flow.input(now: at(3))
        #expect(onKeypad)

        // On "Forgot Passcode", input counts and shows the keypad.
        flow.showForgotPasscode(now: at(4))
        let onForgot = flow.input(now: at(5))
        #expect(onForgot)
        #expect(flow.page == .keypad)
    }

    @Test func restartsAfterIdleOnlyOncePerDelay() {
        var flow = MaskUnlockFlow(hasMessage: true, now: t0)
        flow.unlock(now: at(0))
        let early = flow.restartIfIdle(now: at(MaskUnlockFlow.returnDelay - 1))
        #expect(early == false)
        #expect(flow.page == .keypad)

        let due = flow.restartIfIdle(now: at(MaskUnlockFlow.returnDelay))
        #expect(due)
        #expect(flow.page == .message)

        // The restart counts as the last move: no second restart a second later.
        let again = flow.restartIfIdle(now: at(MaskUnlockFlow.returnDelay + 1))
        #expect(again == false)
    }

    @Test func inputAndMovesRestartTheWait() {
        var flow = MaskUnlockFlow(hasMessage: true, now: t0)
        flow.unlock(now: at(0))
        _ = flow.input(now: at(20))
        let afterInput = flow.restartIfIdle(now: at(40))
        #expect(afterInput == false)

        flow.showForgotPasscode(now: at(45))
        let afterMove = flow.restartIfIdle(now: at(70))
        #expect(afterMove == false)
        let idle = flow.restartIfIdle(now: at(75))
        #expect(idle)
        #expect(flow.page == .message)
    }

    @Test func restartGoesToTheFirstPage() {
        var withMessage = MaskUnlockFlow(hasMessage: true, now: t0)
        withMessage.unlock(now: at(1))
        withMessage.showForgotPasscode(now: at(2))
        withMessage.restart(now: at(3))
        #expect(withMessage.page == .message)

        var without = MaskUnlockFlow(hasMessage: false, now: t0)
        without.showForgotPasscode(now: at(1))
        without.restart(now: at(2))
        #expect(without.page == .keypad)
    }
}
