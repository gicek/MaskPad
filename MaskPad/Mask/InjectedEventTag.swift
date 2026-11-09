import CoreGraphics

/// Marks CGEvents synthesized by MaskPad (a magic value in `eventSourceUserData`).
///
/// The mask's input-blocking tap uses it to let our own HID-level events through (resetting
/// stuck modifiers on engage, the lock-shortcut fallback); otherwise they'd be swallowed as local input.
enum InjectedEventTag {
    /// Randomized per launch: a fixed value would be a public key for bypassing the mask,
    /// since any process that can post events could stamp it.
    static let magic: Int64 = Int64.random(in: 1 ... Int64.max)

    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == magic
    }
}

extension CGEvent {
    /// Tags the event as ours, then posts it.
    func postTagged(tap: CGEventTapLocation) {
        setIntegerValueField(.eventSourceUserData, value: InjectedEventTag.magic)
        post(tap: tap)
    }
}
