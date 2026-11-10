import Combine
import Foundation
import ServiceManagement

/// MaskPad preferences (UserDefaults). The passcode lives in the Keychain (`MaskPasscodeStore`).
@MainActor
final class MaskSettings: ObservableObject {
    static let shared = MaskSettings()

    /// Idle auto-engage choices in minutes; 0 = never. Mirrors the system screen saver delays.
    static let autoEngageOptions = [0, 1, 3, 5, 10, 20, 30, 60, 120, 180]

    /// While masked, hide the keypad and dim the screen after 20 seconds of no local activity.
    @Published var autoDim: Bool {
        didSet { defaults.set(autoDim, forKey: Self.autoDimKey) }
    }

    /// Show `message` on the mask before the keypad (`MaskMessage`).
    @Published var showsMessage: Bool {
        didSet { defaults.set(showsMessage, forKey: Self.showsMessageKey) }
    }

    /// The mask message as typed, kept within `MaskMessage` limits.
    @Published var message: String {
        didSet {
            // Assigning here doesn't run didSet again.
            let limited = MaskMessage.limited(message)
            if limited != message { message = limited }
            defaults.set(message, forKey: Self.messageKey)
        }
    }

    /// The message the mask shows, or nil when it's off or empty.
    var maskMessage: String? {
        showsMessage ? MaskMessage.displayed(message) : nil
    }

    /// Minutes of idle time before auto-engaging; 0 = never. Always one of `autoEngageOptions`.
    @Published var autoEngageMinutes: Int {
        didSet { defaults.set(autoEngageMinutes, forKey: Self.autoEngageMinutesKey) }
    }

    /// Login item status. The system is the source of truth; re-read after toggling and when settings comes to the front.
    enum LoginItemState: Equatable {
        case off
        case on
        /// Registered, but the user must approve it in System Settings > Login Items.
        case requiresApproval
    }

    @Published private(set) var loginItemState: LoginItemState = .off
    @Published private(set) var launchAtLoginChangeFailed = false

    /// Toggle value: on if registered, including pending approval.
    var launchAtLogin: Bool {
        get { loginItemState != .off }
        set { setLaunchAtLogin(newValue) }
    }

    private let defaults: UserDefaults
    private static let autoDimKey = "autoDim"
    private static let autoEngageMinutesKey = "autoEngageMinutes"
    private static let showsMessageKey = "showsMessage"
    private static let messageKey = "message"
    /// Separate defaults domain for tests, cleared on each init so real user preferences are untouched.
    static let testSuiteName = "com.gicek.maskpad.tests"

    init(defaults: UserDefaults = .standard) {
        if TestEnvironment.isRunningInTests, defaults === UserDefaults.standard {
            UserDefaults.standard.removePersistentDomain(forName: Self.testSuiteName)
            self.defaults = UserDefaults(suiteName: Self.testSuiteName)!
        } else {
            self.defaults = defaults
        }
        autoDim = self.defaults.object(forKey: Self.autoDimKey) as? Bool ?? true
        // Values outside the options (old versions, manual edits) would show a blank picker; fall back to never.
        let minutes = self.defaults.integer(forKey: Self.autoEngageMinutesKey)
        autoEngageMinutes = Self.autoEngageOptions.contains(minutes) ? minutes : 0
        showsMessage = self.defaults.bool(forKey: Self.showsMessageKey)
        message = MaskMessage.limited(self.defaults.string(forKey: Self.messageKey) ?? "")
        if TestEnvironment.isRunningInTests == false {
            refreshLaunchAtLogin()
        }
    }

    func refreshLaunchAtLogin() {
        loginItemState = Self.readLoginItemState()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchAtLogin else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginChangeFailed = false
        } catch {
            launchAtLoginChangeFailed = true
        }
        refreshLaunchAtLogin()
    }

    private static func readLoginItemState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .requiresApproval
        default: .off
        }
    }
}
