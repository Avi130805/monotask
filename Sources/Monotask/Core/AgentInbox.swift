import AppKit

/// "Add to Do Next" from coding agents. The agent-side script drops one `.txt` file per item into `inbox/`
/// (written as a dot-file first, then renamed, so a half-written file is never seen). Each file holds the
/// item's title. Agents can only add to Do Next this way; they can't start, change or finish anything.
///
/// Sandboxed agents (Codex by default) can't write into Application Support, so the script falls back to a
/// spool in the user's own temporary folder, which only this user can write to. Both are watched.
@MainActor
final class AgentInbox {
    static let maxTitleLength = 200

    let folder: URL
    /// The fallback for sandboxed agents; nil in tests that don't need it.
    let spool: URL?
    private let store: Store
    /// Called with the Do Next position of the last item added, after an import that added something.
    private let onAdded: (Int) -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var wakeObserver: NSObjectProtocol?
    private var pendingScan: DispatchWorkItem?

    /// Where a sandboxed agent's script drops items: `$TMPDIR/monotask-inbox`.
    nonisolated static var defaultSpool: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("monotask-inbox", isDirectory: true)
    }

    init(store: Store, folder: URL, spool: URL? = nil, onAdded: @escaping (Int) -> Void) {
        self.store = store
        self.folder = folder.appendingPathComponent("inbox", isDirectory: true)
        self.spool = spool
        self.onAdded = onAdded
    }

    private var folders: [URL] { [folder] + (spool.map { [$0] } ?? []) }

    deinit {
        sources.forEach { $0.cancel() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Creates the folder, imports whatever is waiting, then keeps watching it.
    func start() {
        for folder in folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        scan()
        folders.forEach(watch)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
    }

    private func watch(_ folder: URL) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("Monotask: couldn't watch the inbox at \(folder.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    /// A burst of files (or the delete after an import) triggers one scan, not many.
    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { _ = self?.scan() }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Imports every waiting `*.txt` from both folders, in name order (names start with a timestamp).
    /// Returns how many items were added to Do Next.
    @discardableResult
    func scan() -> Int {
        let files = FileManager.default
        let waiting = folders.flatMap { folder in
            ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".txt") }
                .map { (name: $0, url: folder.appendingPathComponent($0)) }
        }
        .sorted { $0.name < $1.name }
        var lastPosition: Int?
        var added = 0
        for (_, url) in waiting {
            guard let title = Self.title(from: url) else { continue }
            if !title.isEmpty && !isKnown(title), let position = store.capture(title) {
                lastPosition = position
                added += 1
            }
            // Blank, duplicate or imported: in every case the file has done its job.
            try? files.removeItem(at: url)
        }
        if let lastPosition { onAdded(lastPosition) }
        return added
    }

    private func isKnown(_ title: String) -> Bool {
        let key = title.trimmed.lowercased()
        return store.now?.item.title.trimmed.lowercased() == key
            || store.next.contains { $0.title.trimmed.lowercased() == key }
    }

    /// The first line of the file, trimmed and capped; nil if the file can't be read at all.
    private static func title(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // A title is one short line; never read more than a few KB of something unexpected.
        guard let data = try? handle.read(upToCount: 8192) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmed
        let first = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return cap(first.trimmed)
    }

    /// At most `maxTitleLength` characters, cut at a word boundary when there is one in the second half.
    static func cap(_ title: String) -> String {
        guard title.count > maxTitleLength else { return title }
        let head = title.prefix(maxTitleLength)
        let next = title[title.index(title.startIndex, offsetBy: maxTitleLength)]
        if next.isWhitespace { return String(head).trimmed }
        if let space = head.lastIndex(where: \.isWhitespace),
           head.distance(from: head.startIndex, to: space) >= maxTitleLength / 2 {
            return String(head[..<space]).trimmed
        }
        return String(head).trimmed
    }
}
