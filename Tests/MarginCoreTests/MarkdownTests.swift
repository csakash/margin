import XCTest
@testable import MarginCore

final class MarkdownTests: XCTestCase {
    func testTitleFromFirstHeading() {
        XCTAssertEqual(Markdown.stats(for: "# Hello\n\nbody").title, "Hello")
    }

    // MARK: classify

    private func type(_ s: String) -> Markdown.BlockType { Markdown.classify(s).0 }
    private func prefix(_ s: String) -> Int { Markdown.classify(s).1 }

    func testHeadings() {
        XCTAssertEqual(type("# A"), .heading(level: 1)); XCTAssertEqual(prefix("# A"), 2)
        XCTAssertEqual(type("## A"), .heading(level: 2)); XCTAssertEqual(prefix("## A"), 3)
        XCTAssertEqual(type("### A"), .heading(level: 3)); XCTAssertEqual(prefix("### A"), 4)
        XCTAssertEqual(type("#A"), .paragraph)
    }

    func testTodos() {
        XCTAssertEqual(type("- [ ] buy milk"), .todo(done: false)); XCTAssertEqual(prefix("- [ ] x"), 6)
        XCTAssertEqual(type("- [x] done"), .todo(done: true))
        XCTAssertEqual(type("- [X] done"), .todo(done: true))
        XCTAssertEqual(type("- [ ]"), .todo(done: false)); XCTAssertEqual(prefix("- [ ]"), 5)
        XCTAssertEqual(type("- [x]"), .todo(done: true))
        XCTAssertEqual(type("- [X]"), .todo(done: true))
    }

    func testBulletsNumberedQuotes() {
        XCTAssertEqual(type("- item"), .bullet); XCTAssertEqual(prefix("- item"), 2)
        XCTAssertEqual(type("* item"), .bullet)
        XCTAssertEqual(type("1. one"), .numbered); XCTAssertEqual(prefix("1. one"), 3)
        XCTAssertEqual(type("12. twelve"), .numbered); XCTAssertEqual(prefix("12. twelve"), 4)
        XCTAssertEqual(type("1.5 kg"), .paragraph)
        XCTAssertEqual(type("> quoted"), .quote); XCTAssertEqual(prefix("> quoted"), 2)
        XCTAssertEqual(type(">"), .quote); XCTAssertEqual(prefix(">"), 1)
    }

    func testDividerImageLinkBlank() {
        XCTAssertEqual(type("---"), .divider)
        XCTAssertEqual(type("***"), .divider)
        XCTAssertEqual(type("![shot](assets/ab12.png)"), .image(path: "assets/ab12.png"))
        XCTAssertEqual(type("[Apple](https://apple.com/mac)"), .link(url: "https://apple.com/mac", title: "Apple"))
        XCTAssertEqual(type("https://example.com/a?b=1"), .link(url: "https://example.com/a?b=1", title: "example.com"))
        XCTAssertEqual(type("see https://example.com"), .paragraph)
        XCTAssertEqual(type(""), .blank)
        XCTAssertEqual(type("   "), .blank)
        XCTAssertEqual(type("plain text"), .paragraph)
    }

    func testFencesAndCode() {
        let text = "intro\n```swift\nlet x = 1\n# not a heading\n```\nafter"
        let types = Markdown.lines(in: text).map(\.type)
        XCTAssertEqual(types, [.paragraph, .codeFence, .code, .code, .codeFence, .paragraph])
    }

    func testLineRangesAreUTF16() {
        let text = "# Héllo 👋\n- [ ] a\n"
        let lines = Markdown.lines(in: text)
        XCTAssertEqual(lines.count, 3)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: lines[0].range), "# Héllo 👋")
        XCTAssertEqual(ns.substring(with: lines[1].range), "- [ ] a")
        XCTAssertEqual(lines[2].type, .blank)
        XCTAssertEqual(lines[2].range, NSRange(location: ns.length, length: 0))
    }

    func testEmptyTextIsOneBlankLine() {
        XCTAssertEqual(Markdown.lines(in: "").map(\.type), [.blank])
        XCTAssertEqual(Markdown.lines(in: "a").count, 1)
    }

    // MARK: stats

    func testStatsCounts() {
        let text = """
        # Groceries
        - [ ] milk
        - [x] eggs
        - [X] bread
        ![](assets/a.png)
        ![](assets/b.png)
        https://example.com
        [Docs](https://docs.example.com)
        > wise words
        plain line
        """
        let st = Markdown.stats(for: text)
        XCTAssertEqual(st.title, "Groceries")
        XCTAssertEqual(st.todos, 3)
        XCTAssertEqual(st.done, 2)
        XCTAssertEqual(st.media, 2)
        XCTAssertEqual(st.links, 2)
        XCTAssertEqual(st.quotes, 1)
        XCTAssertEqual(st.snippet, "milk · eggs · bread · example.com · Docs · wise words · plain line")
    }

    func testStatsTitleFallbacks() {
        XCTAssertEqual(Markdown.stats(for: "").title, "Untitled")
        XCTAssertEqual(Markdown.stats(for: "# ").title, "Untitled")
        XCTAssertEqual(Markdown.stats(for: "\n\nFirst para\nsecond").title, "First para")
        XCTAssertEqual(Markdown.stats(for: "- [ ] task first").title, "task first")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(Markdown.stats(for: long).title.count, 80)
        let manyLines = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertLessThanOrEqual(Markdown.stats(for: manyLines).snippet.count, 160)
    }

    func testStatsIgnoreFrontMatter() {
        let st = Markdown.stats(for: "---\nid: abc\ncreated: 2026-01-01T00:00:00Z\n---\n# Real\nbody")
        XCTAssertEqual(st.title, "Real")
        XCTAssertEqual(st.snippet, "body")
    }

    // MARK: front-matter

    func testFrontMatterRoundTrip() {
        let meta = ["id": "abc123", "created": "2026-11-24T10:00:00Z", "zeta": "1"]
        let body = "# Title\n\n---\nafter divider\n"
        let joined = Markdown.joinFrontMatter(meta, body: body)
        XCTAssertTrue(joined.hasPrefix("---\nid: abc123\ncreated: 2026-11-24T10:00:00Z\nzeta: 1\n---\n"))
        let (m, b) = Markdown.splitFrontMatter(joined)
        XCTAssertEqual(m, meta)
        XCTAssertEqual(b, body)
    }

    func testNoFrontMatter() {
        let (m, b) = Markdown.splitFrontMatter("# Just a note")
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(b, "# Just a note")
        XCTAssertEqual(Markdown.joinFrontMatter([:], body: "x"), "x")
    }

    func testFrontMatterWithEmptyBody() {
        let (m, b) = Markdown.splitFrontMatter("---\nid: x\n---")
        XCTAssertEqual(m, ["id": "x"])
        XCTAssertEqual(b, "")
    }

    /// A body that opens with a divider must not be mistaken for front-matter.
    func testLeadingDividerIsNotFrontMatter() {
        let text = "---\nSome text\n---\nmore"
        let (m, b) = Markdown.splitFrontMatter(text)
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(b, text)
    }
}
