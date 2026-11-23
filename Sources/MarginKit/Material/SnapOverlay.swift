import AppKit

/// Full-screen, click-through overlay shown only while the panel is being dragged.
/// Draws: dimmed backdrop, magnetic dot field, comet trail, dashed beam, 8 slots
/// (nearest glows and pulses), a ghost of the panel at the target, and a landing shockwave.
/// CONTRACT (Wave 0). Loop D implements. Coordinates are screen coordinates.
@MainActor
public final class SnapOverlay {
    public init() {}

    /// Show the overlay on `screen`. `slots` are the 8 minimised-line frames to light up.
    public func begin(on screen: NSScreen, slots: [Anchor: NSRect]) {}

    /// Called on every drag move. `pointer` is the mouse; `object` the centre of the dragged thing;
    /// `nearest` the anchor it would snap to; `ghost` the expanded panel frame at that anchor.
    public func update(pointer: NSPoint, object: NSPoint, nearest: Anchor, ghost: NSRect) {}

    /// Fade out and play the shockwave centred on `landing`.
    public func end(landing: NSRect) {}
}
