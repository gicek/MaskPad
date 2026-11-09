import Carbon.HIToolbox
import XCTest
@testable import MaskPad

@MainActor
final class KeyChordTests: XCTestCase {
    func testHotKeyNeedsCommandOptionOrControl() {
        XCTAssertNotNil(KeyChord(keyCode: UInt16(kVK_ANSI_L), modifiers: []).hotKeyProblem)
        XCTAssertNotNil(KeyChord(keyCode: UInt16(kVK_ANSI_L), modifiers: [.shift]).hotKeyProblem)
        XCTAssertNil(KeyChord(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control]).hotKeyProblem)
        XCTAssertNil(KeyChord(keyCode: UInt16(kVK_ANSI_L), modifiers: [.shift, .option]).hotKeyProblem)
    }

    func testModifierOrderFollowsMenuConvention() {
        let chord = KeyChord(keyCode: UInt16(kVK_F5), modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(chord.displayTokens, ["⌃", "⌥", "⇧", "⌘", "F5"])
    }

    func testCarbonModifierMask() {
        let chord = KeyChord(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .command])
        XCTAssertEqual(chord.carbonModifiers, UInt32(controlKey | cmdKey))
    }

    func testDefaultBindingIsControlCommandL() {
        let chord = MacHotKeyAction.engageMask.defaultChord
        XCTAssertEqual(chord.keyCode, UInt16(kVK_ANSI_L))
        XCTAssertEqual(chord.modifiers, [.control, .command])
    }

    func testCodableRoundTrip() throws {
        let chord = KeyChord(keyCode: 37, modifiers: [.control, .command])
        let decoded = try JSONDecoder().decode(KeyChord.self, from: JSONEncoder().encode(chord))
        XCTAssertEqual(decoded, chord)
    }
}
