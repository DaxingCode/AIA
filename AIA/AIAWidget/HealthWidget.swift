// HealthWidget.swift
// 小型(2x2)：健康管理宫格，复刻 ContentView.healthTile。
// 说明：步数/运动/能量来自 HealthMetric 表（手动补录写入此表，Widget 可读）；
// 自动模式 HealthKit 实时值在 Widget 进程不可读，此为系统限制。
import WidgetKit
import SwiftUI
import AIAKit

struct HealthProvider: TimelineProvider {
    func placeholder(in context: Context) -> HealthEntry {
        HealthEntry(date: Date(), isEmpty: false, steps: 6500, stepGoal: 10000,
                    exerciseMin: 30, energyBurned: 320, sleepText: "7h20m")
    }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    func loadEntry() -> HealthEntry {
        let steps = WidgetStore.widgetSteps()
        let exercise = WidgetStore.widgetExercise()
        let energy = WidgetStore.widgetEnergy()
        let stepGoal = WidgetStore.stepGoal()
        let sleep = WidgetStore.sleepLastNightText()
        let isEmpty = steps == 0 && exercise == 0 && energy == 0 && sleep == "—"
        return HealthEntry(
            date: Date(),
            isEmpty: isEmpty,
            steps: steps,
            stepGoal: stepGoal,
            exerciseMin: exercise,
            energyBurned: energy,
            sleepText: sleep
        )
    }
}

struct HealthWidgetEntryView: View {
    var entry: HealthEntry

    var body: some View {
        WidgetTile(
            accent: AIATheme.health,
            icon: "heart.fill",
            title: "健康管理",
            badge: "",
            number: "\(entry.steps)",
            unit: "步",
            isEmpty: entry.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 6) {
                MiniBar(value: entry.stepGoal > 0 ? Double(entry.steps) / Double(entry.stepGoal) : 0,
                        color: AIATheme.health)
                VStack(alignment: .leading, spacing: 4) {
                    TileRow(label: "能量消耗",
                            value: entry.energyBurned > 0 ? "\(Int(entry.energyBurned)) kcal" : "—",
                            valueColor: AIATheme.sub)
                    TileRow(label: "运动时长", value: "\(Int(entry.exerciseMin)) min", valueColor: AIATheme.sub)
                    TileRow(label: "睡眠时长", value: entry.sleepText, valueColor: AIATheme.health)
                }
            }
        }
        .widgetURL(URL(string: "aia://health"))
    }
}

struct HealthWidget: Widget {
    let kind = "aia.health"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthProvider()) { entry in
            HealthWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("健康管理")
        .description("步数 / 运动 / 睡眠")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
