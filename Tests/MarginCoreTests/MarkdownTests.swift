import XCTest
@testable import MarginCore

final class MarkdownTests: XCTestCase {
    func testTitleFromFirstHeading() {
        XCTAssertEqual(Markdown.stats(for: "# Hello\n\nbody").title, "Hello")
    }
}
