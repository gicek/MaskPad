import CoreGraphics
import Foundation

/// Hides the system cursor while masked, tracked per reason: `dimmed` (no arrow over a black screen)
/// and `remoteInput` (while another tool drives the real cursor).
/// Hidden while any reason is active; this class owns the system hide count and keeps it balanced.
///
/// - Hiding from the background requires `SetsCursorInBackground` on the connection:
///   `CGDisplayHideCursor` otherwise only works for the frontmost app, and other tools may bring
///   another app forward while masked. Resolved dynamically via private SkyLight `SLSSetConnectionProperty`.
/// - The system re-shows the cursor on every frontmost-app change, so callers `reassert()` on
///   `didActivateApplication`; showing balances every hide call actually made.
@MainActor
final class MaskCursorHider {
    enum Reason: Hashable {
        case dimmed
        case remoteInput
    }

    static let shared = MaskCursorHider()

    private var reasons: Set<Reason> = []
    private var backgroundControlEnabled = false
    /// Hide calls actually made on this connection; can exceed the reason count due to `reassert()`.
    /// Showing balances all of them (extra shows are harmless; too few would leave it hidden).
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

    var isHidden: Bool { reasons.isEmpty == false }

    func hide(for reason: Reason) {
        let wasHidden = isHidden
        reasons.insert(reason)
        guard wasHidden == false else { return }
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

    func show(for reason: Reason) {
        guard reasons.remove(reason) != nil, reasons.isEmpty else { return }
        showNow()
    }

    /// Called when the mask is dismissed: shows the cursor regardless of remaining reasons.
    func showAll() {
        guard isHidden else { return }
        reasons = []
        showNow()
    }

    private func hideNow() {
        hideCursor()
        hideCalls += 1
    }

    private func showNow() {
        for _ in 0 ..< max(hideCalls, 1) {
            showCursor()
        }
        hideCalls = 0
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
