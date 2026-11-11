import CoreGraphics
import Foundation

/// Hides the system cursor while the mask is dimmed (no arrow over a black screen). This class owns the
/// system hide count and keeps it balanced.
///
/// - Hiding from the background requires `SetsCursorInBackground` on the connection:
///   `CGDisplayHideCursor` otherwise only works for the frontmost app, and other tools may bring
///   another app forward while masked. Resolved dynamically via private SkyLight `SLSSetConnectionProperty`.
/// - The system re-shows the cursor on every frontmost-app change, so callers `reassert()` on
///   `didActivateApplication`; showing balances every hide call actually made.
@MainActor
final class MaskCursorHider {
    static let shared = MaskCursorHider()

    private(set) var isHidden = false
    private var backgroundControlEnabled = false
    /// Hide calls actually made on this connection; more than one after `reassert()`.
    /// Showing balances all of them (too few would leave the cursor hidden).
    private var hideCalls = 0
    /// Injected system calls, so tests don't hide the developer's cursor.
    private let hideCursor: () -> Void
    private let showCursor: () -> Void
    private let enableBackgroundCursorControl: () -> Void

    init(
        hideCursor: @escaping () -> Void = { CGDisplayHideCursor(CGMainDisplayID()) },
        showCursor: @escaping () -> Void = { CGDisplayShowCursor(CGMainDisplayID()) },
        enableBackgroundCursorControl: @escaping () -> Void = MaskCursorHider.setsCursorInBackground
    ) {
        self.hideCursor = hideCursor
        self.showCursor = showCursor
        self.enableBackgroundCursorControl = enableBackgroundCursorControl
    }

    func hide() {
        guard isHidden == false else { return }
        isHidden = true
        if backgroundControlEnabled == false {
            backgroundControlEnabled = true
            enableBackgroundCursorControl()
        }
        hideNow()
    }

    /// Re-hides after a frontmost-app change (the system shows the cursor on switch). No-op if not hidden.
    func reassert() {
        guard isHidden else { return }
        hideNow()
    }

    /// Shows the cursor again, undoing every hide call made. No-op if not hidden.
    func show() {
        guard isHidden else { return }
        isHidden = false
        for _ in 0 ..< hideCalls {
            showCursor()
        }
        hideCalls = 0
    }

    private func hideNow() {
        hideCursor()
        hideCalls += 1
    }

    nonisolated static func setsCursorInBackground() {
        guard let (connectionID, setProperty) = symbols else { return }
        let connection = connectionID()
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    private typealias ConnectionIDFn = @convention(c) () -> UInt32
    private typealias SetConnectionPropertyFn = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32

    private nonisolated static let symbols: (ConnectionIDFn, SetConnectionPropertyFn)? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
        guard let handle = dlopen(nil, RTLD_LAZY),
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let setProperty = dlsym(handle, "SLSSetConnectionProperty")
        else {
            return nil
        }
        return (
            unsafeBitCast(connection, to: ConnectionIDFn.self),
            unsafeBitCast(setProperty, to: SetConnectionPropertyFn.self)
        )
    }()
}
