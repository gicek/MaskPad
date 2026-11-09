import Foundation

/// Handles "Turn On Screen Mask" from the menu or the global hotkey.
///
/// **No alerts**: if the mask can't engage, open the settings window, whose banners explain a
/// missing passcode or Accessibility permission. On success the mask itself is the feedback.
/// **No hotkeys run while masked**: allowing them would be a passcode bypass.
@MainActor
enum MaskActions {
    static func engageFromUser() {
        let mask = MaskController.shared
        guard mask.isEngaged == false else { return }
        // Check prerequisites first: `engage()` would fail anyway, and this avoids a pointless tap creation.
        guard MaskPasscodeStore.shared.hasPasscode, MaskController.canBlockLocalInput else {
            SettingsWindowController.shared.show()
            return
        }
        // Race: passcode cleared or permission revoked after the check. Also open settings.
        if mask.engage() != nil {
            SettingsWindowController.shared.show()
        }
    }

    static func run(_ action: MacHotKeyAction) {
        guard MaskController.shared.isEngaged == false else { return }
        switch action {
        case .engageMask: engageFromUser()
        }
    }
}
