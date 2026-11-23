import AppKit
import QuartzCore

/// Drag-to-place: dragging the header (expanded) or the minimised line (as a ball of light)
/// shows the SnapOverlay, pulls the orb toward nearby spots, projects the release velocity
/// and springs the panel into the chosen anchor.
///
/// Runs a synchronous tracking loop on the panel (like `PanelController.trackPointer`),
/// working in screen coordinates from `NSEvent.mouseLocation`.
@MainActor
public final class DragPlacement {

    public let controller: PanelController
    public let overlay: SnapOverlay

    /// Called after a drag lands on an anchor (not on Esc-cancel or a plain click).
    public var onPlaced: ((Anchor) -> Void)?

    /// The orb is drawn at 28 pt, but the window is larger so squash-and-stretch (up to 1.84×)
    /// and the orb's glow aren't clipped by the window bounds (a clipped glow shows as a faint
    /// square). The glass fills the window and is scaled down to the orb size with its layer transform.
    private static let orbSize: CGFloat = 28
    private static let orbWindow: CGFloat = 128
    private static let magnetRadius: CGFloat = 110
    private static let magnetStrength: CGFloat = 0.55
    /// Header: pointer travel before a press counts as a drag (below it, it's a click).
    private static let dragThreshold: CGFloat = 3
    private static let historyCount = 6
    private static let flickSpeed: CGFloat = 900   // pt/s
    /// Roughly the header's height: this much of the panel stays on screen when dragged off the bottom.
    private static let headerKeep: CGFloat = 44

    private struct Sample { var p: NSPoint; var t: TimeInterval }

    /// The glow radius GlassView gives the orb, read when the orb look is applied. The layer
    /// transform scales the shadow too, so it is re-applied divided by the scale.
    private var orbGlow: CGFloat = 0

    /// `overlay` defaults to a new `SnapOverlay()` (a default argument can't call a main-actor init).
    public init(controller: PanelController, overlay: SnapOverlay? = nil) {
        self.controller = controller
        self.overlay = overlay ?? SnapOverlay()
    }

    /// Sets `controller.onBeginDrag` so both header drags and minimised-line drags come here.
    public func install() {
        controller.onBeginDrag = { [weak self] event, minimised in
            self?.track(from: event, minimised: minimised)
        }
    }

    // MARK: - Tracking loop

