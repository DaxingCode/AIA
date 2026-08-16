// TodoWidget.swift
// 小型(2x2)：待办提醒宫格，复刻 ContentView.todoTile。
import WidgetKit
import SwiftUI
import AIAKit

struct TodoProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodoEntry {
        TodoEntry(date: Date(), isEmpty: false, recent: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    func loadEntry() -> TodoEntry {
        let recent = WidgetStore.recentTodos(limit: 5)
        return TodoEntry(
            date: Date(),
            isEmpty: WidgetStore.todoCount() == 0,
            recent: recent
        )
    }
}

struct TodoWidgetEntryView: View {
    var entry: TodoEntry

    var body: some View {
        WidgetTile(
            accent: AIATheme.todo,
            icon: "checklist",
            title: "待办提醒",
            badge: "",
            number: "",
            unit: "",
            isEmpty: entry.isEmpty,
            showBigNumber: false
        ) {
            if entry.recent.isEmpty {
                Text("暂无待办 👍")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.recent.prefix(5), id: \.id) { todo in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AIATheme.todo)
                                .frame(width: 6, height: 6)
                            Text(todo.title)
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.reading)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer()
                            if let due = todo.due {
                                Text(relative(due))
                                    .font(AIATheme.Font.micro)
                                    .foregroundStyle(due < Date() ? AIATheme.expense : AIATheme.muted)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .widgetURL(URL(string: "aia://todo"))
    }

    private func relative(_ due: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(due) {
            return AppFormat.hourMinute.string(from: due)
        } else if cal.isDateInTomorrow(due) {
            return "明天"
        } else {
            return AppFormat.monthDay.string(from: due)
        }
    }
}

struct TodoWidget: Widget {
    let kind = "aia.todo"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodoProvider()) { entry in
            TodoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("待办提醒")
        .description("今日待办与近期安排")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
