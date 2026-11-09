import CoreGraphics
import Testing
@testable import MaskPad

@MainActor
struct MaskHeldKeysTests {
    /// Hotkey ⌃⌘L: L (37) gets its physical key-up passed through; modifiers get synthesized key-ups from the flags.
    @Test func hotKeyChordSplitsMainKeyAndModifiers() {
        #expect(MaskController.heldMainKeys(isKeyDown: { [37, 55, 59].contains($0) }) == [37])
        #expect(MaskController.modifierKeysToRelease(heldFlags: [.maskControl, .maskCommand]) == [55, 54, 59, 62])
    }

    @Test func nothingHeld() {
        #expect(MaskController.heldMainKeys(isKeyDown: { _ in false }).isEmpty)
        #expect(MaskController.modifierKeysToRelease(heldFlags: []).isEmpty)
    }

    /// Modifiers and Caps Lock are excluded from regular keys; Caps Lock gets no synthesized key-up.
    @Test func modifiersAndCapsLockExcludedFromMainKeys() {
        #expect(MaskController.heldMainKeys(isKeyDown: { (54...63).contains($0) }).isEmpty)
        #expect(MaskController.modifierKeysToRelease(heldFlags: [.maskAlphaShift]).isEmpty)
    }

    @Test func multipleHeldMainKeys() {
        #expect(MaskController.heldMainKeys(isKeyDown: { [0, 37, 100].contains($0) }) == [0, 37, 100])
    }

    /// Custom shortcut (e.g. ⌥⇧F5): F5 (96) is allowlisted and ⌥⇧ are reset via synthesized events.
    @Test func customShortcutIsHandledTheSameWay() {
        #expect(MaskController.heldMainKeys(isKeyDown: { [96, 58, 56].contains($0) }) == [96])
        #expect(MaskController.modifierKeysToRelease(heldFlags: [.maskAlternate, .maskShift]) == [58, 61, 56, 60])
    }
}
