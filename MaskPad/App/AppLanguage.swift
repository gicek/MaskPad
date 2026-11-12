import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case spanish = "es"
    case korean = "ko"
    case french = "fr"
    case german = "de"

    static let defaultsKey = "appLanguage"
    var id: String { rawValue }

    /// UserDefaults is thread-safe: localization is also used by background services.
    static var current: AppLanguage {
        if TestEnvironment.isRunningInTests { return .system }
        return AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    var title: String {
        switch self {
        case .system: L("Follow System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .spanish: "Español"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        }
    }

    func resolvedCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        let supported = Self.allCases.filter { $0 != .system }.map(\.rawValue)
        return Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages).first ?? "en"
    }

    var locale: Locale { Locale(identifier: resolvedCode()) }

    func bundle(in resources: Bundle = .main) -> Bundle {
        let path = resources.path(forResource: resolvedCode(), ofType: "lproj")
            ?? resources.path(forResource: "en", ofType: "lproj")
        return path.flatMap(Bundle.init(path:)) ?? resources
    }
}
