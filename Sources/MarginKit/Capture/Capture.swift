import AppKit

/// CONTRACTS (Wave 0). Loop F implements ScreenCapture + BrowserClip; Loop E implements LinkMetadata.

@MainActor
public enum ScreenCapture {
    /// Lets the user drag a region (system picker), then returns PNG data, or nil if cancelled.
    public static func captureRegion(_ completion: @escaping (Data?) -> Void) { completion(nil) }
}

@MainActor
public enum BrowserClip {
    public struct Tab: Sendable { public let url: URL; public let title: String }
    /// URL + title of the front tab in Chrome / Arc / Brave / Edge / Safari, whichever is frontmost or running.
    public static func frontTab(_ completion: @escaping (Tab?) -> Void) { completion(nil) }
}

@MainActor
public enum LinkMetadata {
    /// Page title for a URL (LinkPresentation), or nil.
    public static func title(for url: URL, _ completion: @escaping (String?) -> Void) { completion(nil) }
}
