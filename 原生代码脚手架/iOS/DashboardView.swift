// DashboardView.swift
// 首页「净热量联动」卡片：今日摄入（SwiftData 食物）− 今日活动消耗（HealthKit）= 净热量，
// 并展示三大宏量营养素合计。M5 的核心联动页。
import SwiftUI
import SwiftData
import Combine

struct DashboardView: View {
    @Query private var foods: [FoodEntry]
    @ObservedObject var health: HealthManager

    private var todayFoods: [FoodEntry] {
        foods.filter { Calendar.current.isDateInToday($0.date) }
    }
    private var intake:  Double { todayFoods.reduce(0) { $0 + $1.calories } }
    private var protein: Double { todayFoods.reduce(0) { $0 + $1.protein } }
    private var carbs:   Double { todayFoods.reduce(0) { $0 + $1.carbs } }
    private var fat:     Double { todayFoods.reduce(0) { $0 + $1.fat } }

    private var burned: Double { health.activeEnergyToday }   // 来自 HealthKit
    private var net: Double { intake - burned }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 净热量主数字
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("今日净热量")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(net >= 0 ? "+" : "")\(Int(net))")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(net > 0 ? .orange : .green)
                Text("kcal").font(.subheadline).foregroundStyle(.secondary)
            }
            Text(net > 0
                 ? "热量盈余：摄入比消耗多 \(Int(net)) kcal"
                 : (net < 0 ? "热量缺口：消耗比摄入多 \(abs(Int(net))) kcal" : "摄入与消耗持平"))
                .font(.caption).foregroundStyle(.secondary)

            // 摄入 / 消耗 两条进度
            statRow(label: "摄入", value: intake, color: .orange)
            statRow(label: "消耗", value: burned, color: .blue)

            // 三大宏量营养素堆叠条
            macroBar
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statRow(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value)) kcal").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: min(value, max(intake, burned, 1)),
                         total: max(intake, burned, 1))
                .tint(color)
                .progressViewStyle(.linear)
        }
    }

    private var macroBar: some View {
        let total = max(protein + carbs + fat, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("今日营养素").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Capsule().fill(Color.red.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(protein / total))
                    Capsule().fill(Color.yellow.opacity(0.85))
                        .frame(width: geo.size.width * CGFloat(carbs / total))
                    Capsule().fill(Color.brown.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(fat / total))
                }
                .frame(height: 12)
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                legend(.red.opacity(0.8),   "蛋白 \(Int(protein))g")
                legend(.yellow.opacity(0.85), "碳水 \(Int(carbs))g")
                legend(.brown.opacity(0.8),  "脂肪 \(Int(fat))g")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}
