import AppKit
import AVFoundation
import ImageIO

/// Downsampled image / first-frame thumbnails for image lines, loaded off the main thread.
@MainActor
final class MediaCache {
    private let images = NSCache<NSString, NSImage>()
    private var aspects: [URL: CGFloat] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    /// Keeps video frame generators alive until they call back.
    private var generators: [String: AVAssetImageGenerator] = [:]

    /// A thumbnail finished loading: redraw.
    var onImageLoaded: (() -> Void)?
    /// A video's aspect ratio became known: paragraph heights must be recomputed.
    var onAspectChanged: (() -> Void)?

    init() { images.countLimit = 64 }

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// height / width, or nil while unknown (videos until their first frame loads, unreadable files).
    func aspect(for url: URL) -> CGFloat? {
        if let a = aspects[url] { return a }
        if Self.isVideo(url) { return nil }
        guard let a = Self.readAspect(url) else { return nil }
        aspects[url] = a
        return a
    }

    /// The cached thumbnail, or nil (and a background load is started).
    func image(for url: URL, maxPixel: CGFloat) -> NSImage? {
        let bucket = max(256, Int((maxPixel / 256).rounded(.up)) * 256)
        let key = "\(url.path)#\(bucket)"
        if let img = images.object(forKey: key as NSString) { return img }
        guard !loading.contains(key), !failed.contains(key) else { return nil }
        loading.insert(key)
        if Self.isVideo(url) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: bucket, height: bucket)
            generators[key] = gen
            gen.generateCGImageAsynchronously(for: .zero) { [weak self] cg, _, _ in
                DispatchQueue.main.async { self?.finish(key: key, url: url, image: cg) }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let cg = MediaCache.thumbnail(url, maxPixel: bucket)
                DispatchQueue.main.async { self?.finish(key: key, url: url, image: cg) }
            }
        }
        return nil
    }

    private func finish(key: String, url: URL, image cg: CGImage?) {
        loading.remove(key)
        generators[key] = nil
        guard let cg, cg.width > 0 else { failed.insert(key); onImageLoaded?(); return }
        images.setObject(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), forKey: key as NSString)
        let a = CGFloat(cg.height) / CGFloat(cg.width)
        if Self.isVideo(url), aspects[url] == nil || abs(aspects[url]! - a) > 0.001 {
            aspects[url] = a
            onAspectChanged?()
        }
        onImageLoaded?()
    }

    nonisolated static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated static func readAspect(_ url: URL) -> CGFloat? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return CGFloat((5...8).contains(orientation) ? w / h : h / w)
    }
}
