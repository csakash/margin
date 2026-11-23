import AppKit
import QuartzCore

/// Full-screen, click-through overlay shown only while the panel is being dragged.
/// Draws: dimmed backdrop, magnetic dot field, comet trail, dashed beam, 8 slots
/// (nearest glows and pulses), a ghost of the panel at the target, and a landing shockwave.
/// CONTRACT (Wave 0). Loop D implements. Coordinates are screen coordinates.
///
/// The window and its views exist only between `begin` and the end of the landing shockwave;
/// the display link runs only between `begin` and `end`. Nothing remains while idle.
@MainActor
public final class SnapOverlay {
    public init() {}

    private var window: NSPanel?
    private var root: SnapOverlayView?
    /// Bumped on every begin/end so stale completion handlers do nothing.
    private var generation = 0

    /// True between `begin` and `end`.
    public private(set) var isActive = false

    /// Show the overlay on `screen`. `slots` are the 8 minimised-line frames to light up.
    public func begin(on screen: NSScreen, slots: [Anchor: NSRect]) {
        generation += 1
        tearDown()

        let frame = screen.frame
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.ignoresMouseEvents = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.setFrame(frame, display: false)

        let view = SnapOverlayView(frame: NSRect(origin: .zero, size: frame.size), screenOrigin: frame.origin)
        w.contentView = view
        view.configure(slots: slots)

        w.alphaValue = 0
        if let panel = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }) {
            w.order(.below, relativeTo: panel.windowNumber)
        } else {
            w.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = Theme.easeOut
            w.animator().alphaValue = 1
        }

        window = w
        root = view
        isActive = true
        view.start()
    }

    /// Called on every drag move. `pointer` is the mouse; `object` the centre of the dragged thing;
    /// `nearest` the anchor it would snap to; `ghost` the expanded panel frame at that anchor.
    public func update(pointer: NSPoint, object: NSPoint, nearest: Anchor, ghost: NSRect) {
        guard isActive, let root else { return }
        root.update(pointer: pointer, object: object, nearest: nearest, ghost: ghost)
    }

    /// Fade out and play the shockwave centred on `landing`.
    public func end(landing: NSRect) {
        guard isActive, let root, let window else { return }
        isActive = false
        generation += 1
        let gen = generation

        root.stop()
        root.fadeOutContent(duration: 0.3)
        let reduce = Theme.reduceMotion
        if !reduce { root.shockwave(at: NSPoint(x: landing.midX, y: landing.midY)) }

        // Keep the (transparent) window until the shockwave is done, then drop everything.
        let linger: TimeInterval = reduce ? 0.3 : 0.78
        if reduce {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                window.animator().alphaValue = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.tearDown()
            }
        }
    }

    private func tearDown() {
        root?.stop()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        root = nil
        isActive = false
    }
}

// MARK: - Root view

/// Layer-backed root of the overlay. Non-flipped: overlay coordinates = screen − screen.origin.
@MainActor
final class SnapOverlayView: NSView {

    private let screenOrigin: NSPoint
    private let reduceMotion = Theme.reduceMotion

    /// Everything that fades out on end (the shockwave lives outside it).
    private let content = CALayer()
    private let blur = NSVisualEffectView()
    private let dim = CAGradientLayer()
    private let fieldHolder = CALayer()
    private let fieldRow = CAReplicatorLayer()
    private let fieldCols = CAReplicatorLayer()
    private let fieldDot = CALayer()
    private let fieldHole = CAShapeLayer()
    private let fx = SnapFieldView()
    private let slotsLayer = CALayer()
    private var slotLayers: [Anchor: CALayer] = [:]
    private var slotFrames: [Anchor: CGRect] = [:]
    private let ghost = CALayer()
    private let ghostShape = CAShapeLayer()
    private let ghostLabel = CATextLayer()
    private let shockHost = CALayer()

    private var nearest: Anchor?
    private var displayLink: CADisplayLink?

