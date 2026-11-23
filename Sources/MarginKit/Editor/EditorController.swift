import AppKit

/// The markdown editor: an NSTextView (TextKit 2) that styles markdown live.
/// CONTRACT (Wave 0). Loop B implements styling, shortcuts and the `/` menu.
/// Loop E adds media (drop/paste) through the importer closures below.
@MainActor
public final class EditorController: NSObject {

    public let scrollView: NSScrollView
    public let textView: MarkdownTextView

    /// Called (debounce is the store's job) whenever the user edits the text.
    public var onChange: ((String) -> Void)?
    /// Copies a dropped/pasted file into the notes folder; returns "assets/…" or nil. Set by integration.
    public var importFile: ((URL) -> String?)?
    /// Stores raw image data (pasted screenshot); returns "assets/…" or nil. Set by integration.
    public var importData: ((Data, String) -> String?)?
    /// Resolves "assets/…" to a file URL for display. Set by integration.
    public var resolveAsset: ((String) -> URL)?
    /// Called when the user picks Screenshot / Clip tab / Image from the `/` menu or toolbar.
    public var onAction: ((EditorAction) -> Void)?

    public enum EditorAction: Sendable { case image, screenshot, clipTab }

    public override init() {
        textView = MarkdownTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView()
        super.init()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.drawsBackground = false
        textView.font = Theme.ui(14.5)
        textView.textColor = Theme.text
        textView.insertionPointColor = .white
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
    }

    /// The full markdown text of the open note.
    public var text: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    public func focus() { textView.window?.makeFirstResponder(textView) }

    /// Toolbar / `/` menu: set the block type of the caret's line (toggle back to text if same).
    public func apply(_ kind: BlockKind) {}

    /// Insert at the caret as its own paragraph(s).
    public func insertImage(relativePath: String, caption: String? = nil) {}
    public func insertLink(url: URL, title: String?) {}
    public func insertQuote(_ text: String, source: URL?) {}
}

extension EditorController: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) { onChange?(textView.string) }
}

/// Subclass hook for key handling, drag & drop and click-on-attachment.
public final class MarkdownTextView: NSTextView {}
