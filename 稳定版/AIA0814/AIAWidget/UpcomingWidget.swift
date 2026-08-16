// UpcomingWidget.swift
// 中型(4x2)：临近待办 Top3（标题 + 相对时间）。
import WidgetKit
import SwiftUI
import AIAKit

struct UpcomingProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingEntry {
        UpcomingEntry(date: Date(), todos: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> UpcomingEntry {
        UpcomingEntry(date: Date(), todos: WidgetStore.upcomingTodos(limit: 5))
    }
}

struct UpcomingWidgetEntryView: View {
    var entry: UpcomingEntry

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AIATheme.todo)
                    Text("临近待办")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AIATheme.reading)
                    Spacer()
                    if !entry.todos.isEmpty {
                        Text("\(entry.todos.count)")
                            .font(.system(size: 12))
                            .foregroundColor(AIATheme.muted)
                    }
                }
                if entry.todos.isEmpty {
                    Spacer()
                    Text("暂无临近待办")
                        .font(.system(size: 13))
                        .foregroundColor(AIATheme.muted)
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.todos, id: \.id) { todo in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(AIATheme.todo)
                                    .frame(width: 7, height: 7)
                                Text(todo.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AIATheme.reading)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Spacer()
                                if let due = todo.due {
                                    Text(relative(due))
                                        .font(.system(size: 11))
                                        .foregroundColor(dueIsPast(due) ? AIATheme.expense : AIATheme.muted)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
        .widgetURL(URL(string: "aia://todo"))
        .containerBackground(.clear, for: .widget)
    }

    private func dueIsPast(_ due: Date) -> Bool {
        due < Date()
    }

    private func relative(_ due: Date) -> String {
        let now = Date()
        let cal = Calendar.current
        if cal.isDateInToday(due) {
            return "今天 " + AppFormat.hourMinute.string(from: due)
        } else if cal.isDateInTomorrow(due) {
            return "明天 " + AppFormat.hourMinute.string(from: due)
        } else if due < now {
            return "已逾期"
        } else {
            return AppFormat.monthDay.string(from: due)
        }
    }
}

struct UpcomingWidget: Widget {
    let kind = "aia.upcoming"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UpcomingProvider()) { entry in
            UpcomingWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("临近待办")
        .description("即将到期的待办 Top5")
        .supportedFamilies([.systemMedium])
    }
}
