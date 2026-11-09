import Foundation
import Security

/// Keychain storage for the mask passcode (a salted hash, see `MaskPasscode`).
/// Keychain rather than UserDefaults: preference files are readable by any process.
///
/// Whether a passcode exists is cached (`hasPasscode`) because idle auto-mask polling, the menu and
/// hotkeys all ask, and the keychain shouldn't be hit on the main thread each time. `load()` reads it on engage.
///
/// In tests it stays in memory: the test host is the real app, so touching the keychain would change
/// the developer's real passcode and could block on a keychain authorization prompt after re-signing.
final class MaskPasscodeStore: @unchecked Sendable {
    static let shared = MaskPasscodeStore()

    /// Posted after the passcode is saved or cleared (the keychain has no change notification),
    /// for state that depends on whether a passcode exists, e.g. the auto-mask sleep assertion.
    static let didChangeNotification = Notification.Name("com.gicek.maskpad.passcodeDidChange")

    private let service = "com.gicek.maskpad.passcode"
    private let account = "mask"
    private let memoryOnly: Bool
    private var memoryPasscode: MaskPasscode?
    private var cachedHasPasscode: Bool?

    init(memoryOnly: Bool = TestEnvironment.isRunningInTests) {
        self.memoryOnly = memoryOnly
    }

    /// Whether a passcode is set. Reads the keychain once, then uses the cache.
    var hasPasscode: Bool {
        if let cachedHasPasscode { return cachedHasPasscode }
        let has = load() != nil
        cachedHasPasscode = has
        return has
    }

    func load() -> MaskPasscode? {
        if memoryOnly { return memoryPasscode }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MaskPasscode.self, from: data)
    }

    @discardableResult
    func save(_ passcode: MaskPasscode) -> Bool {
        let saved: Bool
        if memoryOnly {
            memoryPasscode = passcode
            saved = true
        } else {
            guard let data = try? JSONEncoder().encode(passcode) else { return false }
            SecItemDelete(baseQuery as CFDictionary)
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            // Readable after lock/restart, but not migrated to other machines.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            saved = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        }
        // On failure the old item is already deleted, so drop the cache and re-read.
        cachedHasPasscode = saved ? true : nil
        if saved {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
        return saved
    }

    func clear() {
        if memoryOnly {
            memoryPasscode = nil
        } else {
            SecItemDelete(baseQuery as CFDictionary)
        }
        cachedHasPasscode = false
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
