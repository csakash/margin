import AppKit
import QuartzCore

/// What one step of the first-launch tour shows. Copy matches design/onboarding.html.
struct TourStep {
    enum Kind { case plain, fold, place, write }
    let eyebrow: String
    let title: String
    let sub: String?
    let kind: Kind
    let cta: String
    /// Hint shown next to the button ("↵" or a short line).
    let hint: String?

    static let all: [TourStep] = [
        TourStep(eyebrow: "WELCOME", title: "A quiet place to write, right next to what you read.",
                 sub: "Four small things, and you are set. About thirty seconds.", kind: .plain, cta: "Begin", hint: "↵"),
        TourStep(eyebrow: "01 · FLOAT", title: "It stays above everything.",
                 sub: "Full-screen Chrome, a PDF, a video call. Margin floats on top, on every Space.", kind: .plain, cta: "Next", hint: "↵"),
        TourStep(eyebrow: "02 · FOLD", title: "Fold it into a line.",
                 sub: "When you want to read, it waits on the edge. Same keys to bring it back.", kind: .fold, cta: "Next", hint: nil),
        TourStep(eyebrow: "03 · PLACE", title: "Put it where it suits you.",
                 sub: "Drag the top of this panel. It snaps to any edge or corner.", kind: .place, cta: "Next", hint: nil),
        TourStep(eyebrow: "04 · WRITE", title: "Just type. It turns into notes.",
                 sub: nil, kind: .write, cta: "Next", hint: "Drop images and links in too"),
        TourStep(eyebrow: "READY", title: "That's all of it.",
                 sub: "Your notes are plain files on this Mac. Nothing leaves it. ⌥N starts a new one.", kind: .plain, cta: "Start writing", hint: nil),
    ]
}

/// The tour's content inside the glass panel. Draws one step at a time; knows nothing about
/// panels, sounds or settings (OnboardingController drives it).
@MainActor
final class OnboardingView: NSView {
    var onPrimary: (() -> Void)?
    var onSkip: (() -> Void)?
    var onKeycaps: (() -> Void)?
    /// mouseDown on the top bar (the Place step turns it into a panel drag).
    var onHeaderMouseDown: ((NSEvent) -> Void)?

