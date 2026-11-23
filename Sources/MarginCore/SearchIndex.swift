import Foundation

/// SQLite FTS5 index at `.margin/index.sqlite`. Rebuildable from the markdown files at any time.
/// CONTRACT (Wave 0). Loop A implements with the system SQLite3 module.
public final class SearchIndex {
    public init(url: URL) throws {}
    public func upsert(id: NoteID, title: String, body: String) {}
    public func remove(id: NoteID) {}
    /// Prefix-matching full-text search, best match first.
    public func search(_ query: String, limit: Int = 200) -> [NoteID] { [] }
    public func removeAll() {}
}
