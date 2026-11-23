import Foundation

/// One `.md` file per note inside `folder`, assets in `folder/assets`, index in `folder/.margin`.
/// All methods are called on the main thread.
///
/// Each note file is `---\nid: <id>\ncreated: <ISO8601>\n---\n<body>` and is named
/// `<slug of title>-<id>.md`. Markdown files dropped into the folder without front-matter
/// are adopted: they get an id in memory and their front-matter is written on first save.
public final class NoteStore {
    public let folder: URL
    public let assets: AssetStore
    /// Called (on main) after any change: save, create, delete, or an external edit on disk.
    public var onChange: (() -> Void)?

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin", isDirectory: true)
    }

    // MARK: - State

    /// Identifies one version of a file on disk; a different stamp means the file changed.
    struct FileStamp: Equatable {
        var modified: Date
        var size: Int
    }

    struct Entry {
        var id: NoteID
        var url: URL
        /// Front-matter as found on disk. Empty for adopted files not yet saved.
        var meta: [String: String]
        var stamp: FileStamp
        var stats: NoteStats
    }

    struct Pending {
        var text: String
        var stats: NoteStats
        var date: Date
        var work: DispatchWorkItem
        var indexed: Bool
    }

    private var entries: [NoteID: Entry] = [:]
    private var pending: [NoteID: Pending] = [:]
    /// Ids handed to files without front-matter, by file name, so they stay stable across rescans.
    private var adoptedIDs: [String: NoteID] = [:]

    let index: SearchIndex
    /// Delay between the last `save` and the write to disk.
    var saveDelay: TimeInterval = 0.3
    /// When false, `delete` removes files outright instead of trashing them (tests).
    var usesTrash = true
    /// Coalescing window for folder events.
    var watchDelay: TimeInterval = 0.15

    private var watcher: DispatchSourceFileSystemObject?
    private var rescanWork: DispatchWorkItem?

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    // MARK: - Init

    public init(folder: URL = NoteStore.defaultFolder) throws {
        self.folder = folder
        self.assets = AssetStore(folder: folder.appendingPathComponent("assets", isDirectory: true))
        let fm = FileManager.default
        let marginDir = folder.appendingPathComponent(".margin", isDirectory: true)
        for dir in [folder, assets.folder, marginDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        index = try SearchIndex(url: marginDir.appendingPathComponent("index.sqlite"))
        // The index is a cache: rebuild it from the files every launch.
        index.performBatch {
            index.removeAll()
            rescan(notify: false)
        }
        startWatching()
    }

    deinit {
        flush()
        rescanWork?.cancel()
        watcher?.cancel()
    }

    // MARK: - Reading

    /// All notes, most recently edited first.
    public func list() -> [NoteSummary] {
        entries.values.map(summary(for:)).sorted {
            $0.updated != $1.updated ? $0.updated > $1.updated : $0.id.raw < $1.id.raw
        }
    }

    /// Body text (without front-matter).
    public func load(_ id: NoteID) -> String {
        if let p = pending[id] { return p.text }
        guard let e = entries[id], let text = try? String(contentsOf: e.url, encoding: .utf8) else { return "" }
        return Markdown.splitFrontMatter(text).body
    }

    // MARK: - Writing

    /// Debounced (300 ms) atomic save. `flush()` forces pending writes.
    public func save(_ id: NoteID, text: String) {
        guard entries[id] != nil else { return }
        pending[id]?.work.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(id) }
        pending[id] = Pending(text: text, stats: Markdown.stats(for: text), date: Date(), work: work, indexed: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
        onChange?()
    }

    /// Performs every pending write now, synchronously.
    public func flush() {
        for id in Array(pending.keys) { write(id) }
    }

    @discardableResult
    public func create(initialText: String = "# ") -> NoteID {
        var id = NoteID.make()
        while entries[id] != nil { id = NoteID.make() }
        let meta = ["id": id.raw, "created": Self.iso.string(from: Date())]
        let stats = Markdown.stats(for: initialText)
        let url = folder.appendingPathComponent(Self.fileName(title: stats.title, id: id))
        let content = Markdown.joinFrontMatter(meta, body: initialText)
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            NSLog("Margin: could not create note: \(error)")
        }
        let stamp = Self.stamp(of: url) ?? FileStamp(modified: Date(), size: 0)
        entries[id] = Entry(id: id, url: url, meta: meta, stamp: stamp, stats: stats)
        index.upsert(id: id, title: stats.title, body: initialText)
        onChange?()
        return id
    }

    /// Moves the file to the Trash (or removes it if there is no Trash).
    public func delete(_ id: NoteID) {
        if let p = pending.removeValue(forKey: id) { p.work.cancel() }
        guard let e = entries.removeValue(forKey: id) else { return }
        adoptedIDs[e.url.lastPathComponent] = nil
        let fm = FileManager.default
        do {
            guard usesTrash else { throw CocoaError(.featureUnsupported) }
            try fm.trashItem(at: e.url, resultingItemURL: nil)
        } catch {
            try? fm.removeItem(at: e.url)
        }
        index.remove(id: id)
        onChange?()
    }

    // MARK: - Search

    /// Full-text search over title and body (FTS5 prefix match). Empty query returns `list()`.
    public func search(_ query: String) -> [NoteSummary] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return list() }
        // Unsaved edits are searchable too.
        for (id, p) in pending where !p.indexed {
            index.upsert(id: id, title: p.stats.title, body: p.text)
            pending[id]?.indexed = true
        }
        return index.search(query).compactMap { id in entries[id].map(summary(for:)) }
    }

    // MARK: - Internals

    private func summary(for e: Entry) -> NoteSummary {
        if let p = pending[e.id] {
            return NoteSummary(id: e.id, stats: p.stats, updated: p.date, fileURL: e.url)
        }
        return NoteSummary(id: e.id, stats: e.stats, updated: e.stamp.modified, fileURL: e.url)
    }

    private func write(_ id: NoteID) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.work.cancel()
        guard var e = entries[id] else { return }
        let fm = FileManager.default

        var meta = e.meta
        meta["id"] = id.raw
        if meta["created"] == nil {
            let created = (try? e.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            meta["created"] = Self.iso.string(from: created)
        }
        let content = Markdown.joinFrontMatter(meta, body: p.text)
        do {
            try Data(content.utf8).write(to: e.url, options: .atomic)
        } catch {
            NSLog("Margin: could not save note \(id): \(error)")
            return
        }

        // Rename when the title changed.
        let oldURL = e.url
        let wanted = Self.fileName(title: p.stats.title, id: id)
        if wanted != oldURL.lastPathComponent {
            let dest = folder.appendingPathComponent(wanted)
            if !fm.fileExists(atPath: dest.path), (try? fm.moveItem(at: oldURL, to: dest)) != nil {
                e.url = dest
            }
        }
        adoptedIDs[oldURL.lastPathComponent] = nil
        e.meta = meta
        e.stats = p.stats
        e.stamp = Self.stamp(of: e.url) ?? FileStamp(modified: p.date, size: content.utf8.count)
        entries[id] = e
        index.upsert(id: id, title: p.stats.title, body: p.text)
        if e.url != oldURL { onChange?() }
    }

    /// Re-reads the folder. Files whose stamp matches the cache are not read again, so our
    /// own writes (whose stamps we record) are not reported as changes.
    /// Returns true if anything changed; calls `onChange` then if `notify`.
    @discardableResult
    func rescan(notify: Bool = true) -> Bool {
        let fm = FileManager.default
        // Keyed by file name (the scan is not recursive), and URLs are rebuilt from `folder`,
        // so /var vs /private/var style aliases never make a file look new.
        let urls = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == "md" }
            .map { folder.appendingPathComponent($0) }

        var byName: [String: Entry] = [:]
        for e in entries.values { byName[e.url.lastPathComponent] = e }

        var fresh: [NoteID: Entry] = [:]
        var changed: [(URL, FileStamp)] = []
        // Pass 1: unchanged files keep their entry (and id).
        for url in urls {
            guard let stamp = Self.stamp(of: url) else { continue }
            if let e = byName[url.lastPathComponent], e.stamp == stamp, fresh[e.id] == nil {
                fresh[e.id] = e
            } else {
                changed.append((url, stamp))
            }
        }
        // Pass 2: new or edited files.
        var didChange = false
        for (url, stamp) in changed.sorted(by: { $0.0.lastPathComponent < $1.0.lastPathComponent }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var (meta, body) = Markdown.splitFrontMatter(text)
            let id: NoteID
            if let raw = meta["id"], !raw.isEmpty, fresh[NoteID(raw)] == nil {
                id = NoteID(raw)
                adoptedIDs[url.lastPathComponent] = nil
            } else {
                // No id, or a copy of a file whose id is taken: adopt with a new id.
                meta["id"] = nil
                if let known = adoptedIDs[url.lastPathComponent], fresh[known] == nil {
                    id = known
                } else {
                    var newID = NoteID.make()
                    while fresh[newID] != nil || entries[newID] != nil { newID = NoteID.make() }
                    id = newID
                }
                adoptedIDs[url.lastPathComponent] = id
            }
            let stats = Markdown.stats(for: body)
            fresh[id] = Entry(id: id, url: url, meta: meta, stamp: stamp, stats: stats)
            index.upsert(id: id, title: stats.title, body: body)
            didChange = true
        }
        // Files that disappeared.
        for id in entries.keys where fresh[id] == nil {
            index.remove(id: id)
            if let p = pending.removeValue(forKey: id) { p.work.cancel() }
            didChange = true
        }
        let livePaths = Set(fresh.values.map { $0.url.lastPathComponent })
        adoptedIDs = adoptedIDs.filter { livePaths.contains($0.key) }
        entries = fresh
        if didChange && notify { onChange?() }
        return didChange
    }

    private func startWatching() {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRescan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + watchDelay, execute: work)
    }

    static func stamp(of url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return FileStamp(modified: modified, size: (attrs[.size] as? NSNumber)?.intValue ?? 0)
    }

    /// `<slug>-<id>.md`
    static func fileName(title: String, id: NoteID) -> String {
        "\(slug(title))-\(id.raw).md"
    }

    /// Lowercase ASCII letters, digits and single dashes; at most 48 characters; "untitled" if empty.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        var lastDash = true
        for u in folded.unicodeScalars {
            if (u >= "a" && u <= "z") || (u >= "0" && u <= "9") {
                out.unicodeScalars.append(u); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        out = String(out.prefix(48))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "untitled" : out
    }
}
