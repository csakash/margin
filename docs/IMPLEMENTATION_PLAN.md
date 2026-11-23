# Margin: implementation plan

Margin is a floating, local-first notes panel for macOS. It sits above any app, including full-screen Chrome, snaps to any of 8 spots on the screen, and minimises to a thin glowing line. Product spec: the Intraface board (PRD tab). Visual reference: `design/mockup.html` and `design/icon.svg`.

## 1. Stack decisions

| Area | Choice | Why |
|---|---|---|
| Language / UI | Swift 6, AppKit shell, SwiftUI only for the notes drawer | AppKit gives full control of `NSPanel`, window levels, Spaces and the text system. SwiftUI's `LazyVGrid` is the quickest route to the card grid. |
| Build | Swift Package Manager, no Xcode project. `scripts/bundle.sh` assembles `Margin.app` | Builds from the command line, diffs cleanly, and lets parallel agents build in separate worktrees. |
| Dependencies | **None.** System frameworks only | A smaller binary, no network access needed to build, and nothing that could cost CPU while idle. Each library from the PRD has a system replacement (next three rows). |
| Search | SQLite FTS5 through the system `SQLite3` module | Replaces GRDB. FTS5 ships with macOS's libsqlite3. |
| Global hotkeys | Carbon `RegisterEventHotKey` | Replaces KeyboardShortcuts. Needs no Accessibility permission. |
| Markdown | A line-based block parser of our own (`MarginCore/Markdown.swift`) | v1 only needs block-level syntax plus simple inline styles. The `.md` text stays the source of truth. |
| Editor | `NSTextView` on TextKit 2 that styles the markdown live while you type | Saved text always round-trips exactly. Syntax marks are dimmed, not hidden. Images and to-do checkboxes are drawn as attachments for display only, so the saved file never changes. |
| Storage | One `.md` file per note in `~/Documents/Margin`, assets in `assets/` named by sha256, index in `.margin/index.sqlite` | Matches the PRD. The folder opens in any markdown editor. |
| Material | `NSVisualEffectView` (`.hudWindow`, behind-window blending) + `CAGradientLayer` tint, rim light, specular hotspot and sheen | GPU-composited, with no redraws while idle. |
| Drag-to-place FX | A borderless, click-through overlay `NSPanel` that draws through `NSView.displayLink` **only while dragging** | Costs nothing while idle, which keeps the 0% idle CPU target. |
| Screenshot | `/usr/sbin/screencapture -i -c`, then read the image from the pasteboard | Uses the system's region picker. No ScreenCaptureKit code is needed for v1. |
| Clip tab | `NSAppleScript` for Chrome, Arc, Brave, Edge and Safari | One Automation permission prompt per browser. |
| Link cards | `LPMetadataProvider` (LinkPresentation) | A system framework, run once per pasted URL. |
| Dock icon | Regular activation policy. If the M0 test fails, switch to `.accessory` while a full-screen app is in front | The PRD wants the logo in the Dock. |

## 2. Module layout

```
Package.swift                      macOS 14+, Swift 6 language mode
Sources/
  MarginCore/        (Foundation + SQLite3; no AppKit, so it is unit-testable)
    Note.swift              NoteID, NoteSummary, NoteStats
    Markdown.swift          block parser, stats (title, snippet, counts)
    NoteStore.swift         list / load / save (atomic, debounced) / create / delete / folder watch
    AssetStore.swift        import file or data → assets/<sha256>.<ext>
    SearchIndex.swift       FTS5 upsert / remove / search
  MarginKit/         (AppKit + SwiftUI)
    Shared/Theme.swift      colours, curves, metrics; Anchor enum; BlockKind
    Window/                 FloatingPanel, Placement, PanelController (states, morph), Hotkeys
    Material/               GlassView (tint, rim, specular, sheen), SnapOverlay (drag FX)
    Editor/                 MarkdownTextView, MarkdownStyler, SlashMenu, EditorController
    Drawer/                 NotesDrawer (SwiftUI), DrawerController (height, drag, velocity)
    Capture/                ScreenCapture, BrowserClip, LinkMetadata
    MainView.swift          composes header / editor / toolbar / drawer (integration)
  Margin/            (executable)
    main.swift, AppDelegate.swift   Dock icon, menu bar item, hotkeys, wiring
Tests/MarginCoreTests/      markdown, store, assets, search
scripts/bundle.sh           release build → Margin.app (Info.plist, icns)
scripts/make-icon.swift     renders design/icon.svg → AppIcon.icns
```

