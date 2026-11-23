import AppKit
import MarginKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)   // the logo lives in the Dock
    withExtendedLifetime(delegate) { app.run() }
}
