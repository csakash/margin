import AppKit
import MarginCore

/// Composes the expanded panel: header, editor, toolbar and the push-up drawer.
/// Lives inside `GlassView.contentView`. Pure layout + event forwarding; the app wires behaviour.
@MainActor
public final class MainView: NSView {

    public let header = HeaderBar()
    public let toolbar = ToolbarBar()
    public let status = NSTextField(labelWithString: "Saved · local")
    public let editor: EditorController
    public let drawer: DrawerController
    /// In-panel update notice; zero height unless an update phase is showing.
    public let updateCard = UpdateCardView()
    /// Plain notices (Screen Recording), stacked above the update card.
    public let noticeCard = UpdateCardView()
    private var cardHeights: (notice: CGFloat, update: CGFloat) = (0, 0)
    private let fade = GradientView()

    // Bottom-anchored scrolling: how far the visible bottom is from the document end.
    private var distanceFromBottom: CGFloat = 0
    private var adjusting = false

    public init(editor: EditorController, drawer: DrawerController) {
        self.editor = editor
        self.drawer = drawer
        super.init(frame: .zero)
        let scroll = editor.scrollView
        for v in [scroll, fade, header, noticeCard, updateCard, toolbar, status, drawer.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        status.font = Theme.mono(10)
        status.textColor = Theme.textTertiary
        status.alignment = .center

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.headerHeight),

            drawer.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            drawer.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            drawer.view.bottomAnchor.constraint(equalTo: bottomAnchor),

            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: drawer.view.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Theme.toolbarHeight),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: noticeCard.topAnchor),
            noticeCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            noticeCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            noticeCard.bottomAnchor.constraint(equalTo: updateCard.topAnchor),
            // The note never collapses to nothing; the card (lower priority) and drawer give way first.
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),

            // The update card sits between the note and the toolbar and pushes the note up.
            updateCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            updateCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            updateCard.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            fade.leadingAnchor.constraint(equalTo: leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: trailingAnchor),
            fade.bottomAnchor.constraint(equalTo: noticeCard.topAnchor),
            fade.heightAnchor.constraint(equalToConstant: 44),

            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.bottomAnchor.constraint(equalTo: noticeCard.topAnchor, constant: -6),
        ])

        // Keep the line you're writing in view while the drawer pushes the editor up.
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollResized), name: NSView.frameDidChangeNotification, object: scroll)

        toolbar.pan.target = self
        toolbar.pan.action = #selector(toolbarPan(_:))

        // The card and the drawer both push the note up; an open drawer shrinks to make room.
        noticeCard.onTargetHeightChange = { [weak self] h, animated in
            guard let self else { return }
            self.cardHeights.notice = h
            self.drawer.reservedHeight = self.cardHeights.notice + self.cardHeights.update
            DispatchQueue.main.async { [weak self] in self?.drawer.refit(animated: animated) }
        }
        updateCard.onTargetHeightChange = { [weak self] h, animated in
            guard let self else { return }
            self.cardHeights.update = h
            self.drawer.reservedHeight = self.cardHeights.notice + self.cardHeights.update
            // May be reported from inside a layout pass; change the drawer after it.
            DispatchQueue.main.async { [weak self] in self?.drawer.refit(animated: animated) }
        }
    }

    public required init?(coder: NSCoder) { fatalError() }

    /// Shows, changes or hides the update card.
    public func setUpdatePhase(_ phase: UpdatePhase, animated: Bool) {
        updateCard.apply(phase, animated: animated)
    }

    @objc private func clipScrolled() {
        guard !adjusting, let doc = editor.scrollView.documentView else { return }
        let clip = editor.scrollView.contentView
        distanceFromBottom = max(0, doc.frame.height - clip.bounds.maxY)
    }

    /// The drawer's room depends on the panel's height, so re-fit it when the panel is resized.
    public override func setFrameSize(_ newSize: NSSize) {
        let heightChanged = abs(newSize.height - frame.height) > 0.5
        super.setFrameSize(newSize)
        if heightChanged, drawer.isOpen {
            DispatchQueue.main.async { [weak self] in self?.drawer.refit(animated: false) }
        }
    }

    @objc private func scrollResized() {
        guard let doc = editor.scrollView.documentView else { return }
        let clip = editor.scrollView.contentView
        adjusting = true
        let y = max(0, doc.frame.height - clip.bounds.height - distanceFromBottom)
        clip.scroll(to: NSPoint(x: 0, y: y))
        editor.scrollView.reflectScrolledClipView(clip)
        adjusting = false
    }

    @objc private func toolbarPan(_ g: NSPanGestureRecognizer) {
        let dy = g.translation(in: toolbar).y   // toolbar isn't flipped: up is +
        switch g.state {
        case .began: drawer.begin()
        case .changed: drawer.change(to: dy)
        case .ended, .cancelled: drawer.end(at: dy)
        default: break
        }
    }
}

// MARK: - Header

