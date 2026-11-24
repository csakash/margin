import AppKit

/// Owns the floating panel: its anchor, size, and the expanded ⇄ minimised morph.
/// The same window changes size and shape between the two states (never a cross-fade between windows).
@MainActor
public final class PanelController: NSObject, NSWindowDelegate {

    public let panel: FloatingPanel
    /// The full UI (header, editor, toolbar, drawer). Faded out when minimised.
    public let contentView: NSView

    public private(set) var anchor: Anchor
    public private(set) var isMinimised = false
    /// Expanded size chosen by the user (clamped to the screen when placed).
    public var expandedSize: NSSize

    /// Called when the user starts dragging the header (expanded) or the minimised line.
    /// Loop G (DragPlacement) installs this. Bool = minimised.
    /// For the minimised line it fires once the pointer has moved > 4 pt, and receives the original
    /// mouseDown event; later drag events are still in the queue for the handler's own tracking loop.
    /// For the header it fires straight from mouseDown.
    public var onBeginDrag: ((NSEvent, Bool) -> Void)?
    /// Called after every state change (anchor, minimised) so the UI can react.
    public var onStateChange: (() -> Void)?

    /// `contentView` typed as the glass material, when it is one (it normally is).
    public var glass: GlassView? { contentView as? GlassView }
    /// An update is downloaded and waiting: the minimised nub shows a pulsing dot.
    public var hasPendingUpdate = false { didSet { glass?.showsUpdateDot = hasPendingUpdate } }

    private let host: NSView
    private let nubHit = NubHitView(frame: .zero)
    /// Bumped on every minimise/expand so stale animation callbacks can bail out.
    private var stateGeneration = 0
    private weak var savedResponder: NSResponder?
    /// Set while the tour holds the panel in the middle of the screen; any anchor or minimise
    /// change ends it.
    private var centredSize: NSSize?
    /// How many app-driven frame animations are in flight. AppKit reports animated frame changes
    /// as a live resize; those must not be saved as the user's size or re-snapped. A counter, not a
    /// flag: one morph can supersede another, and the first one's completion must not clear it.
    private var morphs = 0
    /// While set, a live resize is never saved as the user's size (the tour uses its own size).
    public var sizeLocked = false
    /// True during the tour's arrival (line, then open). Anchor and minimise requests wait.
    public private(set) var isArriving = false

