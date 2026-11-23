import AppKit

@MainActor
public enum BrowserClip {
    public struct Tab: Sendable { public let url: URL; public let title: String }

    private struct Browser {
        let bundleID: String
        let script: String
    }

    private static func chromium(_ name: String, _ id: String) -> Browser {
        Browser(bundleID: id, script: """
            tell application "\(name)" to return {URL of active tab of front window, title of active tab of front window}
            """)
    }

    private static let browsers: [Browser] = [
        chromium("Google Chrome", "com.google.Chrome"),
        chromium("Google Chrome Beta", "com.google.Chrome.beta"),
        chromium("Google Chrome Dev", "com.google.Chrome.dev"),
        chromium("Google Chrome Canary", "com.google.Chrome.canary"),
        chromium("Arc", "company.thebrowser.Browser"),
        chromium("Brave Browser", "com.brave.Browser"),
        chromium("Microsoft Edge", "com.microsoft.edgemac"),
        chromium("Chromium", "org.chromium.Chromium"),
        chromium("Vivaldi", "com.vivaldi.Vivaldi"),
        Browser(bundleID: "com.apple.Safari", script: """
            tell application "Safari" to return {URL of current tab of front window, name of current tab of front window}
            """),
    ]

    private static func browser(for bundleID: String?) -> Browser? {
        guard let bundleID else { return nil }
        return browsers.first { $0.bundleID == bundleID }
    }

    // MARK: Tracking the last active browser

    private static var observer: NSObjectProtocol?
    private static var lastBrowserID: String?

    /// Starts remembering which supported browser was active most recently. Safe to call repeatedly.
    public static func startTracking() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, browser(for: front) != nil {
            lastBrowserID = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated {
                if browser(for: id) != nil { lastBrowserID = id }
            }
        }
    }

    // MARK: Front tab

    private static let queue = DispatchQueue(label: "app.margin.browserclip")

    /// URL + title of the front tab in Chrome / Arc / Brave / Edge / Chromium / Vivaldi / Safari:
    /// the frontmost browser, else the most recently active one, else the first running one.
    /// The completion is called on the main thread exactly once.
    public static func frontTab(_ completion: @escaping (Tab?) -> Void) {
        startTracking()
        let callback = MainCallback<Tab?>(completion)
        guard let target = pickTarget() else { callback.fire(nil); return }
        let source = target.script
        let bundleID = target.bundleID

        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            var tab: Tab?
            if let error {
                NSLog("Margin: BrowserClip AppleScript error for \(bundleID): \(error)")
            } else if let result,
                      let urlString = result.atIndex(1)?.stringValue,
                      let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme != nil {
                let raw = result.atIndex(2)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                tab = Tab(url: url, title: raw.isEmpty ? (url.host ?? url.absoluteString) : raw)
            } else {
                NSLog("Margin: BrowserClip got no tab from \(bundleID)")
            }
            callback.fire(tab)
        }
    }

    private static func pickTarget() -> Browser? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let front = browser(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { return front }
        if let last = browser(for: lastBrowserID), running.contains(last.bundleID) { return last }
        return browsers.first { running.contains($0.bundleID) }
    }
}
