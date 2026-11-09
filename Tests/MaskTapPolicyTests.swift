import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import MaskPad

struct MaskTapPolicyTests {
    private typealias Event = MaskTapPolicy.Event

    private func decide(
        _ policy: inout MaskTapPolicy, _ event: Event, acceptsUnlockKeys: Bool = true, wakes: Bool = false
    ) -> MaskTapPolicy.Verdict {
        policy.decide(event, acceptsUnlockKeys: acceptsUnlockKeys, wake: { wakes })
    }

    @Test func pointerMoveAndLeftClickPass() {
        var policy = MaskTapPolicy()
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            #expect(decide(&policy, Event(type: type)) == .pass)
        }
    }

    @Test func everythingElseIsSwallowed() {
        var policy = MaskTapPolicy()
        for type in [CGEventType.rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .keyUp, .flagsChanged] {
            #expect(decide(&policy, Event(type: type, keyCode: Int64(kVK_ANSI_A))) == .swallow)
        }
        // System-defined keys (volume, brightness, power press, etc.) and private types such as gestures.
        #expect(decide(&policy, Event(type: CGEventType(rawValue: 14)!, isAuxControlButton: true)) == .swallow)
        #expect(decide(&policy, Event(type: CGEventType(rawValue: 29)!)) == .swallow)
    }

    @Test func digitsGoToKeypadAndAreSwallowed() {
        var policy = MaskTapPolicy()
        #expect(decide(&policy, Event(type: .keyDown, keyCode: Int64(kVK_ANSI_5))) == .unlockKey(.digit("5")))
        #expect(decide(&policy, Event(type: .keyDown, keyCode: Int64(kVK_Delete))) == .unlockKey(.delete))
        // A digit with a modifier is not input.
        #expect(decide(&policy, Event(type: .keyDown, keyCode: Int64(kVK_ANSI_5), flags: .maskCommand)) == .swallow)
        // Digits are still swallowed when the unlock keypad is not accepting input.
        #expect(decide(&policy, Event(type: .keyDown, keyCode: Int64(kVK_ANSI_5)), acceptsUnlockKeys: false) == .swallow)
    }

    /// While the screen is off, the first key or click only wakes it and is swallowed; pointer movement passes through.
    @Test func wakeEventIsSwallowedExceptPointerMove() {
        var policy = MaskTapPolicy()
        #expect(decide(&policy, Event(type: .keyDown, keyCode: Int64(kVK_ANSI_5)), wakes: true) == .swallow)
        #expect(decide(&policy, Event(type: .mouseMoved), wakes: true) == .pass)
        #expect(decide(&policy, Event(type: CGEventType(rawValue: 14)!, isAuxControlButton: true), wakes: true) == .swallow)
    }

    /// When a wake swallows a left mouse-down, that click's drags and mouse-up are swallowed too, then behavior returns to normal.
    @Test func wakeClickIsSwallowedUntilMouseUp() {
        var policy = MaskTapPolicy()
        #expect(decide(&policy, Event(type: .leftMouseDown), wakes: true) == .swallow)
        #expect(decide(&policy, Event(type: .leftMouseDragged)) == .swallow)
        #expect(decide(&policy, Event(type: .leftMouseUp)) == .swallow)
        #expect(decide(&policy, Event(type: .leftMouseDown)) == .pass)
    }

    /// Keys held when the mask appears get one physical key-up passed through; key-downs, other keys, and synthesized key-ups from other processes are blocked.
    @Test func heldKeyReleasePassesOnce() {
        var policy = MaskTapPolicy(releasePassThroughKeys: [Int64(kVK_ANSI_L)])
        #expect(decide(&policy, Event(type: .keyDown, keyCode: Int64(kVK_ANSI_L))) == .swallow)
        #expect(decide(&policy, Event(type: .keyUp, keyCode: Int64(kVK_ANSI_A))) == .swallow)
        #expect(decide(&policy, Event(type: .keyUp, keyCode: Int64(kVK_ANSI_L), sourcePID: 4242)) == .swallow)
        #expect(decide(&policy, Event(type: .keyUp, keyCode: Int64(kVK_ANSI_L))) == .pass)
        #expect(decide(&policy, Event(type: .keyUp, keyCode: Int64(kVK_ANSI_L))) == .swallow)
        #expect(policy.releasePassThroughKeys.isEmpty)
    }

    /// A passed-through key-up does not count as local activity and does not wake the screen.
    @Test func heldKeyReleaseDoesNotWake() {
        var policy = MaskTapPolicy(releasePassThroughKeys: [Int64(kVK_ANSI_L)])
        var woke = false
        let verdict = policy.decide(Event(type: .keyUp, keyCode: Int64(kVK_ANSI_L)), acceptsUnlockKeys: true) {
            woke = true
            return true
        }
        #expect(verdict == .pass)
        #expect(woke == false)
    }
}
