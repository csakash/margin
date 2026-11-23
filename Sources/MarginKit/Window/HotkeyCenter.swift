import AppKit
import Carbon.HIToolbox

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

    /// Registers a global hotkey. Returns false if the combo is taken.
    @discardableResult
    public func register(_ combo: Combo, handler: @escaping () -> Void) -> Bool {
        guard installHandlerIfNeeded() else { return false }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeys[id] = ref
        handlers[id] = handler
        return true
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
        return !results.contains(false)
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
    /// ⌥Space: minimise / expand.
    static let optionSpace = HotkeyCenter.Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    /// ⌥N: new note.
    static let optionN = HotkeyCenter.Combo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(optionKey))
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
