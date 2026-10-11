import Foundation

/// Something you might do: captured into Do Next, started into Do Now.
struct TaskItem: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var title: String
    /// The last finish line written for it, kept when it's split or parked so restarting can reuse it.
    var doneWhen: String?
    /// Set while it's parked as blocked. Blocked items aren't offered as next up.
    var blockedReason: String?
    var createdAt = Date()
}

/// The one thing in Do Now, with the finish line you committed to.
struct ActiveTask: Codable, Equatable {
    var item: TaskItem
    var doneWhen: String
    var startedAt: Date
}

/// How a Do Now ended. Only `.done` counts as finished.
struct LogEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case done, dropped }

    var id = UUID()
    var title: String
    var kind: Kind
    var doneWhen: String?
    var reason: String?
    var startedAt: Date?
    var endedAt: Date
}

struct AppState: Codable, Equatable {
    var version = 1
    var now: ActiveTask?
    var next: [TaskItem] = []
    var log: [LogEntry] = []
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
