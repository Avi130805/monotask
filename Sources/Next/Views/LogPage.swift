import SwiftUI

/// Everything that left Do Now: finished end to end, or honestly dropped.
struct LogPage: View {
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model

    var body: some View {
        let entries = Array(store.state.log.prefix(200))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Finished · \(store.finishedThisWeek) this week")
                Spacer()
                Button {
                    model.onOpenInsights()
                } label: {
                    Label("Insights", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Charts of what you finish, how long it takes, and what gets in the way")
            }
            if entries.isEmpty {
                Text("Tasks you mark done end to end show up here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(entries) { LogRow(entry: $0) }
                    }
                }
                .frame(height: min(estimatedHeight(of: entries), 320))
            }
        }
    }

    private func estimatedHeight(of entries: [LogEntry]) -> CGFloat {
        entries.reduce(0) { $0 + ($1.reason == nil ? 31 : 43) }
    }
}

struct LogRow: View {
    let entry: LogEntry

    private var isDone: Bool { entry.kind == .done }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDone ? Palette.done : Palette.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .strikethrough(!isDone, color: Palette.tertiary)
                    .foregroundStyle(isDone ? Palette.primary : Palette.tertiary)
                    .lineLimit(1)
                if let reason = entry.reason {
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(entry.endedAt, format: .relative(presentation: .named))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
    }
}
