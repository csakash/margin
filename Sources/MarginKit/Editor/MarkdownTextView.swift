import AppKit
import MarginCore

/// Subclass hook for key handling, drag & drop, click-on-checkbox and the custom block drawing
/// (checkboxes, quote bars, code backgrounds, dividers, images, link cards).
public final class MarkdownTextView: NSTextView {
    /// Set by integration; consulted before the default drop/paste behaviour.
    public weak var mediaHandler: MediaHandling? {
        didSet { updateDragTypeRegistration() }
    }
    public weak var editorController: EditorController?

    /// Owned by the EditorController.
    weak var styler: MarkdownStyler?

    static let placeholder = "Start typing, or press / for blocks"

    // MARK: - Editing helpers

    /// Undoable replacement (shouldChangeText / replaceCharacters / didChangeText).
    @discardableResult
    func replace(_ range: NSRange, with string: String, select: NSRange?) -> Bool {
        guard let ts = textStorage, NSMaxRange(range) <= ts.length,
              shouldChangeText(in: range, replacementString: string) else { return false }
        ts.replaceCharacters(in: range, with: string)
        didChangeText()
        if let select {
            let len = ts.length
            let loc = min(max(0, select.location), len)
            setSelectedRange(NSRange(location: loc, length: min(select.length, len - loc)))
        }
        return true
    }

    private func isCode(at location: Int) -> Bool {
        let lines = Markdown.lines(in: string)
        guard let l = lines.last(where: { $0.range.location <= location }) else { return false }
        return l.type == .code || l.type == .codeFence
    }

    // MARK: - Enter, Backspace, Tab

