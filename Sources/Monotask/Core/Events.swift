import Foundation

/// One thing that happened to a task. Events are only ever appended, never edited, so they're an honest
/// history to measure from.
struct TaskEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case captured, started, finished, dropped, split, blocked, deleted
    }

    var id = UUID()
    var at: Date
    var kind: Kind
    /// The task it happened to. A piece split off a task is a new task.
    var task: UUID
    var title: String
    /// The finish line for `started` and `finished`, the reason for `blocked` and `dropped`,
    /// and the first piece's title for `split`.
    var note: String?
    /// For `split`: the piece that took over Do Now. For a piece's `started`: the task it came from.
    var related: UUID?
}

/// The event history on disk: one JSON object per line. Adding an event never rewrites what's already
/// there, and a line torn by a crash is skipped when reading.
enum EventFile {
    /// Returns nil if there's no file yet.
    static func read(_ url: URL) -> [TaskEvent]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(TaskEvent.self, from: Data(line))
        }
    }

    static func append(_ event: TaskEvent, to url: URL) throws {
        var line = try encoder.encode(event)
        line.append(UInt8(ascii: "\n"))
        guard FileManager.default.fileExists(atPath: url.path) else {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    static func write(_ events: [TaskEvent], to url: URL) throws {
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
    }

    /// Rebuilds what history it can from a list saved before events existed: finished and dropped tasks
    /// from the log, and the captures and start of what's still in Do Now and Do Next.
    static func backfill(from state: AppState) -> [TaskEvent] {
        var events: [TaskEvent] = []
        for entry in state.log {
            if let started = entry.startedAt {
                events.append(TaskEvent(at: started, kind: .started, task: entry.id, title: entry.title, note: entry.doneWhen))
            }
            let done = entry.kind == .done
            events.append(TaskEvent(at: entry.endedAt, kind: done ? .finished : .dropped, task: entry.id,
                                    title: entry.title, note: done ? entry.doneWhen : entry.reason))
        }
        if let now = state.now {
            events.append(TaskEvent(at: now.item.createdAt, kind: .captured, task: now.item.id, title: now.item.title))
            events.append(TaskEvent(at: now.startedAt, kind: .started, task: now.item.id, title: now.item.title, note: now.doneWhen))
        }
        for item in state.next {
            events.append(TaskEvent(at: item.createdAt, kind: .captured, task: item.id, title: item.title))
        }
        return events.sorted { $0.at < $1.at }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
