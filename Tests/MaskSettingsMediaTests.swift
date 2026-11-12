import Foundation
import Testing
@testable import MaskPad

@MainActor
@Suite(.serialized)
struct MaskSettingsMediaTests {
    private static let suiteName = "com.gicek.maskpad.tests.media"

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        body(defaults)
    }

    @Test func newInstallsShowMediaAndControls() {
        withDefaults { defaults in
            let settings = MaskSettings(defaults: defaults, isExistingInstall: { false })
            #expect(settings.showsNowPlaying)
            #expect(settings.showsPlaybackControls)
        }
    }

    /// Upgrading doesn't start showing what plays to people at the Mac; the choice is stored, so setting a
    /// passcode later on a new install doesn't turn the card off either.
    @Test func upgradesHideMediaAndTheChoiceSticks() {
        withDefaults { defaults in
            #expect(MaskSettings(defaults: defaults, isExistingInstall: { true }).showsNowPlaying == false)
            #expect(MaskSettings(defaults: defaults, isExistingInstall: { false }).showsNowPlaying == false)
        }
        withDefaults { defaults in
            _ = MaskSettings(defaults: defaults, isExistingInstall: { false })
            #expect(MaskSettings(defaults: defaults, isExistingInstall: { true }).showsNowPlaying)
        }
    }

    @Test func preferencesPersistIndependently() {
        withDefaults { defaults in
            let settings = MaskSettings(defaults: defaults, isExistingInstall: { false })
            settings.showsPlaybackControls = false
            #expect(settings.showsNowPlaying)
            settings.showsNowPlaying = false

            let reloaded = MaskSettings(defaults: defaults)
            #expect(!reloaded.showsNowPlaying)
            #expect(!reloaded.showsPlaybackControls)
            reloaded.showsNowPlaying = true
            #expect(!reloaded.showsPlaybackControls)
            #expect(MaskSettings(defaults: defaults).showsNowPlaying)
        }
    }
}
