import AppKit

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
/// CONTRACT (Wave 0). Loop C implements.
@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    public struct Combo: Hashable, Sendable {
        public let keyCode: UInt32          // kVK_* virtual key code
        public let modifiers: UInt32        // Carbon modifiers: optionKey, controlKey, cmdKey, shiftKey
        public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    }

    /// Registers a global hotkey. Returns false if the combo is taken.
    @discardableResult
    public func register(_ combo: Combo, handler: @escaping () -> Void) -> Bool { false }

    public func unregisterAll() {}
}
