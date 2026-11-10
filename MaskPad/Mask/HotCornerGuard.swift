import CoreGraphics

/// Keeps the pointer out of the screen corners while masked, so hot corners can't fire.
///
/// Hot corners are triggered by the Dock from the pointer position, and the pointer has to move freely
/// for the on-screen keypad, so blocking events doesn't help. Hot corners run under the mask unseen
/// but still act: Mission Control or Quick Note take the focus (the next click on the keypad is lost),
/// and Lock Screen or Put Display to Sleep lock the Mac and interrupt whatever runs under the mask.
///
/// The mask's input tap rewrites the location of pointer moves and left drags that land within `margin`
/// of a display corner, pushing them out along the shorter way, so the pointer still slides along the
/// edges. Nothing in the user's settings changes, so there is nothing to restore if MaskPad quits.
/// Every display corner is guarded, including ones shared with another display; the cost there is a
/// tiny square the pointer can't enter.
///
/// Pointer input from Screen Sharing doesn't pass the tap, so a remote user can still reach the corners.
struct HotCornerGuard: Equatable {
    /// Display bounds in global coordinates (origin at the top left of the main display, y down),
    /// the same space as `CGEvent.location`.
    var displays: [CGRect] = []
    /// How close to a corner the pointer may get, in points.
    static let margin: CGFloat = 6

    /// The bounds of the active displays.
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// The location to use instead of `point`, or nil if `point` is not in a corner zone.
    func adjusted(_ point: CGPoint) -> CGPoint? {
        let m = Self.margin
        for display in displays where display.width > 2 * m && display.height > 2 * m {
            // The pointer's extreme positions are the first and last pixel: maxX and maxY are exclusive.
            let lastX = display.maxX - 1, lastY = display.maxY - 1
            // Distance from each edge; a corner zone is where both axes are within `margin` of an edge.
            let fromLeft = point.x - display.minX, fromRight = lastX - point.x
            let fromTop = point.y - display.minY, fromBottom = lastY - point.y
            guard fromLeft >= 0, fromRight >= 0, fromTop >= 0, fromBottom >= 0 else { continue }
            let nearLeft = fromLeft < m, nearRight = fromRight < m
            let nearTop = fromTop < m, nearBottom = fromBottom < m
            guard nearLeft || nearRight, nearTop || nearBottom else { continue }
            // Push out along the axis that needs the smaller move.
            let depthX = m - (nearLeft ? fromLeft : fromRight)
            let depthY = m - (nearTop ? fromTop : fromBottom)
            var result = point
            if depthX <= depthY {
                result.x = nearLeft ? display.minX + m : lastX - m
            } else {
                result.y = nearTop ? display.minY + m : lastY - m
            }
            return result
        }
        return nil
    }
}
