import AppKit

/// Pure geometry: where the panel or the minimised line goes for each anchor.
/// All rects are in screen coordinates (origin bottom-left), inside `visible` (NSScreen.visibleFrame).
public enum Placement {

    public static func panelFrame(_ anchor: Anchor, size: NSSize, in visible: NSRect) -> NSRect {
        let m = Theme.panelMargin
        let w = min(size.width, visible.width - 2 * m)
        let h = min(size.height, visible.height - 2 * m)
        return frame(anchor, width: w, height: h, margin: m, in: visible)
    }

    public static func nubSize(_ anchor: Anchor) -> NSSize {
        if anchor.isCorner { return NSSize(width: Theme.nubCorner, height: Theme.nubCorner) }
        return anchor.isVerticalEdge ? NSSize(width: Theme.nubThin, height: Theme.nubLong)
                                     : NSSize(width: Theme.nubLong, height: Theme.nubThin)
    }

    public static func nubFrame(_ anchor: Anchor, in visible: NSRect) -> NSRect {
        let s = nubSize(anchor)
        return frame(anchor, width: s.width, height: s.height, margin: Theme.nubMargin, in: visible)
    }

    public static func frame(_ anchor: Anchor, minimised: Bool, size: NSSize, in visible: NSRect) -> NSRect {
        minimised ? nubFrame(anchor, in: visible) : panelFrame(anchor, size: size, in: visible)
    }

    /// The anchor whose frame centre is closest to `point`.
    public static func nearest(to point: NSPoint, minimised: Bool, size: NSSize, in visible: NSRect) -> Anchor {
        Anchor.allCases.min { a, b in
            dist(frame(a, minimised: minimised, size: size, in: visible).center, point)
                < dist(frame(b, minimised: minimised, size: size, in: visible).center, point)
        } ?? .right
    }

    private static func frame(_ a: Anchor, width w: CGFloat, height h: CGFloat, margin m: CGFloat, in v: NSRect) -> NSRect {
        let x = a.hasLeft ? v.minX + m : a.hasRight ? v.maxX - w - m : v.midX - w / 2
        // screen coordinates: top is maxY
        let y = a.hasTop ? v.maxY - h - m : a.hasBottom ? v.minY + m : v.midY - h / 2
        return NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    private static func dist(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

public extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
