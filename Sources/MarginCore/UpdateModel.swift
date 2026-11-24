import Foundation

/// What an available update is, in the terms the update card shows.
public struct UpdateInfo: Equatable, Sendable {
    /// Display version, e.g. "0.2.1".
    public let version: String
    /// Up to 5 plain-text release-note lines.
    public let notes: [String]

    public init(version: String, notes: [String]) {
        self.version = version
        self.notes = notes
    }
}

/// Every state the updater can be in. The updater reports these; the card and the nub draw them.
public enum UpdatePhase: Equatable, Sendable {
    case idle
    /// The user asked for a check.
    case checking
    /// Found but not downloaded (only reached from a manual check).
    case available(UpdateInfo)
    /// Fraction is 0...1.
    case downloading(UpdateInfo, Double)
    /// Downloaded; one click restarts into it.
    case ready(UpdateInfo)
    case installing(UpdateInfo)
    /// Carries the version that is running.
    case upToDate(String)
    /// Carries a one-line message.
    case failed(String)
    /// After the relaunch into a new version: "You're on Margin x", shown once.
    case installed(UpdateInfo)

    /// The card is visible for everything except `.idle`.
    public var showsCard: Bool { self != .idle }

    /// The minimised nub glows only when an update is downloaded and waiting.
    public var showsNubDot: Bool {
        if case .ready = self { return true }
        return false
    }

    /// States that go away by themselves, and after how long.
    public var autoDismissAfter: TimeInterval? {
        switch self {
        case .upToDate: return 3
        case .installed: return 6
        default: return nil
        }
    }
}

/// The update that is downloaded and waiting, remembered across the relaunch so the new version
/// can say "You're on Margin x" once.
public struct PendingUpdate: Codable, Equatable, Sendable {
    public let version: String
    public let notes: [String]

    public init(_ info: UpdateInfo) {
        version = info.version
        notes = info.notes
    }

    public var info: UpdateInfo { UpdateInfo(version: version, notes: notes) }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// nil for missing or unreadable data, or a version that does not look like one.
    public static func decode(_ data: Data?) -> PendingUpdate? {
        guard let data, let p = try? JSONDecoder().decode(PendingUpdate.self, from: data),
              ReleaseNotes.safeVersion(p.version) != nil else { return nil }
        return p
    }
}

public enum ReleaseNotes {
    /// A version string from the feed, if it looks like one: up to 20 of `0-9 A-Z a-z . - +`,
    /// starting with a digit. Anything else is refused, so a feed cannot put a sentence in the
    /// card title or the menu.
    public static func safeVersion(_ raw: String?) -> String? {
        guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              v.range(of: "\\A[0-9][0-9A-Za-z.+-]{0,19}\\z", options: .regularExpression) != nil else { return nil }
        return v
    }

    public static let maxLines = 5
    public static let maxLineLength = 120

    /// Turns an appcast `<description>` (HTML or plain text) into at most 5 plain lines.
    /// Tags and entities are removed; nothing from the feed is ever rendered as markup.
    public static func lines(from description: String?) -> [String] {
        guard var s = description, !s.isEmpty else { return [] }
        // Block-level tags become line breaks, every other tag disappears.
        s = s.replacingOccurrences(of: "<\\s*/?\\s*(li|br|p|div|ul|ol|h[1-6])\\b[^>]*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        // A tag starts with a letter, "/" or "!"; a bare "<" in prose ("a < b") is kept.
        s = s.replacingOccurrences(of: "<[/!A-Za-z][^>]*>", with: "", options: .regularExpression)
        // `&amp;` goes last so "&amp;lt;" stays the literal text "&lt;".
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        var out: [String] = []
        for raw in s.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "• ", "* "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            if line.count > maxLineLength { line = String(line.prefix(maxLineLength - 1)) + "…" }
            out.append(line)
            if out.count == maxLines { break }
        }
        return out
    }
}
