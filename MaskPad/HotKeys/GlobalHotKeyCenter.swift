import Carbon.HIToolbox
import Combine
import Foundation

/// Pure state; registers nothing. Bindings saved during recording take effect after the last recording ends.
struct GlobalHotKeyRegistrationState {
    var bindings: [MacHotKeyAction: KeyChord] = [:]
    private var recordingSessions: Set<UUID> = []

    init(bindings: [MacHotKeyAction: KeyChord] = [:]) {
        self.bindings = bindings
    }

    var effectiveBindings: [MacHotKeyAction: KeyChord] {
        recordingSessions.isEmpty ? bindings : [:]
    }

    mutating func beginRecording() -> UUID {
        let token = UUID()
        recordingSessions.insert(token)
        return token
    }

    @discardableResult
    mutating func endRecording(_ token: UUID) -> Bool {
        recordingSessions.remove(token) != nil
    }
}

/// Registers and dispatches global hotkeys.
///
/// **Carbon `RegisterEventHotKey`, not `CGEventTap`**: Carbon needs no Accessibility or Input
/// Monitoring permission (the system matches and only reports hits), whereas a tap sees every
/// keystroke, which contradicts the project's input-security stance.
///
/// The cost is contention: if another app registered the chord first, registration fails and the UI
/// flags it via `unavailableActions`. Chords reserved by the system (⌘Space, etc.) may register
/// but never fire; no API detects that, so the user has to pick another.
@MainActor
final class GlobalHotKeyCenter: ObservableObject {
    static let shared = GlobalHotKeyCenter()

    /// Actions whose registration failed (chord taken by another app); the UI asks for a different chord.
    @Published private(set) var unavailableActions: Set<MacHotKeyAction> = []

    /// Trigger callback, wired to `MaskActions.run` at app launch.
    var onTrigger: ((MacHotKeyAction) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (action: MacHotKeyAction, ref: EventHotKeyRef)] = [:]
    private var nextIdentifier: UInt32 = 1
    private var observation: AnyCancellable?
    private var registrationState = GlobalHotKeyRegistrationState()

    /// Four-char signature Carbon uses to tell apps' hotkeys apart.
    private static let signature: OSType = 0x4D53_4B50 // 'MSKP'

    /// Registers the store's bindings and re-registers whenever they change.
    ///
    /// Skipped in tests: the test host is the real app and would steal chords system-wide on the dev machine.
    func start(store: HotKeyBindingStore) {
        guard TestEnvironment.isRunningInTests == false else { return }
        observation = store.$bindings.sink { [weak self] bindings in
            self?.apply(bindings)
        }
    }

    /// Re-registers everything rather than diffing: there are only one or two hotkeys, and a diffing
    /// bug would leave a replaced chord still active.
    func apply(_ bindings: [MacHotKeyAction: KeyChord]) {
        registrationState.bindings = bindings
        updateRegistrations()
    }

    /// Unregisters from Carbon (not just muting callbacks) so the recorder's key monitor can capture already-bound chords.
    func beginRecording() -> UUID {
        let token = registrationState.beginRecording()
        updateRegistrations()
        return token
    }

    func endRecording(_ token: UUID) {
        guard registrationState.endRecording(token) else { return }
        updateRegistrations()
    }

    private func updateRegistrations() {
        unregisterAll()
        guard TestEnvironment.isRunningInTests == false else { return }
        let bindings = registrationState.effectiveBindings
        guard bindings.isEmpty == false else { return }
        installHandlerIfNeeded()

        var failed: Set<MacHotKeyAction> = []
        // Register in enum order so precedence matches the UI's top-to-bottom order, not dictionary order.
        for action in MacHotKeyAction.allCases {
            guard let chord = bindings[action] else { continue }
            // Never register a chord without ⌘/⌥/⌃: it would swallow a plain or shifted key system-wide.
            // The recorder already rejects these; this is a backstop for hand-edited preferences.
            guard chord.isValidHotKey else {
                failed.insert(action)
                continue
            }

            let identifier = nextIdentifier
            nextIdentifier += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
            let status = RegisterEventHotKey(
                UInt32(chord.keyCode),
                chord.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registrations[identifier] = (action, ref)
            } else {
                failed.insert(action)
            }
            if status != noErr {
                Log.hotKey.error("register \(action.rawValue, privacy: .public) \(chord.displayText, privacy: .public) failed: \(status)")
            }
        }
        unavailableActions = failed
    }

    private func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
        unavailableActions = []
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // A non-capturing closure converts directly to a C function pointer; a global constant would be
        // a non-Sendable global and fail strict concurrency checking.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                // Carbon dispatches application-target events on the main thread.
                MainActor.assumeIsolated {
                    GlobalHotKeyCenter.shared.dispatch(identifier: hotKeyID.id)
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )
    }

    private func dispatch(identifier: UInt32) {
        guard let action = registrations[identifier]?.action else { return }
        onTrigger?(action)
    }
}
