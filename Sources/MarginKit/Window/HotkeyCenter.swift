import AppKit
import Carbon.HIToolbox
import MarginCore

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    public struct Combo: Hashable, Sendable {
        public let keyCode: UInt32          // kVK_* virtual key code
        public let modifiers: UInt32        // Carbon modifiers: optionKey, controlKey, cmdKey, shiftKey
        public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    }

    /// Four-char signature for our hotkey ids: 'MRGN'.
    private static let signature: OSType = 0x4D52_474E

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    private init() {}

    /// Registers a global hotkey. Returns its id (for `unregister`), or nil if the combo is taken.
    @discardableResult
    public func register(_ combo: Combo, handler: @escaping () -> Void) -> UInt32? {
        guard installHandlerIfNeeded() else { return nil }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        hotKeys[id] = ref
        handlers[id] = handler
        return id
    }

    /// Removes one hotkey registered by `register`. Unknown ids are ignored.
    public func unregister(_ id: UInt32) {
        if let ref = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    /// Whether Margin could own this combo right now: macOS has no enabled system shortcut on it
    /// (Spotlight, input sources, Mission Control…) and RegisterEventHotKey accepts it. The trial
    /// registration is removed straight away. A combo Margin itself holds reports false.
    public func isAvailable(_ combo: Combo) -> Bool {
        if Self.isSystemShortcut(combo) { return false }
        guard let id = register(combo, handler: {}) else { return false }
        unregister(id)
        return true
    }

    /// Enabled entries in the system's symbolic hotkeys (System Settings › Keyboard Shortcuts).
    /// Their modifiers use the same Carbon mask as Combo.
    public static func isSystemShortcut(_ combo: Combo) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = Shortcut.Mod.all
        return entries.contains { e in
            (e[kHISymbolicHotKeyEnabled as String] as? Bool ?? false)
                && (e[kHISymbolicHotKeyCode as String] as? Int).map(UInt32.init) == combo.keyCode
                && (e[kHISymbolicHotKeyModifiers as String] as? Int).map { UInt32($0) & mask } == combo.modifiers & mask
        }
    }

    /// Registers ⌃⌥ + ←→↑↓. `nudge` receives (dx, dy) in anchor-grid steps; up is dy = -1.
    @discardableResult
    public func registerArrowNudges(_ nudge: @escaping (_ dx: Int, _ dy: Int) -> Void) -> Bool {
        let a = Combo.ctrlOptionArrows
        let results = [
            register(a.left) { nudge(-1, 0) },
            register(a.right) { nudge(1, 0) },
            register(a.up) { nudge(0, -1) },
            register(a.down) { nudge(0, 1) },
        ]
        return !results.contains(nil)
    }

    public func unregisterAll() {
        for ref in hotKeys.values { UnregisterEventHotKey(ref) }
        hotKeys.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), marginHotKeyCallback, 1, &spec, nil, &eventHandler)
        return status == noErr
    }
}

public extension HotkeyCenter.Combo {
    /// A user binding (ShortcutStore). The defaults, ⌥Space and ⌥N, live in ShortcutAction.
    init(_ shortcut: Shortcut) { self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) }
    /// ⌃⌥ + arrows: walk the 8 anchors.
    static let ctrlOptionArrows: (left: HotkeyCenter.Combo, right: HotkeyCenter.Combo, up: HotkeyCenter.Combo, down: HotkeyCenter.Combo) = {
        let m = UInt32(controlKey | optionKey)
        return (HotkeyCenter.Combo(keyCode: UInt32(kVK_LeftArrow), modifiers: m),
                HotkeyCenter.Combo(keyCode: UInt32(kVK_RightArrow), modifiers: m),
                HotkeyCenter.Combo(keyCode: UInt32(kVK_UpArrow), modifiers: m),
                HotkeyCenter.Combo(keyCode: UInt32(kVK_DownArrow), modifiers: m))
    }()
}

/// Carbon callback (C function pointer, so no captures). Dispatches to the main actor.
private func marginHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) }
    }
    return noErr
}