    public init(contentView: NSView) {
        let d = UserDefaults.standard
        self.anchor = Anchor(rawValue: d.string(forKey: "margin.anchor") ?? "") ?? .right
        let w = d.double(forKey: "margin.width"), h = d.double(forKey: "margin.height")
        self.expandedSize = (w > 0 && h > 0) ? NSSize(width: w, height: h) : Theme.defaultPanelSize
        self.contentView = contentView
        self.panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Theme.defaultPanelSize))
        self.host = NSView()
        super.init()
        host.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: host.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        panel.contentView = host
        panel.delegate = self
        nubHit.controller = self
        glass?.anchor = anchor
        applyStyle(minimised: false)
        panel.setFrame(targetFrame(), display: false)

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeSpaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    public var screen: NSScreen { panel.screen ?? NSScreen.main ?? NSScreen.screens[0] }
    public var visibleFrame: NSRect { screen.visibleFrame }

    public func targetFrame(for anchor: Anchor? = nil, minimised: Bool? = nil) -> NSRect {
        Placement.frame(anchor ?? self.anchor, minimised: minimised ?? isMinimised, size: expandedSize, in: visibleFrame)
    }

    // MARK: - Show / hide

    /// Orders the panel front without activating the app; when expanded it also becomes key so typing works.
    public func show() {
        panel.setFrame(targetFrame(), display: true)
        panel.orderFrontRegardless()
        if !isMinimised { panel.makeKey() }
    }

    /// Dock icon: minimised → expand, expanded → minimise. (The panel is never fully hidden.)
    public func toggleVisibility() {
        if !panel.isVisible { show() }
        toggleMinimised()
    }

    // MARK: - Minimise morph

    public func setMinimised(_ minimised: Bool, animated: Bool = true) {
        guard minimised != isMinimised, !isArriving else { return }
        centredSize = nil
        isMinimised = minimised
        stateGeneration += 1
        let gen = stateGeneration
        let animate = animated && !Theme.reduceMotion && panel.isVisible
        let fadeView = glass?.contentView ?? contentView

        if minimised {
            savedResponder = panel.firstResponder
            panel.makeFirstResponder(nil)
            applyStyle(minimised: true)
            installNubHit()
            let collapse = { [self] in
                pinContent(size: panel.frame.size)
                glass?.isMinimised = true
                glass?.anchor = anchor
                if animate {
                    morph(to: targetFrame()) { [self] in
                        guard gen == stateGeneration else { return }
                        finishMorph()
                        onStateChange?()
                    }
                } else {
                    panel.setFrame(targetFrame(), display: true)
                    finishMorph()
                    onStateChange?()
                }
            }
            if animate {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.1
                    ctx.allowsImplicitAnimation = true
                    fadeView.animator().alphaValue = 0
                }, completionHandler: { [self] in
                    MainActor.assumeIsolated {
                        guard gen == stateGeneration else { return }
                        collapse()
                    }
                })
            } else {
                fadeView.alphaValue = 0
                collapse()
            }
        } else {
            removeNubHit()
            pinContent(size: targetFrame().size)
            glass?.isMinimised = false
            glass?.isOrb = false
            let expanded = { [self] in
                applyStyle(minimised: false)
                fillContent()
                finishMorph()
                panel.makeKey()
                if let r = savedResponder, isInPanel(r) { panel.makeFirstResponder(r) }
                onStateChange?()
            }
            if animate {
                morph(to: targetFrame()) { [self] in
                    guard gen == stateGeneration else { return }
                    expanded()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [self] in
                    MainActor.assumeIsolated {
                        guard gen == stateGeneration else { return }
                        NSAnimationContext.runAnimationGroup { ctx in
                            ctx.duration = 0.28
                            ctx.timingFunction = Theme.easeOut
                            ctx.allowsImplicitAnimation = true
                            fadeView.animator().alphaValue = 1
                        }
                    }
                }
            } else {
                panel.setFrame(targetFrame(), display: true)
                fadeView.alphaValue = 1
                expanded()
            }
        }
    }

    public func toggleMinimised() { setMinimised(!isMinimised) }

    // MARK: - First-launch tour

    /// The first-launch arrival: a line of light appears in the middle of the screen and opens
    /// into a centred panel of `size`. The anchor is untouched; the next `setAnchor` moves it there.
    public func arriveCentered(size: NSSize, completion: @escaping () -> Void) {
        stateGeneration += 1
        let gen = stateGeneration
        isMinimised = false
        removeNubHit()
        centredSize = size
        isArriving = true
        let v = visibleFrame
        let target = centredFrame(size)
        let line = NSRect(x: (v.midX - Theme.nubThin / 2).rounded(), y: (v.midY - Theme.nubLong / 2).rounded(),
                          width: Theme.nubThin, height: Theme.nubLong)
        let reduce = Theme.reduceMotion

        applyStyle(minimised: true)
        pinContent(size: target.size)
        glass?.anchor = .right          // a vertical line
        glass?.isMinimised = true
        panel.setFrame(reduce ? target : line, display: true)
        panel.orderFrontRegardless()

        let open = { [self] in
            guard gen == stateGeneration else { isArriving = false; return }
            glass?.isMinimised = false
            glass?.anchor = anchor
            let landed = { [self] in
                isArriving = false
                guard gen == stateGeneration else { return }
                applyStyle(minimised: false)
                fillContent()
                finishMorph()
                panel.makeKey()
                completion()
            }
            if reduce {
                panel.setFrame(target, display: true)
                landed()
            } else {
                morph(to: target) { landed() }
            }
        }
        if reduce {
            open()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { open() } }
        }
    }

    // MARK: - Anchors

    public func setAnchor(_ anchor: Anchor, animated: Bool = true) {
        guard !isArriving else { return }
        centredSize = nil
        self.anchor = anchor
        UserDefaults.standard.set(anchor.rawValue, forKey: "margin.anchor")
        glass?.anchor = anchor
        snapToAnchor(animated: animated)
        onStateChange?()
    }

    /// ⌃⌥+arrow: move one step around the 3×3 ring of anchors, hopping over the empty centre.
    public func nudge(dx: Int, dy: Int) {
        var (x, y) = anchor.grid
        x = max(0, min(2, x + dx))
        y = max(0, min(2, y + dy))
        if x == 1 && y == 1 {
            x = max(0, min(2, x + dx))
            y = max(0, min(2, y + dy))
        }
        guard let next = Anchor.at(x: x, y: y), next != anchor else { return }
        setAnchor(next)
    }

    /// Re-places the panel at the frame for the current anchor and state.
    private func snapToAnchor(animated: Bool) {
        let target = targetFrame()
        if animated && !Theme.reduceMotion && panel.isVisible {
            morph(to: target) { [self] in finishMorph() }
        } else {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
    }

    // MARK: - Dragging

    /// The header view calls this from mouseDown. Hands off to DragPlacement when installed;
    /// otherwise moves the panel with the mouse and snaps to the nearest expanded anchor on release.
    public func beginHeaderDrag(with event: NSEvent) {
        guard !isMinimised else { return }
        if let onBeginDrag {
            onBeginDrag(event, false)
            return
        }
        trackPointer(from: event, minimised: false)
    }

    /// Shared pointer tracking for the minimised line and the header fallback.
    func trackPointer(from down: NSEvent, minimised: Bool) {
        let startMouse = NSEvent.mouseLocation
        let startOrigin = panel.frame.origin
        var moved = false
        tracking: while let ev = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = NSEvent.mouseLocation
            let dx = p.x - startMouse.x, dy = p.y - startMouse.y
            switch ev.type {
            case .leftMouseUp:
                break tracking
            default:
                if !moved {
                    guard hypot(dx, dy) > 4 else { continue }
                    moved = true
                    if minimised, let onBeginDrag {
                        onBeginDrag(down, true)
                        return
                    }
                }
                panel.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            }
        }
        if !moved {
            if minimised { setMinimised(false) }
            return
        }
        let dropped = Placement.nearest(to: panel.frame.center, minimised: isMinimised,
                                        size: expandedSize, in: visibleFrame)
        setAnchor(dropped, animated: true)
    }

    func nubHovered() {
        glass?.glint()
    }

    // MARK: - NSWindowDelegate

    public func windowDidEndLiveResize(_ notification: Notification) {
        guard !isMinimised, morphs == 0, centredSize == nil, !sizeLocked else { return }
        expandedSize = panel.frame.size
        let d = UserDefaults.standard
        d.set(Double(expandedSize.width), forKey: "margin.width")
        d.set(Double(expandedSize.height), forKey: "margin.height")
        snapToAnchor(animated: true)
        onStateChange?()
    }

    // MARK: - System notifications

    private func centredFrame(_ size: NSSize) -> NSRect {
        let v = visibleFrame
        let w = min(size.width, v.width - 2 * Theme.panelMargin), h = min(size.height, v.height - 2 * Theme.panelMargin)
        return NSRect(x: (v.midX - w / 2).rounded(), y: (v.midY - h / 2).rounded(), width: w, height: h)
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        panel.setFrame(centredSize.map(centredFrame) ?? targetFrame(), display: true)
        panel.invalidateShadow()
    }

    @objc private func activeSpaceChanged(_ note: Notification) {
        guard panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    // MARK: - Helpers

    private func morph(to frame: NSRect, completion: @escaping () -> Void) {
        morphs += 1
        NSAnimationContext.runAnimationGroup({ [panel] ctx in
            ctx.duration = Theme.morphDuration
            ctx.timingFunction = Theme.spring
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                completion()
                // Cleared a turn later: the end-of-live-resize callback can arrive after completion.
                DispatchQueue.main.async { if let self { self.morphs = max(0, self.morphs - 1) } }
            }
        })
    }

    private func finishMorph() {
        panel.invalidateShadow()
        glass?.glint()
    }

    /// Minimised: no min size (so the 8×84 frame isn't blocked) and no native resizing.
    /// `.titled` is dropped too: AppKit constrains tiny titled windows (the bottom corner dots
    /// landed 8 pt too high), and the title bar is invisible anyway.
    private func applyStyle(minimised: Bool) {
        if minimised {
            panel.styleMask.remove([.resizable, .titled])
            panel.minSize = .zero
        } else {
            panel.styleMask.insert([.titled, .resizable])
            panel.minSize = Theme.minPanelSize
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(b)?.isHidden = true
            }
        }
    }

    /// While minimised (and during the morph) the faded UI keeps its expanded size, pinned to the
    /// top-left and clipped by the glass, instead of being squeezed into the 8 pt line. Its layout
    /// minimums (header, toolbar, editor insets) would otherwise stop the window from shrinking.
    private func pinContent(size: NSSize) {
        guard let glass else { return }
        let c = glass.contentView
        c.autoresizingMask = [.minYMargin]
        c.frame = NSRect(x: 0, y: glass.bounds.height - size.height, width: size.width, height: size.height)
    }

    /// Back to filling the glass and tracking its size (expanded state).
    private func fillContent() {
        guard let glass else { return }
        let c = glass.contentView
        c.autoresizingMask = [.width, .height]
        c.frame = glass.bounds
    }

    private func installNubHit() {
        nubHit.frame = host.bounds
        if nubHit.superview !== host {
            host.addSubview(nubHit, positioned: .above, relativeTo: nil)
        }
        panel.invalidateCursorRects(for: nubHit)
    }

    private func removeNubHit() {
        nubHit.removeFromSuperview()
        NSCursor.arrow.set()
    }

    private func isInPanel(_ responder: NSResponder) -> Bool {
        if let v = responder as? NSView { return v.window === panel }
        return responder === panel
    }
}
