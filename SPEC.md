# SPEC: In-app updates for Margin (Sparkle 2, Margin-styled UI) — ship as 0.2.0

Loop: `sparkle-updater` · Branch: `feat/sparkle-updater` · Repos: `margin` (app), `margin-site` (landing page)
Verified against the code on 2026-11-24 (`main` at `b6ae7be`).

## Context

Margin is a floating macOS notes panel, distributed as a notarized DMG from https://margin.motiontic.com.
Today there is no way for an installed copy to learn about or install a new version: a user on 0.1.0
stays on 0.1.0 until they revisit the site by hand. Every fix shipped so far (for example the 0.1.1
rendered-markdown fix) reached nobody who had already installed.

This loop adds automatic updates with Sparkle 2 (https://sparkle-project.org), the standard updater
for Developer ID apps. Sparkle's stock windows are not used. All updater UI is drawn by Margin in its
own black/white glass design, inside the panel.

Who cares: every Margin user (they get fixes without thinking), and the maintainer (a release reaches
the installed base within about a day).

## Decisions already made (do not re-open)

| # | Decision | Choice |
|---|----------|--------|
| D1 | Where the notice appears | A glass card inside the panel that pushes the note up, plus a glow dot on the minimised nub |
| D2 | Install flow | Download silently in the background, then show one "Restart to update" button |
| D3 | Analytics (download and active-user counting) | Out of scope. Separate follow-up loop |
| D4 | Finish line | Two cross-linked PRs. Notarized release, appcast publish and site deploy happen after merge, on the maintainer's go-ahead |

## Current State

| Area | What exists today | Gap |
|------|-------------------|-----|
| Dependencies | `Package.swift` has zero package dependencies; targets `MarginCore`, `MarginKit`, `Margin`, `MarginCoreTests` | Needs Sparkle |
| Version | `scripts/bundle.sh:7` `VERSION="0.1.1"`; `scripts/bundle.sh:45` hard-codes `CFBundleVersion` = `1` | Sparkle compares `CFBundleVersion`, so `1` forever means no update is ever "newer" |
| Bundle | `scripts/bundle.sh` copies one binary into `Contents/MacOS`, no `Contents/Frameworks`; ad-hoc signs with `codesign --force --deep` at line 56 | Needs the framework embedded, an rpath, and inside-out signing (Sparkle docs: do not use `--deep`) |
| Release | `scripts/release.sh` signs the app (hardened runtime, `scripts/Margin.entitlements`), builds a DMG, notarizes with profile `margin-notary`, staples | No update feed, no EdDSA signature |
| UI host | `Sources/MarginKit/MainView.swift:33-59` lays out header, scroll, toolbar, drawer. `scroll.bottomAnchor == toolbar.topAnchor` (line 51) | Nowhere to show an update |
| Minimised nub | `Sources/MarginKit/Window/PanelController.swift:97-135` collapses to a nub; `GlassView.isMinimised` draws it | No "update waiting" signal |
| Menus | Menu-bar menu `Sources/Margin/AppDelegate.swift:323-338`, app menu `:353-357`. There is no settings window | No "Check for Updates" entry, no auto-update toggle |
| Site | `margin-site/_headers` covers `/download/*`; `download/Margin-0.1.1.dmg`; no `appcast.xml` | Needs feed headers and a privacy line |
| Tests | 38 tests in `Tests/MarginCoreTests` (MarginCore only; MarginKit and Margin are not unit-tested) | Updater logic must live in MarginCore to be testable |

Installed copies of 0.1.0 and 0.1.1 contain no updater. Those users must install 0.2.0 by hand once.
Nothing in this loop can change that.

## Proposed Change

### Architecture

```
Sparkle (SPUUpdater)                       Margin target (imports Sparkle)
   │  SPUUserDriver + SPUUpdaterDelegate ─▶ UpdaterController
   │                                           │ reduces Sparkle callbacks to
   │                                           ▼
   │                               MarginCore.UpdatePhase (pure, tested)
   │                                           │ onChange
   │                                           ▼
   │                               MarginKit.UpdateCardView (in MainView)
   │                               MarginKit.GlassView nub dot (minimised)
   └── feed: https://margin.motiontic.com/appcast.xml  (EdDSA-signed DMG enclosure)
```

Only the `Margin` executable target imports Sparkle. `MarginKit` and `MarginCore` stay Sparkle-free.

### Implementation Details

#### 1. Package (`Package.swift`)

Add `dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")]` and add
`.product(name: "Sparkle", package: "Sparkle")` to the `Margin` executable target only. Sparkle is a
binary target. After `swift build`, expect the framework at
`.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/<slice>/Sparkle.framework` and tools at
`.build/artifacts/sparkle/Sparkle/bin/{generate_keys,sign_update}`. The slice directory name is
unverified (expected `macos-arm64_x86_64`): resolve it with a glob in the script, do not hard-code it.

#### 2. Pure state (`Sources/MarginCore/UpdateModel.swift`, new)

```swift
public struct UpdateInfo: Equatable, Sendable {
    public let version: String        // display version, e.g. "0.2.1"
    public let notes: [String]        // 0...5 plain-text lines
}

public enum UpdatePhase: Equatable, Sendable {
    case idle
    case checking                          // user asked; spinner
    case available(UpdateInfo)             // found, not downloaded (manual check only)
    case downloading(UpdateInfo, Double)   // 0...1
    case ready(UpdateInfo)                 // downloaded; one click restarts
    case installing(UpdateInfo)
    case upToDate(String)                  // current version
    case failed(String)                    // one-line message
}

public enum ReleaseNotes {
    /// Turns an appcast <description> (HTML or plain text) into at most 5 plain lines,
    /// each trimmed, tags and entities removed, capped at 120 characters with "…".
    public static func lines(from description: String?) -> [String]
}

public extension UpdatePhase {
    var showsCard: Bool        // true for everything except .idle
    var showsNubDot: Bool      // true only for .ready
    var autoDismissAfter: TimeInterval?   // 3 for .upToDate, nil otherwise
}
```

`ReleaseNotes.lines` rules: split on `<li>`, `<br>`, `<p>` and newlines; strip all other tags; decode
`&amp; &lt; &gt; &quot; &#39; &nbsp;`; drop empty lines and a leading "- " or "• "; keep the first 5.
`nil` or empty input returns `[]`.

#### 3. Sparkle glue (`Sources/Margin/UpdaterController.swift`, new)

`@MainActor final class UpdaterController: NSObject, SPUUserDriver, SPUUpdaterDelegate`.

- Owns `SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)`;
  calls `try updater.start()` from `applicationDidFinishLaunching`. If `start()` throws (for example
  the app is running unbundled via `swift run`, with no `SUFeedURL`), log once and leave the phase
  `.idle`. The app must keep working.
- `private(set) var phase: UpdatePhase` with `var onChange: ((UpdatePhase) -> Void)?`.
- Public API used by `AppDelegate`: `checkNow()`, `restartToUpdate()`, `dismiss()`,
  `var automaticChecks: Bool { get set }` (maps to `updater.automaticallyChecksForUpdates`),
  `var canCheck: Bool` (maps to `updater.canCheckForUpdates`).

Callback mapping (all 16 required `SPUUserDriver` methods must be implemented; verify names against
`SPUUserDriver.h` in the resolved artifact):

| Sparkle callback | Margin behaviour |
|---|---|
| `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` | Store the block, set `.ready(info)`, return `true`. This is the main path |
| `show(_:)` permission request | Return automatic checks = true, send system profile = false. Not expected to fire because `SUEnableAutomaticChecks` is set |
| `showUserInitiatedUpdateCheck(cancellation:)` | `.checking` |
| `showUpdateFound(with:state:)` stage `.notDownloaded` | `.available(info)`; reply `.install` when the user clicks "Update now", `.dismiss` on "Later" |
| `showUpdateFound` stage `.downloaded` or `.installing` | `.ready(info)`; reply `.install` on "Restart to update", `.dismiss` on "Later" |
| `showDownloadInitiated`, `…ExpectedContentLength`, `…DidReceiveData` | `.downloading(info, fraction)`; fraction = received / expected, 0 when expected is 0 |
| `showDownloadDidStartExtractingUpdate`, `showExtractionReceivedProgress` | `.downloading(info, 1.0)` |
| `showReadyToInstallAndRelaunch()` | Reply `.install` immediately (the user already clicked "Update now") |
| `showInstallingUpdate(withApplicationTerminated:…)` | `.installing(info)` |
| `showUpdateNotFoundWithError(_:)` | `.upToDate(currentVersion)`, acknowledge, return to `.idle` after 3 s |
| `showUpdaterError(_:)` | `.failed(error.localizedDescription first line)`, acknowledge when dismissed |
| `showUpdateReleaseNotes…`, `showUpdateInstalledAndRelaunched(_:)`, `dismissUpdateInstallation`, `showUpdateInFocus` | Release notes come from the item's inline description, so the first two are no-ops that acknowledge; `dismissUpdateInstallation` sets `.idle` unless the phase is `.ready` |

`restartToUpdate()` calls the stored immediate-install block if present, otherwise replies `.install`
to the pending `showUpdateFound`. `UpdateInfo` is built from `SUAppcastItem.displayVersionString` and
`ReleaseNotes.lines(from: item.itemDescription)`.

Feed override for QA: implement `feedURLString(for:)` returning the value of the environment variable
`MARGIN_FEED_URL` when it is set and non-empty, otherwise `nil` (Sparkle then uses `SUFeedURL`). This
is safe to ship: Sparkle rejects any archive not signed with Margin's EdDSA key regardless of feed.

Known limit, accepted: returning `true` from `willInstallUpdateOnQuit` pauses further update cycles
until the app restarts. A newer release published while one is pending is picked up after that restart.
Sparkle still installs the pending update when the app quits.

#### 4. Card UI (`Sources/MarginKit/Update/UpdateCardView.swift`, new; `MainView.swift` edited)

- `public final class UpdateCardView: NSView` with `public func apply(_ phase: UpdatePhase, animated: Bool)`,
  `public var onPrimary: (() -> Void)?`, `public var onDismiss: (() -> Void)?`.
- `MainView` adds the card between the editor and the toolbar: `scroll.bottomAnchor == card.topAnchor`,
  `card.bottomAnchor == toolbar.topAnchor`, plus a `card` height constraint that is 0 when hidden.
  `fade` and `status` re-anchor to `card.topAnchor`. Showing the card animates the height from 0 to its
  fitting height, so the note is pushed up and never covered. Motion: 0.42 s with `Theme.spring`;
  instant when `Theme.reduceMotion` is true. `MainView` gains `public func setUpdatePhase(_:animated:)`.
- Look: top hairline (`Theme.hairline`), horizontal padding 18, vertical padding 14, background a
  white 4% wash over the existing glass (no second blur view). A one-shot "tank shine" sweep (a
  diagonal white gradient band, 0 to 10% to 0 alpha, 0.9 s) plays once when the card enters `.ready`;
  skipped under Reduce Motion.
- Content per phase:

| Phase | Title (`Theme.ui(13)` semibold, `Theme.text`) | Body (`Theme.ui(12)`, `Theme.textSecondary`) | Primary `PillButton` | Secondary |
|---|---|---|---|---|
| `.checking` | Checking for updates… | none | none | none |
| `.available(i)` | Margin `i.version` is available | notes as "• line", max 5 | Update now | Later |
| `.downloading(i, f)` | Downloading Margin `i.version` | 2 pt progress hairline, white, width = f | none | none |
| `.ready(i)` | Margin `i.version` is ready | notes as "• line", max 5 | Restart to update | Later |
| `.installing(i)` | Installing Margin `i.version`… | none | none | none |
| `.upToDate(v)` | You're up to date | Margin `v` | none | none (auto-hides after 3 s) |
| `.failed(m)` | Couldn't check for updates | `m` | none | Dismiss |

  Reuse `PillButton` (`MainView.swift:242`) for the primary action; the secondary is a text-only button
  in `Theme.textSecondary`. "Later" hides the card for the rest of this launch; the nub dot stays.

#### 5. Nub dot (`Sources/MarginKit/Material/GlassView.swift`, `PanelController.swift` edited)

- `GlassView` gains `public var showsUpdateDot: Bool`. When true and `isMinimised`, draw a 6 pt white
  dot with a soft 8 pt white glow, 11 pt in from one end of the nub (top end for left and right
  anchors, right end for top and bottom anchors) so it does not cover the nub line. For the four
  corner anchors the existing centre dot pulses instead. `design/mockup.html` is the visual reference
  for the card and the dot. It pulses opacity 0.45 to 1.0 over 1.6 s,
  autoreversing, using a `CABasicAnimation` on a `CALayer` (no display link, no timer). Under Reduce
  Motion the dot is static at 0.9.
- `PanelController` gains `public var hasPendingUpdate: Bool` that forwards to `glass.showsUpdateDot`
  and survives minimise and expand transitions.
- The dot is hidden whenever the panel is expanded (the card is the signal there).

#### 6. Wiring (`Sources/Margin/AppDelegate.swift` edited)

- Create `UpdaterController` after the panel exists. `onChange`: call
  `mainView.setUpdatePhase(phase, animated: true)`, set `panelController.hasPendingUpdate = phase.showsNubDot`,
  and refresh the menu items.
- Background-found updates never expand or focus the panel. A user-initiated check (`checkNow()`)
  expands the panel if it is minimised, so the result is visible.
- Menu-bar menu (`AppDelegate.swift:323`): after "Open Notes Folder" add a separator, then
  "Check for Updates…" (disabled while `!canCheck`), then "Check for Updates Automatically" (checkmark
  reflects `automaticChecks`; clicking toggles it). When the phase is `.ready(i)`, the first item
  reads "Restart to Update (`i.version`)" and calls `restartToUpdate()`.
- App menu (`AppDelegate.swift:354`): add "Check for Updates…" directly under "About Margin".

#### 7. Bundle script (`scripts/bundle.sh` edited)

- `VERSION="${VERSION:-0.2.0}"` (env override exists for QA builds).
- Info.plist: `CFBundleVersion` = `${VERSION}` (replacing the constant `1`), and add
  `SUFeedURL` = `https://margin.motiontic.com/appcast.xml`, `SUPublicEDKey` = the generated public key,
  `SUEnableAutomaticChecks` = true, `SUAutomaticallyUpdate` = true, `SUScheduledCheckInterval` = 86400.
- When `QA_LOCAL_FEED=1`, also add `NSAppTransportSecurity` / `NSAllowsLocalNetworking` = true so a
  feed on `http://127.0.0.1` loads. Never set otherwise.
- Embed: `ditto` the resolved `Sparkle.framework` into `Contents/Frameworks/` (symlinks preserved),
  then delete `Versions/B/XPCServices` and the top-level `XPCServices` symlink (Margin is not sandboxed;
  Sparkle docs allow removal).
- rpath: `install_name_tool -add_rpath @executable_path/../Frameworks Contents/MacOS/Margin` (skip if
  `otool -l` already lists it).
- Signing moves to a new shared script `scripts/sign.sh <identity> [extra codesign flags…]` that signs
  inside-out with no `--deep`: `Sparkle.framework/Versions/B/Autoupdate`, then
  `Sparkle.framework/Versions/B/Updater.app`, then `Sparkle.framework`, then `Margin.app` (the app step
  takes `--entitlements scripts/Margin.entitlements`). `bundle.sh` calls it with identity `-`.

#### 8. Release script (`scripts/release.sh` edited), release notes, key

- Refuse to run when `QA_LOCAL_FEED` is set unless `ALLOW_QA_RELEASE=1` (used only by the QA script).
- Sign via `scripts/sign.sh "$SIGN_ID" --options runtime --timestamp`; keep
  `codesign --verify --strict --deep` as the verification step.
- Release notes: `releases/<version>.md` is required (the script exits 1 with a clear message if it is
  missing). Format: lines starting with "- ", 1 to 5 of them, plain text. Create `releases/0.2.0.md`.
- After the DMG is final (after stapling when notarized, since stapling changes the bytes), run
  `sign_update "$DMG"` and write `dist/appcast.xml` containing exactly one item (the version just
  built):

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Margin</title>
    <link>https://margin.motiontic.com/appcast.xml</link>
    <item>
      <title>Margin 0.2.0</title>
      <pubDate>RFC 822 date of the build</pubDate>
      <sparkle:version>0.2.0</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul><li>note line</li></ul>]]></description>
      <enclosure url="${DOWNLOAD_BASE}/Margin-0.2.0.dmg"
                 sparkle:edSignature="…" length="…" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

  `DOWNLOAD_BASE` defaults to `https://margin.motiontic.com/download`. Note lines are XML-escaped.
  The script ends by printing the two files to copy into `margin-site` (`dist/Margin-<v>.dmg` to
  `download/`, `dist/appcast.xml` to the site root). It does not touch the site repo or deploy.
