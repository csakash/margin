import AppKit
import MarginCore

/// The markdown editor: an NSTextView (TextKit 2) that styles markdown live.
/// The text is always plain markdown; styling is attributes only (see MarkdownStyler).
/// Loop E adds media (drop/paste) through the importer closures below.
@MainActor
public final class EditorController: NSObject {

    public let scrollView: NSScrollView
    public let textView: MarkdownTextView

    /// Called (debounce is the store's job) whenever the user edits the text.
    public var onChange: ((String) -> Void)?
    /// Copies a dropped/pasted file into the notes folder; returns "assets/…" or nil. Set by integration.
    public var importFile: ((URL) -> String?)?
    /// Stores raw image data (pasted screenshot); returns "assets/…" or nil. Set by integration.
    public var importData: ((Data, String) -> String?)?
    /// Resolves "assets/…" to a file URL for display. Set by integration.
    public var resolveAsset: ((String) -> URL)? {
        didSet { styler.restyleMedia() }
    }
    /// Called when the user picks Screenshot / Clip tab / Image from the `/` menu or toolbar.
    public var onAction: ((EditorAction) -> Void)?

    public enum EditorAction: Sendable { case image, screenshot, clipTab }

    let styler: MarkdownStyler
    let slashMenu = SlashMenu()

