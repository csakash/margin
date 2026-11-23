import Foundation

/// Block-level markdown understanding shared by the store (stats) and the editor (styling).
/// Signatures are frozen until the integration wave; bodies may be refined by Loop A.
public enum Markdown {

    public enum BlockType: Equatable, Sendable {
        case paragraph
        case heading(level: Int)        // #, ##, ###
        case bullet                     // - or *
        case numbered                   // 1.
        case todo(done: Bool)           // - [ ] / - [x]
        case quote                      // >
        case codeFence                  // ``` line (opening or closing)
        case code                       // line inside a fence
        case divider                    // ---
        case image(path: String)        // ![alt](path) alone on a line
        case link(url: String, title: String) // [title](url) or a bare URL alone on a line
        case blank
    }

    public struct Line: Equatable, Sendable {
        public var type: BlockType
        /// Range of the line content (without the newline) in UTF-16 offsets (NSString compatible).
        public var range: NSRange
        /// UTF-16 length of the syntax prefix ("## " = 3, "- [ ] " = 6, "> " = 2). 0 if none.
        public var prefixLength: Int
        public init(type: BlockType, range: NSRange, prefixLength: Int) {
            self.type = type; self.range = range; self.prefixLength = prefixLength
        }
    }

    private static let imageRE = try! NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^)\s]+)\)\s*$"#)
    private static let linkRE = try! NSRegularExpression(pattern: #"^\[([^\]]+)\]\((https?://[^)\s]+)\)\s*$"#)
    private static let bareURLRE = try! NSRegularExpression(pattern: #"^https?://\S+$"#)
    private static let numberedRE = try! NSRegularExpression(pattern: #"^\d{1,3}\. "#)

    /// Classify one line (outside code fences).
    public static func classify(_ line: String) -> (BlockType, Int) {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return (.blank, 0) }
        if line.hasPrefix("```") { return (.codeFence, ns.length) }
        if line == "---" || line == "***" || line == "___" { return (.divider, ns.length) }
        if line.hasPrefix("### ") { return (.heading(level: 3), 4) }
        if line.hasPrefix("## ") { return (.heading(level: 2), 3) }
        if line.hasPrefix("# ") { return (.heading(level: 1), 2) }
        if line.hasPrefix("- [ ] ") || line == "- [ ]" { return (.todo(done: false), min(6, ns.length)) }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") || line == "- [x]" { return (.todo(done: true), min(6, ns.length)) }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return (.bullet, 2) }
        if let m = numberedRE.firstMatch(in: line, range: full) { return (.numbered, m.range.length) }
        if line.hasPrefix("> ") { return (.quote, 2) }
        if line == ">" { return (.quote, 1) }
        if let m = imageRE.firstMatch(in: line, range: full) {
            return (.image(path: ns.substring(with: m.range(at: 2))), 0)
        }
        if let m = linkRE.firstMatch(in: line, range: full) {
            return (.link(url: ns.substring(with: m.range(at: 2)), title: ns.substring(with: m.range(at: 1))), 0)
        }
        if bareURLRE.firstMatch(in: line, range: full) != nil {
            let u = line.trimmingCharacters(in: .whitespaces)
            return (.link(url: u, title: URL(string: u)?.host ?? u), 0)
        }
        return (.paragraph, 0)
    }

    /// Classify every line of `text`. Lines between ``` fences are `.code`.
    public static func lines(in text: String) -> [Line] {
        let ns = text as NSString
        var out: [Line] = []
        var inFence = false
        var loc = 0
        while loc <= ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  let c = UnicodeScalar(ns.character(at: contentEnd - 1)), CharacterSet.newlines.contains(c) {
                contentEnd -= 1
            }
            let r = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            let s = ns.substring(with: r)
            if inFence {
                if s.hasPrefix("```") { out.append(Line(type: .codeFence, range: r, prefixLength: r.length)); inFence = false }
                else { out.append(Line(type: .code, range: r, prefixLength: 0)) }
            } else {
                let (t, p) = classify(s)
                if t == .codeFence { inFence = true }
                out.append(Line(type: t, range: r, prefixLength: p))
            }
            if NSMaxRange(lineRange) == loc { break }      // empty final line
            loc = NSMaxRange(lineRange)
            if loc == ns.length {
                // trailing newline means one more empty line
                if ns.length > 0, let c = UnicodeScalar(ns.character(at: ns.length - 1)), CharacterSet.newlines.contains(c) {
                    out.append(Line(type: .blank, range: NSRange(location: ns.length, length: 0), prefixLength: 0))
                }
                break
            }
        }
        return out
    }

    /// Title, snippet and counts for drawer cards.
    public static func stats(for text: String) -> NoteStats {
        let body = splitFrontMatter(text).body
        let ns = body as NSString
        var title: String?
        var snippet: [String] = []
        var st = NoteStats()
        for l in lines(in: body) {
            let s = ns.substring(with: l.range)
            let content = (s as NSString).substring(from: min(l.prefixLength, (s as NSString).length))
                .trimmingCharacters(in: .whitespaces)
            switch l.type {
            case .todo(let done): st.todos += 1; if done { st.done += 1 }
            case .image: st.media += 1
            case .link: st.links += 1
            case .quote: st.quotes += 1
            default: break
            }
            switch l.type {
            case .blank, .codeFence, .divider, .image: continue
            default: break
            }
            if content.isEmpty { continue }
            if title == nil { title = String(content.prefix(80)); continue }
            if case .link(_, let t) = l.type { snippet.append(t) } else { snippet.append(content) }
        }
        st.title = title ?? "Untitled"
        st.snippet = String(snippet.joined(separator: " · ").prefix(160))
        return st
    }

    /// Split `---\nkey: value\n---\n` front-matter from the body.
    public static func splitFrontMatter(_ text: String) -> (meta: [String: String], body: String) {
        guard text.hasPrefix("---\n") else { return ([:], text) }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else {
            return ([:], text)
        }
        var meta: [String: String] = [:]
        for line in rest[rest.startIndex..<end.lowerBound].split(separator: "\n") {
            guard let c = line.firstIndex(of: ":") else { continue }
            meta[line[..<c].trimmingCharacters(in: .whitespaces)] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return (meta, String(rest[end.upperBound...]))
    }

    public static func joinFrontMatter(_ meta: [String: String], body: String) -> String {
        guard !meta.isEmpty else { return body }
        let keys = meta.keys.sorted { a, b in a == "id" ? true : b == "id" ? false : a < b }
        return "---\n" + keys.map { "\($0): \(meta[$0]!)" }.joined(separator: "\n") + "\n---\n" + body
    }
}
