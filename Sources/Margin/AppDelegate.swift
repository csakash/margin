import AppKit
import UniformTypeIdentifiers
import MarginCore
import MarginKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: NoteStore!
    private let editor = EditorController()
    private let drawer = DrawerController()
    private var glass: GlassView!
    private var main: MainView!
    private var panel: PanelController!
    private var statusItem: NSStatusItem?
    private var currentID: NoteID?
    private var refreshScheduled = false
    private var savedTimer: Timer?
    private lazy var opacityPopover = makeOpacityPopover()

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        // MARGIN_NOTES_DIR lets tests and demos use a scratch folder instead of ~/Documents/Margin.
        let folder = ProcessInfo.processInfo.environment["MARGIN_NOTES_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? NoteStore.defaultFolder
        do { store = try NoteStore(folder: folder) } catch {
            let alert = NSAlert(error: error); alert.runModal(); NSApp.terminate(nil); return
        }

        glass = GlassView(frame: NSRect(origin: .zero, size: Theme.defaultPanelSize))
        main = MainView(editor: editor, drawer: drawer)
        main.frame = glass.contentView.bounds
        main.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(main)
        panel = PanelController(contentView: glass)

        wireEditor()
        wireHeaderAndToolbar()
        wireDrawer()
        wirePanel()
        registerHotkeys()
        buildStatusItem()
        BrowserClip.startTracking()   // remember the last browser you were in, for "Clip tab"

        store.onChange = { [weak self] in self?.scheduleRefresh() }
        openInitialNote()
        refreshNow()
        panel.show()
        editor.focus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.toggleVisibility()   // Dock icon: minimised ⇄ expanded
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { store?.flush() }

    // MARK: Notes

    private func openInitialNote() {
        let saved = UserDefaults.standard.string(forKey: "margin.current").map(NoteID.init)
        let notes = store.list()
        if let saved, notes.contains(where: { $0.id == saved }) { open(saved) }
        else if let first = notes.first { open(first.id) }
        else { open(store.create(initialText: Self.welcome)) }
    }

    private func open(_ id: NoteID) {
        store.flush()
        currentID = id
        UserDefaults.standard.set(id.raw, forKey: "margin.current")
        editor.text = store.load(id)
        editor.textView.undoManager?.removeAllActions()   // undo must not cross into another note
        editor.textView.setSelectedRange(NSRange(location: (editor.text as NSString).length, length: 0))
        drawer.model.currentID = id
        updateTitle()
    }

    private func newNote() {
        if panel.isMinimised { panel.setMinimised(false) }
        let id = store.create(initialText: "# ")
        drawer.setOpen(false)
        open(id)
        editor.focus()
        refreshNow()
    }

    private func deleteNote(_ id: NoteID) {
        store.delete(id)
        if id == currentID {
            if let next = store.list().first { open(next.id) } else { open(store.create(initialText: "# ")) }
        }
        refreshNow()
    }

    private func updateTitle() {
        main.header.title.stringValue = Markdown.stats(for: editor.text).title
    }

    /// The store reports every keystroke; the drawer only needs a refresh a few times a second.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refreshNow()
            }
        }
    }

    private func refreshNow() {
        let notes = store.list()
        drawer.model.notes = notes
        main.toolbar.notesButton.count = notes.count
    }

    // MARK: Wiring

    private func wireEditor() {
        editor.onChange = { [weak self] text in
            guard let self, let id = currentID else { return }
            store.save(id, text: text)
            updateTitle()
            showSaving()
        }
        editor.importFile = { [weak self] url in try? self?.store.assets.importFile(at: url) }
        editor.importData = { [weak self] data, ext in try? self?.store.assets.importData(data, ext: ext) }
        editor.resolveAsset = { [weak self] path in self?.store.assets.url(for: path) ?? URL(fileURLWithPath: path) }
        editor.onAction = { [weak self] action in self?.perform(action) }
    }

    private func showSaving() {
        main.status.stringValue = "Saving…"
        savedTimer?.invalidate()
        savedTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.main.status.stringValue = "Saved · local" }
        }
    }

    private func wireHeaderAndToolbar() {
        let h = main.header, t = main.toolbar
        h.onDrag = { [weak self] e in self?.panel.beginHeaderDrag(with: e) }
        h.newButton.target = self; h.newButton.action = #selector(newNoteAction)
        h.minimiseButton.target = self; h.minimiseButton.action = #selector(minimiseAction)
        h.pinButton.target = self; h.pinButton.action = #selector(pinAction)
        h.opacityButton.target = self; h.opacityButton.action = #selector(opacityAction(_:))
        for (i, pair) in t.blockButtons.enumerated() {
            pair.1.tag = i; pair.1.target = self; pair.1.action = #selector(blockAction(_:))
        }
        t.imageButton.target = self; t.imageButton.action = #selector(imageAction)
        t.shotButton.target = self; t.shotButton.action = #selector(shotAction)
        t.clipButton.target = self; t.clipButton.action = #selector(clipAction)
        t.notesButton.target = self; t.notesButton.action = #selector(toggleDrawerAction)
    }

    private func wireDrawer() {
        let m = drawer.model
        m.search = { [weak self] q in self?.store.search(q) ?? [] }
        m.onOpen = { [weak self] id in
            guard let self else { return }
            if id != currentID { open(id) }
            drawer.setOpen(false)
            editor.focus()
        }
        m.onNew = { [weak self] in self?.newNote() }
        m.onDelete = { [weak self] id in self?.deleteNote(id) }
        drawer.onToggle = { [weak self] open in
            self?.main.toolbar.notesButton.isOpen = open
            if open { self?.refreshNow() }
        }
    }

    private func wirePanel() {
        panel.onStateChange = { [weak self] in
            guard let self else { return }
            if panel.isMinimised { drawer.setOpen(false, animated: false) } else { editor.focus() }
        }
    }

    private func registerHotkeys() {
        let hk = HotkeyCenter.shared
        hk.register(.optionSpace) { [weak self] in self?.panel.toggleMinimised() }
        hk.register(.optionN) { [weak self] in self?.newNote() }
        hk.registerArrowNudges { [weak self] dx, dy in self?.panel.nudge(dx: dx, dy: dy) }
    }

    // MARK: Actions

    @objc private func newNoteAction() { newNote() }
    @objc private func minimiseAction() { panel.setMinimised(true) }
    @objc private func toggleDrawerAction() { drawer.toggle() }

    @objc private func pinAction() {
        let b = main.header.pinButton
        b.isOn.toggle()
        panel.panel.level = b.isOn ? .floating : .normal
    }

    @objc private func opacityAction(_ sender: NSButton) {
        if opacityPopover.isShown { opacityPopover.close(); return }
        opacityPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func blockAction(_ sender: NSButton) {
        editor.apply(main.toolbar.blockButtons[sender.tag].0)
        editor.focus()
    }

    @objc private func imageAction() { perform(.image) }
    @objc private func shotAction() { perform(.screenshot) }
    @objc private func clipAction() { perform(.clipTab) }

    private func perform(_ action: EditorController.EditorAction) {
        switch action {
        case .image:
            let p = NSOpenPanel()
            p.allowedContentTypes = [.image, .movie]
            p.allowsMultipleSelection = true
            NSApp.activate(ignoringOtherApps: true)
            p.begin { [weak self] r in
                MainActor.assumeIsolated {
                    guard let self, r == .OK else { return }
                    for url in p.urls {
                        if let rel = try? self.store.assets.importFile(at: url) {
                            self.editor.insertImage(relativePath: rel, caption: url.lastPathComponent)
                        }
                    }
                    self.editor.focus()
                }
            }
        case .screenshot:
            ScreenCapture.captureRegion { [weak self] data in
                guard let self, let data, let rel = try? store.assets.importData(data, ext: "png") else { return }
                if panel.isMinimised { panel.setMinimised(false) }
                editor.insertImage(relativePath: rel, caption: "Screenshot")
                editor.focus()
            }
        case .clipTab:
            BrowserClip.frontTab { [weak self] tab in
                guard let self else { return }
                guard let tab else { NSSound.beep(); return }
                editor.insertLink(url: tab.url, title: tab.title)
                editor.focus()
            }
        }
    }

    // MARK: Opacity popover

    private func makeOpacityPopover() -> NSPopover {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        let vc = NSViewController()
        let label = NSTextField(labelWithString: "Panel opacity")
        label.font = Theme.ui(12); label.textColor = Theme.textSecondary
        let slider = NSSlider(value: 1, minValue: 0.35, maxValue: 1, target: self, action: #selector(opacityChanged(_:)))
        slider.isContinuous = true
        let share = NSButton(checkboxWithTitle: "Hide on screen share", target: self, action: #selector(shareToggled(_:)))
        share.state = .off
        let stack = NSStackView(views: [label, slider, share])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.frame = NSRect(x: 0, y: 0, width: 220, height: 104)
        slider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        vc.view = stack
        pop.contentViewController = vc
        return pop
    }

    @objc private func opacityChanged(_ s: NSSlider) { panel.panel.alphaValue = s.doubleValue }
    @objc private func shareToggled(_ b: NSButton) { panel.panel.sharingType = b.state == .on ? .none : .readOnly }

    // MARK: Menus

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 7, y: 2, width: 2.2, height: 12), xRadius: 1.1, yRadius: 1.1).fill()
                return true
            }
            img.isTemplate = true
            button.image = img
            button.setAccessibilityLabel("Margin")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "New Note", action: #selector(newNoteAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show / Minimise", action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        let place = NSMenuItem(title: "Place", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for a in Anchor.allCases {
            let mi = NSMenuItem(title: a.displayName, action: #selector(placeAction(_:)), keyEquivalent: "")
            mi.representedObject = a.rawValue; mi.target = self
            sub.addItem(mi)
        }
        place.submenu = sub
        menu.addItem(place)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Notes Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Margin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleFromMenu() { panel.toggleVisibility() }
    @objc private func openFolder() { NSWorkspace.shared.open(store.folder) }
    @objc private func placeAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let a = Anchor(rawValue: raw) { panel.setAnchor(a) }
    }

    /// Without a main menu, ⌘C / ⌘V / ⌘Z never reach the text view.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Margin", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Margin", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Margin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Note", action: #selector(newNoteAction), keyEquivalent: "n").target = self
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private static let welcome = """
    # Welcome to Margin

    A floating notepad that stays above what you're reading.

    - ⌥ Space minimises it to a thin line; click or drag the line
    - ⌃⌥ + arrows move it between the 8 spots
    - Type / for blocks, or use # - [ ] > ``` at the start of a line
    - [ ] Drop an image, paste a link, or drag text from a page
    - [ ] Open All notes at the bottom right
    """
}
