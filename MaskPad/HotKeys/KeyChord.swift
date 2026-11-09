import AppKit
import Carbon.HIToolbox

/// Modifier set (only ⌃⌥⇧⌘).
struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8
    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
}

/// A recorded shortcut: virtual key code plus modifiers.
///
/// **Stores key codes, not symbol names**: hotkeys are registered with Carbon as-is, and a round trip
/// through names would silently lose unrecognized keys (keypad, `§`).
struct KeyChord: Codable, Hashable, Sendable {
    let keyCode: UInt16
    let modifiers: KeyModifiers

    init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds from a key event. Only the four modifiers count; Fn, Caps Lock, etc. are ignored.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var modifiers = KeyModifiers()
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// Display text such as `⌃⌘L`, with modifiers in the standard macOS menu order ⌃⌥⇧⌘.
    var displayText: String { displayTokens.joined() }

    /// Display tokens: one per modifier plus the key (which may be multi-character, e.g. `F1`).
    var displayTokens: [String] {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        return symbols + [KeyChordSymbol.keyText(for: keyCode)]
    }

    /// Modifier mask for Carbon `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    var hasModifier: Bool { modifiers.isEmpty == false }

    /// Global hotkeys need at least one of ⌘/⌥/⌃. A hotkey takes the chord system-wide, so a bare
    /// or ⇧-only key would fire while typing in any app.
    var hotKeyProblem: String? {
        modifiers.intersection([.command, .option, .control]).isEmpty
            ? L("A global shortcut needs at least one of Command, Option, or Control.")
            : nil
    }
}

/// Key glyphs: special keys come from a table, others are translated with the current keyboard layout.
enum KeyChordSymbol {
    private static let special: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤",
        kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Space: "␣",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func keyText(for keyCode: UInt16) -> String {
        if let mapped = special[Int(keyCode)] { return mapped }
        return translate(keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// Translates a key code to a character (unmodified) using the current ASCII-capable layout.
    private static func translate(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }
}

extension KeyModifiers {
    var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }
}

extension KeyChordSymbol {
    /// Menu keyEquivalent takes a single character; returns nil for keys like F-keys, so the menu shows none.
    static func menuKeyEquivalent(for keyCode: UInt16) -> String? {
        let text = keyText(for: keyCode)
        guard text.count == 1, let scalar = text.unicodeScalars.first, scalar.isASCII else { return nil }
        return text.lowercased()
    }
}
