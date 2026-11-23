import Foundation

/// Stable identifier for a note. Stored in the note's front-matter as `id:`.
public struct NoteID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public static func make() -> NoteID {
        NoteID(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased())
    }
    public var description: String { raw }
}

/// Counts shown on drawer cards and used by the drawer filters.
public struct NoteStats: Hashable, Sendable {
    public var title: String
    public var snippet: String
    public var todos: Int
    public var done: Int
    public var media: Int
    public var links: Int
    public var quotes: Int

    public init(title: String = "Untitled", snippet: String = "", todos: Int = 0, done: Int = 0,
                media: Int = 0, links: Int = 0, quotes: Int = 0) {
        self.title = title; self.snippet = snippet; self.todos = todos; self.done = done
        self.media = media; self.links = links; self.quotes = quotes
    }
}

/// What the drawer needs to draw one card, without loading the whole note.
public struct NoteSummary: Identifiable, Hashable, Sendable {
    public let id: NoteID
    public var stats: NoteStats
    public var updated: Date
    public var fileURL: URL

    public var title: String { stats.title }
    public var snippet: String { stats.snippet }

    public init(id: NoteID, stats: NoteStats, updated: Date, fileURL: URL) {
        self.id = id; self.stats = stats; self.updated = updated; self.fileURL = fileURL
    }
}
