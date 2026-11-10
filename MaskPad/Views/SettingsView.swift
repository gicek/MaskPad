import AppKit
import ServiceManagement
import SwiftUI

/// Settings window: blockers at the top (missing permission or passcode), then Passcode, Screen Mask,
/// Keyboard Shortcut, General, and a Screen Sharing section when relevant. Turning on the mask and quitting
/// live in the status menu. The passcode is stored in the Keychain as a salted hash, never in UserDefaults.
struct SettingsView: View {
    @ObservedObject var settings: MaskSettings
    @ObservedObject var hotKeys: HotKeyBindingStore
    @ObservedObject private var hotKeyCenter = GlobalHotKeyCenter.shared
    @ObservedObject private var accessibilityGuide = AccessibilityGuide.shared
    @ObservedObject private var updater = AppUpdater.shared
    /// Anchor for the permission banner: the guide flies from here to System Settings and back.
    @State private var accessibilityAnchor = GuideAnchor()

    @State private var hasPasscode = MaskPasscodeStore.shared.hasPasscode
    @State private var canBlockLocalInput = MaskController.canBlockLocalInput
    @State private var newCode = ""
    @State private var confirmCode = ""
    /// Passcode errors (wrong length, mismatch, Keychain failure), shown at the bottom of the section.
    @State private var passcodeError: String?
    /// Failure changing the Screen Sharing setting, shown in that section.
    @State private var relockError: String?
    @State private var shortcutError: String?
    /// Whether the Mac relocks after Screen Sharing ends, and whether sharing is active. Both need probes, so refresh on open and after changes.
    @State private var relockRestores = true
    @State private var screenSharingActive = false
    @State private var relockChanging = false
    @State private var commandLineToolState = CommandLineToolInstaller.state
    @State private var commandLineToolChanging = false
    @State private var commandLineToolFailed = false
    /// Measured content height. Window height is min(content, `maxHeight`); the rest scrolls.
    @State private var contentHeight: CGFloat = Self.maxHeight

