import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// Touch ID as a second way to turn the mask off, next to the passcode (rules; `MaskTouchIDSession` talks
/// to the system).
///
/// - A fingerprint is matched by the Secure Enclave against the fingers enrolled for the logged-in user,
///   the same ones that unlock the Mac. Logging in already removes the mask ("Unlock with Mac Password"),
///   so Touch ID gives nobody access they didn't have. Software can't produce a match: the rule that no
///   software turns the mask off still holds.
/// - Only a finger resting on the sensor counts. The sensor is also the power key; pressing it stays
///   blocked like every other key (`MaskTapPolicy`).
/// - Fingerprints only: no Apple Watch and no fallback to the Mac password.
enum MaskTouchID {
    static let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics

    /// Pause before waiting for a finger again.
    static let retryDelay: TimeInterval = 1

    enum Next: Equatable {
        /// Wait for a finger again after `retryDelay`.
        case retry
        /// Stay off until the keypad is shown again.
        case stop
    }

    /// What to do when waiting for a finger ended without a match.
    ///
    /// - Three unrecognized fingers end one wait (`authenticationFailed`), and the system can interrupt it
    ///   (`systemCancel`, for example when the display sleeps): wait again. The system itself locks
    ///   Touch ID after five unrecognized fingers; then the next wait can't start and only the passcode is
    ///   left, also the next times the mask is on, until the Mac password is entered (Settings offers it).
    /// - Everything else stops: our own cancel when the keypad goes away, Touch ID locked, unavailable
    ///   (lid closed) or without fingers, and errors this code doesn't know. Retrying those could spin.
    static func next(afterFailure code: Int?) -> Next {
        switch code.flatMap(LAError.Code.init(rawValue:)) {
        case .authenticationFailed, .systemCancel: .retry
        default: .stop
        }
    }
}

/// Waits for a finger on Touch ID while the keypad shows, and reports a match.
///
/// One wait is one `LAContext`, shown by the system's own Touch ID view inside the mask window
/// (`MaskTouchIDSensorView`) instead of the standard dialog, which would need clicks the mask blocks.
/// The wait begins only once that view is in a window (`begin`): a context evaluated without its view
/// falls back to the dialog.
@MainActor
final class MaskTouchIDSession: ObservableObject {
    /// The context of the current wait, or nil when not waiting: Touch ID is off in Settings or can't be
    /// used now, the keypad isn't showing, or between two waits.
    @Published private(set) var context: LAContext?
    /// The mask window that shows the system's Touch ID view: the key window. That view reads a finger
    /// only in the key window of the active app; in any other it is dimmed and nothing happens.
    @Published private(set) var hostWindow: ObjectIdentifier?

    private let isEnabled: Bool
    private let onMatch: () -> Void
    /// Whether the keypad is showing, so a wait that ended may start again.
    private var isWanted = false
    private var hasBegun = false
    /// Incremented for each wait, so a reply from an earlier one is ignored.
    private var generation = 0
    private var retryTimer: Timer?

    /// Whether this Mac has a Touch ID sensor, with or without enrolled fingers. For Settings.
    static var isSensorPresent: Bool {
        let context = LAContext()
        // The type is only set after a check, whatever its result.
        _ = context.canEvaluatePolicy(MaskTouchID.policy, error: nil)
        return context.biometryType == .touchID
    }

    /// Whether macOS has locked Touch ID after five unrecognized fingers. It stays locked, for the lock
    /// screen and every app, until the Mac password is entered; the mask's passcode can't unlock it.
    static var isLockedOut: Bool {
        var error: NSError?
        _ = LAContext().canEvaluatePolicy(MaskTouchID.policy, error: &error)
        return error?.code == LAError.Code.biometryLockout.rawValue
    }