    public override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, !isCode(at: sel.location) else { super.insertNewline(sender); return }
        let ns = string as NSString
        let cr = EditorLogic.contentRange(in: ns, at: sel.location)
        switch EditorLogic.newline(line: ns.substring(with: cr), caret: sel.location - cr.location) {
        case .plain:
            super.insertNewline(sender)
        case .insert(let s):
            insertText(s, replacementRange: sel)
        case .removePrefix(let n):
            breakUndoCoalescing()
            replace(NSRange(location: cr.location, length: n), with: "", select: NSRange(location: cr.location, length: 0))
        }
    }

    public override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0, !isCode(at: sel.location) {
            let ns = string as NSString
            let cr = EditorLogic.contentRange(in: ns, at: sel.location)
            if let n = EditorLogic.backspacePrefix(line: ns.substring(with: cr), caret: sel.location - cr.location) {
                breakUndoCoalescing()
                replace(NSRange(location: cr.location, length: n), with: "", select: NSRange(location: cr.location, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
    }

    public override func insertTab(_ sender: Any?) {
        if shiftListLines(outdent: false) { return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if shiftListLines(outdent: true) { return }
        super.insertBacktab(sender)
    }

    /// Indent / outdent every list item in the selection by 2 spaces. False if nothing was a list item.
    private func shiftListLines(outdent: Bool) -> Bool {
        let ns = string as NSString
        let sel = selectedRange()
        guard !isCode(at: sel.location) else { return false }
        let para = ns.paragraphRange(for: sel)
        var changed = false
        var deltas: [Int] = []
        let out = ns.substring(with: para).components(separatedBy: "\n").map { line -> String in
            guard let s = EditorLogic.shifted(line, outdent: outdent) else { deltas.append(0); return line }
            changed = true
            deltas.append(s.delta)
            return s.line
        }.joined(separator: "\n")
        let firstDelta = deltas.first ?? 0
        let total = deltas.reduce(0, +)
        guard changed else { return false }
        let lineStart = para.location
        let newLoc = max(lineStart, sel.location + firstDelta)
        let newLen = max(0, sel.length + total - firstDelta)
        breakUndoCoalescing()
        replace(para, with: out, select: NSRange(location: newLoc, length: newLen))
        return true
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let s = (string as? String) ?? (string as? NSAttributedString)?.string
        if s == "/" { editorController?.slashTyped() }
    }

    public override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r { editorController?.closeSlashMenu() }
        return r
    }

    // MARK: - Mouse: checkboxes and cmd-click links

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = block(at: p) {
            if hit.role == .todo || hit.role == .todoDone,
               let box = checkboxRect(for: hit.fragment, lineStart: hit.lineStart),
               box.insetBy(dx: -4, dy: -4).contains(p) {
                toggleTodo(lineStart: hit.lineStart)
                return
            }
            if event.modifierFlags.contains(.command), let url = linkURL(at: p, hit: hit) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func toggleTodo(lineStart: Int) {
        let ns = string as NSString
        let cr = EditorLogic.contentRange(in: ns, at: lineStart)
        guard let t = EditorLogic.toggledTodo(ns.substring(with: cr)) else { return }
        let keep = selectedRanges
        breakUndoCoalescing()
        if replace(NSRange(location: cr.location + t.range.location, length: t.range.length), with: t.replacement, select: nil) {
            selectedRanges = keep
        }
        breakUndoCoalescing()
    }

    private func linkURL(at p: NSPoint, hit: BlockHit) -> URL? {
        let ns = string as NSString
        let cr = EditorLogic.contentRange(in: ns, at: hit.lineStart)
        let line = ns.substring(with: cr)
        if hit.role == .link, case .link(let u, _) = Markdown.classify(line).0 { return URL(string: u) }
        let idx = characterIndexForInsertion(at: p)
        for m in MarkdownStyler.inlineLinkRE.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            let r = NSRange(location: cr.location + m.range.location, length: m.range.length)
            if idx >= r.location, idx <= NSMaxRange(r) {
                return URL(string: (line as NSString).substring(with: m.range(at: 2)))
            }
        }
        return nil
    }

    // MARK: - Paste and drag & drop

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    public override func paste(_ sender: Any?) {
        if let h = mediaHandler, let c = editorController, h.handlePaste(.general, in: c) { return }
        insertPlainText(from: .general)
    }

    /// Paste stays available for images, files and links too (the media handler takes those),
    /// not only for the plain text NSTextView itself would accept.
    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) { return isEditable }
        return super.validateUserInterfaceItem(item)
    }

    /// Paste and Match Style is the same thing here: notes are plain markdown.
    public override func pasteAsPlainText(_ sender: Any?) { insertPlainText(from: .general) }

    /// Inserts the pasteboard's text at the selection. NSTextView's own plain-text paste routes back
    /// through `paste(_:)` for a plain-text view, so the override above never reached the text and
    /// nothing was pasted. Going through `insertText` keeps it undoable and saved like typing.
    private func insertPlainText(from pb: NSPasteboard) {
        guard isEditable, let s = pb.string(forType: .string), !s.isEmpty else { NSSound.beep(); return }
        let text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        breakUndoCoalescing()
        // NSNotFound: let NSTextView replace the selection (or a pending IME composition) itself.
        // super: a pasted "/" is not typing, so it must not open the block menu.
        super.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        breakUndoCoalescing()
    }

    public override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        for t in mediaHandler?.acceptedDragTypes ?? [] where !types.contains(t) { types.append(t) }
        return types
    }

    private func handlerAccepts(_ info: NSDraggingInfo) -> Bool {
        guard let types = mediaHandler?.acceptedDragTypes, !types.isEmpty else { return false }
        return info.draggingPasteboard.availableType(from: types) != nil
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingEntered(sender)
        return op.isEmpty && handlerAccepts(sender) ? .copy : op
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        return op.isEmpty && handlerAccepts(sender) ? .copy : op
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let h = mediaHandler, let c = editorController, h.handleDrop(sender, in: c) { return true }
        return super.performDragOperation(sender)
    }

    // MARK: - Geometry

    struct BlockHit {
        let fragment: NSTextLayoutFragment
        let role: BlockRole
        let lineStart: Int
    }

    /// The paragraph (layout fragment) under a point in view coordinates, with its role.
    func block(at p: NSPoint) -> BlockHit? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager, let ts = textStorage else { return nil }
        let o = textContainerOrigin
        guard let frag = tlm.textLayoutFragment(for: CGPoint(x: p.x - o.x, y: p.y - o.y)) else { return nil }
        let offset = tcm.offset(from: tcm.documentRange.location, to: frag.rangeInElement.location)
        guard offset >= 0, offset < ts.length,
              let raw = ts.attribute(.marginBlock, at: offset, effectiveRange: nil) as? String,
              let role = BlockRole(rawValue: raw) else { return nil }
        return BlockHit(fragment: frag, role: role, lineStart: offset)
    }

    private struct FragmentGeometry {
        var frame: CGRect       // view coordinates
        var textTop: CGFloat
        var textBottom: CGFloat
        var x0: CGFloat         // left edge of the text column
        var width: CGFloat      // text column width
    }

    private func geometry(_ frag: NSTextLayoutFragment) -> FragmentGeometry {
        let o = textContainerOrigin
        let f = frag.layoutFragmentFrame.offsetBy(dx: o.x, dy: o.y)
        let lines = frag.textLineFragments
        let top = f.minY + (lines.first?.typographicBounds.minY ?? 0)
        let bottom = f.minY + (lines.last?.typographicBounds.maxY ?? f.height)
        let pad = textContainer?.lineFragmentPadding ?? 5
        return FragmentGeometry(frame: f, textTop: top, textBottom: bottom, x0: o.x + pad,
                                width: styler?.contentWidth ?? (bounds.width - 2 * o.x - 2 * pad))
    }

    func checkboxRect(for frag: NSTextLayoutFragment, lineStart: Int) -> NSRect? {
        let g = geometry(frag)
        let ns = string as NSString
        let cr = EditorLogic.contentRange(in: ns, at: lineStart)
        let inf = EditorLogic.info(ns.substring(with: cr))
        let indentW = inf.indent > 0
            ? MarkdownStyler.width(ns.substring(with: NSRange(location: cr.location, length: inf.indent))) : 0
        let font = MarkdownStyler.bodyFont
        let centerY = g.textTop + font.ascender - font.capHeight / 2
        return NSRect(x: g.x0 + indentW, y: round(centerY - 8), width: 16, height: 16)
    }

    // MARK: - Drawing

    /// TextKit 2 repositions layout fragments during the viewport layout pass, which runs in `layout()`.
    /// The decorations are drawn from fragment frames, so redraw after every pass.
    public override func layout() {
        super.layout()
        needsDisplay = true
    }

    /// Redraw decorations once the pending viewport layout has run (after edits and scrolling).
    func invalidateDecorations() {
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
    }

    public override func draw(_ dirtyRect: NSRect) {
        drawDecorations(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawDecorations(in dirty: NSRect) {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager, let ts = textStorage else { return }
        let o = textContainerOrigin
        if ts.length == 0 {
            let pad = textContainer?.lineFragmentPadding ?? 5
            (Self.placeholder as NSString).draw(at: NSPoint(x: o.x + pad, y: o.y),
                                                withAttributes: [.font: MarkdownStyler.bodyFont, .foregroundColor: Theme.textTertiary])
            return
        }
        // Draw only what the viewport layout pass positioned (the same fragments the text is rendered
        // from). Forcing layout elsewhere would move fragments the rendered text never sees.
        guard let viewport = tlm.textViewportLayoutController.viewportRange else { return }
        let docStart = tcm.documentRange.location
        let length = ts.length
        let reach = MarkdownStyler.imageMaxHeight + 80   // images and cards extend below their text
        tlm.enumerateTextLayoutFragments(from: viewport.location, options: []) { frag in
            if frag.rangeInElement.location.compare(viewport.endLocation) != .orderedAscending { return false }
            let g = self.geometry(frag)
            if g.frame.minY > dirty.maxY { return false }
            if g.frame.maxY + reach < dirty.minY { return true }
            let offset = tcm.offset(from: docStart, to: frag.rangeInElement.location)
            guard offset >= 0, offset < length,
                  let raw = ts.attribute(.marginBlock, at: offset, effectiveRange: nil) as? String,
                  let role = BlockRole(rawValue: raw) else { return true }
            self.drawBlock(role, frag, g, lineStart: offset)
            return true
        }
    }

    private static let glow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor(white: 1, alpha: 0.55)
        s.shadowBlurRadius = 8
        s.shadowOffset = .zero
        return s
    }()

    private func drawBlock(_ role: BlockRole, _ frag: NSTextLayoutFragment, _ g: FragmentGeometry, lineStart: Int) {
        switch role {
        case .todo, .todoDone:
            guard let r = checkboxRect(for: frag, lineStart: lineStart) else { return }
            drawCheckbox(r, done: role == .todoDone)
        case .bullet:
            // Only the first fragment of the paragraph gets the dot.
            let ns = string as NSString
            let cr = EditorLogic.contentRange(in: ns, at: lineStart)
            guard cr.location == lineStart else { return }
            let inf = EditorLogic.info(ns.substring(with: cr))
            let indentW = inf.indent > 0
                ? MarkdownStyler.width(ns.substring(with: NSRange(location: cr.location, length: inf.indent))) : 0
            let font = MarkdownStyler.bodyFont
            let cy = g.textTop + font.ascender - font.xHeight / 2
            let d: CGFloat = inf.indent >= 2 ? 4.5 : 5   // nested items get a slightly smaller dot
            let dot = NSRect(x: g.x0 + indentW + 6, y: round(cy - d / 2), width: d, height: d)
            (inf.indent >= 2 ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 1, alpha: 0.7)).setFill()
            if inf.indent >= 2 {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6)); ring.lineWidth = 1.2
                NSColor(white: 1, alpha: 0.6).setStroke(); ring.stroke()
            } else {
                NSBezierPath(ovalIn: dot).fill()
            }
        case .quote:
            let bar = NSRect(x: g.x0, y: g.textTop + 1, width: 2, height: max(4, g.textBottom - g.textTop - 2))
            NSGraphicsContext.saveGraphicsState()
            Self.glow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .codeTop, .codeMid, .codeBottom, .codeSingle:
            drawCodeSlice(role, g)
        case .divider:
            let font = MarkdownStyler.bodyFont
            let y = round(g.textTop + (font.ascender - font.descender) / 2) + 0.5
            NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.2), NSColor(white: 1, alpha: 0)])?
                .draw(in: NSRect(x: g.x0, y: y - 0.5, width: g.width, height: 1), angle: 0)
        case .image:
            drawImage(g, lineStart: lineStart)
        case .link:
            drawLinkCard(g, lineStart: lineStart)
        default:
            break
        }
    }

    private func drawCheckbox(_ r: NSRect, done: Bool) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        if done {
            NSGraphicsContext.saveGraphicsState()
            Self.glow.set()
            NSColor.white.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: r.minX + 4.5, y: r.midY + 0.2))
            check.line(to: NSPoint(x: r.minX + 7, y: r.midY + 2.7))
            check.line(to: NSPoint(x: r.maxX - 4, y: r.midY - 2.8))
            check.lineWidth = 2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.black.setStroke()
            check.stroke()
        } else {
            path.lineWidth = 1.5
            NSColor(white: 0x55 / 255, alpha: 1).setStroke()
            path.stroke()
        }
    }

    private func drawCodeSlice(_ role: BlockRole, _ g: FragmentGeometry) {
        let radius: CGFloat = 12
        let hasTop = role == .codeTop || role == .codeSingle
        let hasBottom = role == .codeBottom || role == .codeSingle
        let top = hasTop ? g.textTop - 7 : g.frame.minY
        let bottom = hasBottom ? g.textBottom + 4 : g.frame.maxY
        guard bottom > top else { return }
        let slice = NSRect(x: g.x0, y: top, width: g.width, height: bottom - top)
        // A rounded rect that extends past the slice on the open sides, clipped to the slice, so
        // consecutive slices join into one block whatever part of it is being redrawn.
        let virt = NSRect(x: slice.minX, y: hasTop ? top : top - 2 * radius,
                          width: slice.width, height: (hasBottom ? bottom : bottom + 2 * radius) - (hasTop ? top : top - 2 * radius))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: slice).addClip()
        NSColor(white: 0, alpha: 0.45).setFill()
        NSBezierPath(roundedRect: virt, xRadius: radius, yRadius: radius).fill()
        let stroke = NSBezierPath(roundedRect: virt.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        stroke.lineWidth = 1
        Theme.hairline.setStroke()
        stroke.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func lineText(at lineStart: Int) -> String {
        let ns = string as NSString
        return ns.substring(with: EditorLogic.contentRange(in: ns, at: lineStart))
    }

    private func drawImage(_ g: FragmentGeometry, lineStart: Int) {
        guard let styler else { return }
        let line = lineText(at: lineStart)
        guard case .image(let path) = Markdown.classify(line).0 else { return }
        let h = styler.mediaHeight(path: path)
        let rect = NSRect(x: g.x0, y: g.textTop + MarkdownStyler.imageTopGap, width: g.width, height: h)
        let clip = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        let url = styler.resolve(path)
        let available = url.map { styler.media.exists($0) } ?? false

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor.black.setFill()
        rect.fill()
        if available, let url, let img = styler.media.image(for: url, maxPixel: g.width * 2) {
            // Aspect-fill (object-fit: cover).
            let s = img.size
            let scale = max(rect.width / max(1, s.width), rect.height / max(1, s.height))
            let w = s.width * scale, hh = s.height * scale
            img.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - hh / 2, width: w, height: hh),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            NSColor(white: 1, alpha: 0.04).setFill()
            rect.fill()
            let label = available ? "Loading…" : "Missing: \(path)"
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(10.5), .foregroundColor: Theme.textTertiary]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: rect.minX + 12, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
        if let url, MediaCache.isVideo(url) {
            let c = NSRect(x: rect.midX - 20, y: rect.midY - 20, width: 40, height: 40)
            NSColor(white: 0, alpha: 0.55).setFill()
            NSBezierPath(ovalIn: c).fill()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: c.midX - 5, y: c.midY - 8))
            tri.line(to: NSPoint(x: c.midX + 9, y: c.midY))
            tri.line(to: NSPoint(x: c.midX - 5, y: c.midY + 8))
            tri.close()
            NSColor.white.setFill()
            tri.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 13.5, yRadius: 13.5)
        outline.lineWidth = 1
        NSColor(white: 1, alpha: 0.10).setStroke()
        outline.stroke()

        let alt = MarkdownStyler.imageAlt(line)
        if !alt.isEmpty {
            (alt as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.maxY + 5),
                                   withAttributes: [.font: Theme.mono(10.5), .foregroundColor: Theme.textTertiary])
        }
    }

    private func drawLinkCard(_ g: FragmentGeometry, lineStart: Int) {
        let line = lineText(at: lineStart)
        guard case .link(let urlString, _) = Markdown.classify(line).0 else { return }
        let pad = MarkdownStyler.linkCardPad
        let card = NSRect(x: g.x0, y: g.textTop - pad, width: g.width,
                          height: g.textBottom - g.textTop + 2 + MarkdownStyler.linkDomainHeight + 2 * pad)
        let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        NSColor(white: 1, alpha: 0.035).setFill()
        path.fill()
        let stroke = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 13.5, yRadius: 13.5)
        stroke.lineWidth = 1
        NSColor(white: 1, alpha: 0.06).setStroke()
        stroke.stroke()

        var host = URL(string: urlString)?.host ?? urlString
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }

        // Favicon tile with the domain's initial.
        let fav = NSRect(x: card.minX + 12, y: round(card.midY - 14), width: 28, height: 28)
        NSGraphicsContext.saveGraphicsState()
        let favShadow = NSShadow()
        favShadow.shadowColor = NSColor(white: 1, alpha: 0.18)
        favShadow.shadowBlurRadius = 12
        favShadow.set()
        let favPath = NSBezierPath(roundedRect: fav, xRadius: 8, yRadius: 8)
        NSColor.white.setFill()
        favPath.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        favPath.addClip()
        NSGradient(starting: .white, ending: NSColor(srgbRed: 0xBD / 255, green: 0xBD / 255, blue: 0xC1 / 255, alpha: 1))?
            .draw(in: fav, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        let initial = String(host.first.map { String($0).uppercased() } ?? "↗") as NSString
        let ia: [NSAttributedString.Key: Any] = [.font: Theme.ui(12, .semibold), .foregroundColor: NSColor.black]
        let isz = initial.size(withAttributes: ia)
        initial.draw(at: NSPoint(x: fav.midX - isz.width / 2, y: fav.midY - isz.height / 2), withAttributes: ia)

        (host as NSString).draw(at: NSPoint(x: g.x0 + MarkdownStyler.linkInset, y: g.textBottom + 1),
                                withAttributes: [.font: Theme.mono(10.5), .foregroundColor: Theme.textTertiary])
    }
}
