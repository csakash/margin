# SPEC: Configurable global shortcuts

Loop: `configurable-shortcuts` · Branch: `feat/configurable-shortcuts` · Repo: `margin` only

## Context

Margin's two main global hotkeys are hardcoded: ⌥Space folds and unfolds the panel, and ⌥N
starts a new note. Users can't move them. When another app (Alfred, Raycast, a launcher, an
IME) already owns ⌥Space, or a keyboard layout types a character on ⌥N, Margin's hotkey
fails to register and the user gets no error, so the app looks broken. This feature adds a
Settings window where the user records their own combo for each of the two actions. Margin
rejects combos it can't own and keeps the previous combo working.

## Current State (verified 2026-11-25 at `origin/main` 7129025)

| Hotkey | Action | Defined | Registered | Configurable | Clash handling |
|---|---|---|---|---|---|
| ⌥Space | Fold / unfold (and tour fold step) | `Sources/MarginKit/Window/HotkeyCenter.swift:74` | `Sources/Margin/AppDelegate.swift:241` | ❌ | ❌ return value ignored |
| ⌥N | New note | `HotkeyCenter.swift:76` | `AppDelegate.swift:245` | ❌ | ❌ return value ignored |
| ⌃⌥ ←→↑↓ | Nudge between anchors | `HotkeyCenter.swift:78-84` | `AppDelegate.swift:246` | ❌ (stays so) | ❌ |

- `HotkeyCenter.register(_:handler:)` (`HotkeyCenter.swift:27`) uses Carbon
  `RegisterEventHotKey`. It returns `false` when the combo is taken, and it needs no
  Accessibility permission.
- `HotkeyCenter` can only `unregisterAll()` (`:54`). It cannot remove a single hotkey.
- No Settings window exists. Prefs live in `UserDefaults` behind menu toggles (`Sounds.swift:18`,
  menus at `AppDelegate.swift:484-503` and `:515-531`).
