import AppKit
import Testing
@testable import MaskPad

struct SettingsCopyTests {
    @Test func retainedErrorsFollowTheSelectedLanguage() {
        let retained = SettingsIssue.passcodesDiffer
        #expect(retained.message(language: .english) == "Passcodes don't match.")
        #expect(retained.message(language: .simplifiedChinese) == "两次输入的密码不一致")
        #expect(retained.message(language: .english) == "Passcodes don't match.")
        for issue in SettingsIssue.allCases {
            #expect(issue.message(language: .english) != issue.message(language: .simplifiedChinese))
        }
    }

    @Test @MainActor func recordingPromptsFitTheExistingField() {
        // The shipped recorder is 128 pt wide; keep 4 pt clear on either side of its text.
        for language in AppLanguage.allCases where language != .system {
            let text = String(localized: "Press keys", bundle: language.bundle())
            let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
            #expect(width <= 120, "\(language.rawValue): prompt needs \(width) pt")
        }
    }
}
