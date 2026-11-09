import AppKit
import CoreGraphics

/// Blocks local input while masked: an active HID-level event tap that swallows everything except
/// pointer moves and the left button, including keys, modifiers (system shortcuts like ⌃⌘Q),
/// system-defined keys (NX_SYSDEFINED: brightness, volume, power short press; blocking only
/// keyDown/keyUp misses these), right/middle clicks, scrolling, and gestures.
/// Digits 0–9 and Delete are forwarded to the unlock keypad (`MaskUnlockKey`) but still swallowed.
/// Events tagged with `InjectedEventTag` always pass. Locking for a forgotten passcode goes through
/// the "Forgot passcode" button (`SystemLock`), never a keyboard shortcut.
///
/// An HID tap only sees physical input and events posted to the HID level; Computer Use tools that
/// post per process (`postToPid`) or at the session level are unaffected.
///
/// Holding the power button forces a hardware shutdown no software can block; that's the last-resort
/// recovery. Mask state isn't persisted, so a restart clears it and the login password still protects the Mac.
///
/// The tap is re-enabled if the system disables it (timeout or permission change). If creation fails,
/// `start()` returns false and the caller **must not** engage: a screen mask without keyboard blocking is worse than none.
///
/// `@unchecked Sendable`: the C callback recovers the instance via refcon, which Swift 6 region
/// analysis can't reason about (a closure even crashes the compiler). In practice start/stop run on the
/// main thread and the callback only reads `tap`.
final class MaskInputBlocker: @unchecked Sendable {
    fileprivate var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Local activity callback (move, click, scroll, key) for waking from auto-dim. Returns true if
    /// this event woke the display; that event is only used to wake and is swallowed. Called on the
    /// main run loop. The caller clears it (`MaskController.disengage()`).
    fileprivate var onLocalActivity: (() -> Bool)?

    /// Physical keyboard unlock input (digits and Delete). Set and cleared by `MaskController`.
    fileprivate var onUnlockKey: ((MaskUnlockKey) -> Void)?

    /// Pass/swallow state and rules (see `MaskTapPolicy`).
    fileprivate var policy = MaskTapPolicy()

    /// Keys still held when the mask engages; set by the controller before `start()`.
    var releasePassThroughKeys: Set<Int64> {
        get { policy.releasePassThroughKeys }
        set { policy.releasePassThroughKeys = newValue }
    }

    func setUnlockKeyHandler(_ handler: ((MaskUnlockKey) -> Void)?) {
        onUnlockKey = handler
    }

    var isActive: Bool { tap != nil }

    func setLocalActivityHandler(_ handler: (() -> Bool)?) {
        onLocalActivity = handler
        policy.swallowingWakeClick = false
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            // All event types, including system-defined (14) and gestures (29+). Enumerating types
            // would miss private ones; a full mask plus an allowlist is safer.
            eventsOfInterest: CGEventMask.max,
            callback: maskTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Must also `CFMachPortInvalidate`: a merely disabled tap stays registered (visible in
    /// `CGGetEventTapList`), leaking one per mask cycle.
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        policy = MaskTapPolicy()
    }
}

/// Tap callback. A file-level function rather than a closure, since Swift 6 region analysis crashes
/// on closures capturing Unmanaged. Rules live in `MaskTapPolicy`; this only converts events and applies verdicts.
private func maskTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let blocker = Unmanaged<MaskInputBlocker>.fromOpaque(refcon).takeUnretainedValue()
    // Disabled by timeout or permission change: re-enable immediately so no input slips through.
    // These are notifications only; pass them unchanged.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = blocker.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // MaskPad's own synthetic events always pass and don't count as local activity.
    if InjectedEventTag.isMarked(event) {
        return Unmanaged.passUnretained(event)
    }
    let tapEvent = MaskTapPolicy.Event(
        type: type,
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        flags: event.flags,
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
        // NX_SYSDEFINED (14) counts as a user keypress only for subtype 8 (brightness, volume, media);
        // other subtypes may come from the system and must not wake the display.
        isAuxControlButton: type.rawValue == 14 && NSEvent(cgEvent: event)?.subtype.rawValue == 8
    )
    let verdict = blocker.policy.decide(
        tapEvent,
        acceptsUnlockKeys: blocker.onUnlockKey != nil,
        wake: { blocker.onLocalActivity?() == true }
    )
    switch verdict {
    case .pass:
        return Unmanaged.passUnretained(event)
    case .swallow:
        return nil
    case .unlockKey(let key):
        blocker.onUnlockKey?(key)
        return nil
    }
}
