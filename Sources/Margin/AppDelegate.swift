import AppKit
import MarginCore
import MarginKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: NoteStore!
    private var editor: EditorController!
    private var glass: GlassView!
    private var panel: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = try? NoteStore()
        editor = EditorController()
        glass = GlassView(frame: NSRect(origin: .zero, size: Theme.defaultPanelSize))

        editor.scrollView.frame = glass.contentView.bounds.insetBy(dx: 0, dy: 24)
        editor.scrollView.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(editor.scrollView)

        panel = PanelController(contentView: glass)
        panel.show()

        let id = store.list().first?.id ?? store.create(initialText: "# Hello, Margin\n\nStart typing.")
        editor.text = store.load(id)
        editor.onChange = { [weak self] text in self?.store.save(id, text: text) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.toggleMinimised()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { store.flush() }
}
