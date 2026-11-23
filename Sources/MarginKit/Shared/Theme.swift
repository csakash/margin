import AppKit
import QuartzCore

/// The 8 places the panel can live: 4 edges (centred) and 4 corners.
public enum Anchor: String, CaseIterable, Codable, Sendable {
    case topLeft = "tl", top = "t", topRight = "tr", right = "r"
    case bottomRight = "br", bottom = "b", bottomLeft = "bl", left = "l"

    public var isCorner: Bool { rawValue.count == 2 }
    public var isVerticalEdge: Bool { self == .left || self == .right }
    public var hasLeft: Bool { rawValue.contains("l") }
    public var hasRight: Bool { rawValue.contains("r") }
    public var hasTop: Bool { rawValue.contains("t") }
    public var hasBottom: Bool { rawValue.contains("b") }

    /// Column/row in a 3×3 grid (centre unused). Used by ⌃⌥+arrow nudging.
    public var grid: (x: Int, y: Int) {
        (hasLeft ? 0 : hasRight ? 2 : 1, hasTop ? 0 : hasBottom ? 2 : 1)
    }

    public static func at(x: Int, y: Int) -> Anchor? {
        allCases.first { $0.grid.x == x && $0.grid.y == y }
    }

    public var displayName: String {
        switch self {
        case .topLeft: "Top left"; case .top: "Top"; case .topRight: "Top right"; case .right: "Right"
        case .bottomRight: "Bottom right"; case .bottom: "Bottom"; case .bottomLeft: "Bottom left"; case .left: "Left"
        }
    }
}

/// Block types the toolbar and `/` menu can apply to the current line.
public enum BlockKind: String, CaseIterable, Sendable {
    case paragraph, heading1, heading2, heading3, bullet, numbered, todo, quote, code, divider

    /// Markdown prefix written at the start of the line.
    public var prefix: String {
        switch self {
        case .paragraph: ""; case .heading1: "# "; case .heading2: "## "; case .heading3: "### "
        case .bullet: "- "; case .numbered: "1. "; case .todo: "- [ ] "; case .quote: "> "
        case .code: "```"; case .divider: "---"
        }
    }

    public var title: String {
        switch self {
        case .paragraph: "Text"; case .heading1: "Heading 1"; case .heading2: "Heading 2"; case .heading3: "Heading 3"
        case .bullet: "Bullet list"; case .numbered: "Numbered list"; case .todo: "To-do"; case .quote: "Quote"
        case .code: "Code"; case .divider: "Divider"
        }
    }
}

/// Design tokens, matching design/mockup.html.
public enum Theme {
    // Colours
    public static let text = NSColor(white: 0.95, alpha: 1)
    public static let textSecondary = NSColor(white: 0.64, alpha: 1)
    public static let textTertiary = NSColor(white: 0.40, alpha: 1)
    public static let hairline = NSColor(white: 1, alpha: 0.07)
    public static let glassTop = NSColor(red: 30/255, green: 30/255, blue: 33/255, alpha: 0.80)
    public static let glassBottom = NSColor(red: 6/255, green: 6/255, blue: 7/255, alpha: 0.90)
    public static let glow = NSColor.white

    // Geometry
    public static let cornerRadius: CGFloat = 26
    public static let panelMargin: CGFloat = 16
    public static let nubMargin: CGFloat = 6
    public static let nubLong: CGFloat = 84
    public static let nubThin: CGFloat = 8
    public static let nubCorner: CGFloat = 18
    public static let defaultPanelSize = NSSize(width: 440, height: 600)
    public static let minPanelSize = NSSize(width: 340, height: 380)
    public static let headerHeight: CGFloat = 48
    public static let toolbarHeight: CGFloat = 50

    // Motion
    /// iOS-sheet / Vaul curve: cubic-bezier(.32,.72,0,1)
    public static let spring = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    /// ease-out-quint-ish: cubic-bezier(.23,1,.32,1)
    public static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    public static let morphDuration: TimeInterval = 0.5
    public static let sheenDuration: TimeInterval = 1.15

    public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    public static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    // Type
    public static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    public static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }
}
