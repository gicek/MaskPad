import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import MaskPad

struct MaskUnlockKeyTests {
    private func key(
        _ code: Int, flags: CGEventFlags = [], isRepeat: Bool = false,
        wokeScreen: Bool = false, pid: Int64 = 0
    ) -> MaskUnlockKey? {
        MaskUnlockKey.from(keyCode: Int64(code), flags: flags, isRepeat: isRepeat,
                           wokeScreen: wokeScreen, sourcePID: pid)
    }

    @Test func topRowAndKeypadDigitsMap() {
        #expect(key(kVK_ANSI_0) == .digit("0"))
        #expect(key(kVK_ANSI_5) == .digit("5"))
        #expect(key(kVK_ANSI_9) == .digit("9"))
        #expect(key(kVK_ANSI_Keypad0) == .digit("0"))
        #expect(key(kVK_ANSI_Keypad7) == .digit("7"))
    }

    @Test func backspaceDeletes() {
        #expect(key(kVK_Delete) == .delete)
        #expect(key(kVK_ForwardDelete) == nil)
    }

    @Test func otherKeysIgnored() {
        #expect(key(kVK_ANSI_A) == nil)
        #expect(key(kVK_ANSI_Q) == nil)
        #expect(key(kVK_Return) == nil)
        #expect(key(kVK_Escape) == nil)
    }

    /// Shift and Caps Lock are ignored (AZERTY needs Shift for top-row digits); the numeric-pad flag is ignored.
    @Test func shiftCapsLockAndNumericPadFlagsAllowed() {
        #expect(key(kVK_ANSI_1, flags: .maskShift) == .digit("1"))
        #expect(key(kVK_ANSI_1, flags: .maskAlphaShift) == .digit("1"))
        #expect(key(kVK_ANSI_Keypad1, flags: .maskNumericPad) == .digit("1"))
    }

    @Test func commandControlOptionCombosAreNotInput() {
        #expect(key(kVK_ANSI_1, flags: .maskCommand) == nil)
        #expect(key(kVK_ANSI_1, flags: .maskControl) == nil)
        #expect(key(kVK_ANSI_1, flags: .maskAlternate) == nil)
        #expect(key(kVK_Delete, flags: .maskCommand) == nil)
    }

    @Test func repeatsWakePressAndSyntheticEventsIgnored() {
        #expect(key(kVK_ANSI_1, isRepeat: true) == nil)
        #expect(key(kVK_Delete, isRepeat: true) == nil)
        #expect(key(kVK_ANSI_1, wokeScreen: true) == nil)
        #expect(key(kVK_ANSI_1, pid: 4242) == nil)
    }
}
