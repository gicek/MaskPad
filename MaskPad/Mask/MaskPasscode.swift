import CryptoKit
import Foundation

/// Stored form of the mask passcode: random salt + SHA-256(salt ‖ code).
///
/// With only 10⁶ six-digit codes, no hash resists offline brute force. The threat model is a
/// passerby touching a Mac that's being remote-controlled, not an attacker with a disk image
/// (FileVault and the login password cover that). Salted hashing just keeps the code out of storage and logs.
struct MaskPasscode: Codable, Equatable {
    let salt: Data
    let digest: Data

    /// Exactly six ASCII digits. `Character.isNumber` alone would accept full-width and other-script digits.
    static func isValidFormat(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func make(code: String) -> MaskPasscode? {
        guard isValidFormat(code) else { return nil }
        var salt = Data(count: 16)
        for index in salt.indices {
            salt[index] = UInt8.random(in: .min ... .max)
        }
        return MaskPasscode(salt: salt, digest: digest(code: code, salt: salt))
    }

    func matches(_ code: String) -> Bool {
        guard Self.isValidFormat(code) else { return false }
        return Self.digest(code: code, salt: salt) == digest
    }

    private static func digest(code: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(code.utf8))
        return Data(hasher.finalize())
    }
}