    public override init() {
        textView = MarkdownTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView()
        styler = MarkdownStyler(textView: textView)
        super.init()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.drawsBackground = false
        textView.font = MarkdownStyler.bodyFont
        textView.textColor = MarkdownStyler.bodyColor
        textView.insertionPointColor = .white
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true                 // ⌘F / ⌘G / ⇧⌘G
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.defaultParagraphStyle = MarkdownStyler.baseParagraph
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.18)]
        textView.delegate = self
        textView.editorController = self
        textView.styler = styler
        textView.textStorage?.delegate = styler

        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(textViewFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: textView)
        slashMenu.onPick = { [weak self] item in self?.pickSlashItem(item) }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // Undo and redo restore the text without a text-did-change notification, so they were
        // never saved. Treat them as edits.
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoneOrRedone(_:)), name: name, object: nil)
        }
    }

    @objc private func undoneOrRedone(_ note: Notification) {
        // The window shares one undo manager with the drawer's search field: only a change to
        // the note's own text is an edit worth saving.
        guard let um = note.object as? UndoManager, um === textView.undoManager,
              textView.string != lastNotifiedText else { return }
        lastNotifiedText = textView.string
        onChange?(textView.string)
        textView.invalidateDecorations()
    }

    @objc private func scrolled(_ note: Notification) {
        textView.invalidateDecorations()
    }

    @objc private func textViewFrameChanged(_ note: Notification) {
        styler.containerWidthMayHaveChanged()
    }

    /// The text the app was last told about (opened or changed), so undo/redo saves only real changes.
    private var lastNotifiedText = ""

    /// The full markdown text of the open note.
    public var text: String {
        get { textView.string }
        set {
            closeSlashMenu()
            textView.string = newValue
            lastNotifiedText = newValue
            textView.typingAttributes = MarkdownStyler.baseAttributes
            textView.invalidateDecorations()
        }
    }

    public func focus() { textView.window?.makeFirstResponder(textView) }

    // MARK: - Block commands

    /// Toolbar / `/` menu: set the block type of the caret's line (toggle back to text if same).
    public func apply(_ kind: BlockKind) {
        let ns = textView.string as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        switch kind {
        case .code: perform(EditorLogic.codeToggle(text: textView.string, caret: caret))
        case .divider: perform(EditorLogic.blockInsertion(text: ns, caret: caret, block: "---"))
        default: perform(EditorLogic.applyPrefix(kind, text: ns, caret: caret))
        }
    }

    /// ⌘B / ⌘I / ⌘E: wrap the selection in a markdown marker, or unwrap it when the marker is
    /// already right around it. With nothing selected, inserts a pair and puts the caret inside.
    public func toggleInline(_ marker: String) {
        closeSlashMenu()
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let m = (marker as NSString).length
        textView.breakUndoCoalescing()
        let selected = ns.substring(with: sel)
        if selected.contains("\n") {
            // Markdown emphasis does not span lines: wrap each non-empty line on its own.
            let wrapped = selected.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : marker + $0 + marker }
                .joined(separator: "\n")
            _ = textView.replace(sel, with: wrapped,
                                 select: NSRange(location: sel.location, length: (wrapped as NSString).length))
            textView.breakUndoCoalescing()
            return
        }
        if sel.length > 0, sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            _ = textView.replace(outer, with: ns.substring(with: sel),
                                 select: NSRange(location: sel.location - m, length: sel.length))
        } else {
            let inner = ns.substring(with: sel)
            _ = textView.replace(sel, with: marker + inner + marker,
                                 select: NSRange(location: sel.location + m, length: sel.length))
        }
        textView.breakUndoCoalescing()
    }

    /// Insert at the caret as its own paragraph(s).
    public func insertImage(relativePath: String, caption: String? = nil) {
        insertBlock(EditorLogic.imageMarkdown(path: relativePath, caption: caption))
    }

    public func insertLink(url: URL, title: String?) {
        insertBlock(EditorLogic.linkMarkdown(url: url, title: title))
    }

    public func insertQuote(_ text: String, source: URL?) {
        insertBlock(EditorLogic.quoteMarkdown(text, source: source))
    }

    private func insertBlock(_ block: String) {
        let ns = textView.string as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        perform(EditorLogic.blockInsertion(text: ns, caret: caret, block: block))
    }

    /// Apply one undoable edit and place the caret.
    private func perform(_ edit: EditorLogic.Edit) {
        closeSlashMenu()
        textView.breakUndoCoalescing()
        if textView.replace(edit.range, with: edit.replacement, select: NSRange(location: edit.caret, length: 0)) {
            textView.breakUndoCoalescing()
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    // MARK: - Slash menu

    /// Called by the text view after a `/` was typed.
    func slashTyped() {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location >= 1, ns.character(at: sel.location - 1) == 0x2F,
              let window = textView.window else { return }
        let slash = sel.location - 1
        let lineStart = ns.lineRange(for: NSRange(location: slash, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: slash - lineStart))
        guard before.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let l = styler.lines.last(where: { $0.range.location <= slash }), l.type == .code || l.type == .codeFence { return }
        let rect = textView.firstRect(forCharacterRange: NSRange(location: slash, length: 1), actualRange: nil)
        slashMenu.slashLocation = slash
        slashMenu.open(at: rect, in: window)
    }

    /// Re-filter the menu, or close it if the caret left the `/query`.
    private func updateSlashMenu() {
        guard slashMenu.isOpen else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let loc = slashMenu.slashLocation
        guard sel.length == 0, loc < ns.length, ns.character(at: loc) == 0x2F, sel.location > loc else {
            closeSlashMenu(); return
        }
        let query = ns.substring(with: NSRange(location: loc + 1, length: sel.location - loc - 1))
        if query.rangeOfCharacter(from: .newlines) != nil || !slashMenu.filter(query) { closeSlashMenu() }
    }

    func closeSlashMenu() { slashMenu.close() }

    private func pickSlashItem(_ item: SlashMenu.Item) {
        let ns = textView.string as NSString
        let loc = slashMenu.slashLocation
        let caret = textView.selectedRange().location
        if loc < ns.length, ns.character(at: loc) == 0x2F, caret > loc {
            // Remove the "/query" and any whitespace before it on the line.
            let lineStart = ns.lineRange(for: NSRange(location: loc, length: 0)).location
            textView.breakUndoCoalescing()
            textView.replace(NSRange(location: lineStart, length: caret - lineStart), with: "",
                             select: NSRange(location: lineStart, length: 0))
        }
        switch item {
        case .block(let kind): apply(kind)
        case .action(let action): onAction?(action)
        }
    }
}

extension EditorController: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        lastNotifiedText = textView.string
        onChange?(textView.string)
        updateSlashMenu()
        textView.invalidateDecorations()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        updateSlashMenu()
        fixTypingAttributes()
    }

    /// Block markers whose syntax is hidden (#, -, - [ ], >). The caret never rests inside one,
    /// so typing can't split the syntax. Returns (marker start, content start) for the caret's line.
    private func hiddenMarker(at loc: Int) -> (start: Int, end: Int)? {
        let ns = textView.string as NSString
        let line = EditorLogic.contentRange(in: ns, at: loc)
        let inf = EditorLogic.info(ns.substring(with: line))
        switch inf.type {
        case .heading, .bullet, .todo, .quote: break
        default: return nil
        }
        guard inf.prefixLength > inf.indent else { return nil }
        if let l = styler.lines.last(where: { $0.range.location <= line.location }), l.type == .code { return nil }
        return (line.location + inf.indent, line.location + inf.prefixLength)
    }

    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges old: [NSValue],
                         toCharacterRanges new: [NSValue]) -> [NSValue] {
        guard new.count == 1, let r = new.first?.rangeValue, r.length == 0,
              let m = hiddenMarker(at: r.location), r.location >= m.start, r.location < m.end else { return new }
        let from = old.first?.rangeValue.location ?? r.location
        // Arrowing left off the start of the content goes to the end of the previous line;
        // anything else (click, Home, arrowing in from the right/above) lands after the marker.
        if from == m.end, r.location == m.end - 1 {
            let lineStart = EditorLogic.contentRange(in: textView.string as NSString, at: r.location).location
            if lineStart > 0 { return [NSValue(range: NSRange(location: lineStart - 1, length: 0))] }
        }
        return [NSValue(range: NSRange(location: m.end, length: 0))]
    }

    /// After hidden syntax the "previous character" is a 1 pt transparent glyph; type (and draw the
    /// caret) in the line's real style instead.
    private func fixTypingAttributes() {
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location > 0, let ts = textView.textStorage, sel.location <= ts.length else { return }
        guard let f = ts.attribute(.font, at: sel.location - 1, effectiveRange: nil) as? NSFont,
              f.pointSize <= MarkdownStyler.hiddenFont.pointSize else { return }
        var attrs = ts.attributes(at: sel.location - 1, effectiveRange: nil)
        let ns = ts.string as NSString
        let line = EditorLogic.contentRange(in: ns, at: sel.location)
        // Borrow the font/colour of real text on this line: the next visible char, or the line's newline.
        var probe: Int? = nil
        var i = sel.location
        while i < NSMaxRange(line) {
            if let pf = ts.attribute(.font, at: i, effectiveRange: nil) as? NSFont, pf.pointSize > MarkdownStyler.hiddenFont.pointSize { probe = i; break }
            i += 1
        }
        if probe == nil, NSMaxRange(line) < ts.length { probe = NSMaxRange(line) }
        if let p = probe {
            let real = ts.attributes(at: p, effectiveRange: nil)
            attrs[.font] = real[.font]; attrs[.foregroundColor] = real[.foregroundColor]
        } else {
            attrs[.font] = MarkdownStyler.bodyFont; attrs[.foregroundColor] = MarkdownStyler.bodyColor
            if let raw = attrs[.marginBlock] as? String, let role = BlockRole(rawValue: raw) {
                switch role {
                case .h1: attrs[.font] = Theme.ui(MarkdownStyler.headingSizes[0], .semibold); attrs[.foregroundColor] = Theme.text
                case .h2: attrs[.font] = Theme.ui(MarkdownStyler.headingSizes[1], .semibold); attrs[.foregroundColor] = Theme.text
                case .h3: attrs[.font] = Theme.ui(MarkdownStyler.headingSizes[2], .semibold); attrs[.foregroundColor] = Theme.text
                case .quote: attrs[.foregroundColor] = MarkdownStyler.quoteColor
                default: break
                }
            }
        }
        attrs[.kern] = nil
        textView.typingAttributes = attrs
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard slashMenu.isOpen else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): slashMenu.move(-1); return true
        case #selector(NSResponder.moveDown(_:)): slashMenu.move(1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            slashMenu.pickSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): closeSlashMenu(); return true
        default: return false
        }
    }
}

/// Media hook. Loop B's MarkdownTextView asks this first on drop and paste; Loop E implements it
/// in its own file (Editor/MediaHandler.swift) so the two loops never edit the same file.
@MainActor
public protocol MediaHandling: AnyObject {
    /// Return true if the drop was handled (files, images, URLs, dragged text → quote).
    func handleDrop(_ info: NSDraggingInfo, in editor: EditorController) -> Bool
    /// Return true if the paste was handled (image data, file URLs, a lone URL → link).
    func handlePaste(_ pasteboard: NSPasteboard, in editor: EditorController) -> Bool
    /// Pasteboard types the text view should accept for drag & drop.
    var acceptedDragTypes: [NSPasteboard.PasteboardType] { get }
}
