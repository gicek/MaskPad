import Carbon.HIToolbox
import CoreGraphics

/// Physical keyboard input for the unlock keypad: digits 0–9 (top row and numpad) and Delete.
///
/// Recognized in the input tap and fed straight to the unlock state machine; **the event itself is
/// always swallowed**, since another app may have come to the front while masked and would receive it.
/// Shares the state machine (and throttling) with the on-screen keypad, so it's no faster for brute force.
enum MaskUnlockKey: Equatable {
    case digit(Character)
    case delete

    /// Digit key codes for the top row and numpad. Matched by key code, not character, so it's
    /// layout-independent (e.g. AZERTY needs Shift for top-row digits).
    private static let digitKeyCodes: [Int64: Character] = [
        Int64(kVK_ANSI_0): "0", Int64(kVK_ANSI_1): "1", Int64(kVK_ANSI_2): "2",
        Int64(kVK_ANSI_3): "3", Int64(kVK_ANSI_4): "4", Int64(kVK_ANSI_5): "5",
        Int64(kVK_ANSI_6): "6", Int64(kVK_ANSI_7): "7", Int64(kVK_ANSI_8): "8",
        Int64(kVK_ANSI_9): "9",
        Int64(kVK_ANSI_Keypad0): "0", Int64(kVK_ANSI_Keypad1): "1", Int64(kVK_ANSI_Keypad2): "2",
        Int64(kVK_ANSI_Keypad3): "3", Int64(kVK_ANSI_Keypad4): "4", Int64(kVK_ANSI_Keypad5): "5",
        Int64(kVK_ANSI_Keypad6): "6", Int64(kVK_ANSI_Keypad7): "7", Int64(kVK_ANSI_Keypad8): "8",
        Int64(kVK_ANSI_Keypad9): "9",
    ]

    /// Maps a keyDown to unlock-keypad input, or nil if it isn't one (it's swallowed either way).
    ///
    /// - Physical keys only (source PID 0), so other processes can't type for a local user.
    ///   This is a conservative filter, not hardware attestation.
    /// - Auto-repeat is ignored.
    /// - The keypress that wakes the display is ignored; the keypad isn't visible yet.
    /// - ⌘/⌃/⌥ combinations are shortcuts, not input; Shift, Caps Lock and the numpad flag are ignored.
    static func from(
        keyCode: Int64, flags: CGEventFlags, isRepeat: Bool, wokeScreen: Bool, sourcePID: Int64
    ) -> MaskUnlockKey? {
        guard sourcePID == 0, isRepeat == false, wokeScreen == false,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        else { return nil }
        if let digit = digitKeyCodes[keyCode] { return .digit(digit) }
        if keyCode == Int64(kVK_Delete) { return .delete }
        return nil
    }
}
