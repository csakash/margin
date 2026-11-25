import Foundation

/// A global shortcut the user can rebind in Settings.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case toggle    // fold / unfold the panel ("Show / Minimise")
    case newNote

    public var title: String {
        switch self {
        case .toggle: return "Show / Minimise Margin"
        case .newNote: return "New Note"
        }
    }

    /// Shorter name for messages ("Already used for New Note.").
    public var shortTitle: String {
        switch self {
        case .toggle: return "Show / Minimise"
        case .newNote: return "New Note"
        }
    }

    public var defaultShortcut: Shortcut {
        switch self {
        case .toggle: return Shortcut(keyCode: Shortcut.Key.space, modifiers: Shortcut.Mod.option)
        case .newNote: return Shortcut(keyCode: Shortcut.Key.n, modifiers: Shortcut.Mod.option)
        }
    }
}

/// A key plus modifiers. `keyCode` is a macOS virtual key code (kVK_*); `modifiers` is a Carbon
/// mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000), the same numbers
/// HotkeyCenter.Combo and RegisterEventHotKey use. Kept free of Carbon/AppKit so it is unit-testable.
public struct Shortcut: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    /// Stray bits (caps lock, fn, device flags) are dropped, so equal-looking shortcuts compare equal.
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Mod.all
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try c.decode(UInt32.self, forKey: .keyCode),
                  modifiers: try c.decode(UInt32.self, forKey: .modifiers))
    }

    public enum Mod {
        public static let command: UInt32 = 0x100
        public static let shift: UInt32 = 0x200
        public static let option: UInt32 = 0x800
        public static let control: UInt32 = 0x1000
        public static let all: UInt32 = command | shift | option | control
    }

    public enum Key {
        public static let space: UInt32 = 0x31
        public static let n: UInt32 = 0x2D
        public static let m: UInt32 = 0x2E
        public static let escape: UInt32 = 0x35
        public static let leftArrow: UInt32 = 0x7B
        public static let rightArrow: UInt32 = 0x7C
        public static let downArrow: UInt32 = 0x7D
        public static let upArrow: UInt32 = 0x7E
    }

    /// Modifier symbols in Apple's order (⌃⌥⇧⌘).
    public var modifierSymbols: [String] {
        var out: [String] = []
        if modifiers & Mod.control != 0 { out.append("⌃") }
        if modifiers & Mod.option != 0 { out.append("⌥") }
        if modifiers & Mod.shift != 0 { out.append("⇧") }
        if modifiers & Mod.command != 0 { out.append("⌘") }
        return out
    }

    public var keyName: String { Self.keyNames[keyCode] ?? "Key\(keyCode)" }

    /// "⌥Space", "⌃⌥M", "⇧⌘F5".
    public var displayString: String { modifierSymbols.joined() + keyName }

    /// One keycap per modifier plus the key: ["⌥", "Space"].
    public var keycaps: [String] { modifierSymbols + [keyName] }

    /// The modifier symbols for a mask on its own, for the recorder's live hint ("⌃⌥…").
    public static func symbols(forModifiers mask: UInt32) -> String {
        Shortcut(keyCode: 0, modifiers: mask).modifierSymbols.joined()
    }

    /// US-ANSI names. Unknown codes render as "Key<code>".
    static let keyNames: [UInt32: String] = {
        var m: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
            0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
            0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
            0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
            0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
            0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x33: "Delete", 0x35: "Esc", 0x75: "Forward Delete",
            0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        ]
        let fKeys: [(UInt32, Int)] = [
            (0x7A, 1), (0x78, 2), (0x63, 3), (0x76, 4), (0x60, 5), (0x61, 6), (0x62, 7), (0x64, 8),
            (0x65, 9), (0x6D, 10), (0x67, 11), (0x6F, 12), (0x69, 13), (0x6B, 14), (0x71, 15), (0x6A, 16),
            (0x40, 17), (0x4F, 18), (0x50, 19), (0x5A, 20),
        ]
        for (code, n) in fKeys { m[code] = "F\(n)" }
        return m
    }()

    /// Keys that can never be a shortcut: Esc, Return, keypad Enter, Tab, Delete, Forward Delete,
    /// Caps Lock, Fn, and the modifier keys themselves.
    static let reservedKeyCodes: Set<UInt32> = [
        0x35, 0x24, 0x4C, 0x30, 0x33, 0x75, 0x39, 0x3F,
        0x36, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
    ]

    static let arrowKeyCodes: Set<UInt32> = [Key.leftArrow, Key.rightArrow, Key.upArrow, Key.downArrow]
}

public enum ShortcutValidation: Equatable, Sendable {
    case ok
    case needsModifier
    case reservedKey
    case duplicate(ShortcutAction)

    /// The inline message the Settings window shows, or nil when ok.
    public var message: String? {
        switch self {
        case .ok: return nil
        case .needsModifier: return "Use at least one of ⌘ ⌥ ⌃."
        case .reservedKey: return "That key can't be a shortcut."
        case .duplicate(let other): return "Already used for \(other.shortTitle)."
        }
    }
}

public extension Notification.Name {
    /// Posted after a shortcut binding changes (rebind or reset).
    static let marginShortcutsChanged = Notification.Name("margin.shortcutsChanged")
}

/// Reads and writes the bindings: one UserDefaults key per action, `margin.shortcut.<rawValue>`,
/// holding JSON `{"keyCode":49,"modifiers":2048}`. Missing or corrupt values read as the default.
public struct ShortcutStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func key(for action: ShortcutAction) -> String { "margin.shortcut.\(action.rawValue)" }

    public func shortcut(for action: ShortcutAction) -> Shortcut {
        storedShortcut(for: action) ?? action.defaultShortcut
    }

    /// The stored value only (nil when unset or unreadable).
    public func storedShortcut(for action: ShortcutAction) -> Shortcut? {
        guard let data = defaults.data(forKey: Self.key(for: action)) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    public func set(_ shortcut: Shortcut, for action: ShortcutAction) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: Self.key(for: action))
    }

    public func reset(_ action: ShortcutAction) {
        defaults.removeObject(forKey: Self.key(for: action))
    }

    /// Checks, in order: a ⌘/⌥/⌃ modifier, a usable key, no clash with another action.
    /// Whether macOS or another app already holds the combo is HotkeyCenter's job (it needs Carbon).
    public func validate(_ shortcut: Shortcut, for action: ShortcutAction) -> ShortcutValidation {
        let m = shortcut.modifiers
        if m & (Shortcut.Mod.command | Shortcut.Mod.option | Shortcut.Mod.control) == 0 { return .needsModifier }
        if Shortcut.reservedKeyCodes.contains(shortcut.keyCode) { return .reservedKey }
        // ⌃⌥ + arrows walk the panel between anchors.
        if Shortcut.arrowKeyCodes.contains(shortcut.keyCode), m == Shortcut.Mod.control | Shortcut.Mod.option {
            return .reservedKey
        }
        for other in ShortcutAction.allCases where other != action && self.shortcut(for: other) == shortcut {
            return .duplicate(other)
        }
        return .ok
    }
}
