import Combine
import Foundation

/// Global hotkey bindings.
///
/// New installs get the default "Turn on screen mask" chord. Saved customizations, including cleared
/// bindings, win; a missing entry is never taken as a request to restore the default.
@MainActor
final class HotKeyBindingStore: ObservableObject {
    static let shared = HotKeyBindingStore()

    @Published private(set) var bindings: [MacHotKeyAction: KeyChord] = [:]

    private let defaults: UserDefaults
    private static let key = "hotKeyBindings"

    private static var defaultBindings: [MacHotKeyAction: KeyChord] {
        Dictionary(uniqueKeysWithValues: MacHotKeyAction.allCases.map { ($0, $0.defaultChord) })
    }

    var hasDefaultBindings: Bool { bindings == Self.defaultBindings }

    /// In-memory only when running tests without injected defaults: the test host shares standard
    /// defaults with the real app, and tests must not clobber the user's hotkeys.
    private let memoryOnly: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        memoryOnly = defaults === UserDefaults.standard && TestEnvironment.isRunningInTests
        bindings = memoryOnly ? Self.defaultBindings : Self.load(from: defaults)
    }

    func chord(for action: MacHotKeyAction) -> KeyChord? { bindings[action] }

    /// Publishes all defaults at once so observers don't see intermediate states and re-register repeatedly.
    func restoreDefaults() {
        bindings = Self.defaultBindings
        persist()
    }

    /// Sets or clears an action's chord. **A chord binds to only one action**: it's removed from any
    /// other action first, otherwise the second registration fails while the UI shows the chord on both rows.
    func set(_ chord: KeyChord?, for action: MacHotKeyAction) {
        if let chord {
            for (other, existing) in bindings where other != action && existing == chord {
                bindings.removeValue(forKey: other)
            }
            bindings[action] = chord
        } else {
            bindings.removeValue(forKey: action)
        }
        persist()
    }

    private func persist() {
        guard memoryOnly == false else { return }
        let encodable = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func load(from defaults: UserDefaults) -> [MacHotKeyAction: KeyChord] {
        guard defaults.object(forKey: key) != nil else { return defaultBindings }
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else {
            return [:]
        }
        // Drop unknown action names (e.g. written by a newer version before a downgrade).
        var result: [MacHotKeyAction: KeyChord] = [:]
        for (name, chord) in decoded {
            guard let action = MacHotKeyAction(rawValue: name) else { continue }
            result[action] = chord
        }
        return result
    }
}
