import AppKit
import SwiftUI
import MarginCore

/// State behind the bottom notes drawer.
@MainActor
public final class DrawerModel: ObservableObject {
    public enum Filter: String, CaseIterable, Identifiable {
        case all = "All", todos = "To-dos", media = "Media", links = "Links", quotes = "Quotes"
        public var id: String { rawValue }
        func matches(_ s: NoteStats) -> Bool {
            switch self {
            case .all: true; case .todos: s.todos > 0; case .media: s.media > 0
            case .links: s.links > 0; case .quotes: s.quotes > 0
            }
        }
    }

    @Published public var notes: [NoteSummary] = []
    @Published public var query = ""
    @Published public var filter: Filter = .all
    @Published public var currentID: NoteID?
    /// Bumped the first time the drawer opens, to play the one-time stagger.
    @Published public var appearToken = 0
    public private(set) var hasAppeared = false

    public var onOpen: ((NoteID) -> Void)?
    public var onNew: (() -> Void)?
    public var onDelete: ((NoteID) -> Void)?
    /// Runs the search; set by integration (store.search).
    public var search: ((String) -> [NoteSummary])?

    public init() {}

    public var visible: [NoteSummary] {
        let base = query.trimmingCharacters(in: .whitespaces).isEmpty ? notes : (search?(query) ?? notes)
        return base.filter { filter.matches($0.stats) }
    }

    func markAppeared() {
        guard !hasAppeared else { return }
        hasAppeared = true
        appearToken += 1
    }
}

struct NotesDrawerView: View {
    @ObservedObject var model: DrawerModel
    var onHandleDrag: ((DragGesture.Value, Bool) -> Void)?   // (value, ended)

