import SwiftUI

/// Shared view model for the unlock pages. Each screen shows its own copy, but input and page state are
/// shared across all screens. Which page shows, and how to get between them, is `MaskUnlockFlow`.
@MainActor
final class MaskUnlockViewModel: ObservableObject {
    typealias Page = MaskUnlockFlow.Page

    /// The message shown before the keypad, or nil to start on the keypad.
    let message: String?
    @Published private(set) var flow: MaskUnlockFlow {
        didSet {
            let shown = flow.page == .keypad
            if shown != (oldValue.page == .keypad) { onKeypadShown(shown) }
        }
    }
    @Published private(set) var state = MaskUnlockState()
    /// Incremented on a wrong code to drive the shake animation.
    @Published private(set) var shakeToken = 0
    /// Seconds left in cooldown, or nil. Updated by a 1 s timer.
    @Published private(set) var cooldownRemaining: Int?
    /// Shows the external-display hint: auto-dim is on and an external display is connected.
    /// Refreshed by the controller whenever windows are (re)built.
    @Published var showsExternalDisplayHint = false

    /// "Unlock with Mac Password": locks the screen; the mask is dismissed after login.
    private let onLockSystem: () -> Void
    private let verify: (String) -> Bool
    private let onUnlock: () -> Void
    /// The keypad came up (true) or went away (false); not called for the page the mask starts on.
    /// Touch ID waits for a finger only while the keypad shows (`MaskTouchIDSession`).
    private let onKeypadShown: (Bool) -> Void
    private var cooldownTimer: Timer?
    /// Checks every second whether to go back to the first page (`MaskUnlockFlow.returnDelay`).
    private var returnTimer: Timer?

    init(
        message: String? = nil,
        onLockSystem: @escaping () -> Void,
        verify: @escaping (String) -> Bool,
        onUnlock: @escaping () -> Void,
        onKeypadShown: @escaping (Bool) -> Void = { _ in }
    ) {
        self.message = message
        flow = MaskUnlockFlow(hasMessage: message != nil, now: Date())
        self.onLockSystem = onLockSystem
        self.verify = verify
        self.onUnlock = onUnlock
        self.onKeypadShown = onKeypadShown
        returnTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfIdle(now: Date()) }
        }
    }

    var page: Page { flow.page }
    var enteredCount: Int { state.entered.count }
    /// Wrong codes entered since the mask turned on.
    var failedAttemptCount: Int { state.totalFailedAttempts }

    /// The message page's Unlock button.
    func unlock() { flow.unlock(now: Date()) }

    func showForgotPasscode() { flow.showForgotPasscode(now: Date()) }

    /// Back on the "Forgot Passcode" page.
    func back() { flow.back(now: Date()) }

    func lockSystem() { onLockSystem() }

    /// The first page, with the digits entered cleared. When the screen wakes from dimming.
    func showStartPage() {
        flow.restart(now: Date())
        state.clearEntry()
    }

    /// Back to the first page, digits cleared, after `MaskUnlockFlow.returnDelay` without input.
    func restartIfIdle(now: Date) {
        // On a copy: this runs every second, and mutating `flow` in place publishes a change each time
        // even when nothing changed, redrawing every mask window once a second.
        var next = flow
        if next.restartIfIdle(now: now) {
            flow = next
            state.clearEntry()
        }
    }

    /// A digit from the on-screen keypad or the keyboard; ignored on the message page (`MaskUnlockFlow`).
    func tap(digit: Character) {
        guard flow.input(now: Date()) else { return }
        switch state.appendDigit(digit, now: Date(), verify: verify) {
        case .unlocked:
            cooldownTimer?.invalidate()
            onUnlock()
        case .rejected:
            shakeToken += 1
            if state.isThrottled(at: Date()) { startCooldownTicker() }
        case .pending, .throttled:
            break
        }
    }

    /// Delete from the on-screen keypad or the keyboard; ignored on the message page.
    func deleteDigit() {
        guard flow.input(now: Date()) else { return }
        state.deleteDigit()
    }

    /// Stops the timers when the mask is dismissed. The run loop retains a `Timer`, so it would keep
    /// firing after the model is released (the cooldown one if the mask is dismissed during cooldown by
    /// another path, the return-to-first-page one always).
    func stopTimers() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        cooldownRemaining = nil
        returnTimer?.invalidate()
        returnTimer = nil
    }

    private func startCooldownTicker() {
        cooldownTimer?.invalidate()
        updateCooldownRemaining()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCooldownRemaining() }
        }
    }

    private func updateCooldownRemaining() {
        guard let until = state.lockedUntil, until > Date() else {
            cooldownRemaining = nil
            cooldownTimer?.invalidate()
            cooldownTimer = nil
            return
        }
        cooldownRemaining = Int(until.timeIntervalSinceNow.rounded(.up))
    }
}

/// Mask unlock UI: an iPhone-style keypad with six progress dots, plus the "Forgot passcode" page.
/// The black background comes from the mask window (alpha 0.99, see `MaskController`).
struct MaskUnlockView: View {
    @ObservedObject var model: MaskUnlockViewModel
    @ObservedObject var touchID: MaskTouchIDSession
    /// The mask window this copy is in; the key window shows the system's Touch ID view (`MaskTouchIDIcon`).
    let window: ObjectIdentifier
    @ObservedObject var media: MaskNowPlaying

    private static let keySide: CGFloat = 72
    private static let keySpacing: CGFloat = 20
    private static let titleFont = Font.system(size: 22, weight: .regular)
    private static let dotSide: CGFloat = 15

