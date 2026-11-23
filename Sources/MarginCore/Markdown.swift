import Foundation

/// Block-level markdown understanding shared by the store (stats) and the editor (styling).
/// CONTRACT (Wave 0). Loop A implements bodies; signatures are frozen until Wave 2.
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
        case image(path: String)        // ![alt](path)
        case blank
    }

    public struct Line: Equatable, Sendable {
        public var type: BlockType
        /// Range of the whole line in the source string, in UTF-16 offsets (NSString compatible).
        public var range: NSRange
        /// Length in UTF-16 of the syntax prefix (e.g. "## " = 3, "- [ ] " = 6). 0 if none.
        public var prefixLength: Int
        public init(type: BlockType, range: NSRange, prefixLength: Int) {
            self.type = type; self.range = range; self.prefixLength = prefixLength
        }
    }

    /// Classify every line of `text`. Lines inside ``` fences are `.code`.
    public static func lines(in text: String) -> [Line] {
        // Wave 0 stub: everything is a paragraph.
        let ns = text as NSString
        var out: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, r, _, _ in
            out.append(Line(type: .paragraph, range: r, prefixLength: 0))
        }
        return out
    }

    /// Title, two-line snippet and counts for the drawer.
    public static func stats(for text: String) -> NoteStats {
        // Wave 0 stub: first non-empty line, stripped of "#".
        let first = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let title = first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? "Untitled"
        return NoteStats(title: title.isEmpty ? "Untitled" : String(title))
    }

    /// Strip front-matter (`---\n...\n---\n`) and return (frontMatter, body).
    public static func splitFrontMatter(_ text: String) -> (meta: [String: String], body: String) {
        return ([:], text)
    }

    /// Render front-matter + body back to a file string.
    public static func joinFrontMatter(_ meta: [String: String], body: String) -> String {
        return body
    }
}
