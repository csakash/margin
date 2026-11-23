import Foundation
import MarginCore

/// Pure text logic behind the editor's key handling and block commands.
/// Everything works on plain strings with UTF-16 (NSString) offsets, so it is easy to reason about
/// and to test without a text view.
public enum EditorLogic {

    /// One text replacement plus where the caret goes afterwards.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public var caret: Int
        public init(range: NSRange, replacement: String, caret: Int) {
            self.range = range; self.replacement = replacement; self.caret = caret
        }
    }

    /// A line's block type, with list indentation understood ("  - x" is an indented bullet).
    public struct LineInfo: Equatable, Sendable {
        public var type: Markdown.BlockType
        /// Leading spaces/tabs before a list marker (UTF-16). 0 for non-list lines.
        public var indent: Int
        /// indent + marker length (UTF-16). 0 if the line has no prefix.
        public var prefixLength: Int
    }

    // MARK: - Classification

    /// Classify one line outside code fences. Indented list items keep their list type.
    public static func info(_ line: String) -> LineInfo {
        let ns = line as NSString
        var i = 0
        while i < ns.length, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        if i > 0, i < ns.length {
            let (t, p) = Markdown.classify(ns.substring(from: i))
            switch t {
            case .bullet, .numbered, .todo: return LineInfo(type: t, indent: i, prefixLength: i + p)
            default: break
            }
        }
        let (t, p) = Markdown.classify(line)
        return LineInfo(type: t, indent: 0, prefixLength: p)
    }

    /// Block types whose prefix can be removed to turn the line into plain text.
    public static func hasBlockPrefix(_ t: Markdown.BlockType) -> Bool {
        switch t {
        case .heading, .bullet, .numbered, .todo, .quote: return true
        default: return false
        }
    }

    /// The content range of the line containing `location` (without its line terminator).
    public static func contentRange(in ns: NSString, at location: Int) -> NSRange {
        let loc = max(0, min(location, ns.length))
        let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
        var end = NSMaxRange(lr)
        while end > lr.location, ns.character(at: end - 1) == 0x0A || ns.character(at: end - 1) == 0x0D { end -= 1 }
        return NSRange(location: lr.location, length: end - lr.location)
    }

    // MARK: - Enter / Backspace / Tab

    public enum NewlineAction: Equatable, Sendable {
        /// Default behaviour: insert a plain newline.
        case plain
        /// Insert this text instead (a newline plus the continued list marker).
        case insert(String)
        /// The item is empty: remove the first `n` characters of the line (its prefix) instead.
        case removePrefix(Int)
    }

    /// What Enter should do on `line` with the caret at UTF-16 offset `caret` inside it.
    public static func newline(line: String, caret: Int) -> NewlineAction {
        let inf = info(line)
        guard inf.prefixLength > 0, caret >= inf.prefixLength else { return .plain }
        switch inf.type {
        case .bullet, .numbered, .todo, .quote: break
        default: return .plain
        }
        let ns = line as NSString
        let content = ns.substring(from: inf.prefixLength).trimmingCharacters(in: .whitespaces)
        if content.isEmpty { return .removePrefix(inf.prefixLength) }
        return .insert("\n" + ns.substring(to: inf.indent) + continuation(line: line, info: inf))
    }

    /// The marker the next list item should start with.
    public static func continuation(line: String, info inf: LineInfo) -> String {
        let ns = line as NSString
        switch inf.type {
        case .bullet: return ns.substring(with: NSRange(location: inf.indent, length: 1)) + " "
        case .numbered:
            let marker = ns.substring(with: NSRange(location: inf.indent, length: inf.prefixLength - inf.indent))
            let n = Int(marker.prefix { $0.isNumber }) ?? 0
            return "\(n + 1). "
        case .todo: return "- [ ] "
        case .quote: return "> "
        default: return ""
        }
    }

    /// Backspace with the caret right after a block prefix removes the whole prefix.
    /// Returns the prefix length to remove, or nil for the default behaviour.
    public static func backspacePrefix(line: String, caret: Int) -> Int? {
        let inf = info(line)
        guard inf.prefixLength > 0, caret == inf.prefixLength, hasBlockPrefix(inf.type) else { return nil }
        return inf.prefixLength
    }

    /// Tab / Shift-Tab on a list item: the shifted line and the change in length. nil if not a list item.
    public static func shifted(_ line: String, outdent: Bool) -> (line: String, delta: Int)? {
        let inf = info(line)
        switch inf.type {
        case .bullet, .numbered, .todo: break
        default: return nil
        }
        if outdent {
            let remove = min(2, inf.indent)
            guard remove > 0 else { return nil }
            return ((line as NSString).substring(from: remove), -remove)
        }
        return ("  " + line, 2)
    }

    /// Clicking a checkbox: the one-character range to replace and its new value.
    public static func toggledTodo(_ line: String) -> (range: NSRange, replacement: String)? {
        let inf = info(line)
        guard case .todo(let done) = inf.type, (line as NSString).length > inf.indent + 3 else { return nil }
        return (NSRange(location: inf.indent + 3, length: 1), done ? " " : "x")
    }

    // MARK: - Block commands

    /// Does `kind` describe a line of type `t`? (Used for "apply again reverts to text".)
    public static func matches(_ kind: BlockKind, _ t: Markdown.BlockType) -> Bool {
        switch (kind, t) {
        case (.heading1, .heading(1)), (.heading2, .heading(2)), (.heading3, .heading(3)),
             (.bullet, .bullet), (.numbered, .numbered), (.todo, .todo), (.quote, .quote): return true
        default: return false
        }
    }

    /// Replace the line's block prefix with `kind`'s (toggling back to text if it already is `kind`).
    public static func applying(_ kind: BlockKind, to line: String) -> (line: String, oldPrefix: Int, newPrefix: Int) {
        let inf = info(line)
        let ns = line as NSString
        let oldPrefix = hasBlockPrefix(inf.type) ? inf.prefixLength : 0
        let content = ns.substring(from: oldPrefix)
        var prefix = ""
        if !matches(kind, inf.type), kind != .paragraph {
            prefix = kind.prefix
            let keepsIndent = [BlockKind.bullet, .numbered, .todo].contains(kind)
            if keepsIndent, inf.indent > 0, oldPrefix > 0 { prefix = ns.substring(to: inf.indent) + prefix }
        }
        return (prefix + content, oldPrefix, (prefix as NSString).length)
    }

    /// `apply(kind)` for prefix kinds (text, headings, lists, to-do, quote) on the caret's line.
    public static func applyPrefix(_ kind: BlockKind, text ns: NSString, caret: Int) -> Edit {
        let cr = contentRange(in: ns, at: caret)
        let r = applying(kind, to: ns.substring(with: cr))
        let inLine = caret - cr.location
        let newInLine = max(r.newPrefix, inLine - r.oldPrefix + r.newPrefix)
        return Edit(range: cr, replacement: r.line, caret: cr.location + min(newInLine, (r.line as NSString).length))
    }

    /// Insert `block` as its own paragraph(s) after the caret's line, followed by an empty line;
    /// the caret ends on that empty line. A blank caret line is reused.
    public static func blockInsertion(text ns: NSString, caret: Int, block: String) -> Edit {
        let cr = contentRange(in: ns, at: caret)
        if ns.substring(with: cr).trimmingCharacters(in: .whitespaces).isEmpty {
            let s = block + "\n"
            return Edit(range: cr, replacement: s, caret: cr.location + (s as NSString).length)
        }
        let s = "\n" + block + "\n"
        let at = NSMaxRange(cr)
        return Edit(range: NSRange(location: at, length: 0), replacement: s, caret: at + (s as NSString).length)
    }

    /// `.code`: wrap the caret's line in ``` fences, or unwrap the fenced block the caret is in.
    public static func codeToggle(text: String, caret: Int) -> Edit {
        let ns = text as NSString
        let lines = Markdown.lines(in: text)
        guard !lines.isEmpty else {
            return Edit(range: NSRange(location: 0, length: 0), replacement: "```\n\n```", caret: 4)
        }
        var groups: [(open: Int, close: Int?)] = []
        var open: Int?
        for (i, l) in lines.enumerated() where l.type == .codeFence {
            if let o = open { groups.append((o, i)); open = nil } else { open = i }
        }
        if let o = open { groups.append((o, nil)) }

        var ci = 0
        for (i, l) in lines.enumerated() where l.range.location <= caret { ci = i }

        if let g = groups.first(where: { ci >= $0.open && ci <= ($0.close ?? lines.count - 1) }) {
            // Unwrap: drop both fence lines, keep the body.
            let bodyEnd = g.close ?? lines.count
            var bodyLines: [Markdown.Line] = []
            if g.open + 1 < bodyEnd { bodyLines = Array(lines[(g.open + 1)..<bodyEnd]) }
            // A trailing empty line appended by `lines(in:)` for a final newline is not part of the block.
            if g.close == nil, let last = bodyLines.last, last.range.length == 0, last.range.location == ns.length,
               ns.length > 0, ns.character(at: ns.length - 1) == 0x0A {
                bodyLines.removeLast()
            }
            let body = bodyLines.map { ns.substring(with: $0.range) }.joined(separator: "\n")
            let start = lines[g.open].range.location
            let endLine = g.close.map { lines[$0] } ?? bodyLines.last ?? lines[g.open]
            let range = NSRange(location: start, length: NSMaxRange(endLine.range) - start)
            var newCaret = start
            if ci > g.open, ci < bodyEnd, let firstBody = bodyLines.first {
                newCaret = start + (caret - firstBody.range.location)
            }
            return Edit(range: range, replacement: body, caret: min(newCaret, start + (body as NSString).length))
        }

        // Wrap the caret's line.
        let cr = contentRange(in: ns, at: caret)
        let content = ns.substring(with: cr)
        return Edit(range: cr, replacement: "```\n" + content + "\n```", caret: cr.location + 4 + (caret - cr.location))
    }

    // MARK: - Markdown writers

    static func sanitizeInline(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")").trimmingCharacters(in: .whitespaces)
    }

    public static func imageMarkdown(path: String, caption: String?) -> String {
        "![\(sanitizeInline(caption ?? ""))](\(path))"
    }

    public static func linkMarkdown(url: URL, title: String?) -> String {
        let t = sanitizeInline(title ?? "")
        return t.isEmpty ? url.absoluteString : "[\(t)](\(url.absoluteString))"
    }

    public static func quoteMarkdown(_ text: String, source: URL?) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.isEmpty ? ">" : "> " + $0 }
        var lines = body.isEmpty ? [">"] : body
        if let source {
            let host = source.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? source.absoluteString
            lines.append("> — [\(sanitizeInline(host))](\(source.absoluteString))")
        }
        return lines.joined(separator: "\n")
    }
}