    var body: some View {
        VStack(spacing: 0) {
            handle
            searchField.padding(.horizontal, 12).padding(.bottom, 10)
            chips.padding(.horizontal, 12).padding(.bottom, 10)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    NewCard { model.onNew?() }
                    ForEach(Array(model.visible.enumerated()), id: \.element.id) { i, n in
                        NoteCard(note: n, selected: n.id == model.currentID, index: i, token: model.appearToken)
                            .onTapGesture { model.onOpen?(n.id) }
                            .contextMenu {
                                Button("Delete note", role: .destructive) { model.onDelete?(n.id) }
                            }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
        .background(
            LinearGradient(colors: [.white.opacity(0.045), .white.opacity(0.015)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private var handle: some View {
        Capsule().fill(.white.opacity(0.22)).frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { onHandleDrag?($0, false) }
                .onEnded { onHandleDrag?($0, true) })
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            TextField("Search all notes", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.06)))
    }

    private var chips: some View {
        HStack(spacing: 4) {
            ForEach(DrawerModel.Filter.allCases) { f in
                let on = model.filter == f
                Button { withAnimation(.easeOut(duration: 0.15)) { model.filter = f } } label: {
                    Text(f.rawValue).font(.system(size: 11.5))
                        .foregroundStyle(on ? .black : .white.opacity(0.45))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(on ? .white : .clear))
                        .shadow(color: on ? .white.opacity(0.35) : .clear, radius: 7)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

private struct NewCard: View {
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 15, weight: .light))
                Text("New note").font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(hover ? 0.95 : 0.45))
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.white.opacity(0.14)))
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

private struct NoteCard: View {
    let note: NoteSummary
    let selected: Bool
    let index: Int
    let token: Int
    @State private var hover = false
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            Text(note.snippet.isEmpty ? " " : note.snippet).font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.4)).lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(note.updated, format: .relative(presentation: .named)).lineLimit(1)
                Spacer(minLength: 0)
                if note.stats.todos > 0 { Text("☐ \(note.stats.done)/\(note.stats.todos)") }
                if note.stats.media > 0 { Text("▣ \(note.stats.media)") }
                if note.stats.links > 0 { Text("↗ \(note.stats.links)") }
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.32))
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(selected ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(selected ? 0.24 : (hover ? 0.12 : 0.05)), lineWidth: 1)
        )
        .shadow(color: .white.opacity(selected ? 0.18 : 0), radius: 12)
        .offset(y: hover ? -2 : 0)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 10)
        .blur(radius: shown ? 0 : 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onAppear { reveal(stagger: false) }
        .onChange(of: token) { _, _ in reveal(stagger: true) }
    }

    private func reveal(stagger: Bool) {
        guard !Theme.reduceMotion else { shown = true; return }
        if stagger {
            shown = false
            withAnimation(.easeOut(duration: 0.35).delay(Double(index + 1) * 0.028)) { shown = true }
        } else if !shown {
            shown = true
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Hosts the SwiftUI drawer and drives its height: opens from the bottom and pushes content up.
@MainActor
public final class DrawerController: NSObject {
    public let model = DrawerModel()
    public let view: NSView
    public private(set) var heightConstraint: NSLayoutConstraint!
    public private(set) var isOpen = false
    /// Called whenever the drawer opens or closes (after the target is set).
    public var onToggle: ((Bool) -> Void)?

    private var dragStartHeight: CGFloat = 0
    private var samples: [(y: CGFloat, t: TimeInterval)] = []

    public override init() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        view = container
        super.init()
        let host = NSHostingView(rootView: NotesDrawerView(model: model, onHandleDrag: { [weak self] v, ended in
            self?.handleSwiftUIDrag(v, ended: ended)
        }))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        // The hosted content is pinned to the top at full height, so a short drawer clips it
        // instead of squashing it — it reads as a sheet sliding up.
        let full = host.heightAnchor.constraint(equalToConstant: 320)
        full.identifier = "drawer.full"
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            full,
        ])
        heightConstraint = container.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        fullHeight = full
    }

    private var fullHeight: NSLayoutConstraint!

    /// Maximum open height, given the panel height.
    public var maxHeight: CGFloat {
        let panelH = view.window?.frame.height ?? 600
        return min(330, max(200, panelH * 0.56)).rounded()
    }

    public func setOpen(_ open: Bool, animated: Bool = true, velocity: CGFloat = 0) {
        isOpen = open
        fullHeight.constant = maxHeight
        if open { model.markAppeared() }
        let target = open ? maxHeight : 0
        if animated && !Theme.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                ctx.timingFunction = Theme.spring
                ctx.allowsImplicitAnimation = true
                heightConstraint.animator().constant = target
                view.window?.contentView?.layoutSubtreeIfNeeded()
            }
        } else {
            heightConstraint.constant = target
        }
        onToggle?(open)
    }

    public func toggle() { setOpen(!isOpen) }

    // MARK: drag (from the handle, or from the toolbar via `drag(began:changed:ended:)`)

    private func handleSwiftUIDrag(_ v: DragGesture.Value, ended: Bool) {
        // SwiftUI global coordinates: y grows downward → dragging up gives negative translation
        if samples.isEmpty { begin() }
        let dy = -v.translation.height
        if ended { end(at: dy) } else { change(to: dy) }
    }

    /// Toolbar pan support. `dy` = upward distance from the start, in points.
    public func begin() {
        dragStartHeight = heightConstraint.constant
        fullHeight.constant = maxHeight
        samples = []
    }

    public func change(to dy: CGFloat) {
        let max = maxHeight
        var h = dragStartHeight + dy
        if h > max { h = max + rubberband(h - max, dimension: max) }
        if h < 0 { h = 0 }
        heightConstraint.constant = h
        samples.append((dy, ProcessInfo.processInfo.systemUptime))
        if samples.count > 6 { samples.removeFirst() }
        if h > 0 && !model.hasAppeared { model.markAppeared() }
    }

    public func end(at dy: CGFloat) {
        change(to: dy)
        var v: CGFloat = 0   // points per second, + = upward
        if let a = samples.first, let b = samples.last, b.t > a.t { v = (b.y - a.y) / CGFloat(b.t - a.t) }
        samples = []
        // Apple's projection: where would a flick at this velocity come to rest?
        let projected = heightConstraint.constant + (v / 1000) * 0.99 / (1 - 0.99)
        setOpen(projected > maxHeight / 2, animated: true, velocity: v)
    }

    private func rubberband(_ overshoot: CGFloat, dimension: CGFloat, c: CGFloat = 0.55) -> CGFloat {
        (overshoot * dimension * c) / (dimension + c * abs(overshoot))
    }
}
