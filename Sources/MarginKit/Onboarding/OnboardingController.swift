import AppKit
import MarginCore

/// Runs the first-launch tour: the arrival, seven steps (welcome, five topics, ready), sounds, the screen veil, and handing the
/// panel back to the user afterwards. The app forwards three things to it while it is active:
/// the fold hotkey (`foldKeyPressed`), panel state changes (`panelStateChanged`) and a finished
/// drag (`didPlace`).
@MainActor
public final class OnboardingController {
    public static let doneKey = "margin.onboarded"
    /// The tour's own panel size; the user's size comes back when it ends.
    static let tourSize = NSSize(width: 400, height: 380)

    /// Called once the tour has ended (finished or skipped) and the normal UI is back.
    public var onFinish: (() -> Void)?
    public private(set) var isActive = false
    /// True from start until the normal UI is fully back (includes the closing fade).
    public var isBusy: Bool { isActive || view != nil }

    private let panel: PanelController
    private let mainView: NSView
    private var view: OnboardingView?
    private var veil: VeilWindow?
    private var step = 0
    private var savedSize = NSSize.zero
    private var sawFold = false
    private var expandSoundPlayed = false
    private var placed = false
    private var timers: [Timer] = []

    public init(panel: PanelController, mainView: NSView) {
        self.panel = panel
        self.mainView = mainView
    }

