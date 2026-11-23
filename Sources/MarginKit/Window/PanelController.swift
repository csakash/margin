import AppKit

/// Owns the floating panel: its anchor, size, and the expanded ⇄ minimised morph.
/// CONTRACT (Wave 0). Loop C implements the morph, minimised look, nudge and persistence.
@MainActor
public final class PanelController: NSObject {

    public let panel: FloatingPanel
    /// The full UI (header, editor, toolbar, drawer). Faded out when minimised.
    public let contentView: NSView

    public private(set) var anchor: Anchor
    public private(set) var isMinimised = false
    /// Expanded size chosen by the user (clamped to the screen when placed).
    public var expandedSize: NSSize

    /// Called when the user starts dragging the header (expanded) or the minimised line.
    /// Loop G (DragPlacement) installs this. Bool = minimised.
    public var onBeginDrag: ((NSEvent, Bool) -> Void)?
    /// Called after every state change (anchor, minimised) so the UI can react.
    public var onStateChange: (() -> Void)?

    public init(contentView: NSView) {
        let d = UserDefaults.standard
        self.anchor = Anchor(rawValue: d.string(forKey: "margin.anchor") ?? "") ?? .right
        let w = d.double(forKey: "margin.width"), h = d.double(forKey: "margin.height")
        self.expandedSize = (w > 0 && h > 0) ? NSSize(width: w, height: h) : Theme.defaultPanelSize
        self.contentView = contentView
        self.panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Theme.defaultPanelSize))
        super.init()
        let host = NSView()
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
        panel.setFrame(targetFrame(), display: false)
    }

    public var screen: NSScreen { panel.screen ?? NSScreen.main ?? NSScreen.screens[0] }
    public var visibleFrame: NSRect { screen.visibleFrame }

    public func targetFrame(for anchor: Anchor? = nil, minimised: Bool? = nil) -> NSRect {
        Placement.frame(anchor ?? self.anchor, minimised: minimised ?? isMinimised, size: expandedSize, in: visibleFrame)
    }

    public func show() {
        panel.setFrame(targetFrame(), display: true)
        panel.orderFrontRegardless()
    }

    public func setMinimised(_ minimised: Bool, animated: Bool = true) {
        guard minimised != isMinimised else { return }
        isMinimised = minimised
        contentView.alphaValue = minimised ? 0 : 1
        panel.setFrame(targetFrame(), display: true, animate: false)
        onStateChange?()
    }

    public func toggleMinimised() { setMinimised(!isMinimised) }

    public func setAnchor(_ anchor: Anchor, animated: Bool = true) {
        self.anchor = anchor
        UserDefaults.standard.set(anchor.rawValue, forKey: "margin.anchor")
        panel.setFrame(targetFrame(), display: true, animate: false)
        onStateChange?()
    }

    /// ⌃⌥+arrow: move one step around the 3×3 ring of anchors.
    public func nudge(dx: Int, dy: Int) {}
}
