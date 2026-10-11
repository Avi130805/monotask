import AppKit

/// "Add to Do Next" from coding agents. The agent-side script drops one `.txt` file per item into `inbox/`
/// (written as a dot-file first, then renamed, so a half-written file is never seen). Each file holds the
/// item's title. Agents can only add to Do Next this way; they can't start, change or finish anything.
@MainActor
final class AgentInbox {
    static let maxTitleLength = 200

    let folder: URL
    private let store: Store
    /// Called with the Do Next position of the last item added, after an import that added something.
    private let onAdded: (Int) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var wakeObserver: NSObjectProtocol?
    private var pendingScan: DispatchWorkItem?

    init(store: Store, folder: URL, onAdded: @escaping (Int) -> Void) {
        self.store = store
        self.folder = folder.appendingPathComponent("inbox", isDirectory: true)
        self.onAdded = onAdded
    }

    deinit {
        source?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Creates the folder, imports whatever is waiting, then keeps watching it.
    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scan()
        watch()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
    }

    private func watch() {
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
        self.source = source
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

    /// Imports every waiting `*.txt`, in name order. Returns how many items were added to Do Next.
    @discardableResult
    func scan() -> Int {
        let files = FileManager.default
        let names = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".txt") }
            .sorted()
        var lastPosition: Int?
        var added = 0
        for name in names {
            let url = folder.appendingPathComponent(name)
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
