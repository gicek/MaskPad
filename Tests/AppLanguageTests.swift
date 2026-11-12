import Foundation
import Testing
@testable import MaskPad

struct AppLanguageTests {
    @Test func systemLanguageMatchesSupportedVariants() {
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["zh-Hant-HK", "en"]) == "zh-Hant")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["de-AT"]) == "de")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["pt-BR"]) == "en")
        #expect(AppLanguage.japanese.resolvedCode(preferredLanguages: ["en"]) == "ja")
    }

    @Test func everyLanguageHasBundledResources() {
        for language in AppLanguage.allCases where language != .system {
            #expect(language.bundle().bundleURL.pathExtension == "lproj", "Missing resources: \(language.rawValue)")
            #expect(language.bundle().bundleURL.lastPathComponent == "\(language.rawValue).lproj")
        }
    }

    @Test func explicitEnglishAndChineseDoNotDependOnSystemLanguage() {
        #expect(String(localized: "Now playing", bundle: AppLanguage.english.bundle()) == "Now playing")
        #expect(String(localized: "Now playing", bundle: AppLanguage.simplifiedChinese.bundle()) == "正在播放")
        #expect(String(localized: "Now playing", bundle: AppLanguage.traditionalChinese.bundle()) == "正在播放")
    }
}

@MainActor
@Suite(.serialized)
struct LanguagePreferenceTests {
    @Test func persistsChoiceAndFallsBackForUnknownValues() throws {
        let suite = "com.gicek.maskpad.tests.language"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MaskSettings(defaults: defaults)
        #expect(settings.language == .system)
        settings.language = .simplifiedChinese
        #expect(MaskSettings(defaults: defaults).language == .simplifiedChinese)
        settings.language = .system
        #expect(MaskSettings(defaults: defaults).language == .system)
        defaults.set("unsupported", forKey: AppLanguage.defaultsKey)
        #expect(MaskSettings(defaults: defaults).language == .system)
    }
}
