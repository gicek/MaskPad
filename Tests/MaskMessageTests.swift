import Foundation
import Testing
@testable import MaskPad

struct MaskMessageTests {
    @Test func cutsToTheCharacterLimit() {
        let long = String(repeating: "a", count: 200)
        #expect(MaskMessage.limited(long).count == MaskMessage.maxLength)
        #expect(MaskMessage.limited("short") == "short")
    }

    /// An emoji is one character, even when it's several code points (family, flags, skin tones).
    @Test func emojiCountAsOneCharacter() {
        let family = "👨‍👩‍👧‍👦"
        #expect(MaskMessage.limited(String(repeating: family, count: 130)).count == MaskMessage.maxLength)
        #expect(MaskMessage.limited("请勿操作 🙏🏻").count == 6)
    }

    @Test func keepsAtMostThreeLines() {
        #expect(MaskMessage.limited("one\ntwo\nthree\nfour\nfive") == "one\ntwo\nthree")
        #expect(MaskMessage.limited("one\ntwo") == "one\ntwo")
        // Typing Return at the end of the third line doesn't add a fourth.
        #expect(MaskMessage.limited("one\ntwo\nthree\n") == "one\ntwo\nthree")
    }

    @Test func displayedTrimsAndTreatsBlankAsNone() {
        #expect(MaskMessage.displayed("  AI 任务运行中 🤖 \n") == "AI 任务运行中 🤖")
        #expect(MaskMessage.displayed("") == nil)
        #expect(MaskMessage.displayed(" \n \n ") == nil)
    }
}

/// Serialized: the tests share one defaults domain, cleared before and after each. A fixed name, since
/// macOS keeps a (cleared) preferences file for every domain used.
@MainActor
@Suite(.serialized)
struct MaskSettingsMessageTests {
    private static let suiteName = "com.gicek.maskpad.tests.message"

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        body(defaults)
    }

    /// The message is kept within the limits as it's typed, and the limited text is what's stored
    /// (a didSet that assigns the property doesn't run again).
    @Test func storesTheLimitedMessage() {
        withDefaults { defaults in
            let settings = MaskSettings(defaults: defaults)
            settings.message = "one\ntwo\nthree\nfour"
            #expect(settings.message == "one\ntwo\nthree")
            #expect(defaults.string(forKey: "message") == "one\ntwo\nthree")
            #expect(MaskSettings(defaults: defaults).message == "one\ntwo\nthree")
        }
    }

    @Test func maskMessageNeedsTheSwitchAndText() {
        withDefaults { defaults in
            let settings = MaskSettings(defaults: defaults)
            settings.message = "  请勿操作 🙏 "
            #expect(settings.maskMessage == nil)
            settings.showsMessage = true
            #expect(settings.maskMessage == "请勿操作 🙏")
            settings.message = "   "
            #expect(settings.maskMessage == nil)
        }
    }
}
