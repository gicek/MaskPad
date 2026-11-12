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

    @Test func existingUsersKeepMediaAndControlsEnabled() {
        withDefaults { defaults in
            let settings = MaskSettings(defaults: defaults)
            #expect(settings.showsNowPlaying)
            #expect(settings.showsPlaybackControls)
        }
    }

    @Test func preferencesPersistIndependently() {
        withDefaults { defaults in
            let settings = MaskSettings(defaults: defaults)
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
