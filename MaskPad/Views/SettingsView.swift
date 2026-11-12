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
    @State private var passcodeError: SettingsIssue?
    @State private var showsResetPasscodeConfirmation = false
    /// Failure changing the Screen Sharing setting, shown in that section.
    @State private var relockError: SettingsIssue?
    @State private var shortcutError: SettingsIssue?
    /// Whether the Mac relocks after Screen Sharing ends, and whether sharing is active. Both need probes, so refresh on open and after changes.
    @State private var relockRestores = true
    @State private var screenSharingActive = false
    @State private var relockChanging = false
    @State private var commandLineToolState = CommandLineToolInstaller.state
    @State private var commandLineToolChanging = false
    @State private var commandLineToolFailed = false
    @State private var page: SettingsPage = .general

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private static let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

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
        .frame(width: SettingsMetrics.windowSize.width, height: SettingsMetrics.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .buttonStyle(SettingsButtonStyle())
        .environment(\.locale, settings.language.locale)
        .onChange(of: settings.language) { _, _ in
            SettingsWindowController.shared.refreshTitle()
        }
        .confirmationDialog(L("Reset passcode?"), isPresented: $showsResetPasscodeConfirmation, titleVisibility: .visible) {
            Button(L("Reset passcode"), role: .destructive, action: resetPasscode)
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This removes the current passcode and turns off automatic masking. Set a new passcode before using the screen mask again."))
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { destination in
                    SettingsSidebarRow(title: destination.title, symbol: destination.symbol, isSelected: page == destination) {
                        page = destination
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, SettingsMetrics.sidebarTopInset)
        }
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SettingsSidebarMaterial())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            if page != .about { warnings }
            switch page {
            case .general:
                languageSection
                generalSection
                shortcutSection
                updatesSection
            case .mask:
                maskSection
                messageSection
                nowPlayingSection
                MaskAppearancePreview(settings: settings)
            case .security:
                passcodeSection
            case .integrations:
                SettingsSection(L("Command line tool")) { commandLineToolRows }
                if screenSharingActive || relockRestores == false {
                    screenSharingSection
                }
            case .about:
                aboutPage
            }
        }
        .padding(.horizontal, SettingsMetrics.pageInset)
        .padding(.top, SettingsMetrics.pageTopInset)
        .padding(.bottom, SettingsMetrics.pageInset)
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
                    Button(L("Set Passcode")) { page = .security }
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
                    Button(L("Reset passcode"), role: .destructive) {
                        showsResetPasscodeConfirmation = true
                    }
                }
            } else {
                SettingsRow(L("New passcode")) {
                    SecureField("", text: $newCode)
                        .accessibilityLabel(L("New passcode"))
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
                        .accessibilityLabel(L("Confirm passcode"))
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
                .padding(.trailing, SettingsMetrics.rowInset)
            }
            if let passcodeError {
                SettingsNote(passcodeError.message(), isWarning: true)
            }
            if hasTouchID {
                SettingsDivider()
                SettingsRow(L("Unlock with Touch ID")) {
                    Toggle(L("Unlock with Touch ID"), isOn: $settings.touchIDUnlock)
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
                    .padding(.trailing, SettingsMetrics.rowInset)
                }
            }
        }
    }

    private var maskSection: some View {
        SettingsSection(L("Automatic behavior")) {
            SettingsRow(L("Turn on when idle"), description: autoMaskSleepNote) {
                Picker(L("Turn on when idle"), selection: $settings.autoEngageMinutes) {
                    ForEach(MaskSettings.autoEngageOptions, id: \.self) { minutes in
                        Text(autoEngageLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(hasPasscode == false)
            }

            SettingsDivider()
            SettingsRow(L("Delay during videos and calls"), description: L("Doesn't turn on when idle while a video, call, presentation, game or screen recording keeps the display awake.")) {
                Toggle(L("Delay during videos and calls"), isOn: $settings.autoEngageWaitsForMedia)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(hasPasscode == false || settings.autoEngageMinutes == 0)
            }

            SettingsDivider()
            SettingsRow(L("Automatically hide and dim"), description: L("After 20 seconds without activity, hides the keypad and dims the screen.")) {
                Toggle(L("Automatically hide and dim"), isOn: $settings.autoDim)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            SettingsDivider()
            SettingsNote(L("Apps under the mask keep running. Computer Use tools that work per window are unaffected; remote desktops see the keypad and can unlock."))
        }
    }

    private var autoMaskSleepNote: String? {
        guard settings.autoEngageMinutes > 0, hasPasscode, canBlockLocalInput else { return nil }
        return L("While waiting for automatic masking, the Mac won't sleep or lock automatically.")
    }

    private var messageSection: some View {
        SettingsSection(L("Message")) {
            SettingsRow(L("Show a message"), description: L("Shows text on the screen mask.")) {
                Toggle(L("Show a message"), isOn: $settings.showsMessage)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if settings.showsMessage {
                messageEditor
                    .padding(.horizontal, SettingsMetrics.rowInset)
                    .padding(.bottom, 14)
            }
        }
    }

    private var nowPlayingSection: some View {
        SettingsSection(L("Now playing")) {
            SettingsRow(L("Show now playing"), description: L("Shows the current track or video on the screen mask.")) {
                Toggle(L("Show now playing"), isOn: $settings.showsNowPlaying)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(L("Show playback controls"), description: L("Allows play, pause and track changes without unlocking the mask.")) {
                Toggle(L("Show playback controls"), isOn: $settings.showsPlaybackControls)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .disabled(!settings.showsNowPlaying)
        }
    }

    /// The mask message (`MaskMessage`); `MaskSettings.message` keeps it within the limits as it's typed.
    private var messageEditor: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: $settings.message)
                .accessibilityLabel(L("Message"))
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
                        error: $shortcutError
                    )
                }
                if hotKeyCenter.unavailableActions.contains(action) {
                    SettingsNote(L("This shortcut is used by another app. Choose a different one."), isWarning: true)
                }
            }
            if let shortcutError {
                SettingsNote(shortcutError.message(), isWarning: true)
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
                .padding(.horizontal, SettingsMetrics.rowInset)
                .padding(.bottom, 12)
            }
        }
    }

    private var generalSection: some View {
        SettingsSection(L("Startup")) {
            SettingsRow(L("Launch at login")) {
                Toggle(L("Launch at login"), isOn: $settings.launchAtLogin)
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
                .padding(.trailing, SettingsMetrics.rowInset)
            }
            if settings.launchAtLoginChangeFailed {
                SettingsNote(L("Couldn't update Login Items."), isWarning: true)
            }
        }
    }

    private var languageSection: some View {
        SettingsSection(L("Language")) {
            SettingsRow(L("Language")) {
                Picker(L("Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                // AppKit caches popup item titles; rebuild only the picker when its language changes.
                .id(settings.language)
            }
        }
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "MaskPad")
                        .font(.system(size: 24, weight: .semibold))
                    Text(L("Cover your screens. Keep your work running."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowInset)

            SettingsSection(L("About")) {
                SettingsRow(L("Version"), description: L("Build \(Self.appBuild)")) {
                    Text(verbatim: Self.appVersion)
                        .font(.system(size: 13).monospacedDigit())
                        .textSelection(.enabled)
                }
                SettingsDivider()
                SettingsRow(L("License")) {
                    Link(destination: URL(string: "https://github.com/gicek/MaskPad/blob/main/LICENSE")!) {
                        Text(verbatim: "MIT")
                    }
                }
            }
            SettingsSection(L("Project")) {
                SettingsRow(L("Source code")) {
                    Link(destination: URL(string: "https://github.com/gicek/MaskPad")!) {
                        Text(verbatim: "GitHub")
                    }
                }
                SettingsDivider()
                SettingsRow(L("Feedback")) {
                    Link(L("Report an issue"), destination: URL(string: "https://github.com/gicek/MaskPad/issues")!)
                }
            }
            Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, SettingsMetrics.rowInset)
        }
    }

    private var updatesSection: some View {
        SettingsSection(L("Updates")) {
            SettingsRow(L("Check for updates automatically")) {
                Toggle(L("Check for updates automatically"), isOn: $updater.automaticallyChecksForUpdates)
                    .disabled(AppIdentity.isDebug)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(L("Version \(Self.appVersion)")) {
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
                SettingsNote(relockError.message(), isWarning: true)
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
                relockError = .systemSettingFailed
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
            passcodeError = .invalidPasscode
            return
        }
        guard confirmCode.isEmpty == false else {
            passcodeError = .confirmationRequired
            return
        }
        guard newCode == confirmCode else {
            passcodeError = .passcodesDiffer
            return
        }
        guard let passcode = MaskPasscode.make(code: newCode),
              MaskPasscodeStore.shared.save(passcode) else {
            passcodeError = .passcodeSaveFailed
            return
        }
        newCode = ""
        confirmCode = ""
        hasPasscode = true
        passcodeError = nil
        // Setting a passcode usually means the user is about to step away: re-check Screen Sharing and show its section if active.
        Task { await refreshRelockState() }
    }

    private func resetPasscode() {
        MaskPasscodeStore.shared.clear()
        hasPasscode = MaskPasscodeStore.shared.hasPasscode
        // Never leave an old idle delay silently armed after a passcode is removed.
        settings.autoEngageMinutes = 0
        newCode = ""
        confirmCode = ""
        passcodeError = nil
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
    case general, mask, security, integrations, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("General")
        case .mask: L("Screen Mask")
        case .security: L("Unlock & Security")
        case .integrations: L("Integrations")
        case .about: L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .mask: "rectangle.on.rectangle"
        case .security: "lock"
        case .integrations: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }
}
