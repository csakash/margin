import AppKit
import MarginCore

/// Shows a shortcut; click it, press keys, and it reports the combo. Esc, a click elsewhere or
/// the window losing key cancels. A modifier-only press updates the hint but doesn't finish.
@MainActor
public final class ShortcutRecorderField: NSButton {
    /// Recording started (true) or ended (false), however it ended.
    public var onRecordingChanged: ((Bool) -> Void)?
    /// A key was pressed with whatever modifiers were held.
    public var onCapture: ((Shortcut) -> Void)?

    public var shortcut: Shortcut { didSet { refresh() } }
    public private(set) var isRecording = false
    private let actionTitle: String
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var liveHint = ""

    public init(shortcut: Shortcut, actionTitle: String) {
        self.shortcut = shortcut
        self.actionTitle = actionTitle
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 28))
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        target = self
        action = #selector(clicked)
        setAccessibilityRole(.button)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        refresh()
    }
    public required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        if isRecording { cancel() } else { startRecording() }
    }

    public func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        liveHint = ""
        window?.makeFirstResponder(self)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let swallowed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return swallowed ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A click on the field itself goes through to `clicked`, which cancels.
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.cancel()
                }
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        refresh()
        onRecordingChanged?(true)
    }

    public func cancel() { stopRecording() }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        keyMonitor = nil; mouseMonitor = nil; resignObserver = nil
        refresh()
        onRecordingChanged?(false)
    }

    /// Swallows (returns true for) every key while recording so nothing else (menus, the editor) acts on it.
    private func handle(_ event: NSEvent) -> Bool {
        let mods = Self.carbonModifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            liveHint = Shortcut.symbols(forModifiers: mods)
            refresh()
            return true
        }
        if event.keyCode == UInt16(Shortcut.Key.escape), mods == 0 {
            cancel()
            return true
        }
        let captured = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
        stopRecording()               // hotkeys come back before the binding is applied
        onCapture?(captured)
        return true
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= Shortcut.Mod.command }
        if f.contains(.shift) { m |= Shortcut.Mod.shift }
        if f.contains(.option) { m |= Shortcut.Mod.option }
        if f.contains(.control) { m |= Shortcut.Mod.control }
        return m
    }

    private func refresh() {
        let text: String
        let color: NSColor
        if isRecording {
            text = liveHint.isEmpty ? "Type shortcut…" : liveHint + "…"
            color = Theme.textSecondary
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        } else {
            text = shortcut.displayString
            color = Theme.text
            layer?.borderColor = NSColor(white: 1, alpha: 0.13).cgColor
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        }
        let style = NSMutableParagraphStyle(); style.alignment = .center
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Theme.mono(12.5, .medium), .foregroundColor: color, .paragraphStyle: style,
        ])
        setAccessibilityLabel("\(actionTitle) shortcut, \(isRecording ? "recording" : shortcut.displayString)")
    }
}
