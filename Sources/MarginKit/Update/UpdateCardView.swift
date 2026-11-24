import AppKit
import QuartzCore
import MarginCore

/// The in-panel update notice. Sits between the editor and the toolbar and grows from zero height,
/// so it pushes the note up instead of covering it. Draws every `UpdatePhase`; knows nothing about
/// the updater itself.
@MainActor
public final class UpdateCardView: NSView {
    /// "Update now" / "Restart to update".
    public var onPrimary: (() -> Void)?
    /// "Later" / "Dismiss".
    public var onDismiss: (() -> Void)?

    public private(set) var phase: UpdatePhase = .idle
    /// Reports the height the card wants (0 when hidden) and whether the change is animated.
    public var onTargetHeightChange: ((CGFloat, Bool) -> Void)?

    private static let padX: CGFloat = 18
    private static let padTop: CGFloat = 14
    private static let padBottom: CGFloat = 15

    private let hairline = HairlineView()
    private let stack = NSStackView()
    private let spinner = SpinnerView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = ProgressLine()
    private let primary = GlowButton()
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let titleRow = NSStackView()
    private let actionRow = NSStackView()
    private let shine = CAGradientLayer()
    private var height: NSLayoutConstraint!
    private var measuredWidth: CGFloat = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: 0)
        height.priority = NSLayoutConstraint.Priority(900)   // in a very short panel the card clips, the layout never breaks
        height.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Software update")

        titleLabel.font = Theme.ui(13, .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = Theme.mono(10.5, .medium)
        detailLabel.textColor = Theme.textTertiary
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        bodyLabel.font = Theme.ui(12)
        bodyLabel.textColor = Theme.textSecondary
        bodyLabel.isSelectable = false
        bodyLabel.maximumNumberOfLines = 10   // 5 notes of up to 2 wrapped lines; bounds the card's height
        bodyLabel.cell?.truncatesLastVisibleLine = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.setViews([spinner, titleLabel, spacer, detailLabel], in: .leading)

        primary.target = self
        primary.action = #selector(primaryClicked)
        secondary.isBordered = false
        secondary.target = self
        secondary.action = #selector(secondaryClicked)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 14
        actionRow.setViews([primary, secondary], in: .leading)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([titleRow, bodyLabel, progress, actionRow], in: .top)
        stack.setCustomSpacing(11, after: bodyLabel)
        stack.setCustomSpacing(12, after: progress)

        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padTop),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padX),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padX),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // One-shot "tank shine" band, shown when an update becomes ready.
        let white = { (a: CGFloat) in NSColor(white: 1, alpha: a).cgColor }
        shine.colors = [white(0), white(0.10), white(0)]
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.transform = CATransform3DMakeAffineTransform(CGAffineTransform(a: 1, b: 0, c: -0.32, d: 1, tx: 0, ty: 0))
        shine.opacity = 0
        layer?.addSublayer(shine)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Phase

    public func apply(_ newPhase: UpdatePhase, animated: Bool) {
        let old = phase
        phase = newPhase
        if newPhase.showsCard { render(newPhase) }   // keep the old content on screen while collapsing
        let target = newPhase.showsCard ? fittingHeight() : 0
        setHeight(target, animated: animated)
        if case .ready = newPhase, old != newPhase { playShine(cardHeight: target) }
        if !newPhase.showsCard {
            // Once collapsed, nothing may keep animating or stay reachable inside a zero-height card.
            let moving = animated && !Theme.reduceMotion && window != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (moving ? 0.45 : 0)) { [weak self] in
                guard let self, !self.phase.showsCard else { return }
                self.spinner.isSpinning = false
                self.spinner.isHidden = true
                self.actionRow.isHidden = true
            }
        }
    }

    private func render(_ p: UpdatePhase) {
        var title = "", detail = "", body = "", primaryTitle: String?, secondaryTitle: String?
        var spinning = false, fraction: Double?
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        func arrow(_ i: UpdateInfo) -> String { current.map { "\($0) → \(i.version)" } ?? "" }
        func bullets(_ i: UpdateInfo) -> String { i.notes.map { "•  \($0)" }.joined(separator: "\n") }

        switch p {
        case .idle: break
        case .checking:
            title = "Checking for updates…"; spinning = true
        case .available(let i):
            title = "Margin \(i.version) is available"; detail = arrow(i); body = bullets(i)
            primaryTitle = "Update now"; secondaryTitle = "Later"
        case .downloading(let i, let f):
            title = "Downloading Margin \(i.version)"; fraction = min(max(f, 0), 1)
            detail = "\(Int((fraction ?? 0) * 100))%"
        case .ready(let i):
            title = "Margin \(i.version) is ready"; detail = arrow(i); body = bullets(i)
            primaryTitle = "Restart to update"; secondaryTitle = "Later"
        case .installing(let i):
            title = "Installing Margin \(i.version)…"; spinning = true
        case .upToDate(let v):
            title = "You're up to date"; body = "Margin \(v)"
        case .failed(let message):
            title = "Couldn't check for updates"; body = message; secondaryTitle = "Dismiss"
        }

        // Everything from the feed is shown as plain text: stringValue, never attributed HTML.
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        bodyLabel.stringValue = body
        bodyLabel.isHidden = body.isEmpty
        spinner.isHidden = !spinning
        spinner.isSpinning = spinning
        progress.isHidden = fraction == nil
        if let fraction { progress.fraction = fraction }
        primary.isHidden = primaryTitle == nil
        if let primaryTitle { primary.title = primaryTitle }
        secondary.isHidden = secondaryTitle == nil
        if let secondaryTitle {
            secondary.attributedTitle = NSAttributedString(string: secondaryTitle, attributes: [
                .font: Theme.ui(12.5), .foregroundColor: Theme.textSecondary,
            ])
        }
        actionRow.isHidden = primaryTitle == nil && secondaryTitle == nil
    }

    // MARK: Height

    private func fittingHeight() -> CGFloat {
        measuredWidth = bounds.width
        let w = max(bounds.width - 2 * Self.padX, 120)
        bodyLabel.preferredMaxLayoutWidth = w
        return ceil(stack.fittingSize.height) + Self.padTop + Self.padBottom
    }

    private func setHeight(_ h: CGFloat, animated: Bool) {
        guard abs(targetHeight - h) > 0.5 else { return }
        targetHeight = h
        onTargetHeightChange?(h, animated)
        if animated, !Theme.reduceMotion, window != nil {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.42
                ctx.timingFunction = Theme.spring
                ctx.allowsImplicitAnimation = true
                height.animator().constant = h
                superview?.layoutSubtreeIfNeeded()
            }
        } else {
            height.constant = h
        }
    }

    /// The height last asked for (the constraint itself may be mid-animation).
    private var targetHeight: CGFloat = 0

    /// Wrapped note lines change height with the panel's width.
    public override func layout() {
        super.layout()
        guard phase.showsCard, abs(bounds.width - measuredWidth) > 0.5 else { return }
        setHeight(fittingHeight(), animated: false)
    }

    // MARK: Shine

    private var shineRun = 0

    private func playShine(cardHeight: CGFloat) {
        guard !Theme.reduceMotion, bounds.width > 0 else { return }
        shineRun += 1
        let run = shineRun
        let h = max(cardHeight, 60)
        let band = bounds.width * 0.38
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shine.bounds = CGRect(x: 0, y: 0, width: band, height: h * 1.6)
        shine.position = CGPoint(x: -band, y: h / 2)
        shine.opacity = 1
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -band
        a.toValue = bounds.width + band
        a.duration = 0.9
        a.timingFunction = Theme.easeOut
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.shineRun == run else { return }   // a newer sweep is in flight
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.shine.opacity = 0   // never leave the band parked where a wider panel would reveal it
            CATransaction.commit()
        }
        shine.position.x = bounds.width + band
        shine.add(a, forKey: "shine")
        CATransaction.commit()
    }

    // MARK: Actions

    @objc private func primaryClicked() { onPrimary?() }
    @objc private func secondaryClicked() { onDismiss?() }
}

