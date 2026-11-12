import Foundation

enum AppIdentity {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.gicek.maskpad"
    static let urlScheme = Bundle.main.object(forInfoDictionaryKey: "MaskPadURLScheme") as? String ?? "maskpad"
    static let passcodeService = bundleIdentifier + ".passcode"
    static let reopenNotification = Notification.Name(bundleIdentifier + ".reopen")
    static let forwardURLNotification = Notification.Name(bundleIdentifier + ".forwardURL")
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif
}
