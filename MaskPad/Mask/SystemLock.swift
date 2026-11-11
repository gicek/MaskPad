import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Locks the screen immediately.
///
/// The escape hatch for a forgotten passcode: after logging back in with the Mac password the mask
/// is dismissed (a self-initiated lock, see `SystemLockTracker`) and the passcode can be reset in Settings.
/// ⌃⌘Q on the keyboard is blocked while masked; locking is only possible from the "Forgot passcode" button.
enum SystemLock {
    /// Prefers the private `SACLockScreenImmediate` (login.framework), which ignores a customized
    /// lock shortcut and the "require password after N minutes" setting. Falls back to a tagged
    /// synthetic ⌃⌘Q (so it passes the mask's input tap) if the symbol is missing or the call fails.
    static func lockNow() {
        if let lock = lockScreenImmediate, lock() == 0 { return }
        postLockShortcut()
    }

    private typealias LockFn = @convention(c) () -> Int32

    private static let lockScreenImmediate: LockFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockFn.self)
    }()

    /// Synthesizes ⌃⌘Q. Fallback only; has no effect if the user remapped the lock shortcut.
    private static func postLockShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: keyDown) else { continue }
            event.flags = [.maskControl, .maskCommand]
            event.postTagged(tap: .cghidEventTap)
        }
    }
}
