import AppKit
import UniformTypeIdentifiers

/// Drop and paste of media into the editor (Loop E):
/// files → assets (images and videos drawn inline, other files as 📎 links),
/// raw image data → PNG asset, a web URL → link card (title upgraded from the page),
/// text dragged from another app → quote with its source.
@MainActor
public final class MediaHandler: NSObject, MediaHandling {

    public override init() { super.init() }

    private static let urlType = NSPasteboard.PasteboardType("public.url")
    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    private static let urlsWithTitlesType = NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")

    /// Browsers BrowserClip can read the front tab from; only asked for a quote's source when one is in front.
    private static let browserIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.Chromium",
        "com.vivaldi.Vivaldi", "com.apple.Safari",
    ]

    public var acceptedDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, Self.urlType, .png, .tiff, Self.jpegType, .string]
    }

    // MARK: - MediaHandling

    public func handleDrop(_ info: NSDraggingInfo, in editor: EditorController) -> Bool {
        let tv = editor.textView
        // Moving text inside the note: let NSTextView do it.
        if let source = info.draggingSource as? NSTextView, source === tv { return false }
        let pb = info.draggingPasteboard

        // Caret at the drop point.
        let point = tv.convert(info.draggingLocation, from: nil)
        let index = tv.characterIndexForInsertion(at: point)
        let length = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(max(0, index), length), length: 0))

        if insertFiles(from: pb, in: editor) { return true }
        if insertImageData(from: pb, caption: nil, in: editor) { return true }

        let webURL = Self.webURL(on: pb)
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = Self.title(on: pb)
        if !text.isEmpty, Self.webURL(from: text) == nil, text != title {
            insertQuote(text, source: webURL, from: info, in: editor)
            return true
        }
        if let url = webURL ?? Self.webURL(from: text) {
            insertLinkCard(url, title: title, in: editor)
            return true
        }
        return false
    }

    public func handlePaste(_ pasteboard: NSPasteboard, in editor: EditorController) -> Bool {
        if insertFiles(from: pasteboard, in: editor) { return true }
        if insertImageData(from: pasteboard, caption: "Screenshot", in: editor) { return true }
        if let text = pasteboard.string(forType: .string), let url = Self.webURL(from: text) {
            insertLinkCard(url, title: nil, in: editor)
            return true
        }
        return false
    }

    // MARK: - Files

    /// Imports every file URL on the pasteboard. Returns true if the pasteboard carried files.
    private func insertFiles(from pb: NSPasteboard, in editor: EditorController) -> Bool {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        var inserted = false
        for url in urls {
            guard let rel = editor.importFile?(url) else { continue }
            if Self.isVisualMedia(url) {
                editor.insertImage(relativePath: rel, caption: url.lastPathComponent)
            } else if let link = URL(string: rel) {
                editor.insertLink(url: link, title: Self.attachmentTitle(for: url))
            } else { continue }
            inserted = true
        }
        return inserted
    }

    /// Images and the videos the editor can draw inline.
    private static func isVisualMedia(_ url: URL) -> Bool {
        if MediaCache.isVideo(url) { return true }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// "📎 report.pdf · 1.2 MB"
    private static func attachmentTitle(for url: URL) -> String {
        var title = "📎 " + url.lastPathComponent
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            title += " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return title
    }

    // MARK: - Image data

    /// PNG / TIFF / JPEG bytes with no file behind them (a browser image, a screenshot on the clipboard).
    private func insertImageData(from pb: NSPasteboard, caption: String?, in editor: EditorController) -> Bool {
        guard let importData = editor.importData else { return false }
        var payload: (Data, String)?
        if let png = pb.data(forType: .png) {
            payload = (png, "png")
        } else if let tiff = pb.data(forType: .tiff),
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            payload = (png, "png")
        } else if let jpeg = pb.data(forType: Self.jpegType) {
            payload = (jpeg, "jpg")
        }
        guard let (data, ext) = payload, let rel = importData(data, ext) else { return false }
        editor.insertImage(relativePath: rel, caption: caption)
        return true
    }

    // MARK: - Link cards

    /// Inserts `[title](url)` now (the host while no title is known), then upgrades it to the page title.
    private func insertLinkCard(_ url: URL, title: String?, in editor: EditorController) {
        let host = Self.displayHost(url)
        let firstTitle = title ?? host
        let hint = editor.textView.selectedRange().location
        editor.insertLink(url: url, title: firstTitle)
        guard title == nil else { return }
        let placed = EditorLogic.linkMarkdown(url: url, title: firstTitle)
        LinkMetadata.title(for: url) { [weak editor] better in
            guard let editor, let better, better != firstTitle else { return }
            Self.replaceBlock(placed, with: EditorLogic.linkMarkdown(url: url, title: better), near: hint, in: editor.textView)
        }
    }

    // MARK: - Quotes

    private func insertQuote(_ text: String, source: URL?, from info: NSDraggingInfo, in editor: EditorController) {
        let hint = editor.textView.selectedRange().location
        editor.insertQuote(text, source: source)
        guard source == nil, info.draggingSource == nil,   // from another app
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              Self.browserIDs.contains(front) else { return }
        // The browser the text came from is still in front: ask it for the page, briefly.
        let placed = EditorLogic.quoteMarkdown(text, source: nil)
        let deadline = Date().addingTimeInterval(1.5)
        BrowserClip.frontTab { [weak editor] tab in
            guard let editor, let tab, Date() < deadline,
                  let scheme = tab.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            Self.replaceBlock(placed, with: EditorLogic.quoteMarkdown(text, source: tab.url), near: hint, in: editor.textView)
        }
    }

    // MARK: - Deferred edits

    /// Replaces the block we inserted earlier (found as whole lines, the copy nearest `hint`) with one undoable edit.
    /// Does nothing if the user already changed or removed it.
    private static func replaceBlock(_ old: String, with new: String, near hint: Int, in tv: MarkdownTextView) {
        guard old != new, !tv.hasMarkedText() else { return }
        let ns = tv.string as NSString
        guard let r = blockRange(of: old, near: hint, in: ns) else { return }
        let newLength = (new as NSString).length
        let sel = tv.selectedRange()
        var select = sel
        if sel.location >= NSMaxRange(r) {
            select.location += newLength - r.length
        } else if NSMaxRange(sel) > r.location {
            select = NSRange(location: r.location + newLength, length: 0)
        }
        // This runs from a callback, not a user event, so no event undo group closes after it:
        // give the edit its own top-level group so it never merges with the user's next keystrokes.
        let um = tv.undoManager
        let ownGroup = um.map { $0.groupingLevel == 0 } ?? false
        let byEvent = um?.groupsByEvent ?? true
        if ownGroup { um?.groupsByEvent = false; um?.beginUndoGrouping() }
        tv.breakUndoCoalescing()
        tv.replace(r, with: new, select: select)
        tv.breakUndoCoalescing()
        if ownGroup { um?.endUndoGrouping(); um?.groupsByEvent = byEvent }
    }

    /// Range of `block` where it fills whole lines, picking the occurrence closest to `hint`.
    private static func blockRange(of block: String, near hint: Int, in ns: NSString) -> NSRange? {
        var best: NSRange?
        var from = 0
        while from < ns.length {
            let r = ns.range(of: block, options: .literal, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            let end = NSMaxRange(r)
            let startsLine = r.location == 0 || ns.character(at: r.location - 1) == 0x0A
            let endsLine = end == ns.length || ns.character(at: end) == 0x0A
            if startsLine, endsLine, best.map({ abs(r.location - hint) < abs($0.location - hint) }) ?? true { best = r }
            from = r.location + 1
        }
        return best
    }

    // MARK: - Pasteboard helpers

    /// A lone http(s) URL: trimmed, no whitespace inside.
    static func webURL(from string: String) -> URL? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: s), isWeb(url) else { return nil }
        return url
    }

    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    private static func webURL(on pb: NSPasteboard) -> URL? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: isWeb) { return url }
        for type in [urlType, NSPasteboard.PasteboardType.URL] {
            if let s = pb.string(forType: type), let url = webURL(from: s) { return url }
        }
        return nil
    }

    /// The link's title if the source put one on the pasteboard (browsers do for dragged links).
    private static func title(on pb: NSPasteboard) -> String? {
        var title = pb.string(forType: urlNameType)
        if title == nil, let list = pb.propertyList(forType: urlsWithTitlesType) as? [[String]],
           list.count > 1, let first = list[1].first {
            title = first
        }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty || webURL(from: t) != nil ? nil : t
    }

    /// "apple.com" for https://www.apple.com/mac
    private static func displayHost(_ url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
