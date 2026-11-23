import XCTest
@testable import MarginCore

final class NoteStoreTests: TempDirTestCase {

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testInitCreatesFolders() throws {
        _ = try NoteStore(folder: dir)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("assets").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".margin/index.sqlite").path))
    }

    func testCreateWritesFileImmediately() throws {
        let store = try NoteStore(folder: dir)
        var changes = 0
        store.onChange = { changes += 1 }
        let id = store.create(initialText: "# Hello World\nbody")
        XCTAssertEqual(changes, 1)
        let url = dir.appendingPathComponent("hello-world-\(id.raw).md")
        let text = try read(url)
        let (meta, body) = Markdown.splitFrontMatter(text)
        XCTAssertEqual(meta["id"], id.raw)
        XCTAssertNotNil(meta["created"].flatMap { ISO8601DateFormatter().date(from: $0) })
        XCTAssertTrue(text.hasPrefix("---\nid: \(id.raw)\ncreated: "))
        XCTAssertEqual(body, "# Hello World\nbody")
        XCTAssertEqual(store.load(id), "# Hello World\nbody")
        XCTAssertEqual(store.list().first?.fileURL.lastPathComponent, url.lastPathComponent)
    }

    func testDefaultCreateIsUntitled() throws {
        let store = try NoteStore(folder: dir)
        let id = store.create()
        XCTAssertEqual(store.load(id), "# ")
        XCTAssertEqual(store.list().first?.title, "Untitled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("untitled-\(id.raw).md").path))
    }

    func testSaveIsDebouncedThenWritten() throws {
        let store = try NoteStore(folder: dir)
        let id = store.create(initialText: "# Note\nv0")
        let url = store.list()[0].fileURL
        store.save(id, text: "# Note\nv1")
        store.save(id, text: "# Note\nv2")
        // Not yet on disk, but visible to load() and list().
        XCTAssertEqual(Markdown.splitFrontMatter(try read(url)).body, "# Note\nv0")
        XCTAssertEqual(store.load(id), "# Note\nv2")
        XCTAssertEqual(store.list()[0].snippet, "v2")
        pump(0.15)
        XCTAssertEqual(Markdown.splitFrontMatter(try read(url)).body, "# Note\nv0", "written before 300 ms")
        pump(0.4)
        XCTAssertEqual(Markdown.splitFrontMatter(try read(url)).body, "# Note\nv2")
    }

    func testFlushWritesSynchronouslyAndPreservesMeta() throws {
        let store = try NoteStore(folder: dir)
        let id = store.create(initialText: "# Note")
        let url = store.list()[0].fileURL
        let created = Markdown.splitFrontMatter(try read(url)).meta["created"]
        store.save(id, text: "# Note\nflushed")
        store.flush()
        let (meta, body) = Markdown.splitFrontMatter(try read(url))
        XCTAssertEqual(body, "# Note\nflushed")
        XCTAssertEqual(meta["id"], id.raw)
        XCTAssertEqual(meta["created"], created)
        // A reopened store sees the same note.
        let again = try NoteStore(folder: dir)
        XCTAssertEqual(again.load(id), "# Note\nflushed")
    }

    func testDeinitFlushes() throws {
        var store: NoteStore? = try NoteStore(folder: dir)
        let id = store!.create(initialText: "# A")
        let url = store!.list()[0].fileURL
        store!.save(id, text: "# A\nlast words")
        store = nil
        XCTAssertEqual(Markdown.splitFrontMatter(try read(url)).body, "# A\nlast words")
    }

    func testListOrderMostRecentFirst() throws {
        let store = try NoteStore(folder: dir)
        let a = store.create(initialText: "# A")
        pump(0.02)
        let b = store.create(initialText: "# B")
        XCTAssertEqual(store.list().map(\.id), [b, a])
        store.save(a, text: "# A\nedited")
        XCTAssertEqual(store.list().map(\.id), [a, b], "pending edit moves to the top immediately")
        store.flush()
        XCTAssertEqual(store.list().map(\.id), [a, b])
    }

    func testRenameOnTitleChange() throws {
        let store = try NoteStore(folder: dir)
        var changes = 0
        let id = store.create(initialText: "# Old title")
        store.onChange = { changes += 1 }
        store.save(id, text: "# Brand New Title!\nbody")
        XCTAssertEqual(changes, 1)
        store.flush()
        XCTAssertEqual(changes, 2, "rename reports the new file URL")
        let files = mdFiles(in: dir).map(\.lastPathComponent)
        XCTAssertEqual(files, ["brand-new-title-\(id.raw).md"])
        XCTAssertEqual(store.list()[0].fileURL.lastPathComponent, "brand-new-title-\(id.raw).md")
        XCTAssertEqual(store.load(id), "# Brand New Title!\nbody")
        // Same title again: no rename.
        store.save(id, text: "# Brand New Title!\nmore")
        store.flush()
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(mdFiles(in: dir).count, 1)
    }

    func testSlug() {
        XCTAssertEqual(NoteStore.slug("Hello, World!"), "hello-world")
        XCTAssertEqual(NoteStore.slug("  Café   Déjà vu "), "cafe-deja-vu")
        XCTAssertEqual(NoteStore.slug(""), "untitled")
        XCTAssertEqual(NoteStore.slug("日本語"), "untitled")
        XCTAssertEqual(NoteStore.slug("---"), "untitled")
        let long = NoteStore.slug(String(repeating: "abc ", count: 40))
        XCTAssertLessThanOrEqual(long.count, 48)
        XCTAssertFalse(long.hasSuffix("-"))
        XCTAssertEqual(NoteStore.fileName(title: "X y", id: NoteID("abc")), "x-y-abc.md")
    }

    func testDeleteMovesFileAway() throws {
        let store = try NoteStore(folder: dir)
        store.usesTrash = false
        let id = store.create(initialText: "# Gone soon")
        let url = store.list()[0].fileURL
        store.save(id, text: "# Gone soon\npending")
        store.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertEqual(store.load(id), "")
        pump(0.4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "cancelled pending save must not resurrect it")
        XCTAssertTrue(store.search("gone").isEmpty)
    }

    func testAdoptsForeignMarkdownFile() throws {
        let foreign = dir.appendingPathComponent("Shopping List.md")
        try "# Shopping\n- [ ] apples".write(to: foreign, atomically: true, encoding: .utf8)
        let store = try NoteStore(folder: dir)
        let notes = store.list()
        XCTAssertEqual(notes.count, 1)
        let id = notes[0].id
        XCTAssertEqual(notes[0].title, "Shopping")
        XCTAssertEqual(notes[0].stats.todos, 1)
        XCTAssertEqual(store.load(id), "# Shopping\n- [ ] apples")
        // Reading does not modify the file.
        XCTAssertEqual(try read(foreign), "# Shopping\n- [ ] apples")
        // The id is stable across rescans.
        store.rescan()
        XCTAssertEqual(store.list().map(\.id), [id])

        store.save(id, text: "# Shopping\n- [x] apples")
        store.flush()
        let files = mdFiles(in: dir)
        XCTAssertEqual(files.map(\.lastPathComponent), ["shopping-\(id.raw).md"])
        let (meta, body) = Markdown.splitFrontMatter(try read(files[0]))
        XCTAssertEqual(meta["id"], id.raw)
        XCTAssertNotNil(meta["created"])
        XCTAssertEqual(body, "# Shopping\n- [x] apples")
        // A fresh store picks up the written id.
        XCTAssertEqual(try NoteStore(folder: dir).list().map(\.id), [id])
    }

    func testForeignFrontMatterIsPreserved() throws {
        let foreign = dir.appendingPathComponent("obsidian.md")
        try "---\ntags: work\n---\n# Meeting".write(to: foreign, atomically: true, encoding: .utf8)
        let store = try NoteStore(folder: dir)
        let id = store.list()[0].id
        store.save(id, text: "# Meeting\nnotes")
        store.flush()
        let (meta, body) = Markdown.splitFrontMatter(try read(store.list()[0].fileURL))
        XCTAssertEqual(meta["tags"], "work")
        XCTAssertEqual(meta["id"], id.raw)
        XCTAssertEqual(body, "# Meeting\nnotes")
    }

    func testDuplicatedFileGetsItsOwnID() throws {
        let store = try NoteStore(folder: dir)
        let id = store.create(initialText: "# Original")
        let url = store.list()[0].fileURL
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("copy.md"))
        XCTAssertTrue(store.rescan())
        let ids = Set(store.list().map(\.id))
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains(id))
    }

    func testRescanDetectsExternalEditsAddsAndRemovals() throws {
        let store = try NoteStore(folder: dir)
        let id = store.create(initialText: "# Mine")
        var changes = 0
        store.onChange = { changes += 1 }
        XCTAssertFalse(store.rescan(), "own writes are not external changes")
        XCTAssertEqual(changes, 0)

        let url = store.list()[0].fileURL
        let edited = Markdown.joinFrontMatter(["id": id.raw], body: "# Mine\nedited elsewhere")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.rescan())
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.load(id), "# Mine\nedited elsewhere")
        XCTAssertEqual(store.list()[0].snippet, "edited elsewhere")
        XCTAssertEqual(store.search("elsewhere").map(\.id), [id])

        try "# Dropped in".write(to: dir.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.rescan())
        XCTAssertEqual(store.list().count, 2)

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(store.rescan())
        XCTAssertEqual(store.list().map(\.title), ["Dropped in"])
        XCTAssertTrue(store.search("mine").isEmpty)
    }

    func testWatcherReportsExternalChangeButNotOwnWrites() throws {
        let store = try NoteStore(folder: dir)
        let id = store.create(initialText: "# Watched")
        pump(0.3)  // let the create's folder event settle
        var changes = 0
        store.onChange = { changes += 1 }

        store.save(id, text: "# Watched\nown edit")
        XCTAssertEqual(changes, 1)
        store.flush()
        pump(0.4)
        XCTAssertEqual(changes, 1, "our own write must not come back as an external change")

        let exp = expectation(description: "external change")
        store.onChange = { exp.fulfill() }
        try "# From Finder".write(to: dir.appendingPathComponent("finder.md"), atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(store.list().count, 2)
    }

    func testSearchRankingAndPrefix() throws {
        let store = try NoteStore(folder: dir)
        let body = store.create(initialText: "# Groceries\nbuy milk and a swift guide book")
        let title = store.create(initialText: "# Swift concurrency\nactors and tasks")
        _ = store.create(initialText: "# Unrelated\nnothing here")
        XCTAssertEqual(store.search("swift").map(\.id), [title, body])
        XCTAssertEqual(store.search("swi").map(\.id), [title, body], "prefix match")
        XCTAssertEqual(store.search("conc act").map(\.id), [title], "all terms must match")
        XCTAssertEqual(store.search("  ").count, 3, "empty query lists everything")
        XCTAssertTrue(store.search("zzz").isEmpty)
        XCTAssertTrue(store.search("\"").isEmpty)
        XCTAssertNoThrow(store.search("a\"b OR (c* NEAR"))
    }

    func testSearchSeesPendingEditsAndDiacritics() throws {
        let store = try NoteStore(folder: dir)
        let id = store.create(initialText: "# Note")
        store.save(id, text: "# Note\nCafé crème")
        XCTAssertEqual(store.search("cafe").map(\.id), [id])
        XCTAssertEqual(store.search("CRE").map(\.id), [id])
    }

    func testIndexRebuiltOnLaunch() throws {
        let id: NoteID
        do {
            let store = try NoteStore(folder: dir)
            id = store.create(initialText: "# Persisted\nkeyword")
        }
        // Change the file while no store is running.
        let url = mdFiles(in: dir)[0]
        try Markdown.joinFrontMatter(["id": id.raw], body: "# Persisted\nreplaced")
            .write(to: url, atomically: true, encoding: .utf8)
        let store = try NoteStore(folder: dir)
        XCTAssertTrue(store.search("keyword").isEmpty)
        XCTAssertEqual(store.search("replaced").map(\.id), [id])
    }

    func testListPerformanceWithManyNotes() throws {
        for i in 0..<1000 {
            let id = NoteID("n\(i)")
            try Markdown.joinFrontMatter(["id": id.raw], body: "# Note \(i)\n- [ ] task\nbody \(i)")
                .write(to: dir.appendingPathComponent("note-\(i)-\(id.raw).md"), atomically: false, encoding: .utf8)
        }
        let start = Date()
        let store = try NoteStore(folder: dir)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(store.list().count, 1000)
        let t0 = Date()
        for _ in 0..<10 { _ = store.list() }
        XCTAssertLessThan(Date().timeIntervalSince(t0) / 10, 0.05, "list() should be fast")
        let t1 = Date()
        XCTAssertFalse(store.rescan())
        XCTAssertLessThan(Date().timeIntervalSince(t1), 1)
        XCTAssertEqual(store.search("note 999").first?.id, NoteID("n999"))
    }
}
