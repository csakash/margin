import AppKit
import Sparkle
import MarginCore
import MarginKit

/// Margin's side of Sparkle. Sparkle finds, verifies, downloads and installs updates; this class
/// is its "user driver": instead of Sparkle's own windows, every callback is reduced to an
/// `UpdatePhase` that the in-panel card and the nub draw.
///
/// Normal path: Sparkle checks once a day, downloads quietly, then calls
/// `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`. We keep that block and show
/// "Margin x is ready". One click runs it; otherwise Sparkle installs when Margin quits.
@MainActor
final class UpdaterController: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    /// Called after `phase` or the card's visibility changes.
    var onChange: (() -> Void)?

    private(set) var phase: UpdatePhase = .idle
    /// "Later" hides the card for this launch but keeps the update (and the nub dot).
    private var cardDismissed = false
    /// What the card should draw.
    var cardPhase: UpdatePhase { cardDismissed ? .idle : phase }
    /// The version waiting to be installed, if one is downloaded.
    var readyVersion: String? {
        if case .ready(let i) = phase { return i.version }
        return nil
    }

    private var updater: SPUUpdater?
    private var info: UpdateInfo?
    /// From `willInstallUpdateOnQuit`: installs and relaunches at once.
    private var installNow: (() -> Void)?
    /// Pending answer to `showUpdateFound`.
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var installWhenFound = false
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var dismissTimer: Timer?
    private var reofferTimer: Timer?

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    // MARK: Lifecycle

    /// Starts Sparkle. Does nothing when Margin runs unbundled (`swift run`), where there is no
    /// Info.plist feed and nothing to replace.
    private static let pendingKey = "margin.pendingUpdate"

    func start() {
        announceIfUpdated()
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let u = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        do {
            try u.start()
            updater = u
        } catch {
            NSLog("Margin: updater did not start: %@", error.localizedDescription)
        }
    }

    /// After the relaunch into the version that was waiting: say so once, with its notes.
    private func announceIfUpdated() {
        let d = UserDefaults.standard
        guard let pending = PendingUpdate.decode(d.data(forKey: Self.pendingKey)) else {
            d.removeObject(forKey: Self.pendingKey)   // unreadable: never show it
            return
        }
        d.removeObject(forKey: Self.pendingKey)
        // Not this version (not installed, or something newer arrived another way): forget it.
        // If the download is still waiting, Sparkle reports it ready again and it is stored again.
        guard pending.version == currentVersion else { return }
        set(.installed(pending.info))
        Sounds.play(.installed)
    }

    // MARK: What the app calls

    var canCheck: Bool { updater?.canCheckForUpdates ?? false }
    var isAvailable: Bool { updater != nil }

    var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// "Check for Updates…". With an update already waiting, just brings its card back.
    func checkNow() {
        if case .ready = phase {
            cardDismissed = false
            onChange?()
            return
        }
        updater?.checkForUpdates()
    }

    /// The card's white button.
    func primaryAction() {
        switch phase {
        case .available:
            let reply = foundReply
            foundReply = nil
            reply?(.install)   // Sparkle now reports download progress, then asks to relaunch
        case .ready:
            restartToUpdate()
        default:
            break
        }
    }

    func restartToUpdate() {
        guard case .ready(let i) = phase else { return }
        set(.installing(i))   // also makes a second click a no-op
        // Whatever path is taken, a restart that does not happen (the quit was cancelled, Sparkle
        // was busy) must not leave a spinner with no buttons: offer it again.
        reofferTimer?.invalidate()
        reofferTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .installing(i) else { return }
                self.set(.ready(i))
            }
        }
        if let installNow {
            installNow()   // Sparkle allows calling this again, so it is kept until the cycle ends
        } else if let reply = foundReply {
            foundReply = nil
            reply(.install)
        } else {
            // "Later" already answered Sparkle; ask it to surface the downloaded update again.
            installWhenFound = true
            updater?.checkForUpdates()
        }
    }

    /// "Later" / "Dismiss".
    func dismiss() {
        switch phase {
        case .available:
            let reply = foundReply
            foundReply = nil
            reply?(.dismiss)
            set(.idle)
        case .ready:
            let reply = foundReply
            foundReply = nil
            reply?(.dismiss)   // keeps the download; Sparkle installs it on quit
            cardDismissed = true
            onChange?()
        case .failed:
            set(.idle)
        default:
            break
        }
    }

    // MARK: State

    private func set(_ new: UpdatePhase) {
        guard new != phase || cardDismissed else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        // Remember a downloaded update so the relaunched version can announce it.
        if case .ready(let i) = new, let data = PendingUpdate(i).encoded() {
            UserDefaults.standard.set(data, forKey: Self.pendingKey)
        }
        phase = new
        cardDismissed = false
        if case .downloading = new {} else { NSLog("Margin updater: %@", String(describing: new).components(separatedBy: "(").first ?? "") }
        if let delay = new.autoDismissAfter {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.phase == new else { return }
                    self.set(.idle)
                }
            }
        }
        onChange?()
    }

    private func describe(_ item: SUAppcastItem) -> UpdateInfo {
        // The feed is outside the app: only version-shaped text is shown, and notes are plain lines.
        let version = ReleaseNotes.safeVersion(item.displayVersionString)
            ?? ReleaseNotes.safeVersion(item.versionString) ?? "update"
        return UpdateInfo(version: version, notes: ReleaseNotes.lines(from: item.itemDescription))
    }

    // MARK: SPUUpdaterDelegate

    /// QA only: point at a local feed. Sparkle refuses any archive that is not signed with the
    /// app's EdDSA key, whatever feed offered it; see `Override` for who may set this.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let url = Override.value("MARGIN_FEED_URL") else { return nil }
        return url
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let i = describe(item)
        info = i
        installNow = { NSLog("Margin updater: immediate install requested"); immediateInstallHandler() }
        set(.ready(i))
        return true   // we present it; Sparkle still installs on quit if the user never clicks
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        installWhenFound = false
        installNow = nil   // the block belongs to the cycle that just ended; a later click asks Sparkle afresh
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Not expected (SUEnableAutomaticChecks is set). Never send a system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if !installWhenFound { set(.checking) }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let i = describe(appcastItem)
        info = i
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            set(.idle)
            return
        }
        switch state.stage {
        case .notDownloaded:
            installWhenFound = false
            foundReply = reply
            set(.available(i))
        case .downloaded, .installing:
            if installWhenFound {
                installWhenFound = false
                set(.installing(i))
                reply(.install)
            } else {
                foundReply = reply
                set(.ready(i))
            }
        @unknown default:
            reply(.dismiss)
        }
    }

    // Notes come from the item's inline description, so there is nothing to load.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        installWhenFound = false
        set(.upToDate(currentVersion))
    }

    /// Sparkle only calls this when the user knew an update was in progress (a manual check, or
    /// after clicking the card). A failed background check never reaches here; it retries tomorrow.
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // Acknowledge at once: the card is not modal, and an unanswered error would keep Sparkle's
        // update cycle open, stopping scheduled checks until the next launch.
        acknowledgement()
        installWhenFound = false
        let line = error.localizedDescription.components(separatedBy: .newlines).first ?? "Unknown error"
        set(.failed(line))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        if let info { set(.downloading(info, 0)) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard let info, expectedBytes > 0 else { return }
        // Whole percents only: a chunk that does not move the number does not redraw the card.
        let percent = min(100, Int(Double(receivedBytes) / Double(expectedBytes) * 100))
        set(.downloading(info, Double(percent) / 100))
    }

    func showDownloadDidStartExtractingUpdate() {
        if let info { set(.downloading(info, 1)) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if let info { set(.downloading(info, 1)) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Only reached after the user clicked "Update now", so there is nothing left to ask.
        if let info { set(.installing(info)) }
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        if let info { set(.installing(info)) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        foundReply = nil
        switch phase {
        case .checking, .available, .downloading, .installing:
            set(.idle)
        case .ready:
            // Still installs on quit. Keep the card only if we can still act on it.
            if installNow == nil { cardDismissed = true; onChange?() }
        case .idle, .upToDate, .failed, .installed:
            break
        }
    }
}

/// Test and demo overrides, read from the environment. QA builds (bundle id ending in ".qa",
/// made by scripts/qa-update.sh) also read them from their own settings, so the copy that
/// relaunches after an update keeps them. The released app never reads them from settings:
/// another process must not be able to redirect its feed or notes folder persistently.
enum Override {
    static func value(_ key: String) -> String? {
        var v = ProcessInfo.processInfo.environment[key]
        if v == nil, Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true {
            v = UserDefaults.standard.string(forKey: key)
        }
        return (v?.isEmpty ?? true) ? nil : v
    }
}
