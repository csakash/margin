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

    /// A non-activating panel leaves Margin inactive, and AppKit only offers key equivalents to
    /// the main menu of the active app, so ⌘C, ⌘V, ⌘Z and the rest went nowhere. Offer them here:
    /// first to the views in this panel, then to the main menu (whose items target the first
    /// responder of this key panel). When Margin is active, AppKit handles them before this point.
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           !NSApp.isActive {
            if performKeyEquivalent(with: event) { return }
            if let menu = NSApp.mainMenu, let item = Self.menuItem(for: event, in: menu), let action = item.action {
                // Items without a target (Copy, Paste, Undo, Select All…) normally go to the key
                // window's first responder, but an inactive app has no key window as far as
                // AppKit's routing is concerned. Walk this panel's responder chain instead.
                if let target = item.target {
                    NSApp.sendAction(action, to: target, from: item)
                } else if action == Selector(("undo:")) || action == Selector(("redo:")) {
                    // Undo and redo are answered by the window's undo manager, which the
                    // responder walk below does not reach for an inactive app.
                    let um = firstResponder?.undoManager ?? undoManager
                    if action == Selector(("undo:")) { if um?.canUndo == true { um?.undo() } }
                    else if um?.canRedo == true { um?.redo() }
                } else if !(firstResponder?.tryToPerform(action, with: item) ?? false) {
                    NSApp.sendAction(action, to: nil, from: item)
                }
                return
            }
        }
        super.sendEvent(event)
    }

    /// The menu item whose key equivalent matches the event (⇧ written as an uppercase key or as
    /// the modifier both count), searching submenus.
    static func menuItem(for event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(relevant)
        let keys = Set([event.charactersIgnoringModifiers, event.characters(byApplyingModifiers: [])]
            .compactMap { $0?.lowercased() }.filter { !$0.isEmpty })
        for item in menu.items {
            if let sub = item.submenu, let hit = menuItem(for: event, in: sub) { return hit }
            guard item.action != nil, !item.keyEquivalent.isEmpty else { continue }
            var itemMods = item.keyEquivalentModifierMask.intersection(relevant)
            var key = item.keyEquivalent
            if key != key.lowercased() { itemMods.insert(.shift); key = key.lowercased() }
            if itemMods == mods, keys.contains(key) { return item }
        }
        return nil
    }
}