    private static let maxHeight: CGFloat = 660
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        ScrollView(.vertical) {
            content.background(GeometryReader { proxy in
                Color.clear.preference(key: SettingsContentHeightKey.self, value: proxy.size.height)
            })
        }
        .scrollBounceBehavior(.basedOnSize)
        // The window sizes to this frame (NSHostingController's preferredContentSize): it fits the content
        // up to 660pt, then scrolls.
        .frame(width: 460, height: min(contentHeight, Self.maxHeight))
        .onPreferenceChange(SettingsContentHeightKey.self) { contentHeight = $0 }
        .onAppear {
            refreshSystemState()
            Task { await refreshRelockState() }
        }
        // Re-read when the window becomes key: the user may have changed Login Items or Accessibility in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshSystemState()
        }
        // Poll Accessibility permission every second until granted so the banner disappears. Cancelled with the view.
        .task(id: canBlockLocalInput) {
            while canBlockLocalInput == false, Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                canBlockLocalInput = MaskController.canBlockLocalInput
            }
        }
    }

    private func refreshSystemState() {
        canBlockLocalInput = MaskController.canBlockLocalInput
        hasPasscode = MaskPasscodeStore.shared.hasPasscode
        commandLineToolState = CommandLineToolInstaller.state
        settings.refreshLaunchAtLogin()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            warnings
            passcodeSection
            maskSection
            shortcutSection
            generalSection
            // Only shown when relevant: sharing is active, or the setting was changed (keep a way to restore it).
            if screenSharingActive || relockRestores == false {
                screenSharingSection
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }

    // MARK: - Warnings

    /// Blockers go first: without them nothing else on the page takes effect.
    @ViewBuilder
    private var warnings: some View {
        if canBlockLocalInput == false {
            Group {
                if accessibilityGuide.isActive {
                    // Guide active: the banner has flown to System Settings; leave a dashed placeholder.
                    Text(L("Finish in System Settings"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        )
                } else {
                    warning(L("Accessibility permission is needed to block the keyboard and mouse.")) {
                        Button(L("Open System Settings")) { grantAccessibility() }
                    }
                }
            }
            .background(GuideAnchorReader(anchor: accessibilityAnchor))
        }
        if hasPasscode == false {
            warning(L("Set a passcode first.")) { EmptyView() }
        }
    }

    /// Icon and text on one line; the action button, if any, on its own line, trailing.
    private func warning<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Action.self != EmptyView.self {
                HStack {
                    Spacer()
                    action()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Sections

    private var passcodeSection: some View {
        SettingsSection(L("Passcode")) {
            if hasPasscode {
                SettingsRow(L("Passcode is set")) {
                    Button(L("Reset")) {
                        MaskPasscodeStore.shared.clear()
                        hasPasscode = false
                        // Also turn off auto-engage: the picker is disabled without a passcode and would keep
                        // the old value, silently re-arming a forgotten delay when a passcode is set later.
                        settings.autoEngageMinutes = 0
                        passcodeError = nil
                    }
                }
            } else {
                SettingsRow(L("New passcode")) {
                    SecureField("", text: $newCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .onChange(of: newCode) { _, value in
                            let clamped = sixDigits(value)
                            if clamped != newCode { newCode = clamped }
                            passcodeError = nil
                        }
                }
                SettingsRow(L("Confirm passcode")) {
                    SecureField("", text: $confirmCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .onChange(of: confirmCode) { _, value in
                            let clamped = sixDigits(value)
                            if clamped != confirmCode { confirmCode = clamped }
                            passcodeError = nil
                        }
                        .onSubmit(savePasscode)
                }
                HStack {
                    SettingsNote(L("6 digits, used to unlock the mask."))
                    Button(L("Save")) { savePasscode() }
                        .disabled(newCode.isEmpty && confirmCode.isEmpty)
                }
            }
            if let passcodeError {
                SettingsNote(passcodeError, isWarning: true)
            }
        }
    }

    private var maskSection: some View {
        SettingsSection(L("Screen Mask")) {
            SettingsRow(L("Turn on when idle")) {
                Picker("", selection: $settings.autoEngageMinutes) {
                    ForEach(MaskSettings.autoEngageOptions, id: \.self) { minutes in
                        Text(autoEngageLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(hasPasscode == false)
            }
            SettingsNote(L("Until the mask turns on, the Mac won't lock or sleep on its own."))

            SettingsDivider()
            SettingsRow(L("Automatically hide and dim")) {
                Toggle("", isOn: $settings.autoDim)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsNote(L("After 20 seconds without activity, hides the keypad and dims the screen."))

            SettingsDivider()
            SettingsRow(L("Show a message")) {
                Toggle("", isOn: $settings.showsMessage)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if settings.showsMessage {
                messageEditor
            }
            SettingsNote(L("Shows text on the screen mask."))

            SettingsDivider()
            SettingsNote(L("Apps under the mask keep running. Computer Use tools that work per window are unaffected; remote desktops see the keypad and can unlock."))
        }
    }

    /// The mask message (`MaskMessage`); `MaskSettings.message` keeps it within the limits as it's typed.
    private var messageEditor: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: $settings.message)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            Text(verbatim: "\(settings.message.count)/\(MaskMessage.maxLength)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutSection: some View {
        SettingsSection(L("Keyboard Shortcut")) {
            ForEach(MacHotKeyAction.allCases) { action in
                SettingsRow(action.title) {
                    ShortcutRecorderField(
                        chord: hotKeys.chord(for: action),
                        validate: { $0.hotKeyProblem },
                        onChange: { hotKeys.set($0, for: action) },
                        errorText: $shortcutError
                    )
                }
                if hotKeyCenter.unavailableActions.contains(action) {
                    SettingsNote(L("This shortcut is used by another app. Choose a different one."), isWarning: true)
                }
            }
            if let shortcutError {
                SettingsNote(shortcutError, isWarning: true)
            }
            if hotKeys.hasDefaultBindings == false {
                HStack {
                    Spacer()
                    Button(L("Restore Default")) {
                        shortcutError = nil
                        hotKeys.restoreDefaults()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var generalSection: some View {
        SettingsSection(L("General")) {
            SettingsRow(L("Launch at login")) {
                Toggle("", isOn: $settings.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if settings.loginItemState == .requiresApproval {
                HStack {
                    SettingsNote(L("Allow MaskPad in Login Items to finish."), isWarning: true)
                    Button(L("Open Login Items")) { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if settings.launchAtLoginChangeFailed {
                SettingsNote(L("Couldn't update Login Items."), isWarning: true)
            }

            SettingsDivider()
            commandLineToolRows

            SettingsDivider()
            SettingsRow(L("Check for updates automatically")) {
                Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            HStack {
                SettingsNote(L("Version \(Self.appVersion)"))
                Button(L("Check Now")) { updater.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(updater.canCheckForUpdates == false && updater.hasPendingUpdate == false)
            }
        }
    }

    /// The `maskpad` command in /usr/local/bin (`CommandLineToolInstaller`).
    @ViewBuilder
    private var commandLineToolRows: some View {
        SettingsRow(L("Command line tool")) {
            switch commandLineToolState {
            case .notInstalled, .otherCopy:
                Button(L("Install")) { changeCommandLineTool(install: true) }
                    .controlSize(.small)
                    .disabled(commandLineToolChanging)
            case .installed:
                Button(L("Remove")) { changeCommandLineTool(install: false) }
                    .controlSize(.small)
                    .disabled(commandLineToolChanging)
            case .otherFile:
                EmptyView()
            }
        }
        switch commandLineToolState {
        case .notInstalled:
            SettingsNote(L("Adds the maskpad command to /usr/local/bin. May ask for an administrator password."))
        case .installed:
            SettingsNote(L("Type maskpad on in Terminal to turn on the mask."))
        case .otherCopy:
            SettingsNote(L("The maskpad command points to another copy of MaskPad. Install it again to use this one."), isWarning: true)
        case .otherFile:
            SettingsNote(L("Another file named maskpad is already in /usr/local/bin."), isWarning: true)
        }
        if commandLineToolFailed {
            SettingsNote(L("Couldn't change the command line tool."), isWarning: true)
        }
    }

    private func changeCommandLineTool(install: Bool) {
        commandLineToolChanging = true
        Task {
            let outcome = install
                ? await CommandLineToolInstaller.install(prompt: L("MaskPad wants to install the maskpad command."))
                : await CommandLineToolInstaller.remove(prompt: L("MaskPad wants to remove the maskpad command."))
            commandLineToolChanging = false
            switch outcome {
            case .applied, .cancelled: commandLineToolFailed = false
            case .failed: commandLineToolFailed = true
            }
            commandLineToolState = CommandLineToolInstaller.state
        }
    }

    private var screenSharingSection: some View {
        SettingsSection(L("macOS Screen Sharing")) {
            SettingsRow(L("Stay unlocked after sharing ends")) {
                if relockRestores {
                    Button(L("Change Setting")) { changeRelock(restores: false) }
                        .disabled(relockChanging)
                } else {
                    Button(L("Restore Default")) { changeRelock(restores: true) }
                        .disabled(relockChanging)
                }
            }
            if let relockError {
                SettingsNote(relockError, isWarning: true)
            }
            if relockRestores {
                SettingsNote(L("When sharing ends, macOS may lock the Mac again and interrupt tools under the mask. Changing this needs an administrator password."), isWarning: true)
            } else {
                SettingsNote(L("The Mac stays unlocked when sharing ends. Other lock settings still apply."))
            }
        }
    }

    // MARK: - Screen Sharing

    /// Probes spawn subprocesses, so run them in the background; UI state is written back on the main actor.
    private func refreshRelockState() async {
        let (restores, active) = await Task.detached {
            (ScreenSharingRelock.currentRestoresLock(), ScreenSharingRelock.isScreenSharingActive())
        }.value
        relockRestores = restores
        screenSharingActive = active
    }

    private func changeRelock(restores: Bool) {
        relockChanging = true
        Task {
            let outcome = await ScreenSharingRelock.setRestoresLock(
                restores, prompt: L("MaskPad wants to change whether this Mac locks again after macOS Screen Sharing ends.")
            )
            relockChanging = false
            switch outcome {
            case .applied, .cancelled:
                relockError = nil
            case .failed:
                relockError = L("Could not change the system setting.")
            }
            await refreshRelockState()
        }
    }

    // MARK: - Permissions

    /// Opens the Accessibility pane in System Settings; the banner flies over and becomes a drag strip (`AccessibilityGuide`).
    /// Doesn't use the system permission prompt, which triggers two chained system dialogs.
    private func grantAccessibility() {
        let anchor = accessibilityAnchor
        AccessibilityGuide.shared.start(
            sourceRect: { anchor.screenRect },
            sourceSnapshot: anchor.snapshot(),
            onGranted: { canBlockLocalInput = MaskController.canBlockLocalInput }
        )
    }

    // MARK: - Passcode

    /// Keeps ASCII 0–9 only, truncated to 6 digits.
    /// Applied via onChange to @State rather than a computed Binding: SecureField has its own edit buffer
    /// and may not re-read a value clamped in Binding.set.
    private func sixDigits(_ s: String) -> String {
        String(s.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }

    private func savePasscode() {
        guard MaskPasscode.isValidFormat(newCode) else {
            passcodeError = L("Enter a 6-digit passcode.")
            return
        }
        guard confirmCode.isEmpty == false else {
            passcodeError = L("Enter the passcode again to confirm.")
            return
        }
        guard newCode == confirmCode else {
            passcodeError = L("Passcodes don't match.")
            return
        }
        guard let passcode = MaskPasscode.make(code: newCode),
              MaskPasscodeStore.shared.save(passcode) else {
            passcodeError = L("Couldn't save the passcode. Please try again.")
            return
        }
        newCode = ""
        confirmCode = ""
        hasPasscode = true
        passcodeError = nil
        // Setting a passcode usually means the user is about to step away: re-check Screen Sharing and show its section if active.
        Task { await refreshRelockState() }
    }

    // MARK: - Auto-Engage Delay

    private func autoEngageLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return L("Never")
        case 1: return L("After 1 minute")
        case 3: return L("After 3 minutes")
        case 5: return L("After 5 minutes")
        case 10: return L("After 10 minutes")
        case 20: return L("After 20 minutes")
        case 30: return L("After 30 minutes")
        case 60: return L("After 1 hour")
        case 120: return L("After 2 hours")
        case 180: return L("After 3 hours")
        default: return L("Never")
        }
    }
}

private struct SettingsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