// MARK: - Pieces

/// White capsule with a soft glow: the one primary action on the card.
@MainActor
final class GlowButton: NSButton {
    override var title: String { didSet { refresh() } }
    private var pressed = false { didSet { layer?.opacity = pressed ? 0.82 : 1 } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.white.cgColor
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 9
        layer?.shadowOpacity = 0.28
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.ui(12.5, .semibold), .foregroundColor: NSColor.black,
        ])
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 28, height: 30)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)   // tracks until mouse-up, then sends the action
        pressed = false
    }
}

/// 2 pt download progress line.
@MainActor
final class ProgressLine: NSView {
    var fraction: Double = 0 { didSet { needsLayout = true } }
    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        fill.backgroundColor = NSColor.white.cgColor
        fill.cornerRadius = 1
        fill.anchorPoint = .zero
        layer?.addSublayer(fill)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 2).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height)
    }
}

/// 10 pt arc that turns while something is in flight. Core Animation only.
@MainActor
final class SpinnerView: NSView {
    var isSpinning = false { didSet { if isSpinning != oldValue { update() } } }
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 10), heightAnchor.constraint(equalToConstant: 10)])
        arc.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        arc.path = CGPath(ellipseIn: CGRect(x: 0.75, y: 0.75, width: 8.5, height: 8.5), transform: nil)
        arc.fillColor = nil
        arc.strokeColor = NSColor.white.cgColor
        arc.lineWidth = 1.5
        arc.lineCap = .round
        arc.strokeEnd = 0.72
        layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }

    private func update() {
        arc.removeAnimation(forKey: "spin")
        guard isSpinning, window != nil, !Theme.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.duration = 0.8
        a.repeatCount = .infinity
        arc.add(a, forKey: "spin")
    }
}
