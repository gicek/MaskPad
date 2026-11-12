import AppKit
import ServiceManagement
import SwiftUI

/// Categorized settings with a stable sidebar and independently scrolling detail pages.
/// The passcode stays in the Keychain; all other preferences apply as they change.
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
    /// Read once: a Touch ID sensor doesn't come and go while Settings is open.
    @State private var hasTouchID = MaskTouchIDSession.isSensorPresent
    /// macOS locked Touch ID after too many unrecognized fingers; it needs the Mac password.
    @State private var touchIDLocked = MaskTouchIDSession.isLockedOut
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
    @State private var page: SettingsPage = .general

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView(.vertical) {
                content
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(page)
        }
        .frame(minWidth: 720, minHeight: 500)
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
        touchIDLocked = MaskTouchIDSession.isLockedOut
        commandLineToolState = CommandLineToolInstaller.state
        settings.refreshLaunchAtLogin()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(verbatim: "MaskPad")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 16)

            List(selection: $page) {
                ForEach(SettingsPage.allCases) { destination in
                    Label(destination.title, systemImage: destination.symbol)
                        .font(.system(size: 13))
                        .padding(.vertical, 4)
                        .tag(destination)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Text(L("Version \(Self.appVersion)"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(20)
        }
        .frame(width: 184)
        .background(.quinary)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(page.title)
                    .font(.system(size: 24, weight: .semibold))
                Text(page.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            warnings
            switch page {
            case .general:
                generalSection
                shortcutSection
                updatesSection
            case .mask:
                maskSection
            case .appearance:
                messageSection
                nowPlayingSection
            case .security:
                passcodeSection
            case .integrations:
                SettingsSection(L("Command line tool")) { commandLineToolRows }
                // Keep a way to restore the setting after sharing ends.
                if screenSharingActive || relockRestores == false {
                    screenSharingSection
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if page == .security {
                warning(L("Set a passcode first.")) { EmptyView() }
            } else {
                warning(L("Set a passcode first.")) {
                    Button(L("Passcode")) { page = .security }
                }
            }
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
            if hasTouchID {
                SettingsDivider()
                SettingsRow(L("Unlock with Touch ID")) {
                    Toggle("", isOn: $settings.touchIDUnlock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if touchIDLocked, settings.touchIDUnlock {
                    HStack(spacing: 12) {
                        SettingsNote(L("Touch ID is locked. Enter your Mac password to use it again."), isWarning: true)
                        Button(L("Enter Password")) {
                            Task {
                                _ = await MaskTouchIDSession.unlockWithMacPassword()
                                touchIDLocked = MaskTouchIDSession.isLockedOut
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var maskSection: some View {
        SettingsSection(L("Automatic behavior")) {
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
            SettingsRow(L("Wait during video and calls")) {
                Toggle("", isOn: $settings.autoEngageWaitsForMedia)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(hasPasscode == false || settings.autoEngageMinutes == 0)
            }
            SettingsNote(L("Doesn't turn on when idle while a video, call, presentation, game or screen recording keeps the display awake."))

            SettingsDivider()
            SettingsRow(L("Automatically hide and dim")) {
                Toggle("", isOn: $settings.autoDim)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsNote(L("After 20 seconds without activity, hides the keypad and dims the screen."))

            SettingsDivider()
            SettingsNote(L("Apps under the mask keep running. Computer Use tools that work per window are unaffected; remote desktops see the keypad and can unlock."))
        }
    }

    private var messageSection: some View {
        SettingsSection(L("Message")) {
            SettingsRow(L("Show a message")) {
                Toggle("", isOn: $settings.showsMessage)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(L("Show a message"))
            }
            if settings.showsMessage { messageEditor }
            SettingsNote(L("Shows text on the screen mask."))
        }
    }

    private var nowPlayingSection: some View {
        SettingsSection(L("Now playing")) {
            SettingsRow(L("Show now playing")) {
                Toggle("", isOn: $settings.showsNowPlaying)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(L("Show now playing"))
            }
            SettingsNote(L("Shows the current track or video on the screen mask."))
            SettingsDivider()
            SettingsRow(L("Show playback controls")) {
                Toggle("", isOn: $settings.showsPlaybackControls)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(L("Show playback controls"))
            }
            .disabled(!settings.showsNowPlaying)
            SettingsNote(L("Allows play, pause and track changes without unlocking the mask."))
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
        SettingsSection(L("Startup")) {
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
        }
    }

    private var updatesSection: some View {
        SettingsSection(L("Updates")) {
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
        SettingsRow("maskpad") {
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

/// Stable navigation, independent of whether optional controls are currently relevant.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, mask, appearance, security, integrations
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("General")
        case .mask: L("Screen Mask")
        case .appearance: L("Mask appearance")
        case .security: L("Unlock & Security")
        case .integrations: L("Integrations")
        }
    }

    var subtitle: String {
        switch self {
        case .general: L("Startup, shortcuts and updates.")
        case .mask: L("Choose when the mask appears and dims the screen.")
        case .appearance: L("Choose what appears on the screen mask.")
        case .security: L("Manage how you unlock the screen mask.")
        case .integrations: L("Connect MaskPad to your tools and remote sessions.")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .mask: "rectangle.on.rectangle"
        case .appearance: "slider.horizontal.3"
        case .security: "lock"
        case .integrations: "puzzlepiece.extension"
        }
    }
}
