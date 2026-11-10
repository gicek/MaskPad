import CoreGraphics
import Testing
@testable import MaskPad

struct HotCornerGuardTests {
    private let m = HotCornerGuard.margin
    /// A 1440 x 900 main display and a 1920 x 1080 display to its right, top-aligned.
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let side = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    @Test func everyCornerIsPushedOut() {
        let guard_ = HotCornerGuard(displays: [main])
        // The extreme pixel of each corner: the pointer's last position is maxX - 1, maxY - 1.
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1439, y: 0), CGPoint(x: 0, y: 899), CGPoint(x: 1439, y: 899)]
        for corner in corners {
            let adjusted = guard_.adjusted(corner)
            #expect(adjusted != nil)
            // The result is outside the zone: re-checking it changes nothing.
            #expect(adjusted.flatMap(guard_.adjusted) == nil)
        }
    }

    @Test func pushesAlongTheShorterAxisSoThePointerSlidesAlongEdges() {
        let guard_ = HotCornerGuard(displays: [main])
        // 1 pt from the left edge and 4 pt from the top: pushing down (2 pt) is shorter than pushing
        // right (5 pt), so the pointer keeps hugging the left edge.
        #expect(guard_.adjusted(CGPoint(x: 1, y: 4)) == CGPoint(x: 1, y: m))
        // Bottom right corner, along the bottom edge: pushed left, y unchanged.
        #expect(guard_.adjusted(CGPoint(x: 1436, y: 899)) == CGPoint(x: 1439 - m, y: 899))
    }

    @Test func edgesAndTheMiddleAreLeftAlone() {
        let guard_ = HotCornerGuard(displays: [main])
        #expect(guard_.adjusted(CGPoint(x: 720, y: 0)) == nil)      // Top edge, middle
        #expect(guard_.adjusted(CGPoint(x: 0, y: 450)) == nil)      // Left edge, middle
        #expect(guard_.adjusted(CGPoint(x: m, y: 0)) == nil)        // Just outside the top-left zone
        #expect(guard_.adjusted(CGPoint(x: 720, y: 450)) == nil)
    }

    @Test func eachDisplayHasItsOwnCorners() {
        let guard_ = HotCornerGuard(displays: [main, side])
        #expect(guard_.adjusted(CGPoint(x: 3359, y: 1079)) != nil)  // Bottom right of the side display
        #expect(guard_.adjusted(CGPoint(x: 1440, y: 1079)) != nil)  // Its bottom left, below the main display
        #expect(guard_.adjusted(CGPoint(x: 2000, y: 1079)) == nil)
    }

    @Test func noDisplaysMeansNoChange() {
        #expect(HotCornerGuard().adjusted(.zero) == nil)
    }

    @Test func tapPolicyMovesPointerOutOfCorners() {
        var policy = MaskTapPolicy()
        policy.hotCornerGuard = HotCornerGuard(displays: [main])
        let corner = CGPoint(x: 0, y: 899)
        let moved = policy.decide(.init(type: .mouseMoved, location: corner), acceptsUnlockKeys: true, wake: { false })
        guard case .passAt(let location) = moved else {
            Issue.record("expected passAt, got \(moved)")
            return
        }
        #expect(policy.hotCornerGuard.adjusted(location) == nil)
        // Left drags are guarded too; clicks and moves elsewhere pass unchanged.
        let drag = policy.decide(.init(type: .leftMouseDragged, location: corner), acceptsUnlockKeys: true, wake: { false })
        #expect(drag == moved)
        #expect(policy.decide(.init(type: .leftMouseDown, location: corner), acceptsUnlockKeys: true, wake: { false }) == .pass)
        #expect(policy.decide(.init(type: .mouseMoved, location: CGPoint(x: 700, y: 400)), acceptsUnlockKeys: true, wake: { false }) == .pass)
    }
}
