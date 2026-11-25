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

    /// Routes ⌘ shortcuts for every Margin panel, before AppKit sees them. Call once at launch.
    ///
    /// The panel never activates Margin, and AppKit's own key-equivalent routing depends on the
    /// app being active and on its idea of the key window: ⌘C, ⌘V, ⌘Z and the rest went nowhere,
    /// or only sometimes worked. A local monitor sees each key press as soon as it reaches Margin,
    /// whatever app is in front, and handles it the same way every time.
    public static func installShortcutRouting() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  let panel = (event.window ?? NSApp.keyWindow) as? FloatingPanel,
                  panel.isKeyWindow else { return event }
            return MainActor.assumeIsolated { panel.routeShortcut(event) } ? nil : event
        }
    }

    /// Performs the menu item matching a ⌘ key press. Returns false when no item matches, so text
    /// navigation (⌘←, ⌘→, ⌘⌫…) still reaches the text view as usual.
    func routeShortcut(_ event: NSEvent) -> Bool {
        if performKeyEquivalent(with: event) { return true }
        guard let menu = NSApp.mainMenu, let item = Self.menuItem(for: event, in: menu),
              let action = item.action else { return false }
        if let target = item.target {
            NSApp.sendAction(action, to: target, from: item)
        } else if action == Selector(("undo:")) || action == Selector(("redo:")) {
            // Undo and redo belong to the undo manager; only while the user is typing in an
            // editable text view, never into a hidden or folded note.
            if let tv = firstResponder as? NSTextView, tv.isEditable, !tv.hasMarkedText(),
               let um = tv.undoManager {
                if action == Selector(("undo:")) { if um.canUndo { um.undo() } }
                else if um.canRedo { um.redo() }
            }
        } else if !(firstResponder?.tryToPerform(action, with: item) ?? false) {
            // Copy, Paste, Select All… go to this panel's own responder chain, not to AppKit's
            // notion of the key window (which an inactive app does not have).
            NSApp.sendAction(action, to: nil, from: item)
        }
        return true
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
            // `isEnabled` is no guide here: AppKit's auto-enabling finds no target for Copy, Paste,
            // Undo… while Margin is inactive (the very problem this works around). Margin's own
            // items are asked directly.
            guard item.action != nil, !item.keyEquivalent.isEmpty, !item.isHidden else { continue }
            if let v = item.target as? NSMenuItemValidation, !v.validateMenuItem(item) { continue }
            var itemMods = item.keyEquivalentModifierMask.intersection(relevant)
            var key = item.keyEquivalent
            if key != key.lowercased() { itemMods.insert(.shift); key = key.lowercased() }
            if itemMods == mods, keys.contains(key) { return item }
        }
        return nil
    }
}


