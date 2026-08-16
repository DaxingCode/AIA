//
//  ChatWidget.swift
//  AIAWidget
//
//  中型(4x2)：对话页「小记」快捷入口。点任意处进 ChatView（aia://chat）。
//

import WidgetKit
import SwiftUI
import AIAKit

struct SimpleEntry: TimelineEntry {
    let date: Date
}

struct SimpleEntryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [SimpleEntry(date: Date())], policy: .after(next)))
    }
}

struct ChatWidgetEntryView: View {
    var entry: SimpleEntry

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AIATheme.todo)
                    Text("好记AI助手")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AIATheme.reading)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AIATheme.muted)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AIATheme.todo)
                        .frame(width: 34, height: 34)
                        .background(AIATheme.todo.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("问小记点这里开始")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AIATheme.reading)
                            .lineLimit(1)
                        Text("记一笔 · 问问题 · 看识别结果")
                            .font(.system(size: 12))
                            .foregroundColor(AIATheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .widgetURL(URL(string: "aia://chat"))
        .containerBackground(.clear, for: .widget)
    }
}

struct ChatWidget: Widget {
    let kind = "aia.chat"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SimpleEntryProvider()) { entry in
            ChatWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("全能助手")
        .description("点此直接进入对话页，问小记或继续记录")
        .supportedFamilies([.systemMedium])
    }
}
