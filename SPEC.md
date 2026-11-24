# SPEC: First-launch onboarding, Paper sounds, "updated" card, styled install window, icon fix (ships in 0.2.0)

Loop: `onboarding` · Branch: `feat/onboarding` · Repos: `margin`, `margin-site` (site: nothing beyond the open updater PR)
Visual reference: `design/onboarding.html` (board version 7, "Onboarding ↗"). Sounds: the "Paper" palette the user chose.

## Decisions already made (from the mockup review)

| # | Decision |
|---|----------|
| D1 | Onboarding runs once, the first time Margin opens; four steps (Float, Fold, Place, Write) between a welcome and a finish; Skip or Esc ends it |
| D2 | Sound palette: Paper (7 sounds: arrive, step, collapse, expand, snap, done, installed) |
| D3 | After an update relaunch, a card says "You're on Margin x" with the update's notes and the installed sound, and hides itself after 6 s |
| D4 | The DMG window has a dark background with an arrow and "Drag Margin into Applications"; Finder plays no sound |
| D5 | The app icon has no white frame |

## Current state (verified on `main` at 17364d1)

- `scripts/bundle.sh` renders `design/icon.svg` with `qlmanage`, which paints an opaque white page; the white margin becomes a frame in the Dock.
- No sounds anywhere in the app. No first-run flow: the first launch opens the "Welcome to Margin" note (`AppDelegate.openInitialNote`).
- `UpdaterController` has no "after relaunch" state; the update card shows nothing once the new version is running.
- `scripts/release.sh` builds a plain DMG (`hdiutil -srcfolder`), default Finder look.

## Proposed change

### 1. Icon (`scripts/mask-icon.swift`, `scripts/bundle.sh`)
After `qlmanage`, cut the rounded tile (480×480, r112 at 16,16 in the 512 grid, padded to 600) onto a transparent 1024² canvas, inset 1 px. All iconset sizes come from that PNG. Done when the four corners and the 44-unit margin of `AppIcon.icns` are fully transparent.

### 2. Sounds (`Resources/Sounds/*.mp3`, `Sources/MarginKit/Shared/Sounds.swift`)
- The 7 Paper files are committed under `Resources/Sounds/` and copied by `bundle.sh` to `Contents/Resources/Sounds/`.
- `public enum SoundEffect: String, CaseIterable { arrive, step, collapse, expand, snap, done, installed }`.
- `Sounds.play(_:)` plays through cached `NSSound`s at volume 0.55. It is silent when the files are missing (unbundled runs), and it is silent when "Sounds" is switched off. The setting is persisted under `margin.sounds`, default on.
- The menu-bar menu gains a "Sounds" item with a checkmark.
- Sounds play only in four places: the onboarding, the "updated" card, and fold/unfold/snap during the onboarding's own steps. Ordinary folding and snapping stay silent.

### 3. Onboarding (`Sources/MarginKit/Onboarding/OnboardingView.swift`, `OnboardingController.swift`)
- **When it runs:** on launch when `margin.onboarded` is not set, or when `MARGIN_ONBOARDING=1` is set (an `Override` value, so QA builds can force it). The app menu's "Show Welcome Tour" replays it.
- **Layout:** the controller hides `MainView` and puts `OnboardingView` in its place inside the glass. While the tour runs, the panel uses 400×380 and keeps its anchor logic; the user's size is restored afterwards.
- **Veil:** a click-through, borderless, full-screen window one level below the panel. It is black at 55% alpha, drops to 25% from the Float step, fades out at the end, and is removed when the tour finishes.
- **Arrival:** the panel starts as the minimised line in the centre of the screen. It morphs open to a centred 400×380 frame with the spring curve, plays `arrive`, then glints. Under Reduce Motion it appears directly.
- **Steps:** each step's copy is exactly as in the mockup, with an eyebrow, a title, a sub-line, then an action.
  - **0 Welcome:** "Begin".
  - **1 Float:** the panel moves to the right anchor. "Next".
  - **2 Fold:** a try-box with ⌥ Space keycaps, which can also be clicked.
    - It completes after the panel has been minimised and expanded once, using the real hotkey or the keycaps.
    - `collapse` and `expand` play.
    - A tick appears and "Next" shows.
  - **3 Place:** dragging the onboarding's top bar starts the real header drag (DragPlacement, with its snap effect). On drop it plays `snap`, shows a tick and shows "Next".
  - **4 Write:** a timed demo types `# Reading notes`. The "# " fades and the line becomes a 18 pt semibold heading. Then `- Capture costs under 2 seconds` becomes a bullet, and a row of "/ Heading To-do Quote Image" chips fades in. "Next".
  - **5 Done:** the veil fades out. It plays `done` and glints. "Start writing".
