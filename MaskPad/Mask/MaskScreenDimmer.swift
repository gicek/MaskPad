import AppKit
import ColorSync

/// When the mask dozes, hides the keypad and cursor and dims DisplayServices displays that can be
/// restored by a stable identity (display UUID). Other displays and keyboard backlights are left
/// alone; the black overlay covers every display.
/// Original values are persisted first and cleared only after a restore is written and read back.
@MainActor
final class MaskScreenDimmer {
    private(set) var isDimmed = false
    private var overlays: [NSWindow] = []
    private var terminationObserver: NSObjectProtocol?
    // Legacy positional records are deliberately not replayed onto unidentified devices.
    private static let pendingRestoreKey = "maskPendingBrightnessRestoreV2"
    private lazy var recovery = Self.makeRecovery()

    func dim() {
        guard !isDimmed else { return }
        isDimmed = true
        recovery.restore()
        // Only DisplayServices displays, which have a stable UUID to restore against.
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            let identity = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
            recovery.dim(identity)
        }
        observeTermination()
        showOverlays()
        MaskCursorHider.shared.hide(for: .dimmed)
    }

    /// Wakes the display. Called on every local mouse move (tap callback, main thread), so brightness
    /// is only touched when actually dimmed; unconfirmed restores are retried by `retryPendingRestore()`.
    func wake() {
        guard isDimmed else { return }
        isDimmed = false
        MaskCursorHider.shared.show(for: .dimmed)
        removeOverlays()
        retryPendingRestore()
    }

    /// Restores brightness not yet confirmed (e.g. read-back mismatch). Called by the mask's 1 s heartbeat and on dismiss.
    func retryPendingRestore() {
        guard isDimmed == false else { return }
        recovery.restore()
        if recovery.hasPending == false { stopObservingTermination() }
    }

    static func restorePendingBrightness() { makeRecovery().restore() }

    private static func makeRecovery() -> BrightnessRecovery {
        BrightnessRecovery(
            load: { (UserDefaults.standard.dictionary(forKey: pendingRestoreKey) as? [String: Float]) ?? [:] },
            save: { values in
                UserDefaults.standard.set(values, forKey: pendingRestoreKey)
                return UserDefaults.standard.synchronize()
            },
            read: { identity in
                guard let id = displayID(identity), let get = displayServicesGetBrightness else { return nil }
                var value: Float = 0
                guard get(id, &value) == 0 else { return nil }
                return value
            },
            write: { identity, value in
                guard let id = displayID(identity), let set = displayServicesSetBrightness else { return false }
                return set(id, value) == 0
            }
        )
    }

    private static func displayID(_ identity: String) -> CGDirectDisplayID? {
        guard let uuid = CFUUIDCreateFromString(kCFAllocatorDefault, identity as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(uuid)
        guard id != 0, CGDisplayIsOnline(id) != 0,
              CGDisplayIsBuiltin(id) != 0 || CGDisplaySerialNumber(id) != 0,
              let actual = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              CFUUIDCreateString(kCFAllocatorDefault, actual) as String == identity else { return nil }
        return id
    }

    /// Restores on normal termination (⌘Q, logout, restart) instead of waiting for the next launch.
    /// **Must run synchronously**: a `Task { @MainActor in … }` would run after the process is gone.
    /// The notification is delivered on the main thread, so `queue: nil` plus `assumeIsolated` runs it inline.
    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wake()
                self?.retryPendingRestore()
            }
        }
    }

    private func stopObservingTermination() {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        terminationObserver = nil
    }

    // MARK: - Black overlay

    private func showOverlays() {
        overlays = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            // Like the mask: non-opaque with alpha 0.99 so covered windows aren't treated as occluded
            // (Chromium would stop rendering, freezing remote view). Sits above the mask to hide the keypad glow.
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.99)
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            window.collectionBehavior = [
                .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
            ]
            window.orderFront(nil)
            return window
        }
    }

    private func removeOverlays() {
        for window in overlays {
            window.orderOut(nil)
        }
        overlays = []
    }

}

private extension MaskScreenDimmer {
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    static let displayServicesHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    )
    static let displayServicesGetBrightness: GetBrightnessFn? = symbol(displayServicesHandle, "DisplayServicesGetBrightness")
    static let displayServicesSetBrightness: SetBrightnessFn? = symbol(displayServicesHandle, "DisplayServicesSetBrightness")
    static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

/// Hardware and durable storage are injected; tests never touch displays or user preferences.
@MainActor
final class BrightnessRecovery {
    private var pending: [String: Float]
    private let save: ([String: Float]) -> Bool
    private let read: (String) -> Float?
    private let write: (String, Float) -> Bool

    init(load: () -> [String: Float], save: @escaping ([String: Float]) -> Bool,
         read: @escaping (String) -> Float?, write: @escaping (String, Float) -> Bool) {
        pending = load()
        self.save = save; self.read = read; self.write = write
    }

    var hasPending: Bool { pending.isEmpty == false }

    func dim(_ identity: String) {
        guard pending[identity] == nil, let original = read(identity),
              original.isFinite, (0...1).contains(original) else { return }
        var next = pending
        next[identity] = original
        guard save(next) else { return }
        pending = next
        _ = write(identity, 0) // Even a failed write may have side effects; retain recovery intent.
    }

    func restore() {
        for (identity, value) in pending {
            guard value.isFinite, (0...1).contains(value), read(identity) != nil,
                  write(identity, value), let actual = read(identity),
                  actual.isFinite, abs(actual - value) <= 0.01 else { continue }
            var next = pending
            next.removeValue(forKey: identity)
            if save(next) { pending = next }
        }
    }
}
