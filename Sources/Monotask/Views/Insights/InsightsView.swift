import Charts
import SwiftUI

/// The analytics window: what you finish, how long it takes, when you finish, and what gets in the way.
struct InsightsView: View {
    @State var range: InsightRange

    init(range: InsightRange = .week) {
        _range = State(initialValue: range)
    }

    var body: some View {
        ScrollView {
            InsightsPage(range: $range)
        }
        .frame(minWidth: 700, minHeight: 560)
        .background(InsightColors.background)
    }
}

/// Everything in the window, without the scroll view, so it can also be rendered whole.
struct InsightsPage: View {
    @Binding var range: InsightRange
    @Environment(Store.self) var store

    var body: some View {
        let insights = Insights(events: store.events, range: range)
        VStack(alignment: .leading, spacing: 16) {
            header(insights)
            if store.events.isEmpty {
                EmptyInsights()
            } else {
                StatTiles(insights: insights)
                Counts(insights: insights)
                FinishedChart(insights: insights)
                HStack(alignment: .top, spacing: 16) {
                    HourChart(insights: insights)
                    DurationChart(insights: insights)
                }
                FlowChart(insights: insights)
                HStack(alignment: .top, spacing: 16) {
                    ReasonCard(title: "What blocked you", reasons: insights.blockedReasons, empty: "Nothing blocked you.")
                    ReasonCard(title: "Why things were dropped", reasons: insights.droppedReasons, empty: "Nothing was dropped.")
                }
                HistoryCard(insights: insights)
            }
        }
        .animation(.snappy, value: range)
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(maxWidth: 940)
        .frame(maxWidth: .infinity)
    }

