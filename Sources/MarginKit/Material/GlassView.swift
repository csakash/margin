import AppKit
import QuartzCore

/// The black-glass material shared with the app icon: blur, tint, top light cone, rim light,
/// pointer-tracking specular hotspot and a one-shot sheen sweep.
/// CONTRACT (Wave 0). Loop D implements the layers. Content goes in `contentView`.
///
/// Stack, bottom → top, inside a rounded, clipped container:
/// blur → tint (or orb fill) → light cone → clearcoat → `contentView` → rim + hotspot → sheen → minimised line.
/// Everything is static CALayers; nothing animates or redraws while idle.
@MainActor
public final class GlassView: NSView {

    /// Put the panel UI here; it sits above the material layers.
    public let contentView = NSView()

    /// When true, draws the minimised look (capsule + glowing centre line or corner dot).
    public var isMinimised = false { didSet { if isMinimised != oldValue { lookChanged() } } }
    /// Which edge/corner the minimised line hugs (affects line orientation).
    public var anchor: Anchor = .right { didSet { if anchor != oldValue { lookChanged() } } }
    /// While dragging the minimised line it becomes a ball of light.
    public var isOrb = false { didSet { if isOrb != oldValue { lookChanged() } } }

    /// True while the pointer is inside the view.
    public private(set) var isHovered = false

    // MARK: Views

    /// Rounded, clipping container for every material layer and the content.
    private let clipView = GlassLayerView()
    private let blur = NSVisualEffectView()
    /// Tint, orb fill, light cone, clearcoat (below the content).
    private let underlay = GlassLayerView()
    /// Rim, hotspot, sheen, minimised line (above the content, click-through).
    private let overlay = GlassLayerView()

    // MARK: Layers

    private let tint = CAGradientLayer()
    private let orbFill = CAGradientLayer()
    private let cone = CAGradientLayer()
    private let coat = CAGradientLayer()

    private let rimGroup = CALayer()
    private let rimGradient = CAGradientLayer()
    private let hotspot = CAGradientLayer()
    private let rimMask = CAShapeLayer()

    private let sheenGroup = CALayer()
    private let sheen = CAGradientLayer()

    private let line = CALayer()

    // MARK: State

    private var tracking: NSTrackingArea?
    /// Pointer in view (flipped, top-left) coordinates; nil when outside.
    private var pointer: CGPoint?
    private var maskRadius: CGFloat = -1
    private var a11yObserver: NSObjectProtocol?
    private var contentFadeToken = 0

    private static let hotspotRadius: CGFloat = 180
    private static let lookDuration: CFTimeInterval = 0.25

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        clipView.frame = bounds
        clipView.autoresizingMask = [.width, .height]
        addSubview(clipView)

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        clipView.addSubview(blur)

        underlay.frame = bounds
        underlay.autoresizingMask = [.width, .height]
        clipView.addSubview(underlay)

        contentView.autoresizingMask = [.width, .height]
        contentView.frame = bounds
        clipView.addSubview(contentView)

        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.passesClicks = true
        clipView.addSubview(overlay)

        buildLayers()
        applyLook(animated: false)

