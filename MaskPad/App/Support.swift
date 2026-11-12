import Foundation

/// Localization lookup. Keys are the English text; translations live in `Localizable.xcstrings`.
func L(_ key: String.LocalizationValue, language: AppLanguage = .current) -> String {
    return String(localized: key, bundle: language.bundle(), locale: language.locale)
}

enum TestEnvironment {
    /// Unit tests are hosted by the real app, so in tests we skip global hotkeys, user defaults writes, and the status item.
    static let isRunningInTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