- **Feedback:** every step change plays `step`. Four progress dots show for steps 1–4. Each step's content fades and rises in by 8 px with a 60 ms stagger (0.42 s, `Theme.easeOut`).
- **Keys:** Return activates the visible primary button, and Esc or "Skip" finishes immediately, with no `done` sound on skip.
- **Finishing:** it sets `margin.onboarded`, removes the overlay and veil, shows `MainView`, restores the size and anchor, and focuses the editor on the current note.
- **While it runs:** the editor is never first responder. `AppDelegate`'s state-change handler must not focus it.

### 4. "Updated" card (`MarginCore/UpdateModel.swift`, `UpdaterController.swift`, `UpdateCardView.swift`)
- **New phase:** `UpdatePhase.installed(UpdateInfo)`. `showsCard` is true, `showsNubDot` is false and `autoDismissAfter` is 6.
- **Card copy:** title "You're on Margin x", the notes as bullets, and no buttons.
- **Remembering the update:** when an update reaches `.ready`, the controller stores `margin.pendingUpdate` as `{"version": …, "notes": [...]}` JSON.
- **After relaunch:** in `start()`, if the stored version equals the running `CFBundleShortVersionString`, it shows `.installed(info)`, plays `installed` and deletes the key.
- **Unit tests:** the new phase's three properties, plus encoding and decoding the stored value with `PendingUpdate` (Codable, in MarginCore).

### 5. Install window (`design/dmg-background.svg`, `scripts/release.sh`)
- **Background:** a 600×380 background (1× and 2× combined with `tiffutil -cathidpicheck`). It has a dark radial gradient, a dashed arc arrow between the two icon spots, and "Drag Margin into Applications" at the bottom.
- **Building the image:** `release.sh` builds a read-write DMG, copies the background into `.background/`, and uses AppleScript to set Finder to icon view. It sets 112 pt icons with no toolbar, the window bounds, the background, and the positions (Margin at 150,170 and Applications at 450,170). It then detaches and converts to UDZO.
- **If styling fails:** when the AppleScript step fails, for example because Finder automation was refused, the script warns and ships the plain layout. The release does not fail.
- **Limit:** Finder label text follows the system appearance, so in Light Mode the labels are dark on the dark background. This is a known limit.

## Acceptance criteria
1. `swift build -c release` and `swift test` exit 0, with at least 56 tests (52 existing + at least 4 new).
2. The icns has transparent corners; in a Dock-like render there is no light frame.
3. A fresh launch (new defaults domain) shows the arrival and all six steps:
   - each step's sound plays;
   - the real ⌥ Space and the real drag complete their steps;
   - "Start writing" lands in the editor with the panel at the chosen anchor and the user's size restored.
4. A second launch shows no onboarding. "Show Welcome Tour" replays it. Esc and Skip end it at any step, leaving a normal panel.
5. The "Sounds" toggle silences everything and persists.
6. After a real update (scripts/qa-update.sh) the relaunched app shows "You're on Margin 0.2.1" with the installed sound, and the card hides after 6 s.
7. The 0.2.0 DMG opens to the styled window in Dark Mode (screenshot), or the script reports why it fell back.
8. Idle CPU after onboarding is at most 0.5% over 30 s; footprint is at most 45 MB.

## Out of scope
Sounds outside the onboarding and the "updated" card; analytics; changing the welcome note; Light Mode label contrast in the DMG.
