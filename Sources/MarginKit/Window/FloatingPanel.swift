import AppKit

/// A panel that floats over every Space, including other apps' full-screen Spaces,
/// without activating the app until the user clicks into it.
public final class FloatingPanel: NSPanel {

    public init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false                  // movement is ours (snap placement), not the system's
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        minSize = Theme.minPanelSize
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
