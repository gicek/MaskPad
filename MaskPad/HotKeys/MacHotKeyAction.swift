import Carbon.HIToolbox
import Foundation

/// Actions that can be bound to a global hotkey.
///
/// Only "turn on mask": **engage only, never disengage**. Exiting requires the passcode; a hotkey exit would be a backdoor.
enum MacHotKeyAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case engageMask

    var id: String { rawValue }

    /// Shared by first launch and Restore Defaults; a cleared binding isn't refilled on relaunch.
    var defaultChord: KeyChord {
        switch self {
        case .engageMask: KeyChord(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .command])
        }
    }

    var title: String {
        switch self {
        case .engageMask: L("Turn on screen mask")
        }
    }
}
