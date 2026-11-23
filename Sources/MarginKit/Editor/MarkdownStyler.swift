import AppKit
import MarginCore

extension NSAttributedString.Key {
    /// The block role of a line (a `BlockRole` raw value). Read by MarkdownTextView's custom drawing.
    static let marginBlock = NSAttributedString.Key("MarginBlock")
}

/// What a line looks like, stored on its characters so drawing never has to re-parse fences.
enum BlockRole: String {
    case paragraph, h1, h2, h3, bullet, numbered, todo, todoDone, quote
    /// Code fence group slices: first line, middle, last, or a fence line on its own.
    case codeTop, codeMid, codeBottom, codeSingle
    case divider, image, link
}

/// Live markdown styling. Attributes only: the string is never rewritten here.
@MainActor
final class MarkdownStyler: NSObject, NSTextStorageDelegate {

    // MARK: Tokens

    static let bodyFont = Theme.ui(14.5)
    static let bodyColor = NSColor(srgbRed: 0xD9 / 255, green: 0xD9 / 255, blue: 0xDC / 255, alpha: 1)
    static let quoteColor = NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xEE / 255, alpha: 1)
    static let codeColor = NSColor(srgbRed: 0xCF / 255, green: 0xCF / 255, blue: 0xD3 / 255, alpha: 1)
    static let codeFont = Theme.mono(12.5)
    /// Hidden syntax is set in a near-zero font so it takes no visible width (a long URL included).
    static let hiddenFont = Theme.ui(0.01)
    static let markerColor = Theme.textTertiary
    /// Markdown syntax is never shown (Notion-style rendering): zero-ish width, transparent.
    static let hidden: [NSAttributedString.Key: Any] = [.font: hiddenFont, .foregroundColor: NSColor.clear, .kern: 0]
    static let bulletGutter: CGFloat = 20
    static let bodyLineSpacing: CGFloat = 5.5          // ≈ line-height 1.6 at 14.5 pt
    static let todoGutter: CGFloat = 26                // 16 pt box + 10 pt gap
    static let quoteGutter: CGFloat = 14
    static let linkInset: CGFloat = 50                 // 12 pad + 28 favicon + 10 gap
    static let linkCardPad: CGFloat = 9
    static let linkDomainHeight: CGFloat = 14
    static let imageMaxHeight: CGFloat = 300
    static let imageTopGap: CGFloat = 2

    static let headingSizes: [CGFloat] = [24, 18, 15]
    static let headingBefore: [CGFloat] = [6, 14, 8]
    static let headingAfter: [CGFloat] = [8, 4, 2]

    static var baseParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = bodyLineSpacing
        p.paragraphSpacing = 4
        return p
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: baseParagraph]
    }

    static func width(_ s: String, _ font: NSFont? = nil) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font ?? bodyFont]).width)
    }

    // MARK: State

    weak var textView: MarkdownTextView?
    let media = MediaCache()
    /// The classified lines of the current text (refreshed on every character edit).
    private(set) var lines: [Markdown.Line] = []
    private var fenceCount = -1
    private var lastWidth: CGFloat = 0

    init(textView: MarkdownTextView) {
        self.textView = textView
        super.init()
        media.onImageLoaded = { [weak self] in self?.textView?.invalidateDecorations() }
        media.onAspectChanged = { [weak self] in self?.restyleMedia() }
    }

    /// Width available to text (and images) inside the container.
    var contentWidth: CGFloat {
        guard let tv = textView, let tc = tv.textContainer else { return 380 }
        let w = tc.size.width - 2 * tc.lineFragmentPadding
        return w > 60 && w < 10_000 ? w : 380
    }

    // MARK: NSTextStorageDelegate

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { self.restyle(textStorage, edited: editedRange) }
    }

    /// Restyle the lines touched by an edit (plus one neighbour each side), or everything if the
    /// fence structure changed.
    func restyle(_ ts: NSTextStorage, edited: NSRange) {
        let text = ts.string
        lines = Markdown.lines(in: text)
        let fences = lines.reduce(0) { $0 + ($1.type == .codeFence ? 1 : 0) }
        let all = fences != fenceCount || edited.length >= ts.length
        fenceCount = fences
        guard !lines.isEmpty else { return }
        let roles = Self.roles(for: lines, text: text as NSString)
        var lo = 0, hi = lines.count - 1
        if !all {
            let editEnd = NSMaxRange(edited)
            lo = lines.firstIndex { NSMaxRange($0.range) >= edited.location } ?? 0
            hi = lines.lastIndex { $0.range.location <= editEnd } ?? lines.count - 1
            lo = max(0, lo - 1); hi = min(lines.count - 1, max(hi, lo) + 1)
        }
        let ns = text as NSString
        for i in lo...hi { style(i, role: roles[i], in: ts, ns: ns, text: text) }
    }

    /// Recompute image paragraph heights (container width changed or a video's size became known).
    func restyleMedia() {
        guard let ts = textView?.textStorage, !lines.isEmpty else { return }
        lastWidth = contentWidth
        let ns = ts.string as NSString
        guard (lines.last.map { NSMaxRange($0.range) } ?? 0) <= ns.length else { return }
        ts.beginEditing()
        for l in lines {
            guard case .image(let path) = l.type, l.range.length > 0 else { continue }
            let alt = Self.imageAlt(ns.substring(with: l.range))
            ts.addAttribute(.paragraphStyle, value: imageParagraph(path: path, alt: alt), range: l.range)
        }
        ts.endEditing()
        textView?.invalidateDecorations()
    }

    func containerWidthMayHaveChanged() {
        if abs(contentWidth - lastWidth) > 0.5 { restyleMedia() }
    }

    // MARK: Roles

    static func roles(for lines: [Markdown.Line], text ns: NSString) -> [BlockRole] {
        var out: [BlockRole] = []
        out.reserveCapacity(lines.count)
        var open = false
        for (i, l) in lines.enumerated() {
            let nextIsCode: Bool = {
                guard i + 1 < lines.count else { return false }
                let t = lines[i + 1].type
                return t == .code || t == .codeFence
            }()
            switch l.type {
            case .codeFence:
                if open { open = false; out.append(.codeBottom) }
                else { open = true; out.append(nextIsCode ? .codeTop : .codeSingle) }
            case .code:
                out.append(nextIsCode ? .codeMid : .codeBottom)
            default:
                out.append(role(for: EditorLogic.info(ns.substring(with: l.range)).type))
            }
        }
        return out
    }

    static func role(for t: Markdown.BlockType) -> BlockRole {
        switch t {
        case .heading(let n): return n == 1 ? .h1 : n == 2 ? .h2 : .h3
        case .bullet: return .bullet
        case .numbered: return .numbered
        case .todo(let done): return done ? .todoDone : .todo
        case .quote: return .quote
        case .divider: return .divider
        case .image: return .image
        case .link: return .link
        case .code, .codeFence: return .codeMid
        case .paragraph, .blank: return .paragraph
        }
    }

    static func isCode(_ r: BlockRole) -> Bool { [.codeTop, .codeMid, .codeBottom, .codeSingle].contains(r) }

    // MARK: Per-line styling

    private func style(_ i: Int, role: BlockRole, in ts: NSTextStorage, ns: NSString, text: String) {
        let line = lines[i]
        let end = i + 1 < lines.count ? lines[i + 1].range.location : ns.length
        let full = NSRange(location: line.range.location, length: end - line.range.location)
        guard full.length > 0, NSMaxRange(full) <= ts.length else { return }
        let L = line.range.location
        let s = ns.substring(with: line.range)

        var attrs = Self.baseAttributes
        attrs[.marginBlock] = role.rawValue

        if Self.isCode(role) {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.firstLineHeadIndent = 12; p.headIndent = 12; p.tailIndent = -12
            p.paragraphSpacing = (role == .codeBottom || role == .codeSingle) ? 12 : 0
            p.paragraphSpacingBefore = (role == .codeTop || role == .codeSingle) ? 12 : 0
            attrs[.font] = Self.codeFont
            // Fence lines (```lang) are padding for the rendered block; their text is not shown.
            attrs[.foregroundColor] = line.type == .codeFence ? NSColor.clear : Self.codeColor
            attrs[.paragraphStyle] = p
            ts.setAttributes(attrs, range: full)
            return
        }

        let inf = EditorLogic.info(s)
        let prefix = NSRange(location: L, length: min(inf.prefixLength, line.range.length))
        let content = NSRange(location: L + prefix.length, length: line.range.length - prefix.length)

        switch role {
        case .h1, .h2, .h3:
            let lvl = role == .h1 ? 0 : role == .h2 ? 1 : 2
            let size = Self.headingSizes[lvl]
            let p = NSMutableParagraphStyle()
            p.lineSpacing = size * 0.2
            p.paragraphSpacingBefore = Self.headingBefore[lvl]
            p.paragraphSpacing = Self.headingAfter[lvl]
            let font = Theme.ui(size, .semibold)
            p.minimumLineHeight = ceil(font.ascender - font.descender)   // an empty heading keeps its height
            attrs[.font] = font
            attrs[.foregroundColor] = Theme.text
            attrs[.paragraphStyle] = p
            if lvl == 0 { attrs[.kern] = -0.5 }
            ts.setAttributes(attrs, range: full)
            ts.addAttributes(Self.hidden, range: prefix)
            styleInline(ts, text: text, range: content)

        case .bullet:
            // "- " is hidden; a • is drawn in the gutter (MarkdownTextView.drawBlock).
            let marker = NSRange(location: L + inf.indent, length: prefix.length - inf.indent)
            let indentW = Self.width(ns.substring(with: NSRange(location: L, length: inf.indent)))
            let p = NSMutableParagraphStyle()
            p.lineSpacing = Self.bodyLineSpacing
            p.paragraphSpacing = 2
            p.firstLineHeadIndent = Self.bulletGutter
            p.headIndent = indentW + Self.bulletGutter
            p.minimumLineHeight = ceil(Self.bodyFont.ascender - Self.bodyFont.descender)
            attrs[.paragraphStyle] = p
            ts.setAttributes(attrs, range: full)
            ts.addAttributes(Self.hidden, range: marker)
            styleInline(ts, text: text, range: content)

        case .numbered:
            // The number is the rendered output (as in Notion), shown in a softer tone.
            let p = NSMutableParagraphStyle()
            p.lineSpacing = Self.bodyLineSpacing
            p.paragraphSpacing = 2
            p.headIndent = Self.width(ns.substring(with: prefix))
            attrs[.paragraphStyle] = p
            ts.setAttributes(attrs, range: full)
            ts.addAttribute(.foregroundColor, value: Theme.textSecondary,
                            range: NSRange(location: L + inf.indent, length: prefix.length - inf.indent))
            styleInline(ts, text: text, range: content)

        case .todo, .todoDone:
            let marker = NSRange(location: L + inf.indent, length: prefix.length - inf.indent)
            let indentW = Self.width(ns.substring(with: NSRange(location: L, length: inf.indent)))
            let p = NSMutableParagraphStyle()
            p.lineSpacing = Self.bodyLineSpacing
            p.paragraphSpacing = 2
            p.headIndent = indentW + Self.todoGutter
            attrs[.paragraphStyle] = p
            ts.setAttributes(attrs, range: full)
            ts.addAttribute(.foregroundColor, value: NSColor.clear, range: marker)
            if marker.length > 0 {
                let mw = Self.width(ns.substring(with: marker))
                ts.addAttribute(.kern, value: Self.todoGutter - mw,
                                range: NSRange(location: NSMaxRange(marker) - 1, length: 1))
            }
            if role == .todoDone, content.length > 0 {
                ts.addAttributes([.foregroundColor: Theme.textTertiary,
                                  .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                  .strikethroughColor: NSColor(white: 0x44 / 255, alpha: 1)], range: content)
            }
            styleInline(ts, text: text, range: content)

        case .quote:
            let p = NSMutableParagraphStyle()
            p.lineSpacing = Self.bodyLineSpacing
            p.paragraphSpacing = 2
            p.headIndent = Self.quoteGutter
            attrs[.paragraphStyle] = p
            attrs[.foregroundColor] = Self.quoteColor
            ts.setAttributes(attrs, range: full)
            ts.addAttribute(.foregroundColor, value: NSColor.clear, range: prefix)
            if prefix.length > 0 {
                let mw = Self.width(ns.substring(with: prefix))
                ts.addAttribute(.kern, value: Self.quoteGutter - mw,
                                range: NSRange(location: NSMaxRange(prefix) - 1, length: 1))
            }
            if ns.substring(with: content).hasPrefix("— ") {
                ts.addAttributes([.font: Theme.mono(10.5), .foregroundColor: Theme.textTertiary], range: content)
            }
            styleInline(ts, text: text, range: content)

        case .divider:
            let p = NSMutableParagraphStyle()
            p.lineSpacing = Self.bodyLineSpacing
            p.paragraphSpacingBefore = 6
            p.paragraphSpacing = 8
            attrs[.paragraphStyle] = p
            attrs[.foregroundColor] = NSColor.clear
            ts.setAttributes(attrs, range: full)

        case .image:
            if case .image(let path) = inf.type {
                attrs[.paragraphStyle] = imageParagraph(path: path, alt: Self.imageAlt(s))
            }
            attrs[.font] = Self.hiddenFont
            attrs[.foregroundColor] = NSColor.clear
            ts.setAttributes(attrs, range: full)

        case .link:
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2
            p.firstLineHeadIndent = Self.linkInset
            p.headIndent = Self.linkInset
            p.tailIndent = -12
            p.paragraphSpacingBefore = 8 + Self.linkCardPad
            p.paragraphSpacing = 2 + Self.linkDomainHeight + Self.linkCardPad + 8
            attrs[.paragraphStyle] = p
            attrs[.font] = Theme.ui(13, .medium)
            attrs[.foregroundColor] = NSColor.white
            ts.setAttributes(attrs, range: full)
            if let title = Self.linkTitleRange(s) {
                let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear]
                ts.addAttributes(hidden, range: NSRange(location: L, length: title.location))
                let after = NSMaxRange(title)
                ts.addAttributes(hidden, range: NSRange(location: L + after, length: line.range.length - after))
            }

        default:
            ts.setAttributes(attrs, range: full)
            styleInline(ts, text: text, range: line.range)
        }
    }

    // MARK: Images & links

    static func imageAlt(_ line: String) -> String {
        guard line.hasPrefix("!["), let close = line.range(of: "](") else { return "" }
        return String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
    }

    /// Range of the title inside "[title](url)" (line-relative), nil for a bare URL.
    static func linkTitleRange(_ line: String) -> NSRange? {
        let ns = line as NSString
        guard line.hasPrefix("[") else { return nil }
        let close = ns.range(of: "](")
        guard close.location != NSNotFound, close.location > 1 else { return nil }
        return NSRange(location: 1, length: close.location - 1)
    }

    /// Resolve an image line's path to a local file URL.
    func resolve(_ path: String) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("file:") { return URL(string: path) }
        if path.hasPrefix("http:") || path.hasPrefix("https:") { return nil }
        let decoded = path.removingPercentEncoding ?? path
        return textView?.editorController?.resolveAsset?(decoded)
    }

    /// Displayed size of an image line's media (width = content width, height capped at 300).
    func mediaHeight(path: String) -> CGFloat {
        guard let url = resolve(path), media.exists(url) else { return 64 }
        let aspect = media.aspect(for: url) ?? (MediaCache.isVideo(url) ? 9.0 / 16.0 : 0.6)
        return min(Self.imageMaxHeight, max(40, round(contentWidth * aspect)))
    }

    static let captionHeight: CGFloat = 22

    private func imageParagraph(path: String, alt: String) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        p.paragraphSpacing = mediaHeight(path: path) + Self.imageTopGap + (alt.isEmpty ? 0 : Self.captionHeight) + 10
        return p
    }

    // MARK: Inline

    private static let codeRE = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let boldRE = try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let italicStarRE = try! NSRegularExpression(pattern: #"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#)
    private static let italicUnderscoreRE = try! NSRegularExpression(pattern: #"(?<![_\w])_(?=\S)(.+?)(?<=\S)_(?![_\w])"#)
    static let inlineLinkRE = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#)

    private func styleInline(_ ts: NSTextStorage, text: String, range: NSRange) {
        guard range.length > 1 else { return }
        let dim = Self.hidden   // inline syntax (** _ ` [ ](url)) is hidden, only the result shows
        var code: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !code.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in Self.codeRE.matches(in: text, range: range) {
            let r = m.range
            code.append(r)
            ts.addAttributes([.font: Theme.mono(12.5), .backgroundColor: NSColor(white: 1, alpha: 0.07)], range: r)
            ts.addAttributes(dim, range: NSRange(location: r.location, length: 1))
            ts.addAttributes(dim, range: NSRange(location: NSMaxRange(r) - 1, length: 1))
        }
        for m in Self.inlineLinkRE.matches(in: text, range: range) where free(m.range) {
            let t = m.range(at: 1)
            ts.addAttributes(dim, range: NSRange(location: m.range.location, length: 1))
            ts.addAttributes([.foregroundColor: NSColor.white, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .underlineColor: NSColor(white: 1, alpha: 0.4)], range: t)
            ts.addAttributes(dim, range: NSRange(location: NSMaxRange(t), length: NSMaxRange(m.range) - NSMaxRange(t)))
            code.append(NSRange(location: NSMaxRange(t), length: NSMaxRange(m.range) - NSMaxRange(t)))  // no emphasis inside URLs
        }
        for m in Self.boldRE.matches(in: text, range: range) where free(m.range) {
            convertFont(ts, range: m.range(at: 1), trait: .boldFontMask)
            ts.addAttributes(dim, range: NSRange(location: m.range.location, length: 2))
            ts.addAttributes(dim, range: NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for re in [Self.italicStarRE, Self.italicUnderscoreRE] {
            for m in re.matches(in: text, range: range) where free(m.range) {
                convertFont(ts, range: m.range(at: 1), trait: .italicFontMask)
                ts.addAttributes(dim, range: NSRange(location: m.range.location, length: 1))
                ts.addAttributes(dim, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            }
        }
    }

    private func convertFont(_ ts: NSTextStorage, range: NSRange, trait: NSFontTraitMask) {
        guard range.length > 0 else { return }
        ts.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let f = value as? NSFont else { return }
            ts.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: r)
        }
    }
}