    init(frame: NSRect, screenOrigin: NSPoint) {
        self.screenOrigin = screenOrigin
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func local(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x - screenOrigin.x, y: p.y - screenOrigin.y) }
    private func local(_ r: NSRect) -> CGRect { r.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y) }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: Build

    private func build() {
        let b = bounds
        let white = { (a: CGFloat) in NSColor(white: 1, alpha: a).cgColor }
        let black = { (a: CGFloat) in NSColor(white: 0, alpha: a).cgColor }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Blur sits in a subview at the bottom; the rest are layers in a view above it.
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.frame = b
        blur.autoresizingMask = [.width, .height]
        blur.isHidden = Theme.reduceTransparency
        addSubview(blur)

        let host = SnapLayerHostView(frame: b)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        guard let hostLayer = host.layer else { CATransaction.commit(); return }

        content.frame = b
        hostLayer.addSublayer(content)

        // Dim: radial darkening centred on the pointer (70% × 70% of the screen), black beyond.
        dim.type = .radial
        dim.startPoint = CGPoint(x: 0.5, y: 0.5)
        dim.endPoint = CGPoint(x: 1, y: 1)
        dim.colors = [black(0.35), black(0.82), black(0.82)]
        dim.locations = [0, 0.5, 1]
        dim.bounds = CGRect(x: 0, y: 0, width: b.width * 2.8, height: b.height * 2.8)
        dim.position = CGPoint(x: b.midX, y: b.midY)
        content.addSublayer(dim)

        // Static dot field: one dot, replicated across columns and rows (GPU only).
        let g = SnapFieldView.grid
        let cols = Int(ceil(b.width / g)), rows = Int(ceil(b.height / g))
        fieldDot.bounds = CGRect(x: 0, y: 0, width: 1.4, height: 1.4)
        fieldDot.cornerRadius = 0.7
        fieldDot.backgroundColor = white(0.05)
        fieldDot.position = CGPoint(x: g / 2, y: g / 2)
        fieldCols.instanceCount = cols
        fieldCols.instanceTransform = CATransform3DMakeTranslation(g, 0, 0)
        fieldCols.frame = CGRect(x: 0, y: 0, width: b.width, height: g)
        fieldCols.addSublayer(fieldDot)
        fieldRow.instanceCount = rows
        fieldRow.instanceTransform = CATransform3DMakeTranslation(0, g, 0)
        fieldRow.frame = b
        fieldRow.addSublayer(fieldCols)
        fieldHolder.frame = b
        fieldHolder.addSublayer(fieldRow)
        // Hole around the pointer, where the live dots are drawn instead.
        fieldHole.frame = b
        fieldHole.fillRule = .evenOdd
        fieldHole.fillColor = NSColor.black.cgColor
        if !reduceMotion { fieldHolder.mask = fieldHole }
        content.addSublayer(fieldHolder)

        // Live drawing (dots near the pointer, trail, beam).
        fx.frame = b
        fx.autoresizingMask = [.width, .height]
        fx.reduceMotion = reduceMotion

        slotsLayer.frame = b

        // Ghost of the panel at the target.
        ghost.isHidden = true
        ghostShape.fillColor = white(0.025)
        ghostShape.strokeColor = white(0.4)
        ghostShape.lineWidth = 1
        ghostShape.lineDashPattern = [4, 3]
        ghostShape.shadowColor = NSColor.white.cgColor
        ghostShape.shadowOpacity = 0.05
        ghostShape.shadowRadius = 20
        ghostShape.shadowOffset = .zero
        ghost.addSublayer(ghostShape)
        ghostLabel.alignmentMode = .center
        ghostLabel.shadowColor = NSColor.white.cgColor
        ghostLabel.shadowOpacity = 0.6
        ghostLabel.shadowRadius = 6
        ghostLabel.shadowOffset = .zero
        ghost.addSublayer(ghostLabel)

        shockHost.frame = b

        CATransaction.commit()

        // Live dots/trail/beam above the field; slots, ghost and shockwave in a layer host above that.
        host.addSubview(fx)
        let top = SnapLayerHostView(frame: b)
        top.autoresizingMask = [.width, .height]
        host.addSubview(top)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.layer?.addSublayer(slotsLayer)
        top.layer?.addSublayer(ghost)
        top.layer?.addSublayer(shockHost)
        CATransaction.commit()
        topHost = top
        fxHost = host

        let s = scale
        for l in [dim, fieldDot, fieldHole, ghostShape, ghostLabel] { l.contentsScale = s }
    }

    private weak var topHost: NSView?
    private weak var fxHost: NSView?

    func configure(slots: [Anchor: NSRect]) {
        let white = { (a: CGFloat) in NSColor(white: 1, alpha: a).cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, a) in Anchor.allCases.enumerated() {
            guard let f = slots[a] else { continue }
            let r = local(f)
            slotFrames[a] = r
            let l = CALayer()
            l.bounds = CGRect(origin: .zero, size: r.size)
            l.position = CGPoint(x: r.midX, y: r.midY)
            let radius = min(r.width, r.height) / 2
            l.cornerRadius = radius
            l.backgroundColor = white(0.07)
            l.borderColor = white(0.28)
            l.borderWidth = 1
            l.shadowColor = NSColor.white.cgColor
            l.shadowOffset = .zero
            l.shadowRadius = 14
            l.shadowOpacity = 0.08
            l.shadowPath = CGPath(roundedRect: l.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            l.contentsScale = scale
            slotsLayer.addSublayer(l)
            slotLayers[a] = l

            if !reduceMotion {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.3
                grow.toValue = 1
                grow.duration = 0.45
                grow.timingFunction = Theme.spring
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.3
                fade.timingFunction = Theme.easeOut
                let group = CAAnimationGroup()
                group.animations = [grow, fade]
                group.duration = 0.45
                group.beginTime = CACurrentMediaTime() + Double(i) * 0.024
                group.fillMode = .backwards
                l.add(group, forKey: "in")
            }
        }
        CATransaction.commit()
        fx.slotCentres = slotFrames.mapValues { CGPoint(x: $0.midX, y: $0.midY) }
    }

    // MARK: Run

    func start() {
        fx.t0 = CACurrentMediaTime()
        guard !reduceMotion, displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        fx.frameTick()
    }

    func update(pointer: NSPoint, object: NSPoint, nearest: Anchor, ghost frame: NSRect) {
        let p = local(pointer), o = local(object)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.position = p
        if !reduceMotion {
            let path = CGMutablePath()
            path.addRect(bounds)
            let r = SnapFieldView.radius
            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            fieldHole.path = path
        }
        CATransaction.commit()

        fx.pointer = p
        fx.object = o
        fx.nearest = nearest
        if !reduceMotion { fx.trail.append((o, CACurrentMediaTime())) }
        if reduceMotion { fx.needsDisplay = true }

        if nearest != self.nearest {
            let previous = self.nearest
            self.nearest = nearest
            highlight(nearest, previous: previous)
            moveGhost(to: local(frame), anchor: nearest, animated: previous != nil && !reduceMotion)
        }
    }

    private func highlight(_ a: Anchor, previous: Anchor?) {
        let white = { (a: CGFloat) in NSColor(white: 1, alpha: a).cgColor }
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.25)
        CATransaction.setAnimationTimingFunction(Theme.spring)
        if let previous, let l = slotLayers[previous] {
            l.backgroundColor = white(0.07)
            l.borderColor = white(0.28)
            l.shadowOpacity = 0.08
            l.transform = CATransform3DIdentity
            l.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        if let l = slotLayers[a] {
            l.backgroundColor = NSColor.white.cgColor
            l.borderColor = NSColor.white.cgColor
            l.shadowOpacity = 0.85
            l.transform = CATransform3DMakeScale(1.3, 1.3, 1)
            if !reduceMotion { addPulse(to: l) }
        }
        CATransaction.commit()
    }

    private func addPulse(to slot: CALayer) {
        let ring = CALayer()
        let b = slot.bounds.insetBy(dx: -10, dy: -10)
        ring.bounds = CGRect(origin: .zero, size: b.size)
        ring.position = CGPoint(x: slot.bounds.midX, y: slot.bounds.midY)
        ring.cornerRadius = min(b.width, b.height) / 2
        ring.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
        ring.borderWidth = 1
        ring.opacity = 0
        ring.contentsScale = scale
        slot.addSublayer(ring)

        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = 0.7
        s.toValue = 2.2
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = 1
        o.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [s, o]
        g.duration = 1
        g.timingFunction = Theme.easeOut
        g.repeatCount = .infinity
        ring.add(g, forKey: "pulse")
    }

    private func moveGhost(to r: CGRect, anchor: Anchor, animated: Bool) {
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size),
                          cornerWidth: min(26, r.width / 2), cornerHeight: min(26, r.height / 2), transform: nil)
        let text = NSAttributedString(string: anchor.displayName.uppercased(), attributes: [
            .font: Theme.mono(11, .medium),
            .kern: 11 * 0.14,
            .foregroundColor: NSColor(white: 1, alpha: 0.75),
        ])
        let textSize = text.size()

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.4)
            CATransaction.setAnimationTimingFunction(Theme.spring)
        } else {
            CATransaction.setDisableActions(true)
        }
        ghost.isHidden = false
        ghost.bounds = CGRect(origin: .zero, size: r.size)
        ghost.position = CGPoint(x: r.midX, y: r.midY)
        ghostShape.frame = CGRect(origin: .zero, size: r.size)
        ghostShape.path = path
        ghostLabel.bounds = CGRect(x: 0, y: 0, width: ceil(textSize.width) + 4, height: ceil(textSize.height))
        ghostLabel.position = CGPoint(x: r.width / 2, y: r.height / 2)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghostLabel.string = text
        CATransaction.commit()
    }

    // MARK: End

    func fadeOutContent(duration: TimeInterval) {
        for v in [blur, fx] as [NSView] {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                v.animator().alphaValue = 0
            }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Theme.easeOut)
        content.opacity = 0
        slotsLayer.opacity = 0
        ghost.opacity = 0
        CATransaction.commit()
    }

    func shockwave(at screenPoint: NSPoint) {
        let c = local(screenPoint)
        let ring = CALayer()
        ring.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        ring.position = c
        ring.cornerRadius = 15
        ring.borderWidth = 1.5
        ring.borderColor = NSColor.white.cgColor
        ring.shadowColor = NSColor.white.cgColor
        ring.shadowOpacity = 0.7
        ring.shadowRadius = 12
        ring.shadowOffset = .zero
        ring.contentsScale = scale
        ring.opacity = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shockHost.addSublayer(ring)
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = 0.2
        s.toValue = 11
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = 1
        o.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [s, o]
        g.duration = 0.75
        g.timingFunction = Theme.easeOut
        ring.add(g, forKey: "shock")
        CATransaction.commit()
    }
}