## 3. Shared contracts (defined in Wave 0, implemented in later waves)

Wave 0 ships compiling stubs for every type below. Parallel agents fill in the bodies without changing the signatures, so their work merges without conflicts. Any change to a signature waits for the integration wave.

- `MarginCore`: `NoteID`, `NoteSummary`, `NoteStore`, `AssetStore`, `SearchIndex`, `Markdown`.
- `MarginKit`: `Anchor`, `BlockKind`, `Theme`, `Placement`, `FloatingPanel`, `PanelController`, `GlassView`, `SnapOverlay`, `EditorController`, `HotkeyCenter`, `DrawerController`, `ScreenCapture`, `BrowserClip`, `LinkMetadata`.

## 4. Waves: what runs in parallel and what runs in sequence

Each parallel loop works in its **own git worktree and branch**, so builds never collide in `.build/`. A loop owns only the directories listed for it. Between waves the orchestrator merges every branch, builds and runs the tests (a gate) before starting the next wave.

| Wave | Mode | Loops | Owns | Done when |
|---|---|---|---|---|
| **0 · Foundation** | sequential, 1 loop | orchestrator | Package.swift, contracts and stubs, Theme, `main.swift` that opens an empty floating panel | `swift build` passes and the app launches |
| **1 · Pillars** | **parallel, 4 loops** | A Core | `Sources/MarginCore/**`, `Tests/**` | store, assets, FTS5 search and markdown stats implemented, all tests passing |
| | | B Editor | `Sources/MarginKit/Editor/**` | live markdown styling, block shortcuts, `/` menu, to-do toggle, image attachments, Enter and Backspace behaviour |
| | | C Window | `Sources/MarginKit/Window/**` | the panel floats over full-screen apps; 8 anchors; minimise morph; ⌥Space and ⌥N hotkeys; ⌃⌥+arrows nudge |
| | | D Material | `Sources/MarginKit/Material/**` | glass, rim, specular hotspot that tracks the pointer, sheen glint, SnapOverlay (dots, trail, beam, slots, ghost, shockwave) |
| **2 · Integration** | sequential, 1 loop | orchestrator | `MainView.swift`, `Drawer/**`, `Sources/Margin/**` | header, editor, toolbar and drawer composed; store ↔ editor autosave; the push-up drawer with drag and flick; note switching |
| **3 · Capabilities** | **parallel, 3 loops** | E Media | `Editor/Media*.swift`, `Capture/LinkMetadata.swift` | drop and paste images, video and files; URL → link card; dragged text → quote with its source |
| | | F Capture | `Capture/ScreenCapture.swift`, `Capture/BrowserClip.swift` | region screenshot into the note; clip the front browser tab |
| | | G Placement | `Window/DragPlacement.swift` | drag the header or the minimised line: overlay FX, magnetic pull, velocity projection, spring landing |
| **4 · Ship** | sequential, 1 loop | orchestrator | `scripts/**`, README, wiring | merge; Reduce Motion and Reduce Transparency; app bundle with icon; launch test; idle RAM and CPU measured |

That's **9 loops in 5 waves: 7 parallel and 2 sequential integration loops**, run as Wave 0 → [A‖B‖C‖D] → 2 → [E‖F‖G] → 4. The parallel waves split along directory boundaries, so no two loops edit the same file.

## 5. Approach per pillar

**Window (C).** `FloatingPanel: NSPanel` with style `[.nonactivatingPanel, .titled, .fullSizeContentView, .resizable]` and a transparent title bar. Level `.floating`; collection behaviour `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`; `hidesOnDeactivate = false`; `isOpaque = false`; `backgroundColor = .clear`. `Placement` turns an `Anchor` into a frame inside `screen.visibleFrame` (16 pt margin for the panel, 6 pt for the minimised line). `PanelController` animates `setFrame` with `NSAnimationContext` using a spring-like timing curve (0.32, 0.72, 0, 1), 0.5 s. It fades the content out in 0.1 s when minimising and back in after a delay when expanding. Hotkeys use Carbon.