    private func header(_ insights: Insights) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insights")
                    .font(.system(size: 26, weight: .bold))
                Text(subtitle(insights))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $range) {
                ForEach(InsightRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func subtitle(_ insights: Insights) -> String {
        switch range {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .all: "Since \(insights.periodStart.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

// MARK: - Numbers

private struct StatTiles: View {
    let insights: Insights

    var body: some View {
        HStack(spacing: 12) {
            StatTile(symbol: "checkmark.circle.fill", tint: .green, title: "Finished",
                     value: "\(insights.finished)", caption: finishedCaption)
            StatTile(symbol: "target", tint: .blue, title: "Finish rate",
                     value: insights.finishRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–",
                     caption: "\(insights.finished) done, \(insights.dropped) dropped")
            StatTile(symbol: "timer", tint: .orange, title: "Time to finish",
                     value: insights.medianTimeToFinish.map(Elapsed.duration) ?? "–",
                     caption: "Typical, from start to done")
            StatTile(symbol: "flame.fill", tint: .pink, title: "Streak",
                     value: days(insights.streak), caption: "Best: \(days(insights.bestStreak))")
        }
    }

    private var finishedCaption: String {
        guard let previous = insights.previousFinished, let days = insights.range.days else {
            return "Since \(insights.periodStart.formatted(.dateTime.day().month(.abbreviated)))"
        }
        let change = insights.finished - previous
        if change == 0 { return "Same as the \(days) days before" }
        return "\(change > 0 ? "+" : "−")\(abs(change)) on the \(days) days before"
    }

    private func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
}

private struct StatTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(CardBackground())
    }
}

/// The smaller counts: everything else that happened in the period.
private struct Counts: View {
    let insights: Insights

    var body: some View {
        HStack(spacing: 18) {
            Label("\(insights.captured) captured", systemImage: "tray.and.arrow.down")
            Label("\(insights.splits) split", systemImage: "scissors")
            Label("\(insights.blocks) blocked", systemImage: "pause.circle")
            Label("\(insights.dropped) dropped", systemImage: "xmark.circle")
            Label("\(insights.deleted) deleted", systemImage: "trash")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

// MARK: - Charts

private struct FinishedChart: View {
    let insights: Insights

    var body: some View {
        InsightCard(title: "Finished", subtitle: subtitle) {
            Chart {
                ForEach(insights.timeline) { point in
                    BarMark(x: .value("Date", point.date, unit: insights.timelineUnit),
                            y: .value("Finished", point.count))
                        .foregroundStyle(Color.green.gradient)
                        .cornerRadius(4)
                }
                if average > 0 {
                    RuleMark(y: .value("Average", average))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: strideUnit, count: strideCount)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: labelFormat)
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 170)
        }
    }

    private var average: Double {
        guard !insights.timeline.isEmpty else { return 0 }
        return Double(insights.timeline.reduce(0) { $0 + $1.count }) / Double(insights.timeline.count)
    }

    private var subtitle: String {
        guard average > 0 else { return "Nothing finished in this period" }
        let per = insights.timelineUnit == .day ? "a day" : "a week"
        return "\(average.formatted(.number.precision(.fractionLength(0...1)))) \(per) on average"
    }

    private var strideUnit: Calendar.Component { insights.range == .all ? .weekOfYear : .day }

    private var strideCount: Int {
        switch insights.range {
        case .week: 1
        case .month: 7
        case .all: insights.timeline.count > 12 ? 4 : 1
        }
    }

    private var labelFormat: Date.FormatStyle {
        insights.range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated)
    }
}

private struct HourChart: View {
    let insights: Insights
    private let midnight = Calendar.current.startOfDay(for: .now)

    var body: some View {
        InsightCard(title: "When you finish", subtitle: subtitle) {
            Chart(Array(insights.finishesByHour.enumerated()), id: \.offset) { item in
                BarMark(x: .value("Hour", hour(item.offset), unit: .hour),
                        y: .value("Finished", item.element))
                    .foregroundStyle(item.offset == insights.peakHour ? Color.green : Color.green.opacity(0.35))
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 150)
        }
    }

    private func hour(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: offset, to: midnight) ?? midnight
    }

    private var subtitle: String {
        guard let peak = insights.peakHour else { return "No finishes in this period" }
        return "Most often around \(hour(peak).formatted(.dateTime.hour()))"
    }
}

private struct DurationChart: View {
    let insights: Insights

    var body: some View {
        InsightCard(title: "Time to finish", subtitle: subtitle) {
            Chart(insights.timeToFinish) { bucket in
                BarMark(x: .value("Tasks", bucket.count), y: .value("Time", bucket.label))
                    .foregroundStyle(Color.orange.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing, spacing: 4) {
                        Text("\(bucket.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: 150)
        }
    }

    private var subtitle: String {
        insights.medianTimeToFinish.map { "Typically \(Elapsed.duration($0))" } ?? "Nothing finished in this period"
    }
}

/// What came in against what got finished. If the grey bars keep winning, the list keeps growing.
private struct FlowChart: View {
    let insights: Insights

    var body: some View {
        InsightCard(title: "In and out", subtitle: sentence) {
            Chart(insights.flow) { point in
                BarMark(x: .value("Week", point.week, unit: .weekOfYear), y: .value("Tasks", point.count))
                    .foregroundStyle(by: .value("Series", point.series))
                    .position(by: .value("Series", point.series))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale([Insights.cameIn: Color.gray.opacity(0.55), Insights.gotDone: Color.green])
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: weeks > 10 ? 4 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 170)
        }
    }

    private var weeks: Int { insights.flow.count / 2 }

    private var sentence: String {
        let span = weeks == 1 ? "this week" : "over the last \(weeks) weeks"
        let change = insights.listChange
        if change > 0 { return "Your list grew by \(change) \(span). Things come in faster than you finish them." }
        if change < 0 { return "Your list shrank by \(-change) \(span). You're finishing faster than things come in." }
        return "Your list held steady \(span)."
    }
}

// MARK: - Lists

private struct ReasonCard: View {
    let title: String
    let reasons: [Insights.Reason]
    let empty: String

    var body: some View {
        InsightCard(title: title) {
            if reasons.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reasons) { reason in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.reason)
                                .font(.callout)
                            Text("\(reason.title) · \(reason.at.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryCard: View {
    let insights: Insights
    @State var showAll = false

    private let shortList = 25

    var body: some View {
        InsightCard(title: "History", subtitle: subtitle) {
            VStack(spacing: 0) {
                ForEach(Array(insights.runs.prefix(showAll ? insights.runs.count : shortList).enumerated()),
                        id: \.element.id) { index, run in
                    if index > 0 { Divider() }
                    HistoryRow(run: run)
                }
                if insights.runs.count > shortList {
                    Divider()
                    Button(showAll ? "Show fewer" : "Show all \(insights.runs.count)") {
                        withAnimation(.snappy) { showAll.toggle() }
                    }
                    .buttonStyle(.link)
                    .padding(.top, 10)
                }
            }
        }
    }

    private var subtitle: String {
        switch insights.runs.count {
        case 0: "Nothing ended in this period"
        case 1: "1 task ended in this period"
        case let count: "\(count) tasks ended in this period"
        }
    }
}

private struct HistoryRow: View {
    let run: Insights.Run

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.finished ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(run.finished ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title)
                    .strikethrough(!run.finished)
                    .foregroundStyle(run.finished ? .primary : .secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(run.ended.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var detail: String {
        if run.finished { return run.duration.map { "Took \(Elapsed.duration($0))" } ?? "Finished" }
        return run.note.map { "Dropped: \($0)" } ?? "Dropped"
    }
}

private struct EmptyInsights: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing to show yet")
                .font(.title3.weight(.semibold))
            Text("Capture, start and finish a few things. Your patterns show up here as you go.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }
}

// MARK: - Building blocks

private struct InsightCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

private struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(InsightColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

/// Grouped style, like System Settings: white cards on grey in light mode, lighter cards on near-black in dark.
enum InsightColors {
    static let background = adaptive(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.11, alpha: 1))
    static let card = adaptive(light: .white, dark: NSColor(white: 0.17, alpha: 1))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