- EdDSA key: generated once with Sparkle's `generate_keys` (stored in the maintainer's login keychain,
  service `https://sparkle-project.org`, account `ed25519`). Only the public key is committed, in
  `bundle.sh`. The private key is never exported, printed, or committed by this loop. `README.md` gets
  a "Releasing" section covering: the release command, copying the two files to the site, and backing
  up the key with `generate_keys -x <file>` to a password manager.

#### 9. Site (`margin-site`)

- `_headers`: add `/appcast.xml` with `Content-Type: application/xml; charset=utf-8` and
  `Cache-Control: public, max-age=300`.
- `index.html`: one privacy line near the existing "local" claim: "Margin checks margin.motiontic.com
  once a day for a new version. Nothing about you or your notes is sent. Turn it off from the menu bar
  icon." Match the surrounding copy style.
- `README.md`: a short "Publishing an update" section (copy DMG and `appcast.xml`, update the three
  download links, deploy with wrangler).
- This PR does not add `appcast.xml` or a 0.2.0 DMG. Those are produced by the notarized release after
  merge.

#### 10. QA harness (`scripts/qa-update.sh`, new)

Builds a signed (not notarized) "old" app at `VERSION=0.2.0 QA_LOCAL_FEED=1` and copies it to
`build/qa/Margin.app`; builds a "new" DMG at `VERSION=0.2.1` with a throwaway `releases/0.2.1.md`
created in `build/qa` (not committed) and `DOWNLOAD_BASE=http://127.0.0.1:8765`; serves `dist/` on
port 8765; launches the old app with `MARGIN_FEED_URL` set to the `appcast.xml` on that local server and
`MARGIN_NOTES_DIR` pointing at a temp folder. It then prints the manual checks from Acceptance
Criteria 4 to 9. `--tamper` flips one byte of the served DMG to exercise criterion 10.

