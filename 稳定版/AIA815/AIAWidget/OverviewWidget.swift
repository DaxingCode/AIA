// OverviewWidget.swift
// 大型(4x4)：旧版四宫格（账单管理 / 待办提醒 / 饮食记录 / 健康管理），
// 2×2 拼装，每块内容铺满所属网格、留小间距可辨边界，点哪块跳对应页。
// 取数口径与四个独立小 widget（Bill/Todo/Diet/Health）逐字对齐、同源。
import WidgetKit
import SwiftUI
import AppIntents
import AIAKit

struct OverviewEntry: TimelineEntry {
    let date: Date
    // 账单
    let billEmpty: Bool
    let billHidden: Bool
    let todayExpense: Double
    let monthIncome: Double
    let monthExpense: Double
    let monthlyBudget: Double
    let monthBalance: Double
    // 待办
    let todoEmpty: Bool
    let todos: [Reminder]
    // 饮食
    let dietEmpty: Bool
    let calories: Int
    let calorieGoal: Double
    let water: Int
    // 健康
    let healthEmpty: Bool
    let steps: Int
    let stepGoal: Int
    let exerciseMin: Double
    let energyBurned: Double
    let sleepText: String
}

struct OverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry {
        loadEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (OverviewEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OverviewEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> OverviewEntry {
        let hidden = WidgetStore.billHidden()
        let income = WidgetStore.monthIncomeDirect()
        let expense = WidgetStore.monthExpenseDirect()
        let budget = WidgetStore.monthlyBudget()
        let recent = WidgetStore.recentTodos(limit: 5)
        let steps = WidgetStore.widgetSteps()
        let exercise = WidgetStore.widgetExercise()
        let energy = WidgetStore.widgetEnergy()
        let sleep = WidgetStore.sleepLastNightText()
        return OverviewEntry(
            date: Date(),
            billEmpty: WidgetStore.billTotalCountDirect() == 0,
            billHidden: hidden,
            todayExpense: WidgetStore.todayExpenseDirect(),
            monthIncome: income,
            monthExpense: expense,
            monthlyBudget: budget,
            monthBalance: income - expense,
            todoEmpty: WidgetStore.todoCount() == 0,
            todos: recent,
            dietEmpty: WidgetStore.foodTotalCountDirect() == 0,
            calories: WidgetStore.todayCaloriesDirect(),
            calorieGoal: WidgetStore.calorieGoal(),
            water: WidgetStore.todayWaterDirect(),
            healthEmpty: steps == 0 && exercise == 0 && energy == 0 && sleep == "—",
            steps: steps,
            stepGoal: WidgetStore.stepGoal(),
            exerciseMin: exercise,
            energyBurned: energy,
            sleepText: sleep
        )
    }
}

// MARK: - 四块各自的内容视图（复用 WidgetTile 骨架，与各小 widget 同款）

struct OverviewBillCell: View {
    let entry: OverviewEntry

    private var hiddenText: String { "¥•••" }
    private var expenseTxt: String { entry.billHidden ? hiddenText : "¥\(Int(entry.todayExpense))" }
    private var monthExpenseTxt: String { entry.billHidden ? hiddenText : "¥\(Int(entry.monthExpense))" }
    private var incomeTxt: String { entry.billHidden ? hiddenText : "¥\(Int(entry.monthIncome))" }
    private var budgetTxt: String { entry.billHidden ? hiddenText : "¥\(Int(entry.monthlyBudget))" }
    private var balanceTxt: String { entry.billHidden ? hiddenText : "¥\(Int(entry.monthBalance))" }
    private var balanceColor: Color {
        entry.billHidden ? AIATheme.muted : (entry.monthBalance >= 0 ? AIATheme.income : AIATheme.expense)
    }

    var body: some View {
        Link(destination: URL(string: "aia://bill")!) {
            WidgetTile(
                accent: AIATheme.bill,
                icon: "creditcard.fill",
                title: "账单管理",
                badge: "",
                number: "",
                unit: "",
                isEmpty: entry.billEmpty,
                showBigNumber: false
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    TileLabeledNumber(label: "今日支出",
                                      value: expenseTxt,
                                      valueColor: entry.billHidden ? AIATheme.muted : AIATheme.expense)
                    HStack(spacing: 8) {
                        BillMetric(label: "本月收入", value: incomeTxt,
                                   valueColor: entry.billHidden ? AIATheme.muted : AIATheme.income)
                        BillMetric(label: "本月支出", value: monthExpenseTxt,
                                   valueColor: entry.billHidden ? AIATheme.muted : AIATheme.expense)
                    }
                    HStack(spacing: 8) {
                        BillMetric(label: "本月预算", value: budgetTxt, valueColor: AIATheme.sub)
                        BillMetric(label: "本月结余", value: balanceTxt, valueColor: balanceColor)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct OverviewTodoCell: View {
    let entry: OverviewEntry

    var body: some View {
        Link(destination: URL(string: "aia://todo")!) {
            WidgetTile(
                accent: AIATheme.todo,
                icon: "checklist",
                title: "待办提醒",
                badge: "",
                number: "",
                unit: "",
                isEmpty: entry.todoEmpty,
                showBigNumber: false
            ) {
                if entry.todos.isEmpty {
                    Text("暂无待办 👍")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entry.todos.prefix(5), id: \.id) { todo in
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
        }
        .contentShape(Rectangle())
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

struct OverviewDietCell: View {
    let entry: OverviewEntry

    var body: some View {
        Link(destination: URL(string: "aia://food")!) {
            WidgetTile(
                accent: AIATheme.food,
                icon: "fork.knife",
                title: "饮食记录",
                badge: "",
                number: "\(entry.calories)",
                unit: "kcal",
                isEmpty: entry.dietEmpty
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
        }
        .contentShape(Rectangle())
    }
}

struct OverviewHealthCell: View {
    let entry: OverviewEntry

    var body: some View {
        Link(destination: URL(string: "aia://health")!) {
            WidgetTile(
                accent: AIATheme.health,
                icon: "heart.fill",
                title: "健康管理",
                badge: "",
                number: "\(entry.steps)",
                unit: "步",
                isEmpty: entry.healthEmpty
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
        }
        .contentShape(Rectangle())
    }
}

/// 双行指标：标签在上、金额在下，与首页账单宫格 billMetric 同款
private struct BillMetric: View {
    let label: String
    let value: String
    let valueColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            Text(value)
                .font(AIATheme.Font.micro)
                .fontWeight(.regular)
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OverviewWidgetEntryView: View {
    var entry: OverviewEntry

    var body: some View {
        GeometryReader { geo in
            let h = (geo.size.height - 1) / 2
            let w = (geo.size.width - 1) / 2
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    OverviewDietCell(entry: entry).frame(width: w, height: h)
                    OverviewTodoCell(entry: entry).frame(width: w, height: h)
                }
                HStack(spacing: 1) {
                    OverviewBillCell(entry: entry).frame(width: w, height: h)
                    OverviewHealthCell(entry: entry).frame(width: w, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Color.clear)
        .containerBackground(Color.clear, for: .widget)
    }
}

struct OverviewWidget: Widget {
    let kind = "aia.overview"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OverviewProvider()) { entry in
            OverviewWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("今日概览")
        .description("账单 / 待办 / 饮食 / 健康 四宫格")
        .contentMarginsDisabled()
        .supportedFamilies([.systemLarge])
    }
}