    /// The tour has run, or this Mac already used Margin before the tour existed
    /// (a saved note or panel position): those people skip it.
    public static var hasRun: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: doneKey) { return true }
        if d.bool(forKey: startedKey) { return false }   // began it on a first launch, never finished
        return d.string(forKey: "margin.current") != nil || d.string(forKey: "margin.anchor") != nil
    }
    static let startedKey = "margin.tourStarted"

    // MARK: Start / finish

    public func start() {
        guard !isBusy, let glass = panel.glass else { return }
        isActive = true
        UserDefaults.standard.set(true, forKey: Self.startedKey)
        panel.panel.makeFirstResponder(nil)   // nothing types into the hidden editor meanwhile
        step = 0
        sawFold = false
        expandSoundPlayed = false
        placed = false
        if panel.isMinimised { panel.setMinimised(false, animated: false) }

        savedSize = panel.expandedSize
        panel.expandedSize = Self.tourSize
        panel.sizeLocked = true

        let v = OnboardingView(frame: glass.contentView.bounds)
        v.onPrimary = { [weak self] in self?.primary() }
        v.onSkip = { [weak self] in self?.finish(skipped: true) }
        v.onKeycaps = { [weak self] in self?.foldKeyPressed() }
        v.onSecondary = { [weak self] in self?.go((self?.step ?? 0) + 1) }
        v.onHeaderMouseDown = { [weak self] e in self?.headerMouseDown(e) }
        glass.contentView.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            v.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            v.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
        mainView.isHidden = true
        view = v
        v.show(0, animated: false)

        let veil = VeilWindow(screen: panel.screen, below: panel.panel.level)
        veil.show(alpha: 0.55)
        self.veil = veil

        Sounds.play(.arrive)
        panel.arriveCentered(size: Self.tourSize) { [weak self] in
            guard let self else { return }
            if let skipped = self.finishAfterArrival {
                self.finishAfterArrival = nil
                self.finish(skipped: skipped)
                return
            }
            guard let v = self.view else { return }
            self.panel.panel.makeFirstResponder(v)
            v.show(0, animated: true)
        }
    }

    /// Ends the tour now (as if skipped) and runs `then` once the normal UI is back.
    public func endNow(then: @escaping () -> Void) {
        if !isActive {
            if view != nil {
                // Already closing: run it once the normal UI is back.
                let earlier = afterFinish
                afterFinish = { earlier?(); then() }
            } else {
                then()
            }
            return
        }
        let earlier = afterFinish
        afterFinish = { earlier?(); then() }
        finish(skipped: true)
    }
    private var afterFinish: (() -> Void)?
    /// A finish requested while the panel was still opening; carried out once it lands.
    private var finishAfterArrival: Bool?

    private func finish(skipped: Bool) {
        guard isActive else { return }
        if panel.isArriving {
            // The panel ignores anchor and size requests while it opens; restoring now would be lost.
            finishAfterArrival = skipped
            return
        }
        isActive = false
        timers.forEach { $0.invalidate() }
        timers = []
        UserDefaults.standard.set(true, forKey: Self.doneKey)

        veil?.hide()
        veil = nil
        let v = view
        let restore = { [self] in
            v?.removeFromSuperview()
            view = nil
            mainView.isHidden = false
            mainView.alphaValue = 1
            panel.expandedSize = savedSize
            panel.sizeLocked = false
            if panel.isMinimised { panel.setMinimised(false) }
            panel.setAnchor(panel.anchor)   // back to the user's size at the chosen spot
            onFinish?()
            let next = afterFinish
            afterFinish = nil
            next?()
        }
        if Theme.reduceMotion || v == nil {
            restore()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                v?.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { restore() } })
        }
    }

    // MARK: Steps

    private var askedForScreens = false

    private func primary() {
        if TourStep.all[step].kind == .screens, !askedForScreens, !ScreenAccess.isGranted {
            // macOS shows its prompt once; the grant takes effect after Margin restarts.
            askedForScreens = true
            if ScreenAccess.wasRequested {
                // macOS only prompts once; after that, the switch is in System Settings.
                ScreenAccess.openSettings()
                view?.setTryMessage("Switch on Margin in System Settings, then reopen Margin")
            } else {
                ScreenAccess.request()
                view?.setTryMessage("Switch on Margin in the list, then reopen Margin when macOS asks")
            }
            view?.setPrimaryTitle("Next")
            view?.setSecondary(nil)
            return
        }
        if step >= TourStep.all.count - 1 {
            finish(skipped: false)
        } else {
            go(step + 1)
        }
    }

    private func go(_ index: Int) {
        step = index
        view?.show(index, animated: true)
        Sounds.play(.step)
        switch index {
        case 1:
            veil?.fade(to: 0.25)
            panel.setAnchor(.right)
        case 4:
            runWriteDemo()
        case 5:
            // Far enough: a restart from macOS's "Quit & Reopen" must not start the tour again.
            UserDefaults.standard.set(true, forKey: Self.doneKey)
            askedForScreens = false
            if ScreenAccess.isGranted {
                view?.completeTry(message: "Already allowed")
                view?.setPrimaryTitle("Next")
                view?.setSecondary(nil)
            }
        case 6:
            veil?.fade(to: 0)
            after(0.12) { [weak self] in
                Sounds.play(.done)
                self?.panel.glass?.glint()
            }
        default:
            break
        }
    }

    // MARK: Fold (the fold hotkey or the keycaps)

    /// The fold hotkey (⌥ Space by default) while the tour is active, and the keycaps button.
    public func foldKeyPressed() {
        let minimising = !panel.isMinimised
        if step == 2 {
            Sounds.play(minimising ? .collapse : .expand)
            if !minimising { expandSoundPlayed = true }
        }
        panel.toggleMinimised()
    }

    /// Every anchor or minimise change while the tour is active.
    public func panelStateChanged() {
        guard isActive, let v = view else { return }
        if !panel.isMinimised { panel.panel.makeFirstResponder(v) }
        guard step == 2 else { return }
        if panel.isMinimised {
            if !sawFold {
                sawFold = true
                expandSoundPlayed = false
                let keys = ShortcutStore().shortcut(for: .toggle).keycaps.joined(separator: " ")
                v.setTryMessage("Now bring it back: \(keys) again")
            }
        } else if sawFold {
            // Expanded by clicking the line instead of the keys: still play the sound once.
            if !expandSoundPlayed { Sounds.play(.expand) }
            sawFold = false
            v.completeTry(message: "That is the whole trick")
        }
    }

    // MARK: Place (drag the top bar)

    private func headerMouseDown(_ event: NSEvent) {
        guard step == 3 else { return }
        panel.beginHeaderDrag(with: event)
    }

    /// A drag ended on a spot (DragPlacement's `onPlaced`).
    public func didPlace() {
        guard isActive, step == 3, !placed else { return }
        placed = true
        Sounds.play(.snap)
        view?.completeTry(message: "Snapped. It remembers this spot")
    }

    // MARK: Write demo

    private func runWriteDemo() {
        guard let v = view else { return }
        let heading = "# Reading notes", bullet = "- Capture costs under 2 seconds"
        let marker: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.textTertiary]
        func typed(_ field: NSTextField, _ text: String, _ count: Int) {
            let s = NSMutableAttributedString(string: String(text.prefix(count)),
                                              attributes: [.font: field.font!, .foregroundColor: field.textColor!])
            s.addAttributes(marker, range: NSRange(location: 0, length: min(2, s.length)))
            field.attributedStringValue = s
        }
        let speed = Theme.reduceMotion ? 0.0 : 0.055
        var t = 0.25
        for i in 1...heading.count { let n = i; after(t) { typed(v.demoHeading, heading, n) }; t += speed }
        t += 0.3
        after(t) { v.demoHeading.stringValue = "Reading notes" }   // the "# " goes; it is a heading now
        t += 0.35
        for i in 1...bullet.count { let n = i; after(t) { typed(v.demoBullet, bullet, n) }; t += speed }
        t += 0.3
        after(t) { v.demoBullet.stringValue = "•  Capture costs under 2 seconds" }
        t += 0.45
        after(t) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                v.demoChips.animator().alphaValue = 1
            }
        }
    }

    private func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { block() }
        }
        timers.append(timer)
    }
}

/// Dims the screen behind the panel during the tour. Click-through, on every Space. A
/// non-activating panel, like Margin's own: an ordinary window cannot appear over another app's
/// full-screen Space.
@MainActor
final class VeilWindow: NSPanel {
    init(screen: NSScreen, below level: NSWindow.Level) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        self.level = NSWindow.Level(rawValue: level.rawValue - 1)
        isOpaque = false
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        alphaValue = 0
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(alpha: CGFloat) {
        orderFrontRegardless()
        fade(to: alpha)
    }

    func fade(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        if Theme.reduceMotion {
            alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.9
            ctx.timingFunction = Theme.easeOut
            animator().alphaValue = alpha
        }, completionHandler: { completion?() })
    }

    /// Holds itself until the fade ends (nothing else keeps the window alive by then).
    func hide() {
        fade(to: 0) { MainActor.assumeIsolated { self.orderOut(nil) } }
    }
}