## Acceptance Criteria

1. `swift build -c release` and `swift test` exit 0; the test count is at least 50 (38 existing plus at least 12 new).
2. `scripts/bundle.sh` produces `dist/Margin.app` where `Contents/Frameworks/Sparkle.framework` exists, contains no `XPCServices`, `otool -l Contents/MacOS/Margin` lists `@executable_path/../Frameworks`, `CFBundleVersion` equals `CFBundleShortVersionString` equals `0.2.0`, and the five `SU*` keys are present. The app launches and shows the panel.
3. With a Developer ID identity, `scripts/release.sh` (notarization skipped via a non-existent `NOTARY_PROFILE`) passes `codesign --verify --strict --deep`, and `dist/appcast.xml` is well-formed XML (`xmllint --noout`) whose enclosure `length` equals the DMG's byte size and whose `sparkle:edSignature` is non-empty.
4. QA run, background path: the old app (0.2.0), left alone, downloads 0.2.1 with no window, alert, focus change or panel expansion, and within 60 s of launch the card reads "Margin 0.2.1 is ready" with the note lines and a "Restart to update" button.
5. With the panel minimised in that state, the nub shows the pulsing dot; expanding hides the dot and shows the card; under Reduce Motion the dot is static and the card appears without animation.
6. Clicking "Restart to update" quits and relaunches Margin without any Sparkle window; the relaunched app's `CFBundleShortVersionString` is `0.2.1`, the card is hidden, and the notes folder content is byte-identical to before.
7. Clicking "Later" hides the card for that launch and keeps the dot; quitting Margin from the menu installs the update, and the next launch is 0.2.1.
8. "Check for Updates…" on an up-to-date app expands the panel if minimised, shows "Checking for updates…", then "You're up to date" with the current version, and the card hides itself after 3 s.
9. Unticking "Check for Updates Automatically" persists across relaunch (menu shows it unticked) and the app then makes no request to the feed URL during a 2 minute run (verified in the QA server log); a manual check still works.
10. With `--tamper`, the app does not install the archive, stays on 0.2.0, and never shows "is ready".
11. With the feed unreachable (server stopped), a background check shows no UI at all; a manual check shows "Couldn't check for updates" with a Dismiss button.
12. No Sparkle-provided window or alert appears in any of 4 to 11.
13. Idle CPU with the card hidden and no update pending is at most 0.5% over 30 s (`top -l 30 -pid`), and at most 1.0% while the nub dot is pulsing. Memory footprint (`footprint`) is at most 45 MB.
14. Running the unbundled binary (`swift run Margin`) does not crash and shows no updater UI.
15. Each test in the Testing Plan states its card: `protects=<observable it protects>; fails_when=<wrong result it rejects>; no_claim=<what green does not prove; which fixtures or mocks stand in for what, or "none beyond protects">`.
16. No degradation of existing functionality: the 38 existing tests pass unchanged; drawer open and close, minimise and expand, drag-to-place, and the editor still work with the card both hidden and shown.