    /// Asks for the Mac password in the system's dialog, which unlocks Touch ID. For Settings; the
    /// mask blocks that dialog. Returns whether the password was entered.
    static func unlockWithMacPassword() async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication, localizedReason: L("turn Touch ID back on")
        )) ?? false
    }

    init(isEnabled: Bool, onMatch: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.onMatch = onMatch
    }

    /// The keypad is showing: wait for a finger. Does nothing while already waiting.
    func start() {
        guard isEnabled else { return }
        isWanted = true
        guard context == nil, retryTimer == nil else { return }
        prepare()
    }

    /// The keypad went away, or the mask is turning off.
    func stop() {
        isWanted = false
        retryTimer?.invalidate()
        retryTimer = nil
        generation += 1
        context?.invalidate()
        context = nil
    }

    /// Another mask window became the key window (a click on another screen), or the windows were
    /// rebuilt. The system's view can't move, so a wait in progress starts over in the new window.
    func setHost(_ window: NSWindow?) {
        let host = window.map(ObjectIdentifier.init)
        guard host != hostWindow else { return }
        hostWindow = host
        guard isWanted else { return }
        stop()
        start()
    }

    /// Called by the sensor view once it is in a window; starts the wait for `context`.
    func begin(_ context: LAContext) {
        guard context === self.context, hasBegun == false else { return }
        hasBegun = true
        let generation = generation
        // The reply arrives on a private queue, so the closure must not inherit the main actor.
        context.evaluatePolicy(
            MaskTouchID.policy, localizedReason: L("unlock the screen mask")
        ) { @Sendable [weak self] matched, error in
            let code = (error as NSError?)?.code
            Task { @MainActor in self?.ended(generation: generation, matched: matched, failureCode: code) }
        }
    }

    private func prepare() {
        retryTimer = nil
        let context = LAContext()
        // Touch ID only (not Optic ID or a companion device), with fingers enrolled and not locked.
        guard context.canEvaluatePolicy(MaskTouchID.policy, error: nil), context.biometryType == .touchID else {
            return
        }
        // No "Use Password…" route.
        context.localizedFallbackTitle = ""
        generation += 1
        hasBegun = false
        self.context = context
    }

    private func ended(generation: Int, matched: Bool, failureCode: Int?) {
        guard generation == self.generation else { return }
        context = nil
        if matched {
            isWanted = false
            onMatch()
            return
        }
        // The error code only; nothing about the finger is known here.
        Log.mask.notice("Touch ID ended without a match: \(failureCode ?? 0, privacy: .public)")
        guard isWanted, MaskTouchID.next(afterFailure: failureCode) == .retry else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: MaskTouchID.retryDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isWanted else { return }
                self.prepare()
            }
        }
    }
}

/// The fingerprint in the keypad's empty corner while Touch ID waits for a finger. Not a button: the sensor
/// is on the keyboard. The screen with the key window shows the system's view (`hostWindow`); the others
/// show the same icon as a picture.
///
/// A view of its own, observing only the session, so the keypad redrawing around it (every digit, every
/// second of a cooldown) doesn't touch the system's view.
struct MaskTouchIDIcon: View {
    @ObservedObject var touchID: MaskTouchIDSession
    /// The mask window this copy is in.
    let window: ObjectIdentifier

    var body: some View {
        if let context = touchID.context {
            Group {
                if touchID.hostWindow == window {
                    MaskTouchIDSensorView(context: context, session: touchID)
                        // A new wait is a new context, and the system view is paired with one for good.
                        .id(ObjectIdentifier(context))
                } else {
                    Image(systemName: "touchid")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.47))
                        .padding(8)
                }
            }
            .frame(width: MaskTouchIDSensorView.side, height: MaskTouchIDSensorView.side)
            .accessibilityLabel(L("Touch ID"))
        }
    }
}

/// The system's Touch ID view for one wait. A context shows its Touch ID prompt in the view paired with
/// it, or else in the standard dialog; only one view can be paired (a second one stays blank), so only
/// one screen shows it: the one with the key window, where it reads fingers (`MaskTouchIDSession.hostWindow`).
///
/// The view has to stay visible and untouched: it pulses about once a second while it waits, and draws
/// the fingerprint filling in before a match is reported. Made invisible, with its animations sped up
/// to hide both, the wait still ran but no finger was ever read.
struct MaskTouchIDSensorView: NSViewRepresentable {
    /// Side of the system view at the regular control size.
    static let side: CGFloat = 64

    let context: LAContext
    let session: MaskTouchIDSession

    func makeNSView(context _: Context) -> NSView {
        HostView(context: context, session: session)
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class HostView: NSView {
        private let context: LAContext
        private weak var session: MaskTouchIDSession?

        init(context: LAContext, session: MaskTouchIDSession) {
            self.context = context
            self.session = session
            super.init(frame: NSRect(x: 0, y: 0, width: MaskTouchIDSensorView.side, height: MaskTouchIDSensorView.side))
            let sensor = LAAuthenticationView(context: context, controlSize: .regular)
            // The mask is black whatever the system appearance.
            sensor.appearance = NSAppearance(named: .darkAqua)
            sensor.frame = bounds
            sensor.autoresizingMask = [.width, .height]
            addSubview(sensor)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { session?.begin(context) }
        }
    }
}
