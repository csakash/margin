import XCTest
@testable import MarginCore

final class ShortcutTests: XCTestCase {
    private typealias M = Shortcut.Mod
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ShortcutStore!

    override func setUp() {
        suiteName = "MarginShortcutTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ShortcutStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Display

    // protects=default fold label reads "⌥Space"; fails_when=modifier symbol or key name is wrong; no_claim=none beyond protects
    func testDisplayDefaultToggle() {
        let s = ShortcutAction.toggle.defaultShortcut
        XCTAssertEqual(s.displayString, "⌥Space")
        XCTAssertEqual(s.keycaps, ["⌥", "Space"])
    }

    // protects=modifiers render in Apple order ⌃⌥⇧⌘ whatever bit order; fails_when=order is ⌘-first or unsorted; no_claim=none beyond protects
    func testModifierOrder() {
        let all = Shortcut(keyCode: Shortcut.Key.m, modifiers: M.command | M.shift | M.option | M.control)
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘M")
        XCTAssertEqual(Shortcut(keyCode: Shortcut.Key.m, modifiers: M.control | M.option).displayString, "⌃⌥M")
    }

    // protects=F-keys and arrows have names; fails_when=F5 shows as Key96; no_claim=only US-ANSI names, not layout-aware ones
    func testFunctionAndArrowNames() {
        XCTAssertEqual(Shortcut(keyCode: 0x60, modifiers: M.command | M.shift).displayString, "⇧⌘F5")
        XCTAssertEqual(Shortcut(keyCode: Shortcut.Key.leftArrow, modifiers: M.command).keycaps, ["⌘", "←"])
    }

    // protects=unknown key codes still render; fails_when=crash or empty name; no_claim=none beyond protects
    func testUnknownKeyCode() {
        XCTAssertEqual(Shortcut(keyCode: 0xA0, modifiers: M.option).displayString, "⌥Key160")
    }

    // MARK: Validation

    // protects=AC4 plain key rejected; fails_when=a shortcut with no modifier validates ok; no_claim=does not prove the UI shows the message
    func testNoModifierRejected() {
        XCTAssertEqual(store.validate(Shortcut(keyCode: 0x00, modifiers: 0), for: .toggle), .needsModifier)
    }

    // protects=⇧ alone is not enough (⇧A types text); fails_when=shift-only validates ok; no_claim=none beyond protects
    func testShiftOnlyRejected() {
        XCTAssertEqual(store.validate(Shortcut(keyCode: 0x00, modifiers: M.shift), for: .toggle), .needsModifier)
    }

    // protects=Esc/Return and ⌃⌥ arrows (nudge, AC11) can't be bound; fails_when=any of them validates ok; no_claim=other arrow combos stay allowed only as far as asserted
    func testReservedKeysRejected() {
        XCTAssertEqual(store.validate(Shortcut(keyCode: Shortcut.Key.escape, modifiers: M.option), for: .toggle), .reservedKey)
        XCTAssertEqual(store.validate(Shortcut(keyCode: 0x24, modifiers: M.command), for: .toggle), .reservedKey)
        XCTAssertEqual(store.validate(Shortcut(keyCode: Shortcut.Key.leftArrow, modifiers: M.control | M.option), for: .toggle), .reservedKey)
        XCTAssertEqual(store.validate(Shortcut(keyCode: Shortcut.Key.leftArrow, modifiers: M.control | M.option | M.shift), for: .toggle), .ok)
    }

    // protects=AC5 one combo can't drive both actions; fails_when=New Note's combo validates for toggle; no_claim=none beyond protects
    func testDuplicateRejected() {
        let newNote = store.shortcut(for: .newNote)
        XCTAssertEqual(store.validate(newNote, for: .toggle), .duplicate(.newNote))
        XCTAssertEqual(ShortcutValidation.duplicate(.newNote).message, "Already used for New Note.")
        // Its own current combo is not a duplicate of itself.
        XCTAssertEqual(store.validate(newNote, for: .newNote), .ok)
    }

    // protects=extra modifiers are allowed (⌃⌥Space, ⌘⇧M); fails_when=multi-modifier combo rejected; no_claim=does not check whether macOS owns the combo
    func testMultipleModifiersOK() {
        XCTAssertEqual(store.validate(Shortcut(keyCode: Shortcut.Key.space, modifiers: M.control | M.option | M.shift), for: .toggle), .ok)
        XCTAssertEqual(store.validate(Shortcut(keyCode: Shortcut.Key.m, modifiers: M.command | M.shift), for: .newNote), .ok)
    }

    // MARK: Store

    // protects=AC1 fresh install uses ⌥Space / ⌥N; fails_when=empty defaults return anything else; no_claim=uses a scratch UserDefaults suite, not the app's domain
    func testDefaultsWhenEmpty() {
        XCTAssertEqual(store.shortcut(for: .toggle), Shortcut(keyCode: 0x31, modifiers: 0x800))
        XCTAssertEqual(store.shortcut(for: .newNote), Shortcut(keyCode: 0x2D, modifiers: 0x800))
        XCTAssertNil(store.storedShortcut(for: .toggle))
    }

    // protects=AC3 a binding persists as JSON under margin.shortcut.toggle; fails_when=key name or JSON shape differs, or value doesn't read back; no_claim=scratch suite stands in for the app's defaults domain
    func testRoundTrip() throws {
        let s = Shortcut(keyCode: Shortcut.Key.m, modifiers: M.control | M.option)
        store.set(s, for: .toggle)
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcut(for: .toggle), s)
        let data = try XCTUnwrap(defaults.data(forKey: "margin.shortcut.toggle"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(json, ["keyCode": 46, "modifiers": 6144])
    }

    // protects=AC8 reset returns to default and clears the key; fails_when=stored value survives reset; no_claim=none beyond protects
    func testReset() {
        store.set(Shortcut(keyCode: Shortcut.Key.m, modifiers: M.command), for: .newNote)
        store.reset(.newNote)
        XCTAssertNil(defaults.object(forKey: "margin.shortcut.newNote"))
        XCTAssertEqual(store.shortcut(for: .newNote), ShortcutAction.newNote.defaultShortcut)
    }

    // protects=AC12 corrupt stored values fall back to the default; fails_when=junk crashes or returns a bogus combo; no_claim=covers string and bad-JSON junk only
    func testCorruptValueFallsBack() {
        defaults.set("junk", forKey: "margin.shortcut.toggle")
        XCTAssertEqual(store.shortcut(for: .toggle), ShortcutAction.toggle.defaultShortcut)
        defaults.set(Data("{\"keyCode\":\"x\"}".utf8), forKey: "margin.shortcut.toggle")
        XCTAssertEqual(store.shortcut(for: .toggle), ShortcutAction.toggle.defaultShortcut)
    }
}
