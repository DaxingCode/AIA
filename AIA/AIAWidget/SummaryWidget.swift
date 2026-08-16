// SummaryWidget.swift
// 小型(2x2) + 锁屏：今日四指标（摄入 / 饮水 / 步数 / 支出）。
import WidgetKit
import SwiftUI
import AIAKit

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: Date(), calories: 1200, water: 800, steps: 3200, expense: 86)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let entry = loadEntry()
        // 15 分钟后刷新兜底（主 App 数据变更会主动 reloadAllTimelines）
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> SummaryEntry {
        SummaryEntry(date: Date(),
                     calories: WidgetStore.todayCalories(),
                     water: WidgetStore.todayWater(),
                     steps: WidgetStore.widgetSteps(),
                     expense: WidgetStore.todayExpense())
    }
}

/// 单个小方块：图标 + 标题 + 大数字 + 单位
/// 单个小方块：图标 + 标题 + 大数字 + 单位
struct SummaryCell: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    let accent: Color

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AIATheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            // 数字 + 单位作为一个整体水平居中于色块中央（不贴左）。
            // 数字 13pt 不加 minimumScaleFactor：四宫格数字视觉等大。
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(accent.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.clear)
    }
}

struct SummaryWidgetEntryView: View {
    var entry: SummaryEntry
    @Environment(\.widgetFamily) var family

    // 四指标配置（顺序：摄入 / 饮水 / 步数 / 支出）
    private var cells: [(icon: String, title: String, value: String, unit: String, accent: Color, url: String)] {
        [
            ("fork.knife", "摄入", "\(entry.calories)", "kcal", AIATheme.food, "aia://home"),
            ("drop.fill", "饮水", "\(entry.water)", "ml", AIATheme.blue, "aia://home"),
            ("figure.walk", "步数", "\(entry.steps)", "步", AIATheme.health, "aia://home"),
            ("yensign.circle.fill", "支出", String(format: "%.0f", entry.expense), "元", AIATheme.bill, "aia://home")
        ]
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessoryRectangular
        case .accessoryCircular:
            accessoryCircular
        default:
            smallGrid
        }
    }

    // 主屏 2x2 四宫格：四块色铺满整个 widget（含四周圆角区域，无白边）
    private var smallGrid: some View {
        let urls = cells.map { $0.url }
        let a0 = cells[0].accent, a1 = cells[1].accent
        let a2 = cells[2].accent, a3 = cells[3].accent
        return ZStack(alignment: .top) {
            // 底层：四块色严格平铺到四个象限（VStack/HStack 二维布局天然平铺，不叠加）。
            // frame(maxWidth/maxHeight: .infinity) 占满 widget 全尺寸，再 padding(-20) 负内边距
            // 把色块整体向四周外扩 20pt，**超出**系统 widget 容器圆角矩形（约 inset 8~10pt）。
            // 系统容器圆角矩形从外侧自动裁掉超出部分，色块就铺到系统容器的圆角外边——圆角区域也有色。
            // 不使用 clipShape（它在 widget 容器内反而把色块裁回内嵌圆角框，导致四周白边）。
            // containerBackground 用 .clear，让圆角外的区域透明（桌面穿透），不再有 surface 白底。
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    a0.opacity(0.32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    a1.opacity(0.32).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 0) {
                    a2.opacity(0.32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    a3.opacity(0.32).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(-20)

            // 上层：四宫格文字（位置与底色一致，无缝拼接）
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SummaryCell(icon: cells[0].icon, title: cells[0].title,
                                value: cells[0].value, unit: cells[0].unit, accent: cells[0].accent)
                        .widgetURL(URL(string: urls[0]))
                    SummaryCell(icon: cells[1].icon, title: cells[1].title,
                                value: cells[1].value, unit: cells[1].unit, accent: cells[1].accent)
                        .widgetURL(URL(string: urls[1]))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 0) {
                    SummaryCell(icon: cells[2].icon, title: cells[2].title,
                                value: cells[2].value, unit: cells[2].unit, accent: cells[2].accent)
                        .widgetURL(URL(string: urls[2]))
                    SummaryCell(icon: cells[3].icon, title: cells[3].title,
                                value: cells[3].value, unit: cells[3].unit, accent: cells[3].accent)
                        .widgetURL(URL(string: urls[3]))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .containerBackground(.clear, for: .widget)
    }

    // 锁屏矩形：一行小字（摄入 / 饮水 / 步数 / 支出）
    private var accessoryRectangular: some View {
        HStack(spacing: 10) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("\(c.value)\(c.unit)").font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // 锁屏圆点：环形进度（步数占目标）+ 中心数字
    private var accessoryCircular: some View {
        let goal = max(1, WidgetStore.stepGoal())
        let ratio = min(1, Double(entry.steps) / Double(goal))
        return ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Text("\(entry.steps)").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("步").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .widgetCurvesContent()
        .widgetLabel {
            ProgressView(value: ratio)
        }
    }
}

struct SummaryWidget: Widget {
    let kind = "aia.summary"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummaryProvider()) { entry in
            SummaryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("今日数据")
        .description("今日摄入热量、饮水、步数、支出")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
    }
}