    private let header = TourHeader()
    private let brand = NSTextField(labelWithString: "MARGIN")
    private let skip = NSButton(title: "", target: nil, action: nil)
    private let content = NSView()
    private var stepStack = NSStackView()
    private let actionRow = NSStackView()
    private let primary = GlowButton()
    private let hintLabel = NSTextField(labelWithString: "")
    private let dots = NSStackView()
    private var dotViews: [NSView] = []
    // Try-box pieces, rebuilt per step.
    private var tryMessage: NSTextField?
    private var tryTick: NSView?
    private var tryBox: NSView?
    // Write demo pieces.
    private(set) var demoHeading = NSTextField(labelWithString: "")
    private(set) var demoBullet = NSTextField(labelWithString: "")
    private(set) var demoChips = NSTextField(labelWithString: "/   Heading   To-do   Quote   Image")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        brand.font = Theme.mono(11, .medium)
        brand.textColor = Theme.textTertiary
        skip.isBordered = false
        skip.attributedTitle = NSAttributedString(string: "Skip", attributes: [.font: Theme.ui(12), .foregroundColor: Theme.textTertiary])
        skip.target = self
        skip.action = #selector(skipClicked)
        header.onMouseDown = { [weak self] e in self?.onHeaderMouseDown?(e) }
        for v in [brand, skip] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(v) }
        header.translatesAutoresizingMaskIntoConstraints = false

        primary.target = self
        primary.action = #selector(primaryClicked)
        hintLabel.font = Theme.ui(12)
        hintLabel.textColor = Theme.textTertiary
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 12
        actionRow.setViews([primary, hintLabel], in: .leading)
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        dots.orientation = .horizontal
        dots.spacing = 6
        dots.alignment = .centerY
        dots.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<4 {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.cornerRadius = 2.5
            d.translatesAutoresizingMaskIntoConstraints = false
            d.heightAnchor.constraint(equalToConstant: 5).isActive = true
            let w = d.widthAnchor.constraint(equalToConstant: 5)
            w.identifier = "dot.width"
            w.isActive = true
            dots.addArrangedSubview(d)
            dotViews.append(d)
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        for v in [header, content, dots, actionRow] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            brand.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            brand.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            skip.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            skip.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: dots.topAnchor, constant: -12),

            dots.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            dots.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -14),
            actionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            actionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])

        for l in [demoHeading, demoBullet, demoChips] { l.lineBreakMode = .byTruncatingTail }
        demoHeading.font = Theme.ui(18, .semibold)
        demoHeading.textColor = .white
        demoBullet.font = Theme.ui(13.5)
        demoBullet.textColor = NSColor(white: 0.85, alpha: 1)
        demoChips.font = Theme.mono(10.5, .medium)
        demoChips.textColor = Theme.textSecondary
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Return, Enter
            if !primary.isHidden { onPrimary?() }
        case 53:       // Esc
            onSkip?()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Steps

    func show(_ index: Int, animated: Bool) {
        let step = TourStep.all[index]
        tryMessage = nil; tryTick = nil; tryBox = nil

        var views: [NSView] = []
        let eyebrow = label(step.eyebrow, Theme.mono(11, .medium), Theme.textTertiary)
        let title = wrapping(step.title, Theme.ui(23, .semibold), Theme.text)
        views += [eyebrow, title]
        if let sub = step.sub { views.append(wrapping(sub, Theme.ui(13.5), Theme.textSecondary)) }
        switch step.kind {
        case .fold:
            views.append(makeTryBox(keycaps: ["⌥", "Space"], message: "Try it now"))
        case .place:
            views.append(makeTryBox(keycaps: [], message: "Drag from the top bar"))
        case .write:
            views.append(makeDemo())
        case .plain:
            break
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: eyebrow)
        if views.count > 3 { stack.setCustomSpacing(18, after: views[views.count - 2]) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Wrapping text and boxes take the full column, so lines break at its edge, not earlier.
        for v in views where v !== eyebrow { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        stepStack.removeFromSuperview()
        stepStack = stack
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        primary.title = step.cta
        primary.isHidden = step.kind == .fold || step.kind == .place
        hintLabel.stringValue = step.hint ?? ""
        hintLabel.isHidden = step.hint == nil
        skip.isHidden = index == TourStep.all.count - 1
        setDots(active: index)

        layoutSubtreeIfNeeded()
        reveal(views + [actionRow], animated: animated)
    }

    /// The step's goal was reached: tick, message, and the Next button.
    func completeTry(message: String) {
        tryMessage?.stringValue = message
        tryBox?.layer?.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        if let t = tryTick {
            t.isHidden = false
            pop(t)
        }
        primary.isHidden = false
        reveal([actionRow], animated: true)
    }

    func setTryMessage(_ message: String) { tryMessage?.stringValue = message }

    // MARK: Pieces

    private func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        return l
    }

    private func wrapping(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = font
        l.textColor = color
        l.isSelectable = false
        l.preferredMaxLayoutWidth = 352
        return l
    }

    private func makeTryBox(keycaps: [String], message: String) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Theme.hairline.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        if !keycaps.isEmpty {
            let caps = KeycapButton(keys: keycaps)
            caps.target = self
            caps.action = #selector(keycapsClicked)
            row.addArrangedSubview(caps)
        }
        let msg = label(message, Theme.ui(12.5), Theme.textSecondary)
        row.addArrangedSubview(msg)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        let tick = TickView()
        tick.isHidden = true
        row.addArrangedSubview(tick)

        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        tryMessage = msg
        tryTick = tick
        tryBox = box
        return box
    }

    private func makeDemo() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.backgroundColor = NSColor(white: 1, alpha: 0.03).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Theme.hairline.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        demoHeading.stringValue = ""
        demoBullet.stringValue = ""
        demoChips.alphaValue = 0
        let stack = NSStackView(views: [demoHeading, demoBullet, demoChips])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -14),
            box.heightAnchor.constraint(equalToConstant: 100),
        ])
        return box
    }

    private func setDots(active index: Int) {
        // Dots stand for steps 1…4; hidden on the welcome and the finish.
        dots.isHidden = !(1...4).contains(index)
        for (i, d) in dotViews.enumerated() {
            let n = i + 1
            let on = n == index
            d.layer?.backgroundColor = NSColor(white: 1, alpha: on ? 1 : n < index ? 0.5 : 0.16).cgColor
            d.layer?.shadowColor = NSColor.white.cgColor
            d.layer?.shadowOpacity = on ? 0.8 : 0
            d.layer?.shadowRadius = 3
            d.layer?.shadowOffset = .zero
            d.constraints.first { $0.identifier == "dot.width" }?.constant = on ? 14 : 5
        }
    }

    // MARK: Motion

    /// Each piece fades in and rises 8 pt, 60 ms apart (the mockup's blur-in, without the blur).
    private func reveal(_ views: [NSView], animated: Bool) {
        let reduce = Theme.reduceMotion || !animated
        for (i, v) in views.enumerated() {
            v.wantsLayer = true
            guard !reduce, let layer = v.layer else { v.alphaValue = 1; continue }
            v.alphaValue = 0
            let delay = 0.06 * Double(i)
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -8   // AppKit layers are not flipped: negative is lower on screen
            rise.toValue = 0
            rise.duration = 0.5
            rise.beginTime = CACurrentMediaTime() + delay
            rise.fillMode = .backwards
            rise.timingFunction = Theme.spring
            rise.isAdditive = true
            layer.add(rise, forKey: "tour.rise")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.42
                    ctx.timingFunction = Theme.easeOut
                    v.animator().alphaValue = 1
                }
            }
        }
    }

    private func pop(_ v: NSView) {
        guard !Theme.reduceMotion, let layer = v.layer else { return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 0.6
        a.toValue = 1
        a.duration = 0.35
        a.timingFunction = Theme.spring
        layer.add(a, forKey: "tour.pop")
    }

    // MARK: Actions

    @objc private func primaryClicked() { onPrimary?() }
    @objc private func skipClicked() { onSkip?() }
    @objc private func keycapsClicked() { onKeycaps?() }
}