        a11yObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLook(animated: false) }
        }
    }

    public required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let a11yObserver { NSWorkspace.shared.notificationCenter.removeObserver(a11yObserver) }
    }

    // MARK: Build

    private func buildLayers() {
        let white = { (a: CGFloat) in NSColor(white: 1, alpha: a).cgColor }

        // Tint: vertical black-glass gradient.
        tint.startPoint = CGPoint(x: 0.5, y: 0)
        tint.endPoint = CGPoint(x: 0.5, y: 1)
        tint.locations = [0, 0.45, 1]

        // Orb fill: radial white core fading to dark glass.
        orbFill.type = .radial
        orbFill.startPoint = CGPoint(x: 0.5, y: 0.42)
        orbFill.endPoint = CGPoint(x: 1.0, y: 0.92)
        orbFill.colors = [
            NSColor.white.cgColor,
            NSColor(red: 242/255, green: 242/255, blue: 243/255, alpha: 1).cgColor,
            white(0.55),
            NSColor(red: 40/255, green: 40/255, blue: 44/255, alpha: 0.6).cgColor,
        ]
        orbFill.locations = [0, 0.22, 0.48, 0.78]
        orbFill.opacity = 0

        // Light cone from above the top edge.
        cone.type = .radial
        cone.startPoint = CGPoint(x: 0.5, y: 0.5)
        cone.endPoint = CGPoint(x: 1, y: 1)
        cone.colors = [white(0.11), white(0.025), white(0)]
        cone.locations = [0, 0.55, 0.75]

        // Clearcoat: soft elliptical highlight, half clipped by the top edge.
        coat.type = .radial
        coat.startPoint = CGPoint(x: 0.5, y: 0.5)
        coat.endPoint = CGPoint(x: 1, y: 1)
        coat.colors = [white(0.10), white(0)]
        coat.locations = [0, 0.7]

        for l in [tint, orbFill, cone, coat] { underlay.layer?.addSublayer(l) }

        // Rim light + specular hotspot, both masked by a 1 pt stroke of the outline.
        rimGradient.startPoint = CGPoint(x: 0.5, y: 0)
        rimGradient.endPoint = CGPoint(x: 0.5, y: 1)
        rimGradient.colors = [white(0.34), white(0.07), white(0.03), white(0.14)]
        rimGradient.locations = [0, 0.22, 0.75, 1]

        hotspot.type = .radial
        hotspot.startPoint = CGPoint(x: 0.5, y: 0.5)
        hotspot.endPoint = CGPoint(x: 1, y: 1)
        hotspot.colors = [white(0.75), white(0)]
        hotspot.locations = [0, 0.7]
        let d = Self.hotspotRadius * 2
        hotspot.bounds = CGRect(x: 0, y: 0, width: d, height: d)

        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 1
        rimGroup.mask = rimMask
        rimGroup.addSublayer(rimGradient)
        rimGroup.addSublayer(hotspot)

        // Sheen: slanted band, screen-blended, swept once by glint().
        sheenGroup.masksToBounds = true
        sheenGroup.compositingFilter = "screenBlendMode"
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.colors = [white(0), white(0.05), white(0.28), white(0.55), white(0.28), white(0.05), white(0)]
        sheen.locations = [0, 0.30, 0.48, 0.50, 0.52, 0.70, 1]
        sheen.isHidden = true
        sheenGroup.addSublayer(sheen)

        // Minimised line / corner dot.
        line.backgroundColor = NSColor.white.cgColor
        line.shadowColor = NSColor.white.cgColor
        line.shadowOffset = .zero
        line.shadowRadius = 6
        line.shadowOpacity = 0.9
        line.opacity = 0

        for l in [rimGroup, sheenGroup, line] { overlay.layer?.addSublayer(l) }

        // Outer glow (minimised hover, orb). Visible only where the window has room around the view.
        layer?.shadowColor = NSColor.white.cgColor
        layer?.shadowOffset = .zero
        layer?.shadowOpacity = 0

        updateScale()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        layoutLayers()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Keep layers glued to the frame during window frame animations (no lag behind layout passes).
        layoutLayers()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for l in [tint, orbFill, cone, coat, rimGroup, rimGradient, hotspot, rimMask, sheenGroup, sheen, line] {
            l.contentsScale = scale
        }
    }

    private var radius: CGFloat {
        let half = min(bounds.width, bounds.height) / 2
        return (isMinimised || isOrb) ? half : min(Theme.cornerRadius, half)
    }

    private func layoutLayers() {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let r = radius
        clipView.layer?.cornerRadius = r
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        updateBlurMask(radius: r)
        layer?.shadowPath = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)

        tint.frame = b
        orbFill.frame = b

        // Cone: ellipse 55% × 45% of a box that is 70% of the height, centred 8% above the top.
        let coneH = b.height * 0.7
        let rx = b.width * 0.55, ry = coneH * 0.45
        cone.frame = CGRect(x: b.width / 2 - rx, y: -coneH * 0.08 - ry, width: rx * 2, height: ry * 2)

        layoutCoat()

        rimGroup.frame = b
        rimGradient.frame = b
        let inset = b.insetBy(dx: 0.5, dy: 0.5)
        let ri = max(0, r - 0.5)
        rimMask.frame = b
        rimMask.path = CGPath(roundedRect: inset, cornerWidth: min(ri, inset.width / 2), cornerHeight: min(ri, inset.height / 2), transform: nil)
        if pointer == nil { hotspot.position = restingHotspot }
        else if let p = pointer { hotspot.position = p }

        sheenGroup.frame = b
        sheen.bounds = CGRect(x: 0, y: 0, width: b.width * 0.55, height: b.height * 1.6)
        sheen.position = CGPoint(x: -b.width * 0.55 * 1.4 + b.width * 0.275, y: b.height / 2)
        sheen.transform = Self.skew

        layoutLine()

        CATransaction.commit()
    }

    private func layoutCoat() {
        let b = bounds
        let sx: CGFloat = pointer.map { ($0.x / max(b.width, 1) - 0.5) * 2 } ?? 0
        coat.frame = CGRect(x: -b.width * 0.1 + sx * 24, y: -38, width: b.width * 1.2, height: 84)
    }

    private func layoutLine() {
        let b = bounds
        let size: CGSize
        if anchor.isCorner { size = CGSize(width: 5, height: 5) }
        else if anchor.isVerticalEdge { size = CGSize(width: 2, height: 34) }
        else { size = CGSize(width: 34, height: 2) }
        line.bounds = CGRect(origin: .zero, size: size)
        line.cornerRadius = anchor.isCorner ? 2.5 : 1
        line.position = CGPoint(x: b.midX, y: b.midY)
    }

    private var restingHotspot: CGPoint { CGPoint(x: bounds.width / 2, y: -bounds.height * 0.3) }

    private static let skew: CATransform3D = {
        var t = CATransform3DIdentity
        t.m21 = tan(-18 * .pi / 180)
        return t
    }()

    /// Behind-window blur is composited by the window server, so it needs its own mask image.
    private func updateBlurMask(radius r: CGFloat) {
        let key = (r * 2).rounded() / 2
        guard key != maskRadius else { return }
        maskRadius = key
        let side = key * 2 + 2
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: key, yRadius: key).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: key, left: key, bottom: key, right: key)
        img.resizingMode = .stretch
        blur.maskImage = img
    }

    // MARK: Looks

    private func lookChanged() {
        needsLayout = true
        layoutLayers()
        applyLook(animated: true)
        fadeContent()
    }

    /// The content hides quickly when the panel collapses and returns after the morph has begun
    /// (mockup: opacity .1s out; .28s in after .14s).
    private func fadeContent() {
        let visible = !(isMinimised || isOrb)
        contentFadeToken += 1
        let token = contentFadeToken
        if !visible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                contentView.animator().alphaValue = 0
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.contentFadeToken == token else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.28
                        ctx.timingFunction = Theme.easeOut
                        self.contentView.animator().alphaValue = 1
                    }
                }
            }
        }
    }

    private func applyLook(animated: Bool) {
        let rt = Theme.reduceTransparency
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Self.lookDuration)
        CATransaction.setAnimationTimingFunction(Theme.easeOut)

        blur.isHidden = rt
        if rt {
            let solid = NSColor(red: 13/255, green: 13/255, blue: 14/255, alpha: 1).cgColor
            tint.colors = [solid, solid, solid]
        } else if isMinimised {
            let top = NSColor(red: 40/255, green: 40/255, blue: 44/255, alpha: 0.9).cgColor
            let bot = NSColor(red: 8/255, green: 8/255, blue: 9/255, alpha: 0.95).cgColor
            let mid = NSColor(red: 24/255, green: 24/255, blue: 26/255, alpha: 0.925).cgColor
            tint.colors = [top, mid, bot]
        } else {
            tint.colors = [
                Theme.glassTop.cgColor,
                NSColor(red: 12/255, green: 12/255, blue: 14/255, alpha: 0.86).cgColor,
                Theme.glassBottom.cgColor,
            ]
        }

        let compact = isMinimised || isOrb
        cone.opacity = compact ? 0 : 1
        coat.opacity = compact ? 0 : 1
        orbFill.opacity = isOrb ? 1 : 0
        tint.opacity = isOrb ? 0 : 1
        rimGroup.opacity = isOrb ? 0 : 1
        line.opacity = (isMinimised && !isOrb) ? (isHovered ? 1 : 0.55) : 0

        if let l = layer {
            if isOrb {
                l.shadowRadius = 22; l.shadowOpacity = 0.55
            } else if isMinimised && isHovered {
                l.shadowRadius = 16; l.shadowOpacity = 0.28
            } else {
                l.shadowRadius = 0; l.shadowOpacity = 0
            }
        }
        CATransaction.commit()
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// Pointer in the overlay's flipped (top-left origin) coordinate space.
    private func flippedPoint(_ event: NSEvent) -> CGPoint {
        overlay.convert(event.locationInWindow, from: nil)
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        movePointer(to: flippedPoint(event))
        if isMinimised { applyLook(animated: true) }
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        movePointer(to: flippedPoint(event))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        pointer = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(Theme.easeOut)
        hotspot.position = restingHotspot
        layoutCoat()
        CATransaction.commit()
        if isMinimised { applyLook(animated: true) }
    }

    private func movePointer(to p: CGPoint) {
        pointer = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hotspot.position = p
        layoutCoat()
        CATransaction.commit()
    }

    // MARK: Glint

    /// One sweep of reflected light across the surface (the "tank shine").
    public func glint() {
        guard !Theme.reduceMotion, bounds.width > 0 else { return }
        let w = bounds.width
        let bandW = w * 0.55
        let from = -bandW * 1.4 + bandW / 2
        let to = bandW * 2.6 + bandW / 2

        sheen.removeAnimation(forKey: "glint")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheen.isHidden = false
        sheen.position = CGPoint(x: from, y: bounds.height / 2)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only hide if no newer glint replaced this one.
                if self.sheen.animation(forKey: "glint") == nil {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.sheen.isHidden = true
                    CATransaction.commit()
                }
            }
        }
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = from
        a.toValue = to
        a.duration = Theme.sheenDuration
        a.timingFunction = Theme.easeOut
        a.isRemovedOnCompletion = true
        sheen.add(a, forKey: "glint")
        CATransaction.commit()
    }
}

/// A flipped, layer-backed host view for hand-built sublayers. Optionally click-through.
@MainActor
final class GlassLayerView: NSView {
    var passesClicks = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicks ? nil : super.hitTest(point)
    }
}
