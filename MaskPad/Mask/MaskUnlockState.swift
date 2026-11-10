import Foundation

/// Pure state machine for the unlock keypad: digit entry, delete, auto-verify at six digits,
/// and throttling after repeated failures. Time and verification are injected for testability.
struct MaskUnlockState: Equatable {
    /// 5 consecutive failures trigger a 30 s cooldown; the failure count resets afterwards.
    static let maxAttempts = 5
    static let cooldown: TimeInterval = 30
    static let codeLength = 6

    private(set) var entered = ""
    private(set) var failedAttempts = 0
    private(set) var lockedUntil: Date?

    enum Outcome: Equatable {
        /// Fewer than six digits entered.
        case pending
        case unlocked
        case rejected
        /// In cooldown; input ignored.
        case throttled
    }

    func isThrottled(at now: Date) -> Bool {
        lockedUntil.map { now < $0 } ?? false
    }

    /// Appends a digit. At six digits, checks with `verify` and clears the entry.
    mutating func appendDigit(
        _ digit: Character, now: Date, verify: (String) -> Bool
    ) -> Outcome {
        if let until = lockedUntil {
            guard now >= until else { return .throttled }
            lockedUntil = nil
            failedAttempts = 0
        }
        guard digit.isASCII, digit.isNumber, entered.count < Self.codeLength else { return .pending }
        entered.append(digit)
        guard entered.count == Self.codeLength else { return .pending }
        let code = entered
        entered = ""
        if verify(code) {
            failedAttempts = 0
            return .unlocked
        }
        failedAttempts += 1
        if failedAttempts >= Self.maxAttempts {
            lockedUntil = now.addingTimeInterval(Self.cooldown)
        }
        return .rejected
    }

    /// Clears the digits entered; failures and cooldown stay.
    mutating func clearEntry() {
        entered = ""
    }

    mutating func deleteDigit() {
        guard entered.isEmpty == false else { return }
        entered.removeLast()
    }
}
