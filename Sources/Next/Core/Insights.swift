import Foundation

enum InsightRange: String, CaseIterable, Identifiable {
    case week = "7 days"
    case month = "30 days"
    case all = "All time"

    var id: Self { self }

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

/// Patterns in how you finish things, computed from the event history. It's a pure function of the
/// events and the clock, so every number can be checked in the self-test.
struct Insights {
    /// A task that left Do Now, timed from the first time it was started.
    struct Run: Identifiable {
        let id: UUID
        let title: String
        let finished: Bool
        let started: Date?
        let ended: Date
        /// The finish line if it was done, the reason if it was dropped.
        let note: String?

        var duration: TimeInterval? { started.map { ended.timeIntervalSince($0) } }
    }

    struct DateCount: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    struct FlowPoint: Identifiable {
        let week: Date
        let series: String
        let count: Int
        var id: String { "\(week.timeIntervalSince1970)-\(series)" }
    }

    struct Bucket: Identifiable {
        let label: String
        let count: Int
        var id: String { label }
    }

    struct Reason: Identifiable {
        let id: UUID
        let title: String
        let reason: String
        let at: Date
    }

    static let cameIn = "Came in"
    static let gotDone = "Finished"

    let range: InsightRange
    let periodStart: Date

    let finished: Int
    /// Finished in the period just before this one, for comparison. Nil for all time.
    let previousFinished: Int?
    let dropped: Int
    let captured: Int
    let splits: Int
    let blocks: Int
    let deleted: Int

    let medianTimeToFinish: TimeInterval?
    let streak: Int
    let bestStreak: Int

    /// Finishes per day, or per week for all time.
    let timeline: [DateCount]
    let timelineUnit: Calendar.Component
    /// What came in versus what got finished, week by week.
    let flow: [FlowPoint]
    /// How much the open list (Do Now and Do Next together) grew over the weeks in `flow`.
    let listChange: Int
    let finishesByHour: [Int]
    let timeToFinish: [Bucket]
    let blockedReasons: [Reason]
    let droppedReasons: [Reason]
    /// Newest first.
    let runs: [Run]

    var finishRate: Double? {
        finished + dropped == 0 ? nil : Double(finished) / Double(finished + dropped)
    }

    /// The hour of day with the most finishes, if there were any.
    var peakHour: Int? {
        guard let most = finishesByHour.max(), most > 0 else { return nil }
        return finishesByHour.firstIndex(of: most)
    }

    init(events unsorted: [TaskEvent], range: InsightRange, now: Date = Date(), calendar: Calendar = .current) {
        let events = unsorted.sorted { $0.at < $1.at }
        let today = calendar.startOfDay(for: now)
        let start: Date
        if let days = range.days {
            start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        } else {
            start = events.first.map { calendar.startOfDay(for: $0.at) } ?? today
        }
        self.range = range
        self.periodStart = start

        let inPeriod = events.filter { $0.at >= start && $0.at <= now }
        func count(_ kind: TaskEvent.Kind, _ list: [TaskEvent]) -> Int { list.filter { $0.kind == kind }.count }

        finished = count(.finished, inPeriod)
        dropped = count(.dropped, inPeriod)
        captured = count(.captured, inPeriod)
        splits = count(.split, inPeriod)
        blocks = count(.blocked, inPeriod)
        deleted = count(.deleted, inPeriod)

        if let days = range.days {
            let previousStart = calendar.date(byAdding: .day, value: -days, to: start)!
            previousFinished = events.filter { $0.kind == .finished && $0.at >= previousStart && $0.at < start }.count
        } else {
            previousFinished = nil
        }

        // Every finished or dropped task, timed from its first start.
        var firstStart: [UUID: Date] = [:]
        var allRuns: [Run] = []
        for event in events {
            switch event.kind {
            case .started:
                if firstStart[event.task] == nil { firstStart[event.task] = event.at }
            case .finished, .dropped:
                allRuns.append(Run(id: event.id, title: event.title, finished: event.kind == .finished,
                                   started: firstStart[event.task], ended: event.at, note: event.note))
            default:
                break
            }
        }
        let periodRuns = allRuns.filter { $0.ended >= start && $0.ended <= now }
        runs = periodRuns.reversed()
        let durations = periodRuns.filter(\.finished).compactMap(\.duration).sorted()
        medianTimeToFinish = Insights.median(of: durations)
        timeToFinish = Insights.buckets(durations)

        let finishDays = Set(events.filter { $0.kind == .finished }.map { calendar.startOfDay(for: $0.at) })
        (streak, bestStreak) = Insights.streaks(finishDays, today: today, calendar: calendar)

        if let days = range.days {
            timelineUnit = .day
            timeline = (0..<days).map { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: start)!
                let next = calendar.date(byAdding: .day, value: 1, to: day)!
                return DateCount(date: day, count: inPeriod.filter { $0.kind == .finished && $0.at >= day && $0.at < next }.count)
            }
        } else {
            timelineUnit = .weekOfYear
            timeline = Insights.weeks(from: start, to: now, calendar: calendar, limit: 52).map { week in
                let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week)!
                return DateCount(date: week, count: events.filter { $0.kind == .finished && $0.at >= week && $0.at < next }.count)
            }
        }

