import AppKit

/// CONTRACTS (Wave 0). Loop F implements ScreenCapture + BrowserClip (see ScreenCapture.swift, BrowserClip.swift);
/// Loop E implements LinkMetadata.

@MainActor
public enum LinkMetadata {
    /// Page title for a URL (LinkPresentation), or nil.
    public static func title(for url: URL, _ completion: @escaping (String?) -> Void) { completion(nil) }
}
