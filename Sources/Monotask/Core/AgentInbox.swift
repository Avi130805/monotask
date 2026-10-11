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
    /// One watcher per folder, keyed by path, with the folder's inode when it was opened (see `ensureWatching`).
    private var watchers: [String: Watcher] = [:]
    private var started = false
    private var wakeObserver: NSObjectProtocol?
    private var pendingScan: DispatchWorkItem?

    /// Where a sandboxed agent's script drops items: `monotask-inbox` in the per-user temporary folder (the script
    /// asks `getconf DARWIN_USER_TEMP_DIR`, which is the same folder as `NSTemporaryDirectory()`).
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

    private struct Watcher {
        let source: DispatchSourceFileSystemObject
        let inode: UInt64
    }

    deinit {
        watchers.values.forEach { $0.source.cancel() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Creates the folders and starts watching them, then imports whatever is waiting. Watching comes first so a
    /// file that lands during the first scan is still noticed instead of falling in the gap between the two.
    func start() {
        started = true
        for folder in folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            watch(folder)
        }
        scan()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
    }

    /// Watches the folder's contents and the folder itself. If the folder is deleted or renamed (the user tidying
    /// up, a cleanup tool emptying the temp folder), the descriptor keeps pointing at the old inode and never fires
    /// again, so that case rebuilds the folder and the watcher.
    private func watch(_ folder: URL) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("Monotask: couldn't watch the inbox at \(folder.path)")
            return
        }
        var info = stat()
        fstat(descriptor, &info)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.rewatch(folder)
                } else {
                    self.scheduleScan()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[folder.path] = Watcher(source: source, inode: UInt64(info.st_ino))
    }

    /// Drops the old watcher, makes sure the folder exists again and watches the new one.
    private func rewatch(_ folder: URL) {
        watchers.removeValue(forKey: folder.path)?.source.cancel()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watch(folder)
        scheduleScan()
    }

    /// For a folder swapped without an event reaching us: if the path now names a different inode than the one
    /// being watched (or nothing is watched), start over.
    private func ensureWatching() {
        guard started else { return }
        for folder in folders {
            var info = stat()
            if let watcher = watchers[folder.path], stat(folder.path, &info) == 0, watcher.inode == UInt64(info.st_ino) { continue }
            rewatch(folder)
        }
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
        ensureWatching()
        let files = FileManager.default
        let waiting = folders.flatMap { folder in
            ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".txt") }
                .map { (name: $0, url: folder.appendingPathComponent($0)) }
        }
        .sorted { $0.name < $1.name }
        var lastPosition: Int?
        var added = 0
        var done: [URL] = []
        for (_, url) in waiting {
            // Only plain files carry items. Reading a named pipe would block the main thread until a writer shows up.
            guard Self.isRegularFile(url) else {
                Self.discard(url)
                continue
            }
            guard let title = Self.title(from: url) else { continue }
            if !title.isEmpty && !isKnown(title), let position = store.capture(title) {
                lastPosition = position
                added += 1
            }
            // Blank, duplicate or imported: in every case the file has done its job.
            done.append(url)
        }
        // The items must be on disk before the files that carry them go; a crash in between would lose them.
        if added > 0 { store.saveNow() }
        for url in done { try? files.removeItem(at: url) }
        if let lastPosition { onAdded(lastPosition) }
        return added
    }

    /// A regular file, not a symlink, pipe, socket or folder (looked at without following links).
    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Removes something that isn't a plain file: a folder only if it is empty, anything else by unlinking it.
    private static func discard(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR { rmdir(url.path) } else { unlink(url.path) }
    }

    private func isKnown(_ title: String) -> Bool {
        let key = title.trimmed.lowercased()
        return store.now?.item.title.trimmed.lowercased() == key
            || store.next.contains { $0.title.trimmed.lowercased() == key }
    }

    /// The first line of the file, trimmed and capped; nil if the file can't be read at all.
    private static func title(from url: URL) -> String? {
        // Opened without blocking or following links, and checked again once open: the file could have been swapped
        // for a pipe since the scan looked at it.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
