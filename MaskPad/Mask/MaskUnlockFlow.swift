import Foundation

/// Which unlock page the mask shows, and the only ways between them (pure logic; `MaskUnlockViewModel`
/// drives it):
///
///     message (if set) ──Unlock──▶ keypad ◀──Forgot Passcode / Back──▶ forgotPasscode
///     any page ──`returnDelay` without input, or the screen waking from dimming──▶ first page
///
/// - Every move is allowed only from its own page, so a click on a page that is fading out is ignored.
/// - Digits and Delete, on screen or on the keyboard, count only on the keypad, and on "Forgot Passcode",
///   which switches back to the keypad to show them. On the message page they are ignored: only Unlock
///   leads on.
/// - Going back to the first page also clears the digits entered (the caller does that); failed attempts
///   and the cooldown stay.
///
/// Every page is centered on the screen (`MaskUnlockView`).
///
/// The pages only decide what the mask shows. Blocking input (`MaskInputBlocker`), keeping the pointer
/// out of hot corners, lock detection and dimming don't depend on them.
struct MaskUnlockFlow: Equatable {
    enum Page: Equatable {
        /// The message from Settings, with an Unlock button.
        case message
        /// Number keypad.
        case keypad
        /// Instructions for a forgotten passcode.
        case forgotPasscode
    }

    static let returnDelay: TimeInterval = 30

    let hasMessage: Bool
    private(set) var page: Page
    /// The last move or input, for going back to the first page.
    private(set) var lastInput: Date

    init(hasMessage: Bool, now: Date) {
        self.hasMessage = hasMessage
        page = hasMessage ? .message : .keypad
        lastInput = now
    }

    var firstPage: Page { hasMessage ? .message : .keypad }

    /// The message page's Unlock button.
    mutating func unlock(now: Date) {
        move(from: .message, to: .keypad, now: now)
    }

    /// "Forgot Passcode?" on the keypad.
    mutating func showForgotPasscode(now: Date) {
        move(from: .keypad, to: .forgotPasscode, now: now)
    }

    /// Back on the "Forgot Passcode" page.
    mutating func back(now: Date) {
        move(from: .forgotPasscode, to: .keypad, now: now)
    }

    /// A digit or Delete. Returns whether it counts; on "Forgot Passcode" it also switches to the keypad.
    mutating func input(now: Date) -> Bool {
        guard page != .message else { return false }
        page = .keypad
        lastInput = now
        return true
    }

    /// Back to the first page; the caller clears the digits entered.
    mutating func restart(now: Date) {
        page = firstPage
        lastInput = now
    }

    /// Restarts after `returnDelay` without input. Returns whether it did.
    mutating func restartIfIdle(now: Date) -> Bool {
        guard now.timeIntervalSince(lastInput) >= Self.returnDelay else { return false }
        restart(now: now)
        return true
    }

    private mutating func move(from: Page, to: Page, now: Date) {
        guard page == from else { return }
        page = to
        lastInput = now
    }
}
