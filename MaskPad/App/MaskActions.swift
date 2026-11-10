import Foundation

/// Handles "Turn On Screen Mask" from the menu, the global hotkey and `maskpad://` URLs.
///
/// **No alerts**: if the mask can't engage, open the settings window, whose banners explain a
/// missing passcode or Accessibility permission. On success the mask itself is the feedback.
/// **No hotkeys run while masked**: allowing them would be a passcode bypass.
@MainActor
enum MaskActions {
    @discardableResult
    static func engageFromUser() -> MaskCommandResult {
        let mask = MaskController.shared
        guard mask.isEngaged == false else { return .alreadyOn }
        // Check prerequisites first: `engage()` would fail anyway, and this avoids a pointless tap creation.
        guard MaskPasscodeStore.shared.hasPasscode else {
            SettingsWindowController.shared.show()
            return .noPasscode
        }
        guard MaskController.canBlockLocalInput else {
            SettingsWindowController.shared.show()
            return .noAccessibility
        }
        // Race: passcode cleared or permission revoked after the check. Also open settings.
        switch mask.engage() {
        case nil:
            return .on
        case .passcodeMissing:
            SettingsWindowController.shared.show()
            return .noPasscode
        case .inputBlockerUnavailable:
            SettingsWindowController.shared.show()
            return .noAccessibility
        }
    }

    static func run(_ action: MacHotKeyAction) {
        guard MaskController.shared.isEngaged == false else { return }
        switch action {
        case .engageMask: engageFromUser()
        }
    }

    /// Runs a `maskpad://` command and, if the sender asked for it, posts the result (see `MaskCommand`).
    /// Unknown URLs are ignored.
    static func handle(_ url: URL) {
        guard let request = MaskCommand.parse(url) else {
            Log.command.notice("ignored an unknown URL")
            return
        }
        let result: MaskCommandResult = switch request.command {
        case .on: engageFromUser()
        case .status: MaskController.shared.isEngaged ? .on : .off
        }
        Log.command.notice("\(request.command.rawValue, privacy: .public): \(result.rawValue, privacy: .public)")
        guard let replyID = request.replyID else { return }
        DistributedNotificationCenter.default().postNotificationName(
            MaskCommand.replyNotification, object: replyID,
            userInfo: [MaskCommand.resultKey: result.rawValue], deliverImmediately: true
        )
    }
}
