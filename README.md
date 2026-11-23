# Margin

A floating, local-first notes panel for macOS. It sits above any app, including full-screen Chrome, so you can write while you read. Notes are plain markdown files on your Mac.

- **Floats everywhere.** A floating panel that doesn't take focus and appears on every Space, including over full-screen apps.
- **8 spots.** Snap it to any edge or corner. Drag it and the screen shows you where it can land.
- **Minimises to a thin line.** A glowing glass line on its edge, with no text or logo. Click it to open; drag it to move it.
- **Markdown, styled live.** `#` headings, lists, `[ ]` to-dos, quotes, code, dividers, images and link cards. Type `/` for the block menu.
- **Bring things in.** Drop or paste images, videos, files and links. Drag text from a page to get a quote with its source. Take a region screenshot, or clip the front browser tab.
- **All notes drawer.** It slides up from the bottom and pushes your note up instead of covering it, with search and filters.
- **Light.** No dependencies, no web view, nothing running while idle.

## Shortcuts

| Keys | Action |
|---|---|
| ⌥ Space | Minimise / expand |
| ⌥ N | New note |
| ⌃⌥ ← ↑ → ↓ | Move the panel between the 8 spots |
| / | Block menu |
| ⌘-click a link | Open it in the browser |

## Build

Requires macOS 14+ and Xcode 16+ (Swift 6 toolchain).

```bash
swift build && .build/debug/Margin     # run a debug build
swift test                             # core tests
scripts/bundle.sh --open               # build dist/Margin.app with its icon and open it
```

Notes live in `~/Documents/Margin`: one `.md` file per note, media in `assets/`, and a rebuildable search index in `.margin/`.

## Layout

```
Sources/MarginCore   storage, markdown, search (Foundation + SQLite only, unit-tested)
Sources/MarginKit    panel, placement, material, editor, drawer, capture (AppKit + SwiftUI)
Sources/Margin       app entry point and wiring
design/              interactive mockup and the icon source
docs/                implementation plan and build waves
```

See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the stack decisions and how the build was split into parallel waves.