@MainActor
public final class HeaderBar: NSView {
    public let title = NSTextField(labelWithString: "Untitled")
    public let newButton = IconButton(symbol: "plus", tip: "New note")
    public let pinButton = IconButton(symbol: "pin", tip: "Float above all Spaces")
    public let opacityButton = IconButton(symbol: "circle.lefthalf.filled", tip: "Opacity")
    public let minimiseButton = IconButton(symbol: "minus", tip: "Minimise")
    /// mouseDown on empty header space (not a button): start dragging the panel.
    public var onDrag: ((NSEvent) -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Theme.ui(13, .medium)
        title.textColor = Theme.textSecondary
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, NSView(), newButton, pinButton, opacityButton, minimiseButton])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        pinButton.isOn = true
        updateShortcutTips()
        NotificationCenter.default.addObserver(self, selector: #selector(updateShortcutTips),
                                               name: .marginShortcutsChanged, object: nil)
        let line = HairlineView(); line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    public required init?(coder: NSCoder) { fatalError() }

    public override func mouseDown(with event: NSEvent) { onDrag?(event) }
    public override var mouseDownCanMoveWindow: Bool { false }

    /// Tooltips name the user's current bindings.
    @objc private func updateShortcutTips() {
        let store = ShortcutStore()
        newButton.tip = "New note  \(store.effectiveShortcut(for: .newNote).displayString)"
        minimiseButton.tip = "Minimise  \(store.effectiveShortcut(for: .toggle).displayString)"
    }
}

// MARK: - Toolbar

@MainActor
public final class ToolbarBar: NSView {
    public let blockButtons: [(BlockKind, IconButton)] = [
        (.heading1, IconButton(symbol: "number", tip: "Heading")),
        (.bullet, IconButton(symbol: "list.bullet", tip: "Bullet list")),
        (.todo, IconButton(symbol: "checkmark.square", tip: "To-do")),
        (.code, IconButton(symbol: "chevron.left.forwardslash.chevron.right", tip: "Code")),
    ]
    public let imageButton = IconButton(symbol: "photo", tip: "Image / video")
    public let shotButton = IconButton(symbol: "viewfinder", tip: "Snap region  ⌃⌥S")
    public let clipButton = IconButton(symbol: "link", tip: "Clip current tab")
    public let notesButton = PillButton()
    /// Drag the toolbar up/down to open or close the drawer.
    public let pan = NSPanGestureRecognizer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        let sep = NSBox(); sep.boxType = .custom; sep.borderWidth = 0; sep.fillColor = Theme.hairline
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let views: [NSView] = blockButtons.map { $0.1 } + [sep, imageButton, shotButton, clipButton, NSView(), notesButton]
        let stack = NSStackView(views: views)
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let line = HairlineView(); line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: topAnchor), line.heightAnchor.constraint(equalToConstant: 1),
        ])
        addGestureRecognizer(pan)
    }
    public required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Controls

/// Borderless SF Symbol button: tertiary at rest, brighter on hover, glows white when `isOn`.
@MainActor
public final class IconButton: NSButton {
    public var isOn = false { didSet { refresh() } }
    private var hovering = false
    private let baseSymbol: String

    /// Tooltip and accessibility label.
    public var tip: String {
        get { toolTip ?? "" }
        set { toolTip = newValue; setAccessibilityLabel(newValue); refresh() }
    }

    public init(symbol: String, tip: String) {
        baseSymbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        toolTip = tip
        setAccessibilityLabel(tip)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        refresh()
    }
    public required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let name = isOn ? (NSImage(systemSymbolName: baseSymbol + ".fill", accessibilityDescription: nil) != nil ? baseSymbol + ".fill" : baseSymbol) : baseSymbol
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?.withSymbolConfiguration(cfg)
        contentTintColor = isOn ? .white : hovering ? Theme.text : Theme.textTertiary
        layer?.backgroundColor = hovering ? NSColor(white: 1, alpha: 0.06).cgColor : NSColor.clear.cgColor
        layer?.shadowColor = NSColor.white.cgColor
        layer?.shadowOpacity = isOn ? 0.6 : 0
        layer?.shadowRadius = 5
        layer?.shadowOffset = .zero
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    public override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    public override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    public override func mouseDown(with event: NSEvent) {
        // Feedback on press, not release.
        layer?.setAffineTransform(CGAffineTransform(scaleX: 0.92, y: 0.92))
        super.mouseDown(with: event)
        layer?.setAffineTransform(.identity)
    }
    public override var mouseDownCanMoveWindow: Bool { false }
}

/// "All notes 4 ⌃" capsule in the toolbar.
@MainActor
public final class PillButton: NSButton {
    public var count = 0 { didSet { refresh() } }
    public var isOpen = false { didSet { refresh() } }

    public init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.06).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityLabel("All notes")
        refresh()
    }
    public required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let s = NSMutableAttributedString(string: "All notes  ", attributes: [.font: Theme.ui(12, .medium), .foregroundColor: isOpen ? NSColor.white : Theme.textSecondary])
        s.append(NSAttributedString(string: "\(count)  ", attributes: [.font: Theme.mono(10.5, .medium), .foregroundColor: Theme.textTertiary]))
        s.append(NSAttributedString(string: isOpen ? "⌄" : "⌃", attributes: [.font: Theme.ui(11, .semibold), .foregroundColor: Theme.textSecondary]))
        attributedTitle = s
        layer?.backgroundColor = NSColor(white: 1, alpha: isOpen ? 0.09 : 0.05).cgColor
        invalidateIntrinsicContentSize()
    }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: attributedTitle.size().width + 24, height: 30)
    }
    public override var mouseDownCanMoveWindow: Bool { false }
}

/// 1 pt line that fades out at both ends.
final class HairlineView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let g = CAGradientLayer()
        g.colors = [NSColor.clear.cgColor, NSColor(white: 1, alpha: 0.09).cgColor, NSColor.clear.cgColor]
        g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
        layer = g
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Soft fade where text slides under the toolbar.
final class GradientView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let g = CAGradientLayer()
        g.colors = [NSColor(red: 6/255, green: 6/255, blue: 7/255, alpha: 0.6).cgColor, NSColor.clear.cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 0); g.endPoint = CGPoint(x: 0.5, y: 1)
        layer = g
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
