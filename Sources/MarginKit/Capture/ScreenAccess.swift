import AppKit
import CoreGraphics

/// Screen Recording permission, which region screenshots need. macOS shows its own prompt the
/// first time it is requested; after the user switches Margin on, the grant only takes effect
/// once Margin restarts.
@MainActor
public enum ScreenAccess {
    private static let requestedKey = "margin.screenAccessRequested"

    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// True once Margin has asked macOS (from the tour or the notice card).
    public static var wasRequested: Bool { UserDefaults.standard.bool(forKey: requestedKey) }

    /// Shows macOS's prompt (the first time) and adds Margin to the list in System Settings.
    /// Only called from an explicit "Allow" button, never from a screenshot.
    @discardableResult
    public static func request() -> Bool {
        UserDefaults.standard.set(true, forKey: requestedKey)
        return CGRequestScreenCaptureAccess()
    }

    /// System Settings › Privacy & Security › Screen & System Audio Recording.
    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quits and opens Margin again, so a new grant takes effect. A tiny shell waits for this
    /// process to exit before opening the app, so two copies (and their hotkeys) never overlap.
    public static func relaunch() {
        let bundle = Bundle.main.bundleURL
        // Unbundled (swift run): there is no app to open again.
        guard bundle.pathExtension == "app" else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits at most ~10 s; if Margin did not quit by then, it does not reopen it later.
        p.arguments = ["-c", "i=0; while /bin/kill -0 \(pid) 2>/dev/null; do i=$((i+1)); [ $i -gt 50 ] && exit 0; /bin/sleep 0.2; done; /usr/bin/open \"$0\"", bundle.path]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("Margin: could not relaunch: %@", error.localizedDescription)
        }
    }
}