**Material (D).** `GlassView` stacks: an `NSVisualEffectView` (.hudWindow), a vertical tint gradient, a top light cone (radial gradient), a rim (gradient layer masked by a stroked rounded-rect path), a specular hotspot (radial gradient layer repositioned from a tracking-area `mouseMoved`) and a sheen band (one-shot `CABasicAnimation` on its position). `SnapOverlay` is a borderless panel covering the screen. Its view drives `displayLink` only between `begin` and `end`, drawing the dimmed backdrop, the magnetic dot field, the comet trail, the dashed beam, the 8 slots (with the nearest one pulsing), the ghost outline and the landing shockwave.

**Editor (B).** `MarkdownTextView: NSTextView` (TextKit 2). `MarkdownStyler` restyles only the edited paragraphs when the text storage changes: heading sizes, dimmed markers, bullets, quote bars, monospaced code with a background, struck-through done to-dos. Typing a prefix followed by a space at the start of a line is native markdown, so no conversion is needed; toolbar actions insert or toggle the prefix. The `/` menu is a child panel with a filterable list. To-do checkboxes and images are drawn as text attachments substituted at display time, so the saved text stays `- [ ]` and `![](assets/x.png)`. Clicking a checkbox flips `[ ]` ↔ `[x]` in the text.

**Core (A).** `NoteStore` keeps one file per note, named by its title with a short id stored in front-matter. Writes are atomic and debounced by 300 ms. A folder watcher (DispatchSource) picks up outside edits. `SearchIndex` uses an FTS5 table `notes(id UNINDEXED, title, body)` with a `MATCH` prefix query. `AssetStore` names files by sha256 and dedupes them.

**Drawer (2).** The panel's content is a vertical stack: header, editor scroll view, toolbar, drawer. The drawer's height constraint animates, so opening it pushes the editor up instead of covering it. The editor keeps the caret line in view. A drag gesture on the handle or toolbar records velocity, rubber-bands past the maximum height and projects its end point with `v·0.99/(1−0.99)/1000` to decide open or closed. Cards stagger in only the first time it opens.

## 6. Quality gates (run after each merge)

1. `swift build -c debug` with zero errors. Swift 6 toolchain in Swift 5 language mode; UI types are `@MainActor`.
2. `swift test`: Core tests pass.
3. Launch smoke test: the app starts, the panel shows, ⌥Space minimises it, and the process stays under 60 MB RSS after 30 s idle.
4. Wave 4 only: `scripts/bundle.sh` produces a `Margin.app` that runs from Finder and shows its icon in the Dock.

## 7. Out of scope for this build

These ship after v1: Sparkle updates, notarisation, App Store packaging, PDF export, and per-display memory of the drawer height.

## 8. Build log (24 Nov 2026)

| Wave | Loop | Result |
|---|---|---|
| 0 | Foundation | Package, contracts, markdown classifier, floating panel |
| 1 | A Core | File-backed store, FTS5 search, asset store; 38 tests |
| 1 | B Editor | Live styling, block shortcuts, `/` menu, checkboxes, images, link cards |
| 1 | C Window | Minimise morph, 8 anchors, nudge, resize persistence, Carbon hotkeys |
| 1 | D Material | Glass, rim, hotspot, clearcoat, sheen, minimised line, orb, SnapOverlay |
| 2 | Integration | Main view, push-up drawer, menus, status item, app wiring |
| 3 | E Media | Drop and paste of files, images, video and URLs; link titles; quotes with sources |
| 3 | F Capture | Region screenshot, front browser tab clip |
| 3 | G Placement | Drag-to-place: overlay, orb stretch, magnetism, flick projection, Esc |
| 4 | Ship | `dist/Margin.app` (2.2 MB, icon); idle footprint 28 MB; minimised idle CPU 0.0–0.1% |

Checked in the running release app: launch, Dock icon, minimise and expand with ⌥Space, the drawer opening and pushing the note up, typing with live styling, and autosave to disk. Not yet checked with a real mouse and keyboard: checkbox clicks, drag and drop from other apps, the drag-to-place magnet near a slot, Reduce Motion, and multiple displays.