    var body: some View {
        // All pages live in the mask window, so window level and input blocking are unaffected.
        // Each page is centered on the screen. A ZStack keeps a page that is fading out on top of the
        // next one; a Group could stack them and push the next one down.
        ZStack {
            switch model.page {
            case .message: messagePage
            case .keypad: keypadPage
            case .forgotPasscode: forgotPasscodePage
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            GeometryReader { geometry in
                VStack(alignment: .trailing, spacing: 20) {
                    MaskStatusBar()
                    // Leave the centered keypad and a gutter clear even at 800 x 600.
                    MaskNowPlayingView(media: media, width: min(324, max(180, (geometry.size.width - 300) / 2 - 56)))
                }
                .padding(.top, 22)
                .padding(.trailing, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .overlay(alignment: .bottom) {
            if model.showsExternalDisplayHint {
                externalDisplayHint
            }
        }
    }

    /// The message from Settings, large, with Unlock leading to the keypad. Text and emoji, up to three
    /// lines (`MaskMessage`); long lines wrap.
    private var messagePage: some View {
        VStack(spacing: 36) {
            Text(model.message ?? "")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .frame(maxWidth: 760)

            Button(action: personPress(model.unlock)) {
                Text(L("Unlock"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
        .transition(.opacity)
    }

    private var keypadPage: some View {
        VStack(spacing: 28) {
            Text(touchID.context == nil ? L("Enter Passcode") : L("Touch ID or Enter Passcode"))
                .font(Self.titleFont)
                .foregroundStyle(.white.opacity(0.85))

            dots
                .modifier(ShakeEffect(animatableData: CGFloat(model.shakeToken)))
                .animation(.default, value: model.shakeToken)

            // One line for both notices: the cooldown while it runs, otherwise how many wrong codes were
            // entered since the mask turned on, so the owner coming back knows someone tried.
            if let remaining = model.cooldownRemaining {
                Text(L("Too many attempts. Try again in \(remaining)s"))
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if model.failedAttemptCount > 0 {
                Text(failedAttemptsText(model.failedAttemptCount))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            keypad

            // The whole row is clickable; the chevron alone is too small a target.
            Button(action: personPress(model.showForgotPasscode)) {
                HStack(spacing: 6) {
                    Text(L("Forgot Passcode?"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity)
    }

    private func failedAttemptsText(_ attempts: Int) -> String {
        attempts == 1 ? L("1 wrong passcode attempt") : L("\(attempts) wrong passcode attempts")
    }

    /// Forgot passcode: lock the Mac, log in with the Mac password to dismiss the mask, then reset the
    /// passcode in Settings. The passcode is never bypassed; the login password is the stronger lock.
    private var forgotPasscodePage: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.85))

            Text(L("Forgot Passcode"))
                .font(Self.titleFont)
                .foregroundStyle(.white.opacity(0.85))

            Text(L("The Mac locks first. Log in with your Mac password and the mask turns off, then reset the passcode in MaskPad Settings."))

            Button(action: personPress(model.lockSystem)) {
                Text(L("Unlock with Mac Password"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: personPress(model.back)) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("Back"))
                }
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 15))
        .foregroundStyle(.white.opacity(0.75))
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .frame(maxWidth: 480)
        .padding(.horizontal, 24)
        .transition(.opacity)
    }

    /// External-display hint, pinned to the bottom so it doesn't crowd the keypad.
    private var externalDisplayHint: some View {
        Label {
            Text(L("An external display is connected. Unplugging its cable while the screen is dimmed may keep its brightness from restoring. Wake the screen first."))
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.55))
        // Wide enough for one line; wrapped Label text looks left-heavy. Center lines on narrow screens.
        .multilineTextAlignment(.center)
        .frame(maxWidth: 960)
        .padding(.horizontal, 24)
        .padding(.bottom, 48)
    }

    /// Progress dots: fill and stroke on one circle. 1.5 pt stroke, since 1 pt looks square on 1x displays.
    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<MaskUnlockState.codeLength, id: \.self) { index in
                let filled = index < model.enteredCount
                Circle()
                    .fill(filled ? Color.white : Color.clear)
                    .overlay(Circle().strokeBorder(Color.white.opacity(filled ? 1 : 0.7), lineWidth: 1.5))
                    .frame(width: Self.dotSide, height: Self.dotSide)
            }
        }
        .drawingGroup()
    }

    private var keypad: some View {
        VStack(spacing: Self.keySpacing) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: Self.keySpacing) {
                    ForEach(1...3, id: \.self) { column in
                        digitKey(Character("\(row * 3 + column)"))
                    }
                }
            }
            HStack(spacing: Self.keySpacing) {
                Color.clear.frame(width: Self.keySide, height: Self.keySide)
                    .overlay { MaskTouchIDIcon(touchID: touchID, window: window) }
                digitKey("0")
                Button(action: personPress(model.deleteDigit)) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: Self.keySide, height: Self.keySide)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Delete"))
            }
        }
    }

    private func digitKey(_ digit: Character) -> some View {
        Button(action: personPress { model.tap(digit: digit) }) {
            Text(String(digit))
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white)
                .frame(width: Self.keySide, height: Self.keySide)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps every button action on the mask: it runs only for a person's click or touch, never for presses by
/// background tools (synthetic clicks, Accessibility actions); see `MaskInputOrigin`.
private func personPress(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    { if MaskInputOrigin.currentEventIsPersonPress() { action() } }
}

/// Wrong-code shake: moves the dots back and forth horizontally.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: 10 * sin(animatableData * .pi * 4), y: 0
        ))
    }
}