/// Plain layer-backed container for hand-built sublayers.
@MainActor
final class SnapLayerHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Live drawing

/// Draws, with Core Graphics, the parts that change every frame: the magnetic dots near the
/// pointer, the comet trail and the dashed beam. Only the dirty region around them is redrawn.
@MainActor
final class SnapFieldView: NSView {
    static let grid: CGFloat = 26
    static let radius: CGFloat = 300
    static let trailLife: CFTimeInterval = 0.26

    var reduceMotion = false
    var t0: CFTimeInterval = 0
    var pointer: CGPoint?
    var object: CGPoint?
    var nearest: Anchor?
    var slotCentres: [Anchor: CGPoint] = [:]
    var trail: [(CGPoint, CFTimeInterval)] = []

    private var lastDirty: CGRect = .null
    private var now: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Called by the display link once per frame.
    func frameTick() {
        now = CACurrentMediaTime()
        trail.removeAll { now - $0.1 > Self.trailLife }
        let dirty = currentBounds()
        let rect = lastDirty.union(dirty)
        lastDirty = dirty
        if !rect.isNull { setNeedsDisplay(rect.intersection(bounds)) }
    }

    private func currentBounds() -> CGRect {
        var r = CGRect.null
        if let p = pointer, !reduceMotion {
            let R = Self.radius + 6
            r = r.union(CGRect(x: p.x - R, y: p.y - R, width: R * 2, height: R * 2))
        }
        if trail.count > 1 {
            var t = CGRect.null
            for (q, _) in trail { t = t.union(CGRect(origin: q, size: .zero)) }
            r = r.union(t.insetBy(dx: -32, dy: -32))
        }
        if let o = object, let n = nearest, let c = slotCentres[n] {
            r = r.union(CGRect(x: min(o.x, c.x), y: min(o.y, c.y), width: abs(o.x - c.x), height: abs(o.y - c.y)).insetBy(dx: -4, dy: -4))
        }
        return r
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = (now - t0) * 1000   // ms, matches the mockup's maths
        if !reduceMotion { drawDots(ctx, dirty: dirtyRect, t: t) }
        if !reduceMotion { drawTrail(ctx) }
        drawBeam(ctx, t: reduceMotion ? 0 : t)
    }

