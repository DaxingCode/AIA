//
//  QuickActionsWidget.swift
//  AIAWidget
//
//  中型(4x2)：桌面「快捷操作」组件。一行排 4 个等宽按钮，从左到右：
//  语音记录 · 拍照记录 · 问好记 · 查待办。每个按钮点击等价于长按 App 图标快捷操作，
//  复用主 App 的 QuickActionRouter + consume(_:) 落地逻辑，行为 100% 一致。
//

import WidgetKit
import SwiftUI
import AIAKit

/// 4 个按钮定义：图标 / 标题 / 触发 URL scheme / 语义色。
/// 每个按钮用 Link 包，走 WidgetKit 已验证的「逐子视图 URL scheme」，
/// 点击触发 aia://xxx → AppDelegate.scene(_:openURLContexts:) 主路径，
/// 与所有其他工作 widget（.widgetURL）同源，与长按 App 图标的快捷操作落地完全一致。
private let quickActionItems: [(icon: String, title: String, url: URL, color: Color)] = [
    ("mic.fill",          "语音记录", URL(string: "aia://voice")!,  AIATheme.todo),    // 蓝
    ("camera.fill",       "拍照记录", URL(string: "aia://camera")!, AIATheme.bill),    // 绿
    ("bubble.left.fill",  "问好记",   URL(string: "aia://chat")!,   AIATheme.health),  // 紫
    ("checklist",         "查待办",   URL(string: "aia://todo")!,   AIATheme.food),    // 琥珀
]

struct QuickActionsWidgetEntryView: View {
    var entry: SimpleEntry

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(quickActionItems.enumerated()), id: \.offset) { _, item in
                Link(destination: item.url) {
                    VStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(item.color)
                            .frame(width: 44, height: 44)
                            .background(item.color.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AIATheme.reading)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(12)
        .containerBackground(.clear, for: .widget)
    }
}

struct QuickActionsWidget: Widget {
    let kind = "aia.quickactions"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SimpleEntryProvider()) { entry in
            QuickActionsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("快捷操作")
        .description("语音记录 · 拍照记录 · 问好记 · 查待办")
        .supportedFamilies([.systemMedium])
    }
}
