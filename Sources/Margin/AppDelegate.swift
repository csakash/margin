import AppKit
import UniformTypeIdentifiers
import MarginCore
import MarginKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var store: NoteStore!
    private let editor = EditorController()
    private let drawer = DrawerController()
    private var glass: GlassView!
    private var main: MainView!
    private var panel: PanelController!
    private var dragPlacement: DragPlacement!
    private let media = MediaHandler()
    private let updates = UpdaterController()
    private var tour: OnboardingController!
    private var statusItem: NSStatusItem?
    private var currentID: NoteID?
    private var refreshScheduled = false
    private var savedTimer: Timer?
    private lazy var opacityPopover = makeOpacityPopover()
    private let shortcuts = ShortcutStore()
    /// The rebindable hotkeys currently registered: Carbon id and the combo it holds.
    private var liveHotkeys: [ShortcutAction: (id: UInt32, shortcut: Shortcut)] = [:] {
        didSet { ShortcutStore.live = liveHotkeys.mapValues { $0.shortcut } }
    }
    /// True while a Settings recorder is listening: every Margin hotkey is off so the keys reach it.
    private var hotkeysSuspended = false
    private var settings: SettingsWindowController?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything below saves a note or a position, which would count as "used before".
        let firstRun = !OnboardingController.hasRun || Override.value("MARGIN_ONBOARDING") == "1"
        buildMainMenu()
        FloatingPanel.installShortcutRouting()   // ⌘C, ⌘V, ⌘Z… whether or not Margin is the active app
        // MARGIN_NOTES_DIR lets tests and demos use a scratch folder instead of ~/Documents/Margin.
        let folder = Override.value("MARGIN_NOTES_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
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
        dragPlacement = DragPlacement(controller: panel)   // drag the header or the line: snap FX + 8 spots
        dragPlacement.install()

        wireEditor()
        editor.textView.mediaHandler = media   // drop / paste files, images, links, quotes
        wireHeaderAndToolbar()
        wireDrawer()
        wirePanel()
        registerHotkeys(atLaunch: true)
        buildStatusItem()
        BrowserClip.startTracking()   // remember the last browser you were in, for "Clip tab"

        store.onChange = { [weak self] in self?.scheduleRefresh() }
        openInitialNote()
        refreshNow()
        main.status.alphaValue = 0   // only shown while saving
        tour = OnboardingController(panel: panel, mainView: main)
        tour.onFinish = { [weak self] in self?.editor.focus() }
        dragPlacement.onPlaced = { [weak self] _ in self?.tour.didPlace() }
        if firstRun {
            tour.start()          // first launch: the welcome tour opens the panel itself
        } else {
            panel.show()
            editor.focus()
        }
        wireUpdates()
        wireScreenNotice()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.toggleVisibility()   // Dock icon: minimised ⇄ expanded
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if hotkeysSuspended { HotkeyCenter.setSystemHotkeysPaused(false) }   // quit mid-recording
        store?.flush()
    }

    // MARK: Notes

    private func openInitialNote() {
        let saved = UserDefaults.standard.string(forKey: "margin.current").map(NoteID.init)
        let notes = store.list()
        if let saved, notes.contains(where: { $0.id == saved }) { open(saved) }
        else if let first = notes.first { open(first.id) }
        else { open(store.create(initialText: welcomeText())) }
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
        // The New Note hotkey, ⌘N or the menu during the tour: end the tour first, then make the note.
        if tour?.isBusy == true {
            tour.endNow { [weak self] in self?.newNote() }
            return
        }
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

    /// "Saving…" appears while you type, turns into "Saved · local", then fades away
    /// so it never sits on top of the text.
    private func showSaving() {
        let s = main.status
        s.stringValue = "Saving…"
        s.alphaValue = 1
        savedTimer?.invalidate()
        savedTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let s = self?.main.status else { return }
                s.stringValue = "Saved · local"
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.6
                    ctx.timingFunction = Theme.easeOut
                    // start fading after a beat
                    s.animator().alphaValue = 0.999
                } completionHandler: {
                    MainActor.assumeIsolated {
                        NSAnimationContext.runAnimationGroup { c in c.duration = 0.5; s.animator().alphaValue = 0 }
                    }
                }
            }
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
            if tour?.isActive == true {
                // The tour owns focus and the keyboard while it runs.
                tour.panelStateChanged()
                return
            }
            if panel.isMinimised {
                drawer.setOpen(false, animated: false)
                // No caret while minimised: its blink animation is the only thing that would wake us.
                panel.panel.makeFirstResponder(nil)
                editor.textView.isEditable = false
            } else {
                editor.textView.isEditable = true
                editor.focus()
            }
        }
    }

    // MARK: Hotkeys

    /// Registers both rebindable hotkeys from ShortcutStore, plus the fixed ⌃⌥ arrow nudges.
    /// A stored combo another app has taken since falls back to the default (the stored value is
    /// kept). If the default fails too the action stays unbound, and at launch one alert says so.
    private func registerHotkeys(atLaunch: Bool) {
        var failed: [Shortcut] = []
        for action in ShortcutAction.allCases {
            let wanted = shortcuts.shortcut(for: action)
            if let id = registerHotkey(action, wanted) { liveHotkeys[action] = (id, wanted); continue }
            let fallback = action.defaultShortcut
            if fallback != wanted, shortcuts.validate(fallback, for: action) == .ok,
               let id = registerHotkey(action, fallback) {
                liveHotkeys[action] = (id, fallback)
                continue
            }
            failed.append(wanted)
            if fallback != wanted { failed.append(fallback) }
        }
        HotkeyCenter.shared.registerArrowNudges { [weak self] dx, dy in self?.panel.nudge(dx: dx, dy: dy) }
        // Labels show the live combos, which a fallback may have changed.
        NotificationCenter.default.post(name: .marginShortcutsChanged, object: nil)
        if atLaunch, !failed.isEmpty {
            // After launch finishes, so Settings never opens over a half-built app.
            DispatchQueue.main.async { [weak self] in self?.showHotkeyFailure(failed) }
        }
    }

    private func registerHotkey(_ action: ShortcutAction, _ shortcut: Shortcut) -> UInt32? {
        HotkeyCenter.shared.register(HotkeyCenter.Combo(shortcut)) { [weak self] in self?.hotkeyFired(action) }
    }

    private func hotkeyFired(_ action: ShortcutAction) {
        switch action {
        case .toggle:
            if tour?.isActive == true { tour.foldKeyPressed() } else { panel.toggleMinimised() }
        case .newNote:
            newNote()
        }
    }

    /// The only way a binding changes. Swaps the live hotkey; if the new combo can't be
    /// registered the old one goes back and nothing is saved.
    private func rebind(_ action: ShortcutAction, to shortcut: Shortcut) -> Bool {
        if hotkeysSuspended {
            // Nothing is registered while recording; the combo goes live on resume.
            guard HotkeyCenter.shared.isAvailable(HotkeyCenter.Combo(shortcut)) else { return false }
        } else {
            let old = liveHotkeys.removeValue(forKey: action)
            if let old { HotkeyCenter.shared.unregister(old.id) }
            guard !HotkeyCenter.isSystemShortcut(HotkeyCenter.Combo(shortcut)), let id = registerHotkey(action, shortcut) else {
                if let old, let back = registerHotkey(action, old.shortcut) { liveHotkeys[action] = (back, old.shortcut) }
                return false
            }
            liveHotkeys[action] = (id, shortcut)
        }
        if shortcut == action.defaultShortcut { shortcuts.reset(action) } else { shortcuts.set(shortcut, for: action) }
        NotificationCenter.default.post(name: .marginShortcutsChanged, object: nil)
        return true
    }

    /// Settings recorders turn every Margin hotkey off while they listen, so pressing the
    /// current combo records it instead of folding the panel.
    private func setHotkeysSuspended(_ suspended: Bool) {
        guard suspended != hotkeysSuspended else { return }
        hotkeysSuspended = suspended
        if suspended {
            HotkeyCenter.shared.unregisterAll()
            liveHotkeys.removeAll()
            HotkeyCenter.setSystemHotkeysPaused(true)
        } else {
            HotkeyCenter.setSystemHotkeysPaused(false)
            registerHotkeys(atLaunch: false)
        }
    }

    private func showHotkeyFailure(_ failed: [Shortcut]) {
        let combos = failed.map(\.displayString).joined(separator: " or ")
        let alert = NSAlert()
        alert.messageText = "Margin couldn't use \(combos)."
        alert.informativeText = "Another app or macOS is using it. Choose another shortcut in Settings."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { showSettings() }
    }

    /// One Settings window, made on first use.
    @objc private func showSettings() {
        if settings == nil {
            let s = SettingsWindowController(store: shortcuts)
            s.onRecordingChanged = { [weak self] recording in self?.setHotkeysSuspended(recording) }
            s.apply = { [weak self] action, shortcut in self?.rebind(action, to: shortcut) ?? false }
            settings = s
        }
        settings?.show()
    }

    /// ⌘W closes Settings when it is in front; otherwise it folds the panel, as before.
    @objc private func closeAction() {
        if let w = settings?.window, w.isKeyWindow { w.performClose(nil); return }
        minimiseAction()
    }

    // MARK: Actions

    @objc private func newNoteAction() { newNote() }
    @objc private func boldAction() { formatInline("**") }
    @objc private func italicAction() { formatInline("_") }
    @objc private func inlineCodeAction() { formatInline("`") }
    @objc private func formatBlockAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = BlockKind(rawValue: raw), editorIsActive else { return }
        editor.apply(kind)
    }
    private func formatInline(_ marker: String) {
        guard editorIsActive else { return }
        editor.toggleInline(marker)
    }
    /// Formatting shortcuts only act on the note when the editor has the keyboard.
    private var editorIsActive: Bool {
        tour?.isBusy != true && !panel.isMinimised && panel.panel.firstResponder === editor.textView
    }
    @objc private func minimiseAction() {
        if tour?.isActive == true {
            if !panel.isMinimised { tour.foldKeyPressed() }   // same as the tour's own fold step
            return
        }
        panel.setMinimised(true)
    }
    @objc private func toggleDrawerAction() {
        guard tour?.isBusy != true else { return }
        if panel.isMinimised {
            panel.setMinimised(false)
            drawer.setOpen(true)
            return
        }
        drawer.toggle()
    }

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
            let start = ScreenCapture.captureRegion { [weak self] data in
                guard let self, let data, let rel = try? store.assets.importData(data, ext: "png") else { return }
                if panel.isMinimised { panel.setMinimised(false) }
                editor.insertImage(relativePath: rel, caption: "Screenshot")
                editor.focus()
            }
            switch start {
            case .needsPermission: showScreenNotice(ScreenAccess.wasRequested ? .settings : .ask)
            case .started: showScreenNotice(nil)
            case .busy: break
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

    // MARK: Screen Recording notice

    /// Where the screenshot permission card is: not asked yet, asked (go to Settings), or Settings
    /// opened (a restart makes the grant take effect).
    private enum ScreenNotice { case ask, settings, reopen }
    private var screenNotice: ScreenNotice?

    private func showScreenNotice(_ n: ScreenNotice?) {
        screenNotice = n
        let card: CardNotice?
        switch n {
        case .ask:
            card = CardNotice(title: "Screenshots need one permission",
                              body: "macOS asks once. Margin only captures the area you select.",
                              primary: "Allow", secondary: "Not now")
        case .settings:
            card = CardNotice(title: "Switch on Margin for screenshots",
                              body: "System Settings › Privacy & Security › Screen & System Audio Recording. Margin needs a restart after that.",
                              primary: "Open Settings", secondary: "Not now")
        case .reopen:
            card = CardNotice(title: "Reopen Margin to finish",
                              body: "Once Margin is switched on in System Settings, a restart lets it take screenshots.",
                              primary: "Reopen Margin", secondary: "Not now")
        case nil:
            card = nil
        }
        main.noticeCard.showNotice(card, animated: !panel.isMinimised)
    }

    private func wireScreenNotice() {
        main.noticeCard.onDismiss = { [weak self] in self?.showScreenNotice(nil) }
        main.noticeCard.onPrimary = { [weak self] in
            guard let self else { return }
            switch screenNotice {
            case .ask:
                ScreenAccess.request()
                showScreenNotice(ScreenAccess.isGranted ? nil : .settings)
            case .settings:
                ScreenAccess.openSettings()
                showScreenNotice(.reopen)
            case .reopen:
                // A waiting update installs on quit; let Sparkle restart into it instead of racing it.
                if updates.readyVersion != nil { updates.restartToUpdate() } else { ScreenAccess.relaunch() }
            case nil:
                break
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

    // MARK: Updates

    private func wireUpdates() {
        main.updateCard.onPrimary = { [weak self] in self?.updates.primaryAction() }
        main.updateCard.onDismiss = { [weak self] in self?.updates.dismiss() }
        updates.onChange = { [weak self] in
            guard let self else { return }
            // An update found in the background never expands or focuses the panel:
            // the card is there when you open it, and the nub glows until then.
            self.main.setUpdatePhase(self.updates.cardPhase, animated: !self.panel.isMinimised)
            self.panel.hasPendingUpdate = self.updates.phase.showsNubDot
        }
        updates.start()
    }

    /// "Check for Updates…" doubles as "Restart to Update (x)" while one is waiting.
    @objc private func checkForUpdatesAction() {
        if updates.readyVersion != nil, updates.cardPhase != .idle {
            updates.restartToUpdate()
            return
        }
        if panel.isMinimised { panel.setMinimised(false) }   // you asked, so show the answer
        updates.checkNow()
    }

    @objc private func toggleAutomaticUpdates() { updates.automaticChecks.toggle() }
    @objc private func toggleSounds() { Sounds.isEnabled.toggle() }
    @objc private func showTour() { tour.start() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(checkForUpdatesAction):
            if let v = updates.readyVersion {
                item.title = updates.cardPhase == .idle ? "Show Update (\(v))…" : "Restart to Update (\(v))"
                return true
            }
            item.title = "Check for Updates…"
            return updates.canCheck
        case #selector(toggleAutomaticUpdates):
            item.state = updates.automaticChecks ? .on : .off
            return updates.isAvailable
        case #selector(toggleSounds):
            item.state = Sounds.isEnabled ? .on : .off
            return true
        case #selector(showTour):
            return !tour.isBusy
        default:
            return true
        }
    }

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
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Notes Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates Automatically", action: #selector(toggleAutomaticUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Sounds", action: #selector(toggleSounds), keyEquivalent: "").target = self
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
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "").target = self
        app.addItem(withTitle: "Check for Updates Automatically", action: #selector(toggleAutomaticUpdates), keyEquivalent: "").target = self
        app.addItem(withTitle: "Show Welcome Tour", action: #selector(showTour), keyEquivalent: "").target = self
        app.addItem(.separator())
        // Margin is never fully hidden (the fold hotkey and the menu bar icon could not bring it back):
        // "Hide" folds the panel into its line.
        app.addItem(withTitle: "Hide Margin", action: #selector(minimiseAction), keyEquivalent: "h").target = self
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Quit Margin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Note", action: #selector(newNoteAction), keyEquivalent: "n").target = self
        file.addItem(withTitle: "All Notes", action: #selector(toggleDrawerAction), keyEquivalent: "o").target = self
        file.addItem(.separator())
        // The panel never closes; ⌘W folds it into its line, like the fold hotkey.
        file.addItem(withTitle: "Close", action: #selector(closeAction), keyEquivalent: "w").target = self
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
        let pastePlain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "Find")
        for (title, key, mods, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", [.command], .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
        ] as [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] {
            let item = find.addItem(withTitle: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = action.rawValue
        }
        findItem.submenu = find
        edit.addItem(findItem)
        editItem.submenu = edit
        let formatItem = NSMenuItem(); main.addItem(formatItem)
        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(boldAction), keyEquivalent: "b").target = self
        format.addItem(withTitle: "Italic", action: #selector(italicAction), keyEquivalent: "i").target = self
        format.addItem(withTitle: "Inline Code", action: #selector(inlineCodeAction), keyEquivalent: "e").target = self
        format.addItem(.separator())
        let blocks: [(String, String, NSEvent.ModifierFlags, BlockKind)] = [
            ("Body Text", "0", [.command], .paragraph),
            ("Heading 1", "1", [.command], .heading1),
            ("Heading 2", "2", [.command], .heading2),
            ("Heading 3", "3", [.command], .heading3),
            ("Numbered List", "7", [.command, .shift], .numbered),
            ("Bullet List", "8", [.command, .shift], .bullet),
            ("To-do", "9", [.command, .shift], .todo),
            ("Quote", ".", [.command, .shift], .quote),
            ("Code Block", "c", [.command, .option], .code),
        ]
        for (title, key, mods, kind) in blocks {
            let item = format.addItem(withTitle: title, action: #selector(formatBlockAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.representedObject = kind.rawValue
            item.target = self
        }
        formatItem.submenu = format

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimise", action: #selector(minimiseAction), keyEquivalent: "m").target = self
        windowItem.submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func welcomeText() -> String {
        let fold = shortcuts.effectiveShortcut(for: .toggle).keycaps.joined(separator: " ")
        return """
    # Welcome to Margin

    A floating notepad that stays above what you're reading.

    - \(fold) minimises it to a thin line; click or drag the line
    - ⌃⌥ + arrows move it between the 8 spots
    - Type / for blocks, or use # - [ ] > ``` at the start of a line
    - [ ] Drop an image, paste a link, or drag text from a page
    - [ ] Open All notes at the bottom right
    """
    }
}
