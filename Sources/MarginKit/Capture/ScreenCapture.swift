import AppKit
import CoreGraphics

/// Carries a main-thread callback across a `@Sendable` boundary. It is only ever invoked on the main thread,
/// at most once.
final class MainCallback<T>: @unchecked Sendable {
    private var fn: ((T) -> Void)?
    init(_ fn: @escaping (T) -> Void) { self.fn = fn }

    func fire(_ value: T) {
        let run = {
            guard let f = self.fn else { return }
            self.fn = nil
            f(value)
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }
}

@MainActor
public enum ScreenCapture {
    private static var inFlight = false

    /// Lets the user drag a region (system picker), then returns PNG data, or nil if cancelled.
    /// The completion is called on the main thread exactly once.
    public static func captureRegion(_ completion: @escaping (Data?) -> Void) {
        let callback = MainCallback<Data?>(completion)
        guard !inFlight else { callback.fire(nil); return }
        inFlight = true

        // Without Screen Recording permission screencapture only sees the wallpaper. Ask once, then go ahead anyway.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        // Keep our own floating panels out of the shot.
        let hidden = NSApp.windows.filter { $0 is FloatingPanel && $0.isVisible }
        hidden.forEach { $0.orderOut(nil) }

        let finish: @MainActor (Data?) -> Void = { data in
            hidden.forEach { $0.orderFrontRegardless() }
            inFlight = false
            callback.fire(data)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-capture-\(UUID().uuidString).png")

        // Give the window server a moment to actually remove the panels.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-o", "-t", "png", url.path]
            process.terminationHandler = { _ in
                let data = readAndRemove(url)
                DispatchQueue.main.async { MainActor.assumeIsolated { finish(data) } }
            }
            do {
                try process.run()
            } catch {
                NSLog("Margin: screencapture failed to launch: \(error)")
                try? FileManager.default.removeItem(at: url)
                finish(nil)
            }
        }
    }

    /// Reads the capture (nil when the user cancelled: file missing or empty) and deletes it.
    nonisolated private static func readAndRemove(_ url: URL) -> Data? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }
}