## Testing Plan

| Layer | What | Count |
|-------|------|-------|
| Unit (`Tests/MarginCoreTests/UpdateModelTests.swift`) | `ReleaseNotes.lines`: nil, empty, plain lines, `<ul><li>`, `<br>`/`<p>`, entity decoding, more than 5 lines, 121+ character line, leading "- " stripped | +9 |
| Unit (same file) | `UpdatePhase.showsCard`, `showsNubDot`, `autoDismissAfter` across all 8 cases | +3 |
| Script | `scripts/bundle.sh` and `scripts/release.sh` structural checks from criteria 2 and 3, run as shell assertions in `scripts/qa-update.sh --check-only` | +1 |
| E2E (manual, scripted setup) | `scripts/qa-update.sh` covering criteria 4 to 12, with a screenshot of the ready card, the nub dot, and the post-relaunch version saved under `.loops/runs/` as proof | +1 run, 9 checks |

Unit tests cover parsing and phase logic only. They do not prove Sparkle integration, signing or the
visual result; the E2E run is the only evidence for those.

## Rules for the implementing agent

1. Acceptance criteria are the `protects / fails_when / no_claim` profile of each test: the observable it protects, the wrong result it rejects, and what green does not prove. Never "make the tests pass".
2. Real code and real tests land in the same change; a placeholder, a stub assertion or a test deferred to a follow-up is not done.
3. Any change to a test, validator, CI step, timeout, tolerance, threshold, snapshot or suppression pragma is reported on its own line in your summary with its justification, before any other result.
4. A reported command names the command and its observed result (exit status, counts, the failing line); a command you did not run is not reported, and stderr is never silenced in a command you cite.
5. Your report is a claim until the parent re-executes it: say what you verified, what you reused, and what you could not check.
6. Build gate for this workspace: `swift build -c release && swift test` in `margin`. Neither repo has a `package.json`; the workspace convention's `npm run build` does not apply. `margin-site` is static and has no build.
7. Do not notarize, publish `appcast.xml`, deploy the site, push to `main`, or export the EdDSA private key. Do not commit anything under `dist/` or `build/`.
8. Verify every Sparkle symbol name against the headers in the resolved artifact before use. Where the header disagrees with this spec, the header wins; report the difference.

