import AppKit
import Darwin

/// Decides whether a press on one of the mask's buttons came from a person: a click of a real mouse or
/// trackpad, a tap on a touch screen, or a click through macOS Screen Sharing (how a remote user unlocks).
///
/// Everything else is ignored, because the mask covers a Mac that background tools keep using: Computer
/// Use agents and automation can click (synthetic events at the HID level, or events posted straight to
/// MaskPad's window) and press buttons through the Accessibility API. Their presses must not enter digits
/// (wrong attempts start the cooldown and lock the user out) or press "Unlock with Mac Password", which
/// locks the Mac and interrupts what runs under the mask. Physical digit keys are checked separately, in
/// the input tap (`MaskUnlockKey`).
///
/// - A press is accepted only while handling a left mouse event or a direct touch (a finger on a touch
///   screen, `NSEvent.EventType.directTouch`): Accessibility presses and keyboard activation of a focused
///   button (Space) have no such event.
/// - A click's source process ID must be 0 (hardware) or a Screen Sharing process, one of the system
///   executables in /System/Library/CoreServices/RemoteManagement. A touch must come from hardware.
///
/// The source process ID is set by the window server for posted events, so this is a strong filter, not
/// hardware attestation.
enum MaskInputOrigin {
    private static let screenSharingDirectory = "/System/Library/CoreServices/RemoteManagement/"

    /// Whether the event AppKit is handling now is a person's click or touch.
    @MainActor
    static func currentEventIsPersonPress() -> Bool {
        let event = NSApp.currentEvent
        let sourcePID = event?.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        let allowed = isPersonPress(type: event?.type, sourcePID: sourcePID, processPath: processPath)
        if allowed == false {
            // Which tool is pressing the mask's buttons; never the key or digit pressed.
            let eventType = event.map { String($0.type.rawValue) } ?? "none"
            let source = processPath(Int32(clamping: sourcePID)) ?? String(sourcePID)
            Log.mask.notice("ignored a mask button press: event type \(eventType, privacy: .public), source \(source, privacy: .public)")
        }
        return allowed
    }

    /// Pure rule, for tests. `processPath` maps a process ID to its executable path.
    static func isPersonPress(
        type: NSEvent.EventType?, sourcePID: Int64, processPath: (Int32) -> String?
    ) -> Bool {
        if type == .directTouch { return sourcePID == 0 }
        guard type == .leftMouseUp || type == .leftMouseDown else { return false }
        if sourcePID == 0 { return true }
        guard sourcePID > 0, sourcePID <= Int64(Int32.max),
              let path = processPath(Int32(sourcePID))
        else { return false }
        return path.hasPrefix(screenSharingDirectory)
    }

    static func processPath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
