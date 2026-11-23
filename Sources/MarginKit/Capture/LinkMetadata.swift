import AppKit
import LinkPresentation

/// Page titles for link cards, fetched with LinkPresentation (Loop E).
@MainActor
public enum LinkMetadata {
    /// Titles already fetched this session, keyed by URL.
    private static var cache: [URL: String] = [:]
    /// Callers waiting on a fetch already in flight for the same URL.
    private static var waiting: [URL: [(String?) -> Void]] = [:]
    /// Each provider can be used only once and must stay alive until it completes.
    private static var providers: [URL: LPMetadataProvider] = [:]

    /// Page title for a URL (LinkPresentation), or nil. The completion runs on the main thread, exactly once.
    public static func title(for url: URL, _ completion: @escaping (String?) -> Void) {
        if let cached = cache[url] { completion(cached); return }
        if waiting[url] != nil { waiting[url]?.append(completion); return }
        waiting[url] = [completion]

        let provider = LPMetadataProvider()
        provider.timeout = 6
        providers[url] = provider
        let callback = MainCallback<String?> { title in finish(url, title) }
        provider.startFetchingMetadata(for: url) { metadata, _ in
            // Read the title here: LPLinkMetadata itself must not cross threads.
            let raw = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            callback.fire(raw?.isEmpty == false ? raw : nil)
        }
    }

    private static func finish(_ url: URL, _ title: String?) {
        providers[url] = nil
        if let title { cache[url] = title }
        let completions = waiting.removeValue(forKey: url) ?? []
        for c in completions { c(title) }
    }
}
