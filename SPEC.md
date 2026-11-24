# SPEC: Ask for Screen Recording once, from the tour; never prompt on every screenshot (ships as 0.2.1)

Loop: `screen-permission` · Branch: `feat/screen-permission` · Repo: `margin` (site gets the 0.2.1 DMG and feed at release)

## Problem (verified 2026-11-24, `main` at b06a92f)

`ScreenCapture.captureRegion` (Sources/MarginKit/Capture/ScreenCapture.swift) has two faults.
- It calls `CGRequestScreenCaptureAccess()` on every screenshot while `CGPreflightScreenCaptureAccess()` is false, then runs `/usr/sbin/screencapture -i` anyway.
- macOS applies a new Screen Recording grant only after the app restarts. So after the user switches Margin on, every screenshot until a relaunch brings back the macOS dialog "Margin would like to record this computer's screen and audio", and captures only the wallpaper.

The user saw the dialog on every screenshot with Margin already switched on.

## Change

1. **`ScreenAccess` (MarginKit/Capture/ScreenAccess.swift)**
   - `isGranted` is `CGPreflightScreenCaptureAccess()`.
   - `request()` calls `CGRequestScreenCaptureAccess()` once and records `margin.screenAccessRequested`.
   - `wasRequested` reads that record.
   - `openSettings()` opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
   - `relaunch()` starts a small `/bin/sh` that waits for this process to exit and then `open`s the bundle, then terminates the app. This keeps two Margins (and their hotkeys) from running at once.
2. **Capture never prompts.** `captureRegion` returns `.started`, `.busy` or `.needsPermission`.
   - It never calls the request API.
   - Without permission it does nothing else: no `screencapture`, no hidden panels.
3. **In-panel notice card.** A second card (same look as the update card, stacked above it) is shown when a capture returns `.needsPermission`.
   - **Not yet asked:** "Screenshots need one permission" / "macOS asks once. Margin only captures the area you select." [Allow] [Not now]. Allow calls `request()` and moves on to the next state.
   - **Asked, not granted:** "Switch on Margin for screenshots" / "System Settings › Privacy & Security › Screen & System Audio Recording. Margin needs a restart after that." [Open Settings] [Not now].
   - **After Open Settings:** the primary button becomes [Reopen Margin].
   - Not now hides the card.
4. **Tour step "05 · SCREENSHOTS"**, between Write and Ready.
   - Title "Snap any part of the screen."
   - Sub "The ⌖ button below turns a region of your screen into an image in the note. macOS asks once for permission; Margin only sees what you select."
   - **Already granted:** the try-box ticks "Already allowed" and shows Next.
   - **Otherwise:** buttons [Allow screenshots] and a text [Skip].
     - Allow calls `request()`, sets the try message to "Switch on Margin in the list, then reopen Margin when macOS asks", and turns the primary into Next.
     - Skip goes to Ready.
   - **Relaunch:** entering this step sets `margin.onboarded`, so a relaunch from macOS's "Quit & Reopen" does not restart the tour.
   - **Dots:** there are now 5.

## Acceptance criteria

1. `swift build -c release` and `swift test` pass.
2. With permission missing, clicking the screenshot button shows the notice card and no macOS dialog, and no `screencapture` process starts. Repeating it shows the card again and still no dialog.
3. "Allow" (in the card or the tour) shows macOS's dialog at most once per install.
4. With permission granted (after a relaunch), the screenshot button works with no dialog.
5. "Reopen Margin" quits and starts Margin again, and the new process has its hotkeys.
6. The tour shows the new step. Skip and Allow both continue to Ready, and "Already allowed" shows when granted.

## Out of scope
Recording the screen; ScreenCaptureKit; wiring the ⌃⌥S shortcut shown in the button tooltip.
