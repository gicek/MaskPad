import Foundation

/// The optional message on the mask: shown large before the keypad, with an Unlock button that leads to
/// the keypad (see `MaskUnlockViewModel`). Set in Settings; text and emoji.
enum MaskMessage {
    /// Characters as people count them: an emoji, even one made of several code points, is one.
    static let maxLength = 120
    static let maxLines = 3

    /// `text` cut to `maxLines` lines and `maxLength` characters, for the settings field as it's typed.
    static func limited(_ text: String) -> String {
        let lines = text.split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false)
        return String(lines.prefix(maxLines).joined(separator: "\n").prefix(maxLength))
    }

    /// The text to show, or nil if there's nothing to show (empty or only whitespace).
    static func displayed(_ text: String) -> String? {
        let trimmed = limited(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