        let flowStart = range == .all ? start : calendar.date(byAdding: .weekOfYear, value: -7, to: today)!
        let flowWeeks = Insights.weeks(from: flowStart, to: now, calendar: calendar, limit: range == .all ? 26 : 8)
        flow = flowWeeks.flatMap { week -> [FlowPoint] in
            let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week)!
            let slice = events.filter { $0.at >= week && $0.at < next }
            return [FlowPoint(week: week, series: Insights.cameIn, count: count(.captured, slice)),
                    FlowPoint(week: week, series: Insights.gotDone, count: count(.finished, slice))]
        }
        if let first = flowWeeks.first {
            let slice = events.filter { $0.at >= first && $0.at <= now }
            // Captures and split-off pieces add open tasks; finishing, dropping and deleting remove them.
            listChange = count(.captured, slice) + count(.split, slice)
                - count(.finished, slice) - count(.dropped, slice) - count(.deleted, slice)
        } else {
            listChange = 0
        }

        var hours = Array(repeating: 0, count: 24)
        for event in inPeriod where event.kind == .finished {
            hours[calendar.component(.hour, from: event.at)] += 1
        }
        finishesByHour = hours

        func reasons(_ kind: TaskEvent.Kind) -> [Reason] {
            inPeriod.filter { $0.kind == kind }.reversed().prefix(6).map {
                Reason(id: $0.id, title: $0.title, reason: $0.note ?? "", at: $0.at)
            }
        }
        blockedReasons = reasons(.blocked)
        droppedReasons = reasons(.dropped)
    }

    // MARK: Helpers

    static func median(of sorted: [TimeInterval]) -> TimeInterval? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static let bucketLimits: [(String, TimeInterval)] = [
        ("Under 1h", 3_600), ("1–4h", 4 * 3_600), ("4h–1d", 86_400), ("1–3d", 3 * 86_400), ("Over 3d", .infinity),
    ]

    static func buckets(_ durations: [TimeInterval]) -> [Bucket] {
        var lower: TimeInterval = 0
        return bucketLimits.map { label, upper in
            defer { lower = upper }
            return Bucket(label: label, count: durations.filter { $0 >= lower && $0 < upper }.count)
        }
    }

    /// The current streak counts today once you've finished something; until then it's still alive from yesterday.
    static func streaks(_ days: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, best: Int) {
        var current = 0
        var day = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while days.contains(day) {
            current += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var best = 0
        var run = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return (current, best)
    }

    /// Week starts from the week containing `start` through the week containing `end`, keeping the last `limit`.
    static func weeks(from start: Date, to end: Date, calendar: Calendar, limit: Int) -> [Date] {
        guard var week = calendar.dateInterval(of: .weekOfYear, for: start)?.start else { return [] }
        var result: [Date] = []
        while week <= end {
            result.append(week)
            week = calendar.date(byAdding: .weekOfYear, value: 1, to: week)!
        }
        return Array(result.suffix(limit))
    }
}