/// The tour's top bar: forwards mouseDown so the Place step can start a real panel drag.
@MainActor
final class TourHeader: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
}

/// "⌥ Space" drawn as keycaps; clicking it does what the keys do.
@MainActor
final class KeycapButton: NSButton {
    init(keys: [String]) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setAccessibilityLabel(keys.joined(separator: " "))
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        for k in keys {
            let cap = NSTextField(labelWithString: k)
            cap.font = Theme.mono(12.5, .medium)
            cap.textColor = Theme.text
            cap.alignment = .center
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 6
            cap.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
            cap.layer?.borderWidth = 1
            cap.layer?.borderColor = NSColor(white: 1, alpha: 0.13).cgColor
            cap.translatesAutoresizingMaskIntoConstraints = false
            cap.heightAnchor.constraint(equalToConstant: 24).isActive = true
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
            cap.widthAnchor.constraint(equalToConstant: cap.intrinsicContentSize.width + 16).isActive = true
            row.addArrangedSubview(cap)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// White disc with a check: the step's goal was reached.
@MainActor
final class TickView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 18), heightAnchor.constraint(equalToConstant: 18)])
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.white.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 6
        layer?.shadowOffset = .zero
        let check = CAShapeLayer()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 5, y: 9.2))
        p.addLine(to: CGPoint(x: 7.8, y: 6.4))
        p.addLine(to: CGPoint(x: 13, y: 11.8))
        check.path = p
        check.strokeColor = NSColor.black.cgColor
        check.fillColor = nil
        check.lineWidth = 2
        check.lineCap = .round
        check.lineJoin = .round
        check.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        layer?.addSublayer(check)
    }
    required init?(coder: NSCoder) { fatalError() }
}