    private func track(from down: NSEvent, minimised: Bool) {
        let panel = controller.panel
        let visible = controller.visibleFrame
        let size = controller.expandedSize
        let originalAnchor = controller.anchor
        let startMouse = NSEvent.mouseLocation
        let startFrame = panel.frame
        // Expanded: keep the cursor on the same point of the header.
        let grab = NSPoint(x: startMouse.x - startFrame.minX, y: startMouse.y - startFrame.minY)
        let reduce = Theme.reduceMotion

        var history: [Sample] = [Sample(p: startMouse, t: ProcessInfo.processInfo.systemUptime)]
        var started = false
        var objectCentre = startFrame.center
        var savedShadow = panel.hasShadow

        func record(_ p: NSPoint, _ t: TimeInterval) {
            history.append(Sample(p: p, t: t))
            if history.count > Self.historyCount { history.removeFirst(history.count - Self.historyCount) }
        }

        func begin() {
            started = true
            var slots: [Anchor: NSRect] = [:]
            for a in Anchor.allCases { slots[a] = Placement.nubFrame(a, in: visible) }
            overlay.begin(on: controller.screen, slots: slots)
            if minimised {
                savedShadow = panel.hasShadow
                panel.hasShadow = false   // the orb casts its own glow (layer shadow)
                controller.glass?.isOrb = true
                orbGlow = controller.glass?.layer?.shadowRadius ?? 0
            }
        }

        func move(to p: NSPoint) {
            if minimised {
                var c = p
                if !reduce {
                    let near = Placement.nearest(to: p, minimised: true, size: size, in: visible)
                    let t = Placement.nubFrame(near, in: visible).center
                    let d = hypot(t.x - p.x, t.y - p.y)
                    if d < Self.magnetRadius {
                        let k = (1 - d / Self.magnetRadius) * Self.magnetStrength
                        c = NSPoint(x: p.x + (t.x - p.x) * k, y: p.y + (t.y - p.y) * k)
                    }
                }
                let s = Self.orbWindow
                let f = NSRect(x: (c.x - s / 2).rounded(), y: (c.y - s / 2).rounded(), width: s, height: s)
                if panel.frame.size != f.size {
                    panel.setFrame(f, display: true)
                } else {
                    panel.setFrameOrigin(f.origin)
                }
                applyOrbTransform(velocity: reduce ? .zero : velocity(history, perMillisecond: true))
                objectCentre = c
                let near = nearestAnchor(to: c, minimised: true)
                overlay.update(pointer: p, object: c, nearest: near, ghost: ghost(for: near))
            } else {
                let f = panel.frame
                var o = NSPoint(x: p.x - grab.x, y: p.y - grab.y)
                // Keep the header reachable: top edge inside the visible frame, and at least
                // 80 pt of the panel's width on screen.
                let keep: CGFloat = 80
                o.x = min(max(o.x, visible.minX - f.width + keep), visible.maxX - keep)
                o.y = min(max(o.y, visible.minY + Self.headerKeep - f.height), visible.maxY - f.height)
                panel.setFrameOrigin(o)
                objectCentre = NSRect(origin: o, size: f.size).center
                let near = nearestAnchor(to: objectCentre, minimised: false)
                // As in the mockup, the trail and beam follow the pointer (the panel covers its centre).
                overlay.update(pointer: p, object: p, nearest: near, ghost: ghost(for: near))
            }
        }

        if minimised {
            // The nub already moved past its 4 pt threshold before handing off.
            begin()
            let p = NSEvent.mouseLocation
            record(p, ProcessInfo.processInfo.systemUptime)
            move(to: p)
        }

        var cancelled = false
        tracking: while true {
            // Wake up a few times a second even without events: the panel is non-activating, so a
            // .keyDown for Esc only arrives when Margin is the active app; otherwise poll the key.
            let ev = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                     until: Date(timeIntervalSinceNow: 0.05),
                                     inMode: .eventTracking, dequeue: true)
            if Self.escapeIsDown {
                cancelled = true
                break tracking
            }
            guard let ev else {
                // Lost the mouse-up (e.g. another app grabbed the pointer): treat as a release.
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    record(NSEvent.mouseLocation, ProcessInfo.processInfo.systemUptime)
                    break tracking
                }
                continue
            }
            switch ev.type {
            case .keyDown:
                if ev.keyCode == 53 {   // Esc
                    cancelled = true
                    break tracking
                }
            case .leftMouseUp:
                record(NSEvent.mouseLocation, ev.timestamp)
                break tracking
            default:
                let p = NSEvent.mouseLocation
                record(p, ev.timestamp)
                if !started {
                    guard hypot(p.x - startMouse.x, p.y - startMouse.y) > Self.dragThreshold else { continue }
                    begin()
                }
                move(to: p)
            }
        }

        // Plain click on the header: nothing to place.
        guard started else { return }

        let target: Anchor
        if cancelled {
            target = originalAnchor
        } else {
            let current = nearestAnchor(to: objectCentre, minimised: minimised)
            // Apple-style projection of the release velocity (v in pt/s).
            let v = velocity(history, perMillisecond: false)
            let project: (CGFloat) -> CGFloat = { v in (v / 1000) * 0.99 / (1 - 0.99) }
            let projected = NSPoint(x: objectCentre.x + project(v.dx) * 0.5,
                                    y: objectCentre.y + project(v.dy) * 0.5)
            target = hypot(v.dx, v.dy) > Self.flickSpeed
                ? nearestAnchor(to: projected, minimised: minimised)
                : current
        }

        if minimised {
            resetOrbTransform()
            controller.glass?.isOrb = false
            panel.hasShadow = savedShadow
        }
        // Springs into place (minimised or expanded frame), persists the anchor and glints after
        // the morph, so no extra glint here.
        controller.setAnchor(target, animated: true)
        overlay.end(landing: controller.targetFrame())
        if !cancelled { onPlaced?(target) }
    }

    private static var escapeIsDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 53)
    }

    // MARK: - Geometry

    private func nearestAnchor(to p: NSPoint, minimised: Bool) -> Anchor {
        Placement.nearest(to: p, minimised: minimised, size: controller.expandedSize, in: controller.visibleFrame)
    }

    private func ghost(for anchor: Anchor) -> NSRect {
        Placement.panelFrame(anchor, size: controller.expandedSize, in: controller.visibleFrame)
    }

    /// Velocity across the sample history: pt/ms when `perMillisecond`, else pt/s.
    /// dt is floored at 16 ms (as in the mockup) so a single fast frame doesn't explode.
    private func velocity(_ h: [Sample], perMillisecond: Bool) -> CGVector {
        guard let a = h.first, let b = h.last, h.count > 1 else { return .zero }
        let dtMs = max(16, (b.t - a.t) * 1000)
        let vx = (b.p.x - a.p.x) / dtMs, vy = (b.p.y - a.p.y) / dtMs
        return perMillisecond ? CGVector(dx: vx, dy: vy) : CGVector(dx: vx * 1000, dy: vy * 1000)
    }

    // MARK: - Orb squash & stretch

    /// rotate(θ) · scale(1 + 0.6s, 1 − 0.25s) · rotate(−θ), about the layer centre, on top of the
    /// base scale that shrinks the glass to the 28 pt orb. `v` in pt/ms.
    private func applyOrbTransform(velocity v: CGVector) {
        guard let glass = controller.glass, let layer = glass.layer else { return }
        let base = Self.orbSize / max(1, min(glass.bounds.width, glass.bounds.height))
        let s = min(1.4, hypot(v.dx, v.dy))
        // The glass is non-flipped (y up), like screen coordinates, so the screen angle applies as is.
        let theta = atan2(v.dy, v.dx)
        // Applied right to left: rotate(−θ), then scale, then rotate(θ).
        let m = CGAffineTransform(rotationAngle: -theta)
            .concatenating(CGAffineTransform(scaleX: base * (1 + 0.6 * s), y: base * (1 - 0.25 * s)))
            .concatenating(CGAffineTransform(rotationAngle: theta))
        setTransform(m, on: layer, bounds: glass.bounds)
        // Keep the glow at its on-screen size (also re-asserts it if a hover re-applied the look).
        let glow = orbGlow / base
        if orbGlow > 0, layer.shadowRadius != glow {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.shadowRadius = glow
            CATransaction.commit()
        }
    }

    private func resetOrbTransform() {
        guard let glass = controller.glass, let layer = glass.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(.identity)
        if orbGlow > 0 { layer.shadowRadius = orbGlow }
        CATransaction.commit()
        orbGlow = 0
    }

    /// Applies `m` about the layer's centre, whatever its anchor point (AppKit uses (0, 0)).
    private func setTransform(_ m: CGAffineTransform, on layer: CALayer, bounds: NSRect) {
        let ap = layer.anchorPoint
        let cx = bounds.width * (0.5 - ap.x), cy = bounds.height * (0.5 - ap.y)
        let t = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(m)
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(t)
        CATransaction.commit()
    }
}
