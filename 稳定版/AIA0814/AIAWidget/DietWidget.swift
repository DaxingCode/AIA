// DietWidget.swift
// 小型(2x2)：饮食记录宫格，复刻 ContentView.dietTile。
import WidgetKit
import SwiftUI
import AIAKit

struct DietProvider: TimelineProvider {
    func placeholder(in context: Context) -> DietEntry {
        DietEntry(date: Date(), isEmpty: false, todayCount: 3, calories: 1200,
                  calorieGoal: 2000, water: 800)
    }

    func getSnapshot(in context: Context, completion: @escaping (DietEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DietEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    func loadEntry() -> DietEntry {
        return DietEntry(
            date: Date(),
            isEmpty: WidgetStore.foodTotalCountDirect() == 0,
            todayCount: WidgetStore.todayCaloriesDirect() > 0 ? 1 : 0,
            calories: WidgetStore.todayCaloriesDirect(),
            calorieGoal: WidgetStore.calorieGoal(),
            water: WidgetStore.todayWaterDirect()
        )
    }
}

struct DietWidgetEntryView: View {
    var entry: DietEntry

    var body: some View {
        WidgetTile(
            accent: AIATheme.food,
            icon: "fork.knife",
            title: "饮食记录",
            badge: "",
            number: "\(entry.calories)",
            unit: "kcal",
            isEmpty: entry.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 6) {
                MiniBar(value: entry.calorieGoal > 0 ? Double(entry.calories) / entry.calorieGoal : 0,
                        color: AIATheme.food)
                VStack(alignment: .leading, spacing: 4) {
                    TileRow(label: "目标热量", value: "\(Int(entry.calorieGoal)) kcal", valueColor: AIATheme.sub)
                    TileRow(label: entry.calories > Int(entry.calorieGoal) ? "已超" : "还可摄入",
                            value: "\(max(0, Int(abs(entry.calorieGoal - Double(entry.calories))))) kcal",
                            valueColor: entry.calories > Int(entry.calorieGoal) ? AIATheme.over : AIATheme.sub)
                    TileRow(label: "饮水量", value: "\(entry.water) ml", valueColor: AIATheme.food)
                }
            }
        }
        .widgetURL(URL(string: "aia://food"))
    }
}

struct DietWidget: Widget {
    let kind = "aia.diet"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DietProvider()) { entry in
            DietWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("饮食记录")
        .description("今日热量 / 饮水进度")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