- Hardcoded ⌥Space and ⌥N labels (all must follow the user's binding):

| File:line | Text |
|---|---|
| `Sources/MarginKit/MainView.swift:150` | tooltip `"New note  ⌥N"` |
| `Sources/MarginKit/MainView.swift:153` | tooltip `"Minimise  ⌥Space"` |
| `Sources/MarginKit/Onboarding/OnboardingView.swift:30` | tour copy `"⌥N starts a new one."` |
| `Sources/MarginKit/Onboarding/OnboardingView.swift:172` | keycaps `["⌥", "Space"]` |
| `Sources/MarginKit/Onboarding/OnboardingController.swift:234` | `"Now bring it back: ⌥ Space again"` |
| `Sources/Margin/AppDelegate.swift:609` | help/about text `"⌥ Space minimises it…"` |

Code comments that mention ⌥Space (`AppDelegate.swift:103,524,538`, `OnboardingController.swift:5,213,215`)
should be rewritten to say "the fold hotkey". They don't affect behavior.

- Tests: only `MarginCoreTests` exists, and it depends on `MarginCore` (no AppKit) (`Package.swift:29-32`).

## Proposed Change

### 1. Model (`MarginCore`, no AppKit, unit-testable)

New file `Sources/MarginCore/Shortcut.swift`:

```swift
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case toggle    // fold / unfold ("Show / Minimise")
    case newNote
    public var title: String      // "Show / Minimise Margin", "New Note"
    public var defaultShortcut: Shortcut   // ⌥Space, ⌥N
}

/// keyCode = macOS virtual key code (kVK_*); modifiers = Carbon mask
/// (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000). Same numbers HotkeyCenter.Combo uses.
public struct Shortcut: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public var displayString: String   // "⌃⌥⇧⌘" order + key name, e.g. "⌥Space", "⌃⌥M", "⌘⇧F5"
    public var keycaps: [String]       // ["⌥", "Space"] for the tour keycaps
}

public enum ShortcutValidation: Equatable { case ok, needsModifier, reservedKey, duplicate(ShortcutAction) }

public struct ShortcutStore {
    public init(defaults: UserDefaults = .standard)
    public func shortcut(for: ShortcutAction) -> Shortcut      // stored value or default
    public func set(_: Shortcut, for: ShortcutAction)
    public func reset(_: ShortcutAction)                        // removes the key -> default
    public func validate(_: Shortcut, for: ShortcutAction) -> ShortcutValidation
}
```

- Storage: one `UserDefaults` key per action, `margin.shortcut.<rawValue>`, holding JSON
  `{"keyCode":49,"modifiers":2048}`. A missing or corrupt value falls back to the default.
- Validation rules, checked in order:
  1. `needsModifier`: at least one of ⌘ ⌥ ⌃ is required (⇧ alone is not enough, since ⇧A types text).
     Extra modifiers are allowed, so ⌃⌥Space and ⌘⇧M are valid.
  1a. `commandOnly` (amended in build, D8): ⌘ as the only modifier is rejected, so standard
     app shortcuts (⌘W, ⌘Q, ⌘C…) can't become global hotkeys. Message: "Add ⌥, ⌃ or ⇧ to a ⌘ shortcut."
  2. `reservedKey`: Esc, Return, Tab, Delete/Forward-Delete, Caps Lock, Fn and modifier-only key codes.
     The four arrow keys are also reserved when combined with exactly ⌃⌥, since those belong to the nudge.
  3. `duplicate(other)`: the same combo is already bound to the other `ShortcutAction`.
- Key names come from a static US-ANSI table (letters, digits, punctuation, Space, F1-F20,
  arrows, Home/End/PgUp/PgDn). Unknown codes render as `Key<code>`.

### 2. HotkeyCenter: per-hotkey unregister (`MarginKit`)

- `register` returns the hotkey id (`UInt32?`, nil when it fails) instead of `Bool`.
- Add `unregister(_ id: UInt32)`.
- Add `isAvailable(_ combo: Combo) -> Bool`. It test-registers the combo and immediately
  unregisters it, so it reports whether the system or another app holds the combo. It must
  not leave a hotkey registered.
- Add `Combo.init(_ shortcut: Shortcut)`.
- Remove `Combo.optionSpace` and `Combo.optionN`. The defaults now live in `ShortcutAction.defaultShortcut`.

### 3. AppDelegate wiring (`Margin`)

- `registerHotkeys()` reads both bindings from `ShortcutStore` and keeps the returned ids
  in `[ShortcutAction: UInt32]`.
- New `rebind(_ action:, to:) -> Bool`, the only way a binding changes:
  1. Unregister the action's current hotkey.
  2. Register the new combo. If that fails, re-register the old combo, return `false`,
     and persist nothing.
  3. On success, persist the combo, post `Notification.Name.marginShortcutsChanged`, and return `true`.
- At launch, if a stored combo fails to register (another app took it since), fall back
  to the default for that action. If the default also fails, leave the action unbound and
  show a one-time `NSAlert`: "Margin couldn't use ⌥Space. Choose another shortcut in
  Settings." with buttons Open Settings / Later. The stored value is not erased.
- Ordering for the tour stays as it is: the toggle handler still routes to
  `tour.foldKeyPressed()` while the tour is active.

### 4. Settings window (`MarginKit/Settings/SettingsWindowController.swift`, new)

- Opened by **⌘,** via a "Settings…" item in the app menu (after "About Margin"), and by
  "Settings…" in the menu-bar status menu (before "Open Notes Folder"). Single instance:
  re-opening brings the existing window to the front.
- A plain `NSWindow`: titled "Settings", ~420×180 pt, not resizable, centered on first open.
  It uses `Theme` fonts and colours, so it looks like the rest of Margin.
- Section header "Shortcuts", then one row per `ShortcutAction`:
  `[title label] [ShortcutRecorderField] [Reset button]`
  - **ShortcutRecorderField** (`MarginKit/Settings/ShortcutRecorderField.swift`, new): shows
    the current `displayString`. Click it to enter recording mode, where it shows "Type
    shortcut…" with a highlighted border.
    - While recording, `AppDelegate` suspends **all** Margin global hotkeys
      (`unregisterAll` + re-register on exit), so pressing the current combo records it
      instead of folding the panel.
    - (Amended in build, D7.) While recording, system and other apps' global hotkeys are also
      paused with `CGSSetGlobalHotKeyOperatingMode` (private SkyLight API, as the ShortcutRecorder
      library does; fine for the direct-download build, not Mac App Store). It is restored when
      recording ends and on quit. This lets system-held combos such as ⌃Space (input sources) reach the recorder so AC6 can
      reject them. (⌘Space is rejected earlier by the D8 ⌘-only rule.)
    - It captures the first keyDown with its modifiers through a local `NSEvent` monitor. A
      modifier-only press updates the hint live (e.g. "⌃⌥…") but does not finish recording.
    - **Esc** cancels and leaves the binding unchanged. A click outside the field, or the
      window losing key, also cancels.
    - When a key is captured, the field runs `validate`, then `HotkeyCenter.isAvailable`, then `rebind`.
      Any failure shows a red inline message under the row and keeps the old binding:
      - needsModifier: "Use at least one of ⌘ ⌥ ⌃."
      - reservedKey: "That key can't be a shortcut."
      - duplicate: "Already used for New Note." (names the other action)
      - not available or rebind failed: "⌃⌥M is in use by macOS or another app."
    - On success the field shows the new combo and the message clears.
  - **Reset** restores the default through the same validate/rebind path. It is disabled
    while the binding already equals the default.
- VoiceOver: the recorder's accessibility label is "<title> shortcut, <displayString>" and
  its role is button.

### 5. Labels follow the binding

Every location in the hardcoded-label table above reads from `ShortcutStore` and updates on
`.marginShortcutsChanged`:
- Labels show the **live** binding: the combo actually registered, which differs from the stored
  one after a launch fallback (amended in build, review R1). `ShortcutStore.effectiveShortcut(for:)`.
- `MainView` tooltips: `"New note  \(newNote.displayString)"`, `"Minimise  \(toggle.displayString)"`.
- Tour: the keycaps come from `toggle.keycaps`. The ⌥N copy and the "bring it back" copy
  interpolate `displayString`.
- Help text at `AppDelegate.swift:609` interpolates the current toggle binding.
- The menu-bar items "New Note" and "Show / Minimise" get **no** key equivalents. Global
  hotkeys can't be shown as menu equivalents without colliding, and that stays as today.

## Acceptance Criteria

1. Fresh install, no stored keys: ⌥Space folds/unfolds and ⌥N makes a new note, same as `origin/main`.
2. Settings → record ⌃⌥M for Show / Minimise: ⌃⌥M toggles the panel from another frontmost app, ⌥Space no longer does, and the minimise tooltip reads `Minimise  ⌃⌥M`.
3. The binding from AC2 survives quit + relaunch. `defaults read <bundle-id> margin.shortcut.toggle` shows `{"keyCode":46,"modifiers":6144}` (JSON data).
4. Record plain `A`: the inline message "Use at least one of ⌘ ⌥ ⌃." appears and the previous binding still works.
5. Record the New Note combo onto Show / Minimise: the duplicate message appears and both old bindings still work.
6. Record a combo already held by the system or another app (QA uses ⌃Space, an enabled input-source shortcut on the QA Mac; corrected from ⌘Space after D8, review R10): the in-use message appears and the old binding still fires.
7. While a recorder is recording, pressing the current Show / Minimise combo records it and does **not** fold the panel. Esc cancels and the binding is unchanged.
8. Reset restores ⌥Space / ⌥N and is disabled when already default.
9. Welcome Tour fold step shows keycaps for the current binding, and pressing that binding advances the tour.
10. ⌘, opens Settings. Invoking it twice leaves exactly one Settings window.
11. ⌃⌥ arrow nudges keep working whatever the two bindings are. Recording ⌃⌥← is rejected as reserved.
12. Corrupt stored value (`defaults write … margin.shortcut.toggle -string junk`): the app launches with ⌥Space.
13a. (D8) Recording ⌘W or ⌘Q shows "Add ⌥, ⌃ or ⇧ to a ⌘ shortcut." and nothing is rebound.
13b. (R1) After a launch fallback, tooltips, tour keycaps and Settings show the combo that works, and Reset/recording the default succeeds.
13. Each test in the Testing Plan states its card: `protects=<observable it protects>; fails_when=<wrong result it rejects>; no_claim=<what green does not prove; which fixtures or mocks stand in for what, or "none beyond protects">`.
14. `swift build` and `swift test` are clean. No existing test changes behavior.

## Testing Plan

| Layer | What | Count |
|---|---|---|
| Unit (`MarginCoreTests/ShortcutTests.swift`) | `displayString` / `keycaps` for ⌥Space, ⌃⌥M, ⌘⇧F5, unknown code; modifier ordering ⌃⌥⇧⌘ | +4 |
| Unit | `validate`: no modifier, ⇧-only, reserved keys (Esc, ⌃⌥←), duplicate, ok with 3 modifiers | +5 |
| Unit | `ShortcutStore` with a suite-scoped `UserDefaults`: default when empty, round-trip, reset, corrupt JSON → default | +4 |
| Manual QA (`/qa`, built app) | AC 2, 3, 6, 7, 9, 10, 11, with screenshots in PROOF.md | 7 checks |

HotkeyCenter and the recorder are AppKit/Carbon and are not unit-tested; AC2-11 are verified
by hand on a built app. The QA launch steals keyboard focus, so warn the user before it runs.

## Rules for the implementing agent

1. Acceptance criteria are the `protects / fails_when / no_claim` profile of each test: the observable it protects, the wrong result it rejects, and what green does not prove. Never "make the tests pass".
2. Real code and real tests land in the same change; a placeholder, a stub assertion or a test deferred to a follow-up is not done.
3. Any change to a test, validator, CI step, timeout, tolerance, threshold, snapshot or suppression pragma is reported on its own line in your summary with its justification, before any other result.
4. A reported command names the command and its observed result (exit status, counts, the failing line); a command you did not run is not reported, and stderr is never silenced in a command you cite.
5. Your report is a claim until the parent re-executes it: say what you verified, what you reused, and what you could not check.

## Rollback Plan

Revert the PR. Stored `margin.shortcut.*` keys are ignored by older builds, which keep using
⌥Space / ⌥N, so no data migration or cleanup is needed.

## Effort Estimate

0.5h model + tests · 0.5h HotkeyCenter changes · 1h AppDelegate rebind + launch fallback ·
2h Settings window + recorder · 0.5h labels/tour · 1h QA. Total ~5.5h (human), well under
an hour with CC.

## Files Reference

| File | Change |
|---|---|
| `Sources/MarginCore/Shortcut.swift` | **New**: `ShortcutAction`, `Shortcut`, `ShortcutValidation`, `ShortcutStore` |
| `Tests/MarginCoreTests/ShortcutTests.swift` | **New**: 13 unit tests |
| `Sources/MarginKit/Window/HotkeyCenter.swift:25-58,72-77` | id-returning `register`, `unregister(id)`, `isAvailable`, `Combo(Shortcut)`, drop `optionSpace`/`optionN` |
| `Sources/MarginKit/Settings/SettingsWindowController.swift` | **New**: Settings window |
| `Sources/MarginKit/Settings/ShortcutRecorderField.swift` | **New**: click-to-record field |
| `Sources/Margin/AppDelegate.swift:239-247` | store-driven registration, `rebind`, suspend/resume, launch fallback + alert |
| `Sources/Margin/AppDelegate.swift:484-503, 515-531` | "Settings…" items, ⌘, |
| `Sources/Margin/AppDelegate.swift:609` | help text uses binding |
| `Sources/MarginKit/MainView.swift:150,153` | tooltips from binding, observe change |
| `Sources/MarginKit/Onboarding/OnboardingView.swift:30,172` | copy + keycaps from binding |
| `Sources/MarginKit/Onboarding/OnboardingController.swift:234` | copy from binding |

## Out of Scope

- Making ⌃⌥ arrow nudges configurable.
- The ⌃⌥S "Snap region" label (`MainView.swift:197`, `SlashMenu.swift:42`): no global hotkey appears to register it. Track it separately.
- Local menu shortcuts (⌘N, ⌘W, ⌘B, …).
- Other preferences moving into Settings (Sounds, auto-updates stay in menus).
- Shortcuts without a modifier, double-tap shortcuts, or modifier-only shortcuts.
- margin-site copy.
- Layout-aware key names (non-US layouts show US-ANSI names).