    private func drawDots(_ ctx: CGContext, dirty: CGRect, t: Double) {
        guard let p = pointer else { return }
        let g = Self.grid, R = Self.radius
        let x0 = max(0, floor((p.x - R) / g)), x1 = min(floor(bounds.width / g), ceil((p.x + R) / g))
        let y0 = max(0, floor((p.y - R) / g)), y1 = min(floor(bounds.height / g), ceil((p.y + R) / g))
        guard x0 <= x1, y0 <= y1 else { return }
        var yi = y0
        while yi <= y1 {
            let y = yi * g + g / 2
            var xi = x0
            while xi <= x1 {
                let x = xi * g + g / 2
                let dx = p.x - x, dy = p.y - y
                let d = (dx * dx + dy * dy).squareRoot()
                if d < R {
                    let f = max(0, 1 - d / R), f2 = f * f
                    let wave = max(0, sin(Double(d) / 26 - t / 80)) * Double(f)
                    let a = 0.05 + Double(f2) * 0.55 + wave * 0.25
                    let rr = 0.7 + Double(f2) * 1.6 + wave * 0.8
                    let cx = x + dx * f2 * 0.22, cy = y + dy * f2 * 0.22
                    ctx.setFillColor(gray: 1, alpha: CGFloat(a))
                    ctx.fillEllipse(in: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2))
                }
                xi += 1
            }
            yi += 1
        }
    }

    private func drawTrail(_ ctx: CGContext) {
        guard trail.count > 1 else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: 18, color: NSColor(white: 1, alpha: 0.9).cgColor)
        let n = CGFloat(trail.count)
        for i in 1..<trail.count {
            let k = CGFloat(i) / n
            ctx.setStrokeColor(gray: 1, alpha: k * 0.8)
            ctx.setLineWidth(1 + k * 9)
            ctx.move(to: trail[i - 1].0)
            ctx.addLine(to: trail[i].0)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawBeam(_ ctx: CGContext, t: Double) {
        guard let o = object, let n = nearest, let c = slotCentres[n] else { return }
        let dx = c.x - o.x, dy = c.y - o.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1 else { return }
        ctx.saveGState()
        ctx.setLineWidth(1.2)
        // CSS lineDashOffset = -t/20 moves the dashes forward along the line.
        let phase = CGFloat(-t / 20)
        let segments = 14
        for i in 0..<segments {
            let a = CGFloat(i) / CGFloat(segments), b = CGFloat(i + 1) / CGFloat(segments)
            let alpha = 0.7 + (0.05 - 0.7) * (a + b) / 2
            ctx.setStrokeColor(gray: 1, alpha: alpha)
            ctx.setLineDash(phase: phase + a * length, lengths: [3, 6])
            ctx.move(to: CGPoint(x: o.x + dx * a, y: o.y + dy * a))
            ctx.addLine(to: CGPoint(x: o.x + dx * b, y: o.y + dy * b))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
