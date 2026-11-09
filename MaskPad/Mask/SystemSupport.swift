import AppKit
import IOKit.pwr_mgt

/// A `PreventUserIdleDisplaySleep` power assertion: while held, idle display sleep, system sleep,
/// and the screen-saver auto-lock don't trigger. `hold()` and `release()` are idempotent.
///
/// The mask (`MaskController`) and auto-mask standby (`MaskAutoEngage`) each hold their own.
@MainActor
final class SleepAssertion {
    private let name: String
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHeld = false

    init(name: String) {
        self.name = name
    }

    func hold() {
        guard isHeld == false else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &assertionID
        )
        isHeld = (result == kIOReturnSuccess)
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHeld = false
    }
}

extension NSScreen {
    /// The CoreGraphics display ID of this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen with the largest intersection with `rect`.
    static func best(for rect: NSRect) -> NSScreen? {
        screens.max { lhs, rhs in
            lhs.frame.intersection(rect).area < rhs.frame.intersection(rect).area
        }.flatMap { $0.frame.intersects(rect) ? $0 : nil } ?? main
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