## Rollback Plan

- Before release: revert the two PRs. No user is affected.
- After 0.2.0 is live: users on 0.2.0 only act on what `appcast.xml` offers. To stop a bad update,
  replace `appcast.xml` on the site with the last good item (takes effect within the 5 minute cache).
  To fix forward, publish a higher version. An update is never offered unless its version is higher
  than the installed one, so a broken release cannot be "un-installed" remotely; it needs a fixed
  higher version.
- If the EdDSA private key is lost: Sparkle supports key rotation for Developer ID apps as long as the
  Apple signing certificate is unchanged in that same update.

## Effort Estimate

| Component | Human | CC |
|-----------|-------|----|
| Package + bundle embedding + shared signing script | 4 h | 15 min |
| `UpdateModel` + unit tests | 2 h | 10 min |
| `UpdaterController` (16 driver methods + delegate) | 5 h | 20 min |
| Card view, MainView layout, nub dot | 6 h | 25 min |
| Release script, appcast generation, key, README | 3 h | 15 min |
| Site PR | 1 h | 5 min |
| QA harness + E2E run + proof | 4 h | 25 min |
| Total | ~25 h | ~2 h |

## Files Reference

| File | Change |
|------|--------|
| `Package.swift` | Add Sparkle dependency to the `Margin` target |
| `Sources/MarginCore/UpdateModel.swift` | New: `UpdateInfo`, `UpdatePhase`, `ReleaseNotes` |
| `Sources/Margin/UpdaterController.swift` | New: Sparkle user driver and delegate |
| `Sources/Margin/AppDelegate.swift:323-357` | Menu items; create and wire `UpdaterController` |
| `Sources/MarginKit/Update/UpdateCardView.swift` | New: the glass card |
| `Sources/MarginKit/MainView.swift:25-59` | Host the card between scroll and toolbar; `setUpdatePhase` |
| `Sources/MarginKit/Material/GlassView.swift` | `showsUpdateDot` and the pulsing dot layer |
| `Sources/MarginKit/Window/PanelController.swift` | `hasPendingUpdate`, kept across minimise and expand |
| `Tests/MarginCoreTests/UpdateModelTests.swift` | New: 12 tests |
| `scripts/bundle.sh:7,45,55-56` | Version 0.2.0, `CFBundleVersion`, `SU*` keys, embed framework, rpath, call `sign.sh` |
| `scripts/sign.sh` | New: inside-out signing |
| `scripts/release.sh` | Use `sign.sh`; require release notes; write `dist/appcast.xml` |
| `scripts/qa-update.sh` | New: local end-to-end update harness |
| `releases/0.2.0.md` | New: release notes |
| `README.md` | "Releasing" section; mention auto-update and how to turn it off |
| `margin-site/_headers` | `/appcast.xml` headers |
| `margin-site/index.html` | Privacy line about the daily update check |
| `margin-site/README.md` | "Publishing an update" section |

## Out of Scope

- Download counts, active-install counts, or any analytics (follow-up loop; the feed URL chosen here lets that be added without an app release).
- Notarizing and publishing 0.2.0, deploying the site, merging the PRs.
- Delta updates, beta channels, phased rollouts, critical-update flags.
- A settings window. The toggle lives in the menu-bar menu.
- An "Updated to x" confirmation after relaunch.
- Universal (Intel) builds; the build stays host-architecture as it is today.
- Fixing the npm-based `dev` commands that `gloop init` wrote to the workspace `loops.json`.

## Related

- https://sparkle-project.org/documentation/custom-user-interfaces/
- https://sparkle-project.org/documentation/publishing/
- `docs/IMPLEMENTATION_PLAN.md` (original architecture)
