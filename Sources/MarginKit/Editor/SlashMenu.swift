import AppKit
import QuartzCore

/// The `/` block menu: a small dark child panel under the caret with a filterable list.
@MainActor
final class SlashMenu {

    enum Item: Equatable {
        case block(BlockKind)
        case action(EditorController.EditorAction)

        var title: String {
            switch self {
            case .block(let k): return k.title
            case .action(.image): return "Image or video"
            case .action(.screenshot): return "Screenshot"
            case .action(.clipTab): return "Clip current tab"
            }
        }

        var glyph: String {
            switch self {
            case .block(let k):
                switch k {
                case .paragraph: return "T"; case .heading1: return "H1"; case .heading2: return "H2"; case .heading3: return "H3"
                case .bullet: return "•"; case .numbered: return "1."; case .todo: return "☐"; case .quote: return "❝"
                case .code: return "{}"; case .divider: return "—"
                }
            case .action(.image): return "▣"
            case .action(.screenshot): return "⌗"
            case .action(.clipTab): return "↗"
            }
        }

        var hint: String {
            switch self {
            case .block(let k):
                switch k {
                case .paragraph: return ""; case .todo: return "[]"; case .numbered: return "1."
                default: return k.prefix.trimmingCharacters(in: .whitespaces)
                }
            case .action(.screenshot): return "⌃⌥S"
            case .action: return ""
            }
        }
    }

    static let allItems: [Item] = [
        .block(.paragraph), .block(.heading1), .block(.heading2), .block(.heading3), .block(.bullet),
        .block(.numbered), .block(.todo), .block(.quote), .block(.code), .block(.divider),
        .action(.image), .action(.screenshot), .action(.clipTab),
    ]

    /// Pure filter: items whose title contains the query (case-insensitive).
    static func filtered(_ query: String) -> [Item] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return allItems }
        return allItems.filter { $0.title.lowercased().contains(q) }
    }

    /// UTF-16 offset of the `/` in the text.
    var slashLocation = 0
    var onPick: ((Item) -> Void)?
    private(set) var isOpen = false

    private var panel: SlashPanel?
    private let view = SlashMenuView()

    init() {
        view.onPick = { [weak self] i in self?.pick(i) }
    }

    /// Open below `caretRect` (screen coordinates), or above it if there is no room.
    func open(at caretRect: NSRect, in parent: NSWindow) {
        view.items = Self.allItems
        view.selected = 0
        view.scrollOffset = 0
        let size = view.preferredSize
        let panel = self.panel ?? SlashPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: true)
        self.panel = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = parent.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        panel.contentView = container

        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = caretRect.minX - 8
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        var y = caretRect.minY - 6 - size.height
        var below = true
        if y < screen.minY + 8 { y = caretRect.maxY + 6; below = false }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        isOpen = true
        animateIn(container, height: size.height, fromTop: below)
    }

    private func animateIn(_ v: NSView, height: CGFloat, fromTop: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = Theme.easeOut
            panel?.animator().alphaValue = 1
        }
        guard !Theme.reduceMotion, let layer = v.layer else { return }
        // Layers of NSViews scale about their bottom-left corner; shift so the caret-side edge stays put.
        let s: CGFloat = 0.97
        var t = CATransform3DMakeScale(s, s, 1)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(0, fromTop ? height * (1 - s) + 4 : -4, 0))
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: t)
        a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        a.duration = 0.16
        a.timingFunction = Theme.easeOut
        layer.add(a, forKey: "in")
    }

    /// Apply a query; returns false (and the caller should close) when nothing matches.
    @discardableResult
    func filter(_ query: String) -> Bool {
        let items = Self.filtered(query)
        guard !items.isEmpty else { return false }
        if items != view.items {
            view.items = items
            view.selected = min(view.selected, items.count - 1)
            view.scrollOffset = 0
            resize()
        }
        return true
    }

    private func resize() {
        guard let panel else { return }
        let size = view.preferredSize
        var f = panel.frame
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        panel.setFrame(f, display: true)
        view.ensureSelectionVisible()
        view.needsDisplay = true
    }

    func move(_ delta: Int) {
        guard !view.items.isEmpty else { return }
        view.selected = (view.selected + delta + view.items.count) % view.items.count
        view.ensureSelectionVisible()
        view.needsDisplay = true
    }

    func pickSelected() { pick(view.selected) }

    private func pick(_ index: Int) {
        guard isOpen, view.items.indices.contains(index) else { return }
        let item = view.items[index]
        close()
        onPick?(item)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
}

