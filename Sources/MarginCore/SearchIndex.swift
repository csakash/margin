import Foundation
import SQLite3

/// SQLite FTS5 index at `.margin/index.sqlite`. Rebuildable from the markdown files at any time.
/// Not thread-safe: use it from one thread (the store uses it on main).
public final class SearchIndex {
    private var db: OpaquePointer?
    private var deleteStmt: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var searchStmt: OpaquePointer?
    private var clearStmt: OpaquePointer?

    struct SQLiteError: Error, CustomStringConvertible {
        let message: String
        var description: String { "SQLite: \(message)" }
    }

    /// SQLITE_TRANSIENT: SQLite copies the bound text before the call returns.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        do {
            try open(url)
        } catch {
            // The index is only a cache: if it is unreadable, start over.
            close()
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            try open(url)
        }
    }

    deinit { close() }

    private func open(_ url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(message: msg)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=OFF")
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS notes USING fts5(
                id UNINDEXED, title, body, tokenize='unicode61 remove_diacritics 2')
            """)
        deleteStmt = try prepare("DELETE FROM notes WHERE id = ?")
        insertStmt = try prepare("INSERT INTO notes(id, title, body) VALUES (?, ?, ?)")
        // Title matches weigh more than body matches (column order: id, title, body).
        searchStmt = try prepare("""
            SELECT id FROM notes WHERE notes MATCH ? ORDER BY bm25(notes, 0.0, 4.0, 1.0) LIMIT ?
            """)
        clearStmt = try prepare("DELETE FROM notes")
    }

    private func close() {
        for s in [deleteStmt, insertStmt, searchStmt, clearStmt] { sqlite3_finalize(s) }
        deleteStmt = nil; insertStmt = nil; searchStmt = nil; clearStmt = nil
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    @discardableResult
    private func run(_ stmt: OpaquePointer?, _ bind: (OpaquePointer?) -> Void = { _ in }) -> Bool {
        guard let stmt else { return false }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, Self.transient)
    }

    public func upsert(id: NoteID, title: String, body: String) {
        run(deleteStmt) { self.bind($0, 1, id.raw) }
        run(insertStmt) {
            self.bind($0, 1, id.raw)
            self.bind($0, 2, title)
            self.bind($0, 3, body)
        }
    }

    public func remove(id: NoteID) {
        run(deleteStmt) { self.bind($0, 1, id.raw) }
    }

    /// Prefix-matching full-text search, best match first.
    public func search(_ query: String, limit: Int = 200) -> [NoteID] {
        guard let match = Self.matchExpression(for: query), let stmt = searchStmt else { return [] }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        bind(stmt, 1, match)
        sqlite3_bind_int64(stmt, 2, Int64(max(limit, 0)))
        var out: [NoteID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(NoteID(String(cString: c))) }
        }
        return out
    }

    public func removeAll() {
        run(clearStmt)
    }

    /// Runs `body` inside one transaction (much faster for bulk upserts).
    public func performBatch(_ body: () throws -> Void) rethrows {
        let began = (try? exec("BEGIN")) != nil
        defer { if began { try? exec("COMMIT") } }
        try body()
    }

    /// Turns user input into an FTS5 expression: every term becomes a quoted prefix
    /// phrase (`"term"*`), all of which must match. Returns nil if nothing is searchable.
    static func matchExpression(for query: String) -> String? {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
