import Foundation

/// Content-addressed media store: `assets/<sha256-prefix>.<ext>`, deduplicated.
/// CONTRACT (Wave 0). Loop A implements.
public final class AssetStore {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    /// Copies a file in; returns the path relative to the notes folder, e.g. "assets/7f3a…c1.png".
    public func importFile(at url: URL) throws -> String {
        throw CocoaError(.featureUnsupported)
    }

    /// Writes raw data (e.g. a pasted screenshot) with the given extension ("png").
    public func importData(_ data: Data, ext: String) throws -> String {
        throw CocoaError(.featureUnsupported)
    }

    /// Resolves "assets/x.png" to an absolute URL.
    public func url(for relativePath: String) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(relativePath)
    }
}