private final class SlashPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the menu: header, rows with a 24 pt glyph tile, title and shortcut hint.
private final class SlashMenuView: NSView {
    var items: [SlashMenu.Item] = [] { didSet { needsDisplay = true } }
    var selected = 0
    var scrollOffset: CGFloat = 0
    var onPick: ((Int) -> Void)?

    static let width: CGFloat = 214
    static let pad: CGFloat = 5
    static let headerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 36
    static let maxHeight: CGFloat = 280

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var contentHeight: CGFloat { Self.pad * 2 + Self.headerHeight + CGFloat(items.count) * Self.rowHeight }
    var preferredSize: NSSize { NSSize(width: Self.width, height: min(Self.maxHeight, contentHeight)) }

    func rowRect(_ i: Int) -> NSRect {
        NSRect(x: Self.pad, y: Self.pad + Self.headerHeight + CGFloat(i) * Self.rowHeight - scrollOffset,
               width: bounds.width - 2 * Self.pad, height: Self.rowHeight)
    }

    func ensureSelectionVisible() {
        let maxOffset = max(0, contentHeight - bounds.height)
        let r = rowRect(selected)
        if r.minY < Self.pad { scrollOffset += r.minY - Self.pad }
        if r.maxY > bounds.height - Self.pad { scrollOffset += r.maxY - (bounds.height - Self.pad) }
        scrollOffset = min(max(0, scrollOffset), maxOffset)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor(srgbRed: 16 / 255, green: 16 / 255, blue: 17 / 255, alpha: 0.97).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        let mono10: [NSAttributedString.Key: Any] = [.font: Theme.mono(10), .foregroundColor: Theme.textTertiary, .kern: 0.6]
        ("BLOCKS" as NSString).draw(at: NSPoint(x: Self.pad + 8, y: Self.pad + 5 - scrollOffset), withAttributes: mono10)

        let tx2 = NSColor(srgbRed: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255, alpha: 1)
        for (i, item) in items.enumerated() {
            let r = rowRect(i)
            guard r.maxY > 0, r.minY < bounds.height else { continue }
            let hi = i == selected
            if hi {
                NSColor(white: 1, alpha: 0.08).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            }
            let tile = NSRect(x: r.minX + 8, y: r.minY + 6, width: 24, height: 24)
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
            let ga: [NSAttributedString.Key: Any] = [.font: Theme.mono(11, .medium), .foregroundColor: tx2]
            let g = item.glyph as NSString
            let gs = g.size(withAttributes: ga)
            g.draw(at: NSPoint(x: tile.midX - gs.width / 2, y: tile.midY - gs.height / 2), withAttributes: ga)

            let ta: [NSAttributedString.Key: Any] = [.font: Theme.ui(12.5), .foregroundColor: hi ? NSColor.white : tx2]
            let t = item.title as NSString
            let ts = t.size(withAttributes: ta)
            t.draw(at: NSPoint(x: tile.maxX + 10, y: r.midY - ts.height / 2), withAttributes: ta)

            let h = item.hint as NSString
            if h.length > 0 {
                let ha: [NSAttributedString.Key: Any] = [.font: Theme.mono(10), .foregroundColor: Theme.textTertiary]
                let hs = h.size(withAttributes: ha)
                h.draw(at: NSPoint(x: r.maxX - 8 - hs.width, y: r.midY - hs.height / 2), withAttributes: ha)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // Rim: 1 px ring and a top inner highlight.
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13.5, yRadius: 13.5)
        ring.lineWidth = 1
        NSColor(white: 1, alpha: 0.08).setStroke()
        ring.stroke()
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: 14, y: 1, width: bounds.width - 28, height: 1).fill()
    }

    private func row(at p: NSPoint) -> Int? {
        items.indices.first { rowRect($0).contains(p) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)), i != selected {
            selected = i
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)) { onPick?(i) }
    }

    override func scrollWheel(with event: NSEvent) {
        let maxOffset = max(0, contentHeight - bounds.height)
        scrollOffset = min(max(0, scrollOffset - event.scrollingDeltaY), maxOffset)
        needsDisplay = true
    }
}
