import AppKit
import MarginCore

/// Settings › Shortcuts: one row per rebindable global shortcut. A combo is checked in order
/// (ShortcutStore.validate, then HotkeyCenter.isAvailable, then `apply`); any failure shows an
/// inline message and the old binding stays.
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// A recorder started or stopped listening. The app turns its hotkeys off meanwhile.
    public var onRecordingChanged: ((Bool) -> Void)?
    /// Makes the binding live and saves it. Returns false if it couldn't be registered.
    public var apply: ((ShortcutAction, Shortcut) -> Bool)?

    private let store: ShortcutStore
    private var rows: [ShortcutAction: Row] = [:]

    private struct Row {
        let recorder: ShortcutRecorderField
        let reset: NSButton
        let message: NSTextField
    }

    public init(store: ShortcutStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 22/255, green: 22/255, blue: 24/255, alpha: 1)
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: .marginShortcutsChanged, object: nil)
    }
    public required init?(coder: NSCoder) { fatalError() }

    /// Brings the one Settings window to the front.
    public func show() {
        reloadRows()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        for row in rows.values { row.recorder.cancel() }
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let header = NSTextField(labelWithString: "Shortcuts")
        header.font = Theme.ui(13, .semibold)
        header.textColor = Theme.text
        let note = NSTextField(labelWithString: "Global: they work from any app.")
        note.font = Theme.ui(11.5)
        note.textColor = Theme.textTertiary

        var views: [NSView] = [header, note]
        for action in ShortcutAction.allCases {
            let (rowView, row) = makeRow(action)
            rows[action] = row
            views.append(rowView)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: header)
        stack.setCustomSpacing(14, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
        for v in views.dropFirst(2) { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func makeRow(_ action: ShortcutAction) -> (NSView, Row) {
        let label = NSTextField(labelWithString: action.title)
        label.font = Theme.ui(13)
        label.textColor = Theme.textSecondary
        let recorder = ShortcutRecorderField(shortcut: store.shortcut(for: action), actionTitle: action.title)
        recorder.onRecordingChanged = { [weak self] recording in
            guard let self else { return }
            if recording {
                // Only one recorder listens at a time.
                for (a, r) in self.rows where a != action { r.recorder.cancel() }
                self.setMessage(nil, for: action)
            }
            self.onRecordingChanged?(recording)
        }
        recorder.onCapture = { [weak self] shortcut in self?.attempt(shortcut, for: action) }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetClicked(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.tag = ShortcutAction.allCases.firstIndex(of: action) ?? 0
        reset.setAccessibilityLabel("Reset \(action.title) to \(action.defaultShortcut.displayString)")
        let message = NSTextField(labelWithString: "")
        message.font = Theme.ui(11.5)
        message.textColor = NSColor.systemRed
        message.isHidden = true

        let line = NSStackView(views: [label, NSView(), recorder, reset])
        line.orientation = .horizontal
        line.spacing = 8
        let column = NSStackView(views: [line, message])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return (column, Row(recorder: recorder, reset: reset, message: message))
    }

    // MARK: Binding

    private func attempt(_ shortcut: Shortcut, for action: ShortcutAction) {
        if shortcut == store.shortcut(for: action) {   // unchanged
            setMessage(nil, for: action)
            return
        }
        let validation = store.validate(shortcut, for: action)
        if let message = validation.message {
            setMessage(message, for: action)
            return
        }
        guard HotkeyCenter.shared.isAvailable(HotkeyCenter.Combo(shortcut)),
              apply?(action, shortcut) == true else {
            setMessage("\(shortcut.displayString) is in use by macOS or another app.", for: action)
            return
        }
        setMessage(nil, for: action)
        reloadRows()
    }

    @objc private func resetClicked(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        rows[action]?.recorder.cancel()
        attempt(action.defaultShortcut, for: action)
    }

    @objc private func shortcutsChanged() { reloadRows() }

    private func reloadRows() {
        for (action, row) in rows {
            let current = store.shortcut(for: action)
            row.recorder.shortcut = current
            row.reset.isEnabled = current != action.defaultShortcut
        }
    }

    private func setMessage(_ text: String?, for action: ShortcutAction) {
        guard let row = rows[action] else { return }
        row.message.stringValue = text ?? ""
        row.message.isHidden = text == nil
    }
}
