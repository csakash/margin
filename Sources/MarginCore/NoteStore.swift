import Foundation

/// One `.md` file per note inside `folder`, assets in `folder/assets`, index in `folder/.margin`.
/// CONTRACT (Wave 0). Loop A replaces the in-memory stub with the real file-backed store.
/// All methods are called on the main thread.
public final class NoteStore {
    public let folder: URL
    public let assets: AssetStore
    /// Called (on main) after any change: save, create, delete, or an external edit on disk.
    public var onChange: (() -> Void)?

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin", isDirectory: true)
    }

    // Wave 0 stub storage
    private var texts: [NoteID: String] = [:]
    private var dates: [NoteID: Date] = [:]

    public init(folder: URL = NoteStore.defaultFolder) throws {
        self.folder = folder
        self.assets = AssetStore(folder: folder.appendingPathComponent("assets", isDirectory: true))
    }

    /// All notes, most recently edited first.
    public func list() -> [NoteSummary] {
        texts.map { id, t in
            NoteSummary(id: id, stats: Markdown.stats(for: t), updated: dates[id] ?? .distantPast,
                        fileURL: folder.appendingPathComponent("\(id.raw).md"))
        }.sorted { $0.updated > $1.updated }
    }

    /// Body text (without front-matter).
    public func load(_ id: NoteID) -> String { texts[id] ?? "" }

    /// Debounced (300 ms) atomic save. `flush()` forces pending writes.
    public func save(_ id: NoteID, text: String) {
        texts[id] = text; dates[id] = Date(); onChange?()
    }

    public func flush() {}

    @discardableResult
    public func create(initialText: String = "# ") -> NoteID {
        let id = NoteID.make(); texts[id] = initialText; dates[id] = Date(); onChange?(); return id
    }

    /// Moves the file to the Trash.
    public func delete(_ id: NoteID) { texts[id] = nil; dates[id] = nil; onChange?() }

    /// Full-text search over title and body (FTS5 prefix match). Empty query returns `list()`.
    public func search(_ query: String) -> [NoteSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list() }
        return list().filter { load($0.id).lowercased().contains(q) }
    }
}
