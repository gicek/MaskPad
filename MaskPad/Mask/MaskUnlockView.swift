import SwiftUI

/// Shared view model for the unlock keypad. Each screen shows its own keypad, but input and page
/// state are shared across all screens.
@MainActor
final class MaskUnlockViewModel: ObservableObject {
    enum Page: Equatable {
        /// Number keypad.
        case keypad
        /// Instructions for a forgotten passcode.
        case forgotPasscode
    }

    @Published private(set) var page: Page = .keypad
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
    private var cooldownTimer: Timer?

    init(
        onLockSystem: @escaping () -> Void,
        verify: @escaping (String) -> Bool,
        onUnlock: @escaping () -> Void
    ) {
        self.onLockSystem = onLockSystem
        self.verify = verify
        self.onUnlock = onUnlock
    }

    var enteredCount: Int { state.entered.count }

    func showForgotPasscode() { page = .forgotPasscode }

    func showKeypad() { page = .keypad }

    func lockSystem() { onLockSystem() }

    /// Digits typed on the "Forgot passcode" page still count, and switch back to the keypad to show progress.
    func tap(digit: Character) {
        showKeypad()
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

    func deleteDigit() {
        showKeypad()
        state.deleteDigit()
    }

    /// Stops the cooldown timer when the mask is dismissed. The run loop retains the `Timer`, so it
    /// would keep firing after the model is released if the mask is dismissed during cooldown by another path.
    func stopCooldown() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        cooldownRemaining = nil
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

    private static let keySide: CGFloat = 72
    private static let keySpacing: CGFloat = 20
    private static let titleFont = Font.system(size: 22, weight: .regular)
    private static let dotSide: CGFloat = 15

    var body: some View {
        // Both pages live in the mask window, so window level and input blocking are unaffected.
        Group {
            switch model.page {
            case .keypad: keypadPage
            case .forgotPasscode: forgotPasscodePage
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            MaskStatusBar()
                .padding(.top, 22)
                .padding(.trailing, 28)
        }
        .overlay(alignment: .bottom) {
            if model.showsExternalDisplayHint {
                externalDisplayHint
            }
        }
    }

    private var keypadPage: some View {
        VStack(spacing: 28) {
            Text(L("Enter Passcode"))
                .font(Self.titleFont)
                .foregroundStyle(.white.opacity(0.85))

            dots
                .modifier(ShakeEffect(animatableData: CGFloat(model.shakeToken)))
                .animation(.default, value: model.shakeToken)

            if let remaining = model.cooldownRemaining {
                Text(L("Too many attempts. Try again in \(remaining)s"))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            keypad

            // The whole row is clickable; the chevron alone is too small a target.
            Button(action: model.showForgotPasscode) {
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
            Button(action: model.lockSystem) {
                Text(L("Unlock with Mac Password"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: model.showKeypad) {
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
                digitKey("0")
                Button(action: model.deleteDigit) {
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
        Button {
            model.tap(digit: digit)
        } label: {
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

/// Wrong-code shake: moves the dots back and forth horizontally.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: 10 * sin(animatableData * .pi * 4), y: 0
        ))
    }
}
