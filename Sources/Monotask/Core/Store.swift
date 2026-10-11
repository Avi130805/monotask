import Foundation
import Observation

/// The single source of truth for Do Now, Do Next and the log, saved as JSON in Application Support,
/// plus the append-only event history that Insights are computed from.
@Observable
@MainActor
final class Store {
    private(set) var state: AppState
    /// Everything that has happened to tasks, oldest first.
    private(set) var events: [TaskEvent]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let eventsURL: URL
    @ObservationIgnored private var pendingSave: DispatchWorkItem?

    /// `eventsURL` defaults to `events.jsonl` beside the state file.
    init(fileURL: URL = Store.defaultFileURL, eventsURL: URL? = nil) {
        let eventsURL = eventsURL ?? fileURL.deletingLastPathComponent().appendingPathComponent("events.jsonl")
        self.fileURL = fileURL
        self.eventsURL = eventsURL
        let state = Store.load(from: fileURL)
        self.state = state
        if let events = EventFile.read(eventsURL) {
            self.events = events
        } else {
            // First run with an event history: rebuild what the saved list allows, once.
            let events = EventFile.backfill(from: state)
            self.events = events
            do {
                try FileManager.default.createDirectory(at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try EventFile.write(events, to: eventsURL)
            } catch {
                NSLog("Monotask: couldn't start the event history: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Monotask", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    // MARK: Reading

    var now: ActiveTask? { state.now }
    var next: [TaskItem] { state.next }

    /// The first Do Next item that isn't parked as blocked.
    var nextUp: TaskItem? { state.next.first { $0.blockedReason == nil } }

    func item(_ id: UUID) -> TaskItem? { state.next.first { $0.id == id } }

    var finishedThisWeek: Int {
        let calendar = Calendar.current
        let today = Date()
        return state.log.filter {
            $0.kind == .done && calendar.isDate($0.endedAt, equalTo: today, toGranularity: .weekOfYear)
        }.count
    }

    // MARK: Do Next

    /// Adds a thought to the end of Do Next and returns its 1-based position, or nil if it was blank.
    @discardableResult
    func capture(_ title: String) -> Int? {
        let title = title.trimmed
        guard !title.isEmpty else { return nil }
        let item = TaskItem(title: title)
        mutate { $0.next.append(item) }
        record(.captured, item, at: item.createdAt)
        return state.next.count
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmed
        guard !title.isEmpty, let index = index(of: id) else { return }
        mutate { $0.next[index].title = title }
    }

    func delete(_ id: UUID) {
        guard let item = item(id) else { return }
        mutate { $0.next.removeAll { $0.id == id } }
        record(.deleted, item, at: Date())
    }

    func unblock(_ id: UUID) {
        guard let index = index(of: id) else { return }
        mutate { $0.next[index].blockedReason = nil }
    }

    func moveUp(_ id: UUID) { move(id) { $0 - 1 } }
    func moveDown(_ id: UUID) { move(id) { $0 + 1 } }
    func moveToTop(_ id: UUID) { move(id) { _ in 0 } }
    func moveToBottom(_ id: UUID) { move(id) { _ in .max } }

    private func move(_ id: UUID, to destination: (Int) -> Int) {
        guard let from = index(of: id) else { return }
        let to = min(max(destination(from), 0), state.next.count - 1)
        guard from != to else { return }
        mutate {
            let item = $0.next.remove(at: from)
            $0.next.insert(item, at: to)
        }
    }

    private func index(of id: UUID) -> Int? { state.next.firstIndex { $0.id == id } }

    // MARK: Do Now

    /// Moves a Do Next item into the empty Do Now slot, with the finish line you commit to.
    @discardableResult
    func start(_ id: UUID, doneWhen: String) -> Bool {
        let doneWhen = doneWhen.trimmed
        guard state.now == nil, !doneWhen.isEmpty, let index = index(of: id) else { return false }
        let date = Date()
        var item = state.next[index]
        item.blockedReason = nil
        item.doneWhen = doneWhen
        mutate {
            $0.next.remove(at: index)
            $0.now = ActiveTask(item: item, doneWhen: doneWhen, startedAt: date)
        }
        record(.started, item, at: date, note: doneWhen)
        return true
    }

    /// The only way something counts as finished.
    func finish() {
        guard let now = state.now else { return }
        let date = Date()
        mutate {
            $0.log.insert(LogEntry(title: now.item.title, kind: .done, doneWhen: now.doneWhen,
                                   startedAt: now.startedAt, endedAt: date), at: 0)
            $0.now = nil
        }
        record(.finished, now.item, at: date, note: now.doneWhen)
    }

    /// Swaps Do Now for its first finishable piece; the whole task goes back to the top of Do Next.
    @discardableResult
    func split(firstPiece: String, doneWhen: String) -> Bool {
        let title = firstPiece.trimmed
        let doneWhen = doneWhen.trimmed
        guard let now = state.now, !title.isEmpty, !doneWhen.isEmpty else { return false }
        let date = Date()
        var whole = now.item
        whole.doneWhen = now.doneWhen
        let piece = TaskItem(title: title, doneWhen: doneWhen, createdAt: date)
        mutate {
            $0.next.insert(whole, at: 0)
            $0.now = ActiveTask(item: piece, doneWhen: doneWhen, startedAt: date)
        }
        record(.split, whole, at: date, note: piece.title, related: piece.id)
        record(.started, piece, at: date, note: doneWhen, related: whole.id)
        return true
    }

    /// Parks Do Now at the top of Do Next with the reason it's stuck.
    @discardableResult
    func block(reason: String) -> Bool {
        let reason = reason.trimmed
        guard let now = state.now, !reason.isEmpty else { return false }
        var item = now.item
        item.doneWhen = now.doneWhen
        item.blockedReason = reason
        mutate {
            $0.next.insert(item, at: 0)
            $0.now = nil
        }
        record(.blocked, item, at: Date(), note: reason)
        return true
    }

    /// Gives up on Do Now. It's logged as dropped, never as done.
    @discardableResult
    func drop(reason: String) -> Bool {
        let reason = reason.trimmed
        guard let now = state.now, !reason.isEmpty else { return false }
        let date = Date()
        mutate {
            $0.log.insert(LogEntry(title: now.item.title, kind: .dropped, doneWhen: now.doneWhen, reason: reason,
                                   startedAt: now.startedAt, endedAt: date), at: 0)
            $0.now = nil
        }
        record(.dropped, now.item, at: date, note: reason)
        return true
    }

    // MARK: Saving

    private func mutate(_ change: (inout AppState) -> Void) {
        var copy = state
        change(&copy)
        guard copy != state else { return }
        state = copy
        scheduleSave()
    }

    private func record(_ kind: TaskEvent.Kind, _ item: TaskItem, at date: Date, note: String? = nil, related: UUID? = nil) {
        let event = TaskEvent(at: date, kind: kind, task: item.id, title: item.title, note: note, related: related)
        events.append(event)
        do {
            try FileManager.default.createDirectory(at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try EventFile.append(event, to: eventsURL)
        } catch {
            NSLog("Monotask: couldn't record a \(kind.rawValue) event: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            backUpOncePerDay()
            try Store.encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Monotask: couldn't save: \(error.localizedDescription)")
        }
    }

    /// Keeps the first version of each day's list and event history, two weeks deep, in case something goes wrong.
    private func backUpOncePerDay() {
        let files = FileManager.default
        let folder = fileURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        let day = Store.day.string(from: Date())
        for (source, prefix) in [(fileURL, "state"), (eventsURL, "events")] {
            guard files.fileExists(atPath: source.path) else { continue }
            let target = folder.appendingPathComponent("\(prefix)-\(day).\(source.pathExtension)")
            guard !files.fileExists(atPath: target.path) else { continue }
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            try? files.copyItem(at: source, to: target)
            let backups = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("\(prefix)-") }.sorted()
            for name in backups.dropLast(14) {
                try? files.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    /// Whether `data` is a list this app (or Next before it) saved.
    nonisolated static func isStateFile(_ data: Data) -> Bool {
        (try? decoder.decode(AppState.self, from: data)) != nil
    }

    private static func load(from url: URL) -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        do {
            return try decoder.decode(AppState.self, from: data)
        } catch {
            // Never overwrite a file we couldn't read: move it aside so it can be recovered.
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            NSLog("Monotask: couldn't read \(url.path), moved it to \(aside.lastPathComponent): \(error)")
            return AppState()
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
