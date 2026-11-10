import CoreGraphics

/// Pass/swallow decisions for the mask's input tap (pure logic, testable). The tap callback in
/// `MaskInputBlocker` only converts CGEvents to `Event`, applies the verdict, and runs side effects on the main thread.
///
/// Rules:
/// - Keys still held when the mask engages (e.g. the hotkey's main key) get one physical keyUp through (see `MaskController.engage()`).
/// - While the display is asleep, the first local input only wakes it and is swallowed (except pointer moves);
///   a swallowed left mouse-down also swallows its drags and mouse-up.
/// - Physical digit and Delete keys go to the unlock keypad; the event itself is swallowed.
/// - Otherwise only pointer moves and left clicks (for the keypad) pass; everything else is swallowed.
/// - Pointer moves and left drags into a screen corner are moved out of it, so hot corners can't fire
///   (see `HotCornerGuard`).
struct MaskTapPolicy {
    struct Event {
        var type: CGEventType
        var keyCode: Int64 = 0
        var flags: CGEventFlags = []
        var isRepeat = false
        var sourcePID: Int64 = 0
        var location: CGPoint = .zero
        /// NX_SYSDEFINED subtype 8 (brightness, volume, media keys); counts as a user keypress.
        var isAuxControlButton = false
    }

    enum Verdict: Equatable {
        case pass
        /// Pass, with the event's location changed to this point.
        case passAt(CGPoint)
        case swallow
        /// Swallow and forward the key to the unlock keypad.
        case unlockKey(MaskUnlockKey)
    }

    /// Keys held when the mask engaged; each gets one physical keyUp through.
    var releasePassThroughKeys: Set<Int64> = []
    /// A wake swallowed a left mouse-down; also swallow its drags and mouse-up to avoid a half click.
    var swallowingWakeClick = false
    /// Display bounds for keeping the pointer out of the corners; set by the controller.
    var hotCornerGuard = HotCornerGuard()

    /// Events normally allowed: pointer moves and left button down/up/drag.
    static let allowedTypes: Set<CGEventType> = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged]

    /// Local events that wake the display. Up events are excluded since the down already woke it;
    /// system-defined keys are checked by subtype separately.
    static let wakeTypes: Set<CGEventType> = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .scrollWheel, .keyDown, .flagsChanged,
    ]

    /// - Parameters:
    ///   - acceptsUnlockKeys: Whether the unlock keypad accepts physical keyboard input.
    ///   - wake: Local-activity callback (auto-dimming); returns true if this event woke the display.
    mutating func decide(_ event: Event, acceptsUnlockKeys: Bool, wake: () -> Bool) -> Verdict {
        if event.type == .keyUp, event.sourcePID == 0,
           releasePassThroughKeys.remove(event.keyCode) != nil {
            return .pass
        }
        if swallowingWakeClick {
            if event.type == .leftMouseUp { swallowingWakeClick = false }
            if event.type == .leftMouseUp || event.type == .leftMouseDragged { return .swallow }
        }
        let isWakeEvent = Self.wakeTypes.contains(event.type) || event.isAuxControlButton
        let wokeScreen = isWakeEvent && wake()
        if wokeScreen {
            if event.type == .leftMouseDown { swallowingWakeClick = true }
            if event.type != .mouseMoved { return .swallow }
        }
        if event.type == .keyDown, acceptsUnlockKeys,
           let key = MaskUnlockKey.from(
               keyCode: event.keyCode, flags: event.flags, isRepeat: event.isRepeat,
               wokeScreen: wokeScreen, sourcePID: event.sourcePID
           ) {
            return .unlockKey(key)
        }
        guard Self.allowedTypes.contains(event.type) else { return .swallow }
        if event.type == .mouseMoved || event.type == .leftMouseDragged,
           let location = hotCornerGuard.adjusted(event.location) {
            return .passAt(location)
        }
        return .pass
    }
}
