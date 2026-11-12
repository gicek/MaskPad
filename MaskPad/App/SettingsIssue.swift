import Foundation

/// Store the reason, not a translated sentence: existing errors follow live language changes.
enum SettingsIssue: Equatable, CaseIterable, Sendable {
    case invalidPasscode
    case confirmationRequired
    case passcodesDiffer
    case passcodeSaveFailed
    case systemSettingFailed
    case shortcutNeedsModifier

    func message(language: AppLanguage = .current) -> String {
        switch self {
        case .invalidPasscode: L("Enter a 6-digit passcode.", language: language)
        case .confirmationRequired: L("Enter the passcode again to confirm.", language: language)
        case .passcodesDiffer: L("Passcodes don't match.", language: language)
        case .passcodeSaveFailed: L("Couldn't save the passcode. Please try again.", language: language)
        case .systemSettingFailed: L("Could not change the system setting.", language: language)
        case .shortcutNeedsModifier: L("A global shortcut needs at least one of Command, Option, or Control.", language: language)
        }
    }
}
