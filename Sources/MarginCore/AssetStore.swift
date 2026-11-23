import CryptoKit
import Foundation

/// Content-addressed media store: `assets/<sha256-prefix>.<ext>`, deduplicated.
public final class AssetStore {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    /// Copies a file in; returns the path relative to the notes folder, e.g. "assets/7f3a…c1.png".
    /// A file with identical content is stored only once.
    public func importFile(at url: URL) throws -> String {
        let name = Self.fileName(hash: try Self.sha256(ofFileAt: url), ext: url.pathExtension)
        try ensureFolder()
        let dest = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            // Copy next to the destination, then move into place, so a half-copied
            // file is never visible under its final name.
            let temp = folder.appendingPathComponent(".import-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: url, to: temp)
            do {
                try FileManager.default.moveItem(at: temp, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                if !FileManager.default.fileExists(atPath: dest.path) { throw error }
            }
        }
        return relativePath(name)
    }

    /// Writes raw data (e.g. a pasted screenshot) with the given extension ("png").
    public func importData(_ data: Data, ext: String) throws -> String {
        let digest = SHA256.hash(data: data)
        let name = Self.fileName(hash: Self.hex(digest), ext: ext)
        try ensureFolder()
        let dest = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try data.write(to: dest, options: .atomic)
        }
        return relativePath(name)
    }

    /// Resolves "assets/x.png" to an absolute URL.
    public func url(for relativePath: String) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(relativePath)
    }

    // MARK: - Helpers

    private func relativePath(_ name: String) -> String {
        folder.lastPathComponent + "/" + name
    }

    private func ensureFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func fileName(hash: String, ext: String) -> String {
        let prefix = String(hash.prefix(16))
        let e = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return e.isEmpty ? prefix : "\(prefix).\(e)"
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file through SHA-256 in 1 MB chunks, so large videos never load whole.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
}
