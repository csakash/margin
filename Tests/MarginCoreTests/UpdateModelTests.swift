import XCTest
@testable import MarginCore

final class UpdateModelTests: XCTestCase {
    // MARK: ReleaseNotes.lines

    // protects=no notes means an empty list, not a crash or a blank bullet
    // fails_when=nil or "" produces any line
    // no_claim=none beyond protects
    func testNilAndEmptyGiveNoLines() {
        XCTAssertEqual(ReleaseNotes.lines(from: nil), [])
        XCTAssertEqual(ReleaseNotes.lines(from: ""), [])
        XCTAssertEqual(ReleaseNotes.lines(from: "  \n \n"), [])
    }

    // protects=plain-text notes come through one line each
    // fails_when=lines are merged, reordered or keep surrounding spaces
    // no_claim=none beyond protects
    func testPlainLines() {
        XCTAssertEqual(ReleaseNotes.lines(from: "First fix\n  Second fix  \n\nThird"), ["First fix", "Second fix", "Third"])
    }

    // protects=the <ul><li> form release.sh writes becomes one line per item
    // fails_when=tags leak into the text or items are joined
    // no_claim=does not prove Sparkle hands us this exact string; release.sh output is checked in the QA run
    func testListItems() {
        XCTAssertEqual(ReleaseNotes.lines(from: "<ul><li>Updates itself</li><li>Faster search</li></ul>"),
                       ["Updates itself", "Faster search"])
    }

    // protects=<br> and <p> split lines, inline tags vanish
    // fails_when=<b>, <a href> or a stray tag survives as text or markup
    // no_claim=none beyond protects
    func testBreaksParagraphsAndInlineTags() {
        XCTAssertEqual(ReleaseNotes.lines(from: "<p>One <b>bold</b></p><p>Two<br/>Three <a href=\"https://x.test\">link</a></p>"),
                       ["One bold", "Two", "Three link"])
    }

    // protects=the six entities decode, and a double-escaped one is not decoded twice
    // fails_when="&amp;lt;" becomes "<" instead of the literal "&lt;"
    // no_claim=numeric entities other than &#39; are left as written
    func testEntities() {
        XCTAssertEqual(ReleaseNotes.lines(from: "Tom &amp; Jerry &lt;3 &quot;hi&quot; it&#39;s&nbsp;ok"),
                       ["Tom & Jerry <3 \"hi\" it's ok"])
        XCTAssertEqual(ReleaseNotes.lines(from: "&amp;lt;b&amp;gt;"), ["&lt;b&gt;"])
    }

    // protects=the card never shows more than 5 note lines
    // fails_when=a 6th line is returned, or the first five are not the ones kept
    // no_claim=none beyond protects
    func testCapsAtFiveLines() {
        let seven = (1...7).map { "Line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ReleaseNotes.lines(from: seven), ["Line 1", "Line 2", "Line 3", "Line 4", "Line 5"])
    }

    // protects=a long line is cut to 120 characters ending in an ellipsis; a 120-character line is untouched
    // fails_when=the result is longer than 120 or the cut drops the ellipsis
    // no_claim=none beyond protects
    func testLongLineIsTruncated() {
        let exact = String(repeating: "a", count: 120)
        XCTAssertEqual(ReleaseNotes.lines(from: exact), [exact])
        let long = ReleaseNotes.lines(from: String(repeating: "b", count: 121))
        XCTAssertEqual(long.first?.count, 120)
        XCTAssertEqual(long.first?.last, "…")
    }

    // protects=markdown-style list markers are removed so the card does not draw a double bullet
    // fails_when="- note" or "• note" keeps its marker
    // no_claim=a hyphen inside a line is not touched
    func testLeadingMarkersStripped() {
        XCTAssertEqual(ReleaseNotes.lines(from: "- One\n• Two\n* Three\nfour - five"), ["One", "Two", "Three", "four - five"])
    }

    // protects=script or style markup in a feed can only ever become inert text
    // fails_when=any "<" tag survives in the output
    // no_claim=the card must still render these strings as plain text; that is checked in review, not here
    func testMarkupNeverSurvives() {
        let out = ReleaseNotes.lines(from: "<script>alert(1)</script><li onclick=\"x()\">ok</li><img src=x onerror=y>")
        XCTAssertEqual(out, ["alert(1)", "ok"])
        XCTAssertFalse(out.joined().contains("<"))
    }

    // protects=a bare "<" or ">" in a plain-text note is kept
    // fails_when="a < b and c > d" loses the text between the two signs
    // no_claim=none beyond protects
    func testBareAngleBracketsAreKept() {
        XCTAssertEqual(ReleaseNotes.lines(from: "Fixes a < b and c > d"), ["Fixes a < b and c > d"])
    }

    // protects=only version-shaped text from the feed reaches the card title and the menu
    // fails_when=a sentence, markup, an over-long or empty string is accepted, or "0.2.1" / "1.0-beta+3" is refused
    // no_claim=does not prove the driver uses it for every title; that is a code-review point
    func testSafeVersion() {
        XCTAssertEqual(ReleaseNotes.safeVersion("0.2.1"), "0.2.1")
        XCTAssertEqual(ReleaseNotes.safeVersion(" 1.0-beta+3 "), "1.0-beta+3")
        XCTAssertNil(ReleaseNotes.safeVersion(nil))
        XCTAssertNil(ReleaseNotes.safeVersion(""))
        XCTAssertNil(ReleaseNotes.safeVersion("is broken. Visit evil.example to fix"))
        XCTAssertNil(ReleaseNotes.safeVersion("<b>1.0</b>"))
        XCTAssertNil(ReleaseNotes.safeVersion("v1.0"))
        XCTAssertNil(ReleaseNotes.safeVersion(String(repeating: "1", count: 21)))
    }

    // MARK: UpdatePhase

    private let info = UpdateInfo(version: "0.2.1", notes: ["A"])
    private var all: [UpdatePhase] {
        [.idle, .checking, .available(info), .downloading(info, 0.5), .ready(info), .installing(info), .upToDate("0.2.0"), .failed("x")]
    }

    // protects=the card is hidden only when idle
    // fails_when=any non-idle phase hides the card, or idle shows it
    // no_claim=does not prove the view obeys it
    func testShowsCard() {
        XCTAssertEqual(all.map(\.showsCard), [false, true, true, true, true, true, true, true])
    }

    // protects=the nub glows only for a downloaded, waiting update
    // fails_when=checking, downloading or an error lights the nub
    // no_claim=does not prove the nub draws it
    func testShowsNubDot() {
        XCTAssertEqual(all.map(\.showsNubDot), [false, false, false, false, true, false, false, false])
    }

    // protects=only "up to date" hides itself, after 3 seconds
    // fails_when=a ready update or an error would disappear without the user acting
    // no_claim=does not prove the timer fires
    func testAutoDismiss() {
        XCTAssertEqual(all.map(\.autoDismissAfter), [nil, nil, nil, nil, nil, nil, 3, nil])
    }
}
