import AppKit

/// The black-glass material shared with the app icon: blur, tint, top light cone, rim light,
/// pointer-tracking specular hotspot and a one-shot sheen sweep.
/// CONTRACT (Wave 0). Loop D implements the layers. Content goes in `contentView`.
@MainActor
public final class GlassView: NSView {

    /// Put the panel UI here; it sits above the material layers.
    public let contentView = NSView()

    /// When true, draws the minimised look (capsule + glowing centre line or corner dot).
    public var isMinimised = false { didSet { needsLayout = true } }
    /// Which edge/corner the minimised line hugs (affects line orientation).
    public var anchor: Anchor = .right { didSet { needsLayout = true } }
    /// While dragging the minimised line it becomes a ball of light.
    public var isOrb = false { didSet { needsLayout = true } }

    private let blur = NSVisualEffectView()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.cornerRadius
        layer?.masksToBounds = true
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)
        contentView.autoresizingMask = [.width, .height]
        contentView.frame = bounds
        addSubview(contentView)
    }

    public required init?(coder: NSCoder) { fatalError() }

    /// One sweep of reflected light across the surface (the "tank shine").
    public func glint() {}
}
