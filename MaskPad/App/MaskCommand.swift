import Foundation

/// Commands from outside the app, through the `maskpad://` URL scheme:
///
/// - `maskpad://on` turns the screen mask on (launchers, Shortcuts, `open`, scripts and automation).
/// - `maskpad://status` reports whether it is on.
///
/// There is deliberately no command to turn the mask off: any process can open these URLs, and only a
/// person at the Mac (or through Screen Sharing) may remove the mask, with the passcode.
///
/// A `reply` query item with a UUID asks the app to post the result as a distributed notification
/// (`replyNotification`, object: the UUID, userInfo `result`: a `MaskCommandResult` raw value). The
/// `maskpad` command-line tool (`CommandLineTool`) uses it to wait for the result and set its exit code.
enum MaskCommand: String, CaseIterable, Equatable {
    case on
    case status

    static let scheme = AppIdentity.urlScheme
    static let replyNotification = replyNotificationName(for: AppIdentity.bundleIdentifier)
    static func replyNotificationName(for bundleIdentifier: String) -> Notification.Name {
        Notification.Name(bundleIdentifier + ".commandReply")
    }
    static let resultKey = "result"

    struct Request: Equatable {
        var command: MaskCommand
        /// Present when the sender waits for the result.
        var replyID: String?
    }

    /// Parses `maskpad://<command>[?reply=<UUID>]`; nil for anything else. Only a well-formed UUID is
    /// accepted as the reply ID, so a URL can't make the app post an arbitrary notification object.
    static func parse(_ url: URL, scheme: String = Self.scheme) -> Request? {
        guard url.scheme?.lowercased() == scheme,
              let host = url.host(percentEncoded: false)?.lowercased(), let command = MaskCommand(rawValue: host),
              ["", "/"].contains(url.path(percentEncoded: false))
        else { return nil }
        let reply = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "reply" }?.value
        return Request(command: command, replyID: reply.flatMap(UUID.init(uuidString:))?.uuidString)
    }

    func url(replyID: String? = nil, scheme: String = Self.scheme) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = rawValue
        if let replyID { components.queryItems = [URLQueryItem(name: "reply", value: replyID)] }
        return components.url!
    }
}

/// The outcome of a `MaskCommand`.
enum MaskCommandResult: String, Equatable {
    /// The mask is on (it was just turned on, or `status` found it on).
    case on
    /// `on` found the mask already on.
    case alreadyOn
    /// `status` found the mask off.
    case off
    /// `on` failed: no passcode is set.
    case noPasscode
    /// `on` failed: MaskPad doesn't have Accessibility permission, so it can't block input.
    case noAccessibility
}
