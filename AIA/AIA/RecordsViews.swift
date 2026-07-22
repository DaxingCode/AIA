// RecordsViews.swift
// 四个模块的「记录列表」页，按《UI完整页面流.html》③饮食 ④健康 ⑤账单 ⑥待办 重做。
// 数据均来自本地 SwiftData；健康页步数/活动消耗来自 HealthManager（真机 HealthKit 生效）。
import SwiftUI
import SwiftData
import Combine
import Charts

// 图表用数据点
private struct ChartPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}

private let dayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "M/d"; return f
}()

// MARK: - 饮食记录（③）
private enum MealFilter: String, CaseIterable {
    case bf, lu, dn, sn
    // 存储用规范中文值（与历史数据一致，不可本地化）
    var mealString: String {
        switch self {
        case .bf: return "早餐"
        case .lu: return "午餐"
        case .dn: return "晚餐"
        case .sn: return "加餐"
        }
    }
    // 界面展示用本地化文本
    var label: String {
        switch self {
        case .bf: return NSLocalizedString("food.meal.breakfast", comment: "")
        case .lu: return NSLocalizedString("food.meal.lunch", comment: "")
        case .dn: return NSLocalizedString("food.meal.dinner", comment: "")
        case .sn: return NSLocalizedString("food.meal.snack", comment: "")
        }
    }
}

struct FoodListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \FoodEntry.date, order: .reverse) private var foods: [FoodEntry]
    @State private var meal: MealFilter = .lu
    @State private var selectedDate: Date = Date()
    @State private var showDatePicker: Bool = false
    @State private var showGoalEditor: Bool = false
    @State private var editedGoal: Double = 0
    @State private var showCamera = false
    @State private var showPicker = false
    @StateObject private var health = HealthManager.shared
    @AppStorage("aia.calorieGoalOverride") private var goalOverride: Double = 0
    @AppStorage("aia.calorieGoalIsCustom") private var goalIsCustom: Bool = false

    // 按进入时间自动匹配餐次页签：5-11 早餐、11-16 午餐、16-22 晚餐，其余为加餐
    private static func defaultMeal(for date: Date) -> MealFilter {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<11:  return .bf
        case 11..<16: return .lu
        case 16..<22: return .dn
        default:      return .sn
        }
    }

    private var selectedFoods: [FoodEntry] { foods.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) } }
    private var selectedCalories: Double { selectedFoods.reduce(0) { $0 + $1.calories } }
    private var tdee: Double { 1730 + health.activeEnergyToday }
    private var goal: Double { goalIsCustom ? goalOverride : tdee }
    private var net: Double { selectedCalories - tdee }

    private var macros: (p: Double, c: Double, f: Double) {
        selectedFoods.reduce((0, 0, 0)) { ($0.0 + $1.protein, $0.1 + $1.carbs, $0.2 + $1.fat) }
    }

    private var weekData: [ChartPoint] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: selectedDate)
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: day)!
            let sum = foods.filter { cal.isDate($0.date, inSameDayAs: d) }.reduce(0) { $0 + $1.calories }
            return ChartPoint(label: dayFmt.string(from: d), value: sum)
        }
    }

    private var mealItems: [FoodEntry] {
        selectedFoods.filter { $0.meal == meal.mealString }.sorted { $0.date > $1.date }
    }
    private var mealTotal: Double {
        selectedFoods.filter { $0.meal == meal.mealString }.reduce(0) { $0 + $1.calories }
    }

    private var dateTitleText: String {
        let cal = Calendar.current
        if cal.isDateInToday(selectedDate) {
            return String(format: "今天 · %@ %@", AppFormat.date.string(from: selectedDate), weekday(for: selectedDate))
        } else if cal.isDateInYesterday(selectedDate) {
            return String(format: "昨天 · %@ %@", AppFormat.date.string(from: selectedDate), weekday(for: selectedDate))
        } else if cal.isDateInTomorrow(selectedDate) {
            return String(format: "明天 · %@ %@", AppFormat.date.string(from: selectedDate), weekday(for: selectedDate))
        }
        return String(format: "%@ %@", AppFormat.date.string(from: selectedDate), weekday(for: selectedDate))
    }

    private func shiftDate(by days: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                shiftDate(by: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(AIATheme.Font.caption.weight(.semibold))
                                    .foregroundStyle(AIATheme.sub)
                                    .frame(width: 24, height: 24)
                                    .background(AIATheme.surfaceSecondary)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)

                            Text(dateTitleText)
                                .font(AIATheme.Font.footnote.weight(.medium))

                            Spacer()

                            Button {
                                editedGoal = goal
                                showGoalEditor = true
                            } label: {
                                HStack(spacing: 4) {
                                    Pill(text: "\(Int(selectedCalories)) / \(Int(goal))")
                                    Image(systemName: "pencil")
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.muted)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                shiftDate(by: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(AIATheme.Font.caption.weight(.semibold))
                                    .foregroundStyle(AIATheme.sub)
                                    .frame(width: 24, height: 24)
                                    .background(AIATheme.surfaceSecondary)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }

                        MiniBar(value: selectedCalories / goal, color: AIATheme.food)
                    }
                    .padding(.bottom, 4)

                    // 净热量卡 + 今日能量消耗
                    HStack(spacing: 8) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Int(net))").font(AIATheme.Font.title3.weight(.semibold)).foregroundStyle(AIATheme.food)
                                Text(NSLocalizedString("food.netLabel", comment: "")).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                            }
                            Divider().frame(height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: NSLocalizedString("food.intakeTdee", comment: ""), Int(selectedCalories), Int(tdee))).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                                Text(net < 0 ? NSLocalizedString("food.belowGoal", comment: "") : NSLocalizedString("food.overGoal", comment: "")).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(AIATheme.billBG)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))

                        // 今日能量消耗
                        VStack(spacing: 2) {
                            Text("\(Int(health.activeEnergyToday))")
                                .font(AIATheme.Font.title3.weight(.semibold))
                                .foregroundStyle(AIATheme.health)
                            Text("kcal")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.sub)
                            Text(NSLocalizedString("food.burned", comment: ""))
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.sub)
                        }
                        .frame(width: 86)
                        .padding(.vertical, 12)
                        .background(AIATheme.health.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }

                    SectionTitle(text: NSLocalizedString("food.nutrition", comment: ""),
                                 trailing: String(format: NSLocalizedString("food.nutritionTarget", comment: ""), 75, 220, 55))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        MacroCard(title: NSLocalizedString("food.macro.protein", comment: ""), value: "\(Int(macros.p))g", progress: macros.p / 75, color: AIATheme.blue)
                        MacroCard(title: NSLocalizedString("food.macro.carb", comment: ""), value: "\(Int(macros.c))g", progress: macros.c / 220, color: AIATheme.amber)
                        MacroCard(title: NSLocalizedString("food.macro.fat", comment: ""), value: "\(Int(macros.f))g", progress: macros.f / 55, color: AIATheme.green)
                        MacroCard(title: NSLocalizedString("food.macro.fiber", comment: ""), value: "—", progress: 0, color: AIATheme.health)
                    }

                    if !foods.isEmpty {
                        SectionTitle(text: NSLocalizedString("food.last7days", comment: ""))
                        Chart(weekData) { p in
                            LineMark(x: .value(NSLocalizedString("chart.day", comment: ""), p.label), y: .value(NSLocalizedString("chart.kcal", comment: ""), p.value))
                                .foregroundStyle(AIATheme.food)
                                .interpolationMethod(.monotone)
                        }
                        .frame(height: 64)
                        .chartYAxis(.hidden).chartXAxis(.hidden)

                        SegmentedPicker(options: MealFilter.allCases.map { (value: $0, label: $0.label) }, selection: $meal)
                            .padding(.top, 4)

                        // 本餐热量汇总
                        HStack {
                            Text(meal.label)
                                .font(AIATheme.Font.footnote.weight(.semibold))
                            Spacer()
                            Text("共 \(Int(mealTotal)) kcal")
                                .font(AIATheme.Font.footnote.weight(.medium))
                                .foregroundStyle(AIATheme.food)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .card(radius: AIATheme.rMD, shadow: false)
                    }

                    if mealItems.isEmpty {
                        EmptyStateView(
                            kind: .diet,
                            title: "这餐还没记录",
                            message: "到相册选一张照片，阿宝会自动识别菜名、热量和营养元素。",
                            actionTitle: "到相册选一张",
                            action: { showPicker = true },
                            footer: "点击底部拍照、相册上传食物照片\n或点击文字输入、语音输入\n也可使用AI快速记录哦"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ForEach(mealItems) { f in
                            SelectableCard(
                                content: HStack(spacing: 10) {
                                    // 类型色圆点：饮食=琥珀，与首页时间线、各列表类型色一致
                                    Circle().fill(AIATheme.food).frame(width: 7, height: 7).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.name).font(AIATheme.Font.footnote.weight(.medium))
                                        Text([f.portion, NSLocalizedString("food.recognized", comment: "")].compactMap { $0.isEmpty ? nil : $0 }.joined(separator: " · "))
                                            .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                                    }
                                    Spacer()
                                    Text("\(Int(f.calories))").font(AIATheme.Font.footnote.weight(.medium))
                                }
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .card(radius: AIATheme.rMD, shadow: false),
                                destination: FoodDetailView(entry: f)
                            )
                        }
                    }
                }
                .padding()
            }
            AIBottomBar(prompts: [
                AIPrompt(text: "点拍照识别、记录美食", pointsTo: .camera),
                AIPrompt(text: "吃了什么美食？点此阿宝帮你记", pointsTo: nil),
                AIPrompt(text: "点麦克风，语音记录饮食", pointsTo: .mic),
                AIPrompt(text: "阿宝帮总结今天的饮食情况", pointsTo: nil),
                AIPrompt(text: "点相册上传、记录美食", pointsTo: .album)
            ])
        }
        .navigationTitle(LocalizedStringKey("food.navTitle"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showDatePicker = true } label: {
                    Image(systemName: "calendar")
                        .font(AIATheme.Font.headline)
                        .foregroundStyle(AIATheme.blue)
                }
            }
        }
        .sheet(isPresented: $showDatePicker) {
            VStack(spacing: 0) {
                HStack {
                    Text("选择日期")
                        .font(AIATheme.Font.headline.weight(.semibold))
                    Spacer()
                    Button("确定") { showDatePicker = false }
                        .font(AIATheme.Font.body.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                }
                .padding()
                DatePicker("", selection: $selectedDate, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.horizontal)
                Spacer()
            }
            .presentationDetents([.height(420)])
        }
        .sheet(isPresented: $showGoalEditor) {
            VStack(spacing: 0) {
                HStack {
                    Text("修改目标热量")
                        .font(AIATheme.Font.headline.weight(.semibold))
                    Spacer()
                    Button("完成") { showGoalEditor = false }
                        .font(AIATheme.Font.body.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                }
                .padding()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("当前目标")
                            .font(AIATheme.Font.footnote)
                            .foregroundStyle(AIATheme.sub)
                        Spacer()
                        Text(goalIsCustom ? "自定义" : "自动（TDEE）")
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(AIATheme.blue)
                    }

                    HStack {
                        Text("\(Int(goal))")
                            .font(AIATheme.Font.hero.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("kcal")
                            .font(AIATheme.Font.subhead)
                            .foregroundStyle(AIATheme.muted)
                        Spacer()
                    }
                }
                .padding()
                .background(AIATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("手动设置")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.sub)
                    HStack {
                        TextField("目标热量", value: $editedGoal, format: .number)
                            .keyboardType(.numberPad)
                            .font(AIATheme.Font.headline)
                        Text("kcal")
                            .font(AIATheme.Font.subhead)
                            .foregroundStyle(AIATheme.muted)
                    }
                    .padding()
                    .background(AIATheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .padding()

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        goalIsCustom = true
                        goalOverride = editedGoal
                        showGoalEditor = false
                    } label: {
                        Text("保存")
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(AIATheme.blue)
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    .buttonStyle(.plain)

                    Button {
                        goalIsCustom = false
                        showGoalEditor = false
                    } label: {
                        Text("恢复自动（TDEE \(Int(tdee)) kcal）")
                            .font(AIATheme.Font.body.weight(.medium))
                            .foregroundStyle(AIATheme.sub)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .presentationDetents([.height(360)])
        }
        .onAppear { meal = FoodListView.defaultMeal(for: .now) }
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker)
    }

    private func weekday(for date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func deleteFood(_ f: FoodEntry) {
        LocalImageStore.delete(f.imageName)
        // 列表页删除：cell 非 NavigationLink 目标，直接硬删即可；不显式 save，
        // 交给 SwiftData autosave，避免同步写盘阻塞主线程（用户多次反馈删除卡死）。
        withAnimation {
            context.delete(f)
        }
    }
}

// MARK: - 健康管理（④）
struct HealthListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \HealthMetric.date, order: .reverse) private var healths: [HealthMetric]
    @StateObject private var health = HealthManager.shared

    private var sleepHours: Double {
        healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0
    }
    private func stat(_ key: String) -> String {
        healths.first(where: { $0.metric.contains(key) }).map { "\($0.value)\($0.unit)" } ?? "—"
    }
    private var weightTrend: [ChartPoint] {
        healths.filter { $0.metric.contains("体重") || $0.metric.lowercased().contains("weight") }
            .sorted { $0.date < $1.date }
            .map { ChartPoint(label: dayFmt.string(from: $0.date), value: Double($0.value) ?? 0) }
    }
    private var weekSteps: [ChartPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let names = cal.shortWeekdaySymbols
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: today)!
            let v = cal.isDateInToday(d) ? Double(health.stepsToday) : 0
            let wd = cal.component(.weekday, from: d) - 1
            return ChartPoint(label: names[wd], value: v)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // 顶部4个圆环，与下方4模块同列宽对齐
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        RingView(value: "\(health.stepsToday)", caption: NSLocalizedString("health.ring.steps", comment: ""),
                                 progress: Double(health.stepsToday) / 10000, color: AIATheme.health,
                                 size: 74, lineWidth: 7)
                        RingView(value: sleepHours > 0 ? String(format: "%.1f", sleepHours) : "—",
                                 caption: NSLocalizedString("health.ring.sleep", comment: ""),
                                 progress: sleepHours / 8, color: AIATheme.health,
                                 size: 74, lineWidth: 7)
                        RingView(value: health.activeEnergyToday > 0 ? "\(Int(health.activeEnergyToday))" : "—",
                                 caption: NSLocalizedString("health.ring.energy", comment: ""),
                                 progress: health.activeEnergyToday / 500, color: AIATheme.health,
                                 size: 74, lineWidth: 7)
                        RingView(value: health.exerciseTimeToday > 0 ? "\(Int(health.exerciseTimeToday))" : "—",
                                 caption: NSLocalizedString("health.ring.exercise", comment: ""),
                                 progress: health.exerciseTimeToday / 30, color: AIATheme.health,
                                 size: 74, lineWidth: 7)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        NavigationLink { WeightTrendView() } label: {
                            StatCard(value: stat("体重"), caption: NSLocalizedString("health.stat.weight", comment: ""))
                        }
                        .buttonStyle(.plain)
                        StatCard(value: stat("身高"), caption: NSLocalizedString("health.stat.height", comment: ""))
                        StatCard(value: stat("心率"), caption: NSLocalizedString("health.stat.restingHR", comment: ""))
                        StatCard(value: stat("BMI"), caption: NSLocalizedString("health.stat.bmi", comment: ""))
                    }

                    SectionTitle(text: NSLocalizedString("health.weightTrend", comment: ""))
                    if weightTrend.isEmpty {
                        Text(NSLocalizedString("health.noWeight", comment: "")).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                    } else {
                        Chart(weightTrend) { p in
                            LineMark(x: .value(NSLocalizedString("chart.day", comment: ""), p.label), y: .value(NSLocalizedString("chart.kg", comment: ""), p.value))
                                .foregroundStyle(AIATheme.health).interpolationMethod(.monotone)
                            PointMark(x: .value(NSLocalizedString("chart.day", comment: ""), p.label), y: .value(NSLocalizedString("chart.kg", comment: ""), p.value))
                                .foregroundStyle(AIATheme.health)
                        }
                        .frame(height: 80)
                        .chartYAxis(.hidden).chartXAxis(.hidden)
                    }

                    SectionTitle(text: NSLocalizedString("health.sleepStages", comment: ""))
                    CardRow(icon: "🌙", iconBG: AIATheme.surfaceSecondary, title: String(format: NSLocalizedString("health.sleep.deep", comment: ""), 1.8), subtitle: String(format: NSLocalizedString("health.sleep.deepSub", comment: ""), 25), value: "25%")
                    CardRow(icon: "💤", iconBG: AIATheme.surfaceSecondary, title: String(format: NSLocalizedString("health.sleep.light", comment: ""), 4.2), subtitle: NSLocalizedString("common.none", comment: ""), value: "58%")
                    CardRow(icon: "⚡", iconBG: AIATheme.surfaceSecondary, title: String(format: NSLocalizedString("health.sleep.rem", comment: ""), 1.2), subtitle: NSLocalizedString("health.sleep.remSub", comment: ""), value: "17%")

                    if !healths.isEmpty {
                        SectionTitle(text: NSLocalizedString("health.weekSteps", comment: ""))
                        Chart(weekSteps) { p in
                            BarMark(x: .value(NSLocalizedString("chart.day", comment: ""), p.label), y: .value(NSLocalizedString("chart.step", comment: ""), p.value))
                                .foregroundStyle(AIATheme.health.opacity(0.7))
                        }
                        .frame(height: 70)
                        .chartYAxis(.hidden).chartXAxis(.hidden)
                    }

                    SectionTitle(text: "健康记录")
                    if healths.isEmpty {
                        EmptyStateView(
                            kind: .health,
                            title: "还没有健康记录",
                            message: "连接 iPhone 健康，或手动记录体重、睡眠、心率，阿宝帮你画出趋势。"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ForEach(healths) { h in
                            SelectableCard(
                                content: HStack(spacing: 12) {
                                    Image(systemName: "heart.circle").foregroundStyle(AIATheme.health)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h.metric).font(AIATheme.Font.footnote.weight(.medium))
                                        Text(AppFormat.dateTime.string(from: h.date)).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                                    }
                                    Spacer()
                                    Text("\(h.value)\(h.unit)").font(AIATheme.Font.footnote.weight(.medium))
                                }
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .background(AIATheme.surface).clipShape(RoundedRectangle(cornerRadius: 14)),
                                destination: HealthDetailView(metric: h)
                            )
                        }
                    }
                }
                .padding()
            }
            AIBottomBar()
        }
        .navigationTitle(LocalizedStringKey("health.navTitle"))
    }

    private func deleteHealth(_ h: HealthMetric) {
        LocalImageStore.delete(h.imageName)
        withAnimation {
            context.delete(h)
        }
    }
}

// MARK: - 账单管理（⑤）
private enum BillFilter: String, CaseIterable {
    case all, month, calendar
    var label: String {
        switch self {
        case .all:      return NSLocalizedString("bill.filter.all", comment: "")
        case .month:    return NSLocalizedString("bill.filter.month", comment: "")
        case .calendar: return NSLocalizedString("bill.filter.calendar", comment: "")
        }
    }
}

struct BillListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \Bill.time, order: .reverse) private var bills: [Bill]
    @AppStorage("aia.monthlyBudget") private var monthlyBudget: Double = 5000
    @State private var showBudgetEditor: Bool = false
    @State private var editedBudget: Double = 0
    @State private var filter: BillFilter = .all
    @State private var billCalendarMonth = Date()
    @State private var billSelectedDate: Date? = Date()
    @State private var showCamera = false
    @State private var showPicker = false

    private var todayBills: [Bill] {
        bills.filter { Calendar.current.isDateInToday($0.time) }
    }
    private var todayExpenseBills: [Bill] { todayBills.filter { !$0.isIncome } }
    private var todayExpenseTotal: Double { todayExpenseBills.reduce(0) { $0 + $1.amount } }
    private var todayExpenseByCategory: [(cat: String, sum: Double)] { expenseByCategory(for: todayExpenseBills) }
    private var monthBills: [Bill] {
        bills.filter { Calendar.current.isDate($0.time, equalTo: Date(), toGranularity: .month) }
    }
    private var monthExpenseBills: [Bill] { monthBills.filter { !$0.isIncome } }
    private var monthExpenseTotal: Double { monthExpenseBills.reduce(0) { $0 + $1.amount } }
    private var monthExpenseByCategory: [(cat: String, sum: Double)] { expenseByCategory(for: monthExpenseBills) }

    private var mondayCalendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2 // 周一为每周起始
        c.minimumDaysInFirstWeek = 4
        return c
    }

    private func expenseByCategory(for bills: [Bill]) -> [(cat: String, sum: Double)] {
        var dict: [String: Double] = [:]
        for b in bills { dict[b.category.isEmpty ? NSLocalizedString("common.other", comment: "") : b.category, default: 0] += b.amount }
        return dict.sorted { $0.value > $1.value }.map { (cat: $0.key, sum: $0.value) }
    }

    private var weekBills: [Bill] {
        let comp = mondayCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        guard let start = mondayCalendar.date(from: comp) else { return [] }
        guard let end = mondayCalendar.date(byAdding: .day, value: 7, to: start) else { return [] }
        return bills.filter { $0.time >= start && $0.time < end }
    }
    private var weekExpenseBills: [Bill] { weekBills.filter { !$0.isIncome } }
    private var weekExpenseTotal: Double { weekExpenseBills.reduce(0) { $0 + $1.amount } }
    private var weekExpenseByCategory: [(cat: String, sum: Double)] { expenseByCategory(for: weekExpenseBills) }

    private var yearBills: [Bill] {
        let comp = Calendar.current.dateComponents([.year], from: Date())
        guard let start = Calendar.current.date(from: comp) else { return [] }
        guard let end = Calendar.current.date(byAdding: .year, value: 1, to: start) else { return [] }
        return bills.filter { $0.time >= start && $0.time < end }
    }
    private var yearExpenseBills: [Bill] { yearBills.filter { !$0.isIncome } }
    private var yearExpenseTotal: Double { yearExpenseBills.reduce(0) { $0 + $1.amount } }
    private var yearExpenseByCategory: [(cat: String, sum: Double)] { expenseByCategory(for: yearExpenseBills) }

    private var monthlyGroups: [(year: Int, month: Int, income: Double, expense: Double, balance: Double, bills: [Bill])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: bills) { cal.dateComponents([.year, .month], from: $0.time) }
        return grouped.map { (key, bills) in
            let income = bills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
            let expense = bills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
            return (year: key.year ?? 0, month: key.month ?? 0, income: income, expense: expense, balance: income - expense, bills: bills.sorted { $0.time > $1.time })
        }.sorted {
            if $0.year != $1.year { return $0.year > $1.year }
            return $0.month > $1.month
        }
    }

    private var filtered: [Bill] {
        switch filter {
        case .all, .month, .calendar: return monthBills
        }
    }
    private var groupedByDate: [(date: Date, bills: [Bill])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.time) }
        return grouped.sorted { $0.key > $1.key }
            .map { (date: $0.key, bills: $0.value.sorted { $0.time > $1.time }) }
    }
    private func weekdayText(_ date: Date) -> String {
        switch Calendar.current.component(.weekday, from: date) {
        case 1: return NSLocalizedString("todo.calendar.weekday.sun", comment: "")
        case 2: return NSLocalizedString("todo.calendar.weekday.mon", comment: "")
        case 3: return NSLocalizedString("todo.calendar.weekday.tue", comment: "")
        case 4: return NSLocalizedString("todo.calendar.weekday.wed", comment: "")
        case 5: return NSLocalizedString("todo.calendar.weekday.thu", comment: "")
        case 6: return NSLocalizedString("todo.calendar.weekday.fri", comment: "")
        case 7: return NSLocalizedString("todo.calendar.weekday.sat", comment: "")
        default: return ""
        }
    }

    // MARK: - 顶部圆环轮播
    private var summaryCarousel: some View {
        VStack(spacing: 6) {
            TabView {
                // 第 1 页：今日账单 + 本月账单
                HStack(spacing: 0) {
                    summaryDonutCard(titleKey: "bill.today", bills: todayExpenseBills, mode: .week)
                    Divider().frame(height: 120)
                    summaryDonutCard(titleKey: "bill.thisMonth", bills: monthExpenseBills, mode: .month)
                }
                .padding(12)
                .background(AIATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))

                // 第 2 页：本周账单 + 本年账单
                HStack(spacing: 0) {
                    summaryDonutCard(titleKey: "bill.thisWeek", bills: weekExpenseBills, mode: .week)
                    Divider().frame(height: 120)
                    summaryDonutCard(titleKey: "bill.thisYear", bills: yearExpenseBills, mode: .year)
                }
                .padding(12)
                .background(AIATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 160)

            Text(NSLocalizedString("bill.carousel.hint", comment: ""))
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
    }

    private func summaryDonutCard(titleKey: String, bills: [Bill], mode: BillDashboardMode) -> some View {
        let categories = expenseByCategory(for: bills)
        let total = bills.reduce(0) { $0 + $1.amount }
        return NavigationLink { BillDashboardView(mode: mode) } label: {
            VStack(spacing: 6) {
                Text(LocalizedStringKey(titleKey))
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                if categories.isEmpty {
                    DonutView(segments: [], size: 88, lineWidth: 11)
                        .overlay(
                            Text("¥0")
                                .font(AIATheme.Font.subhead.weight(.medium))
                                .foregroundStyle(AIATheme.sub)
                        )
                } else {
                    DonutView(segments: categories.map { (color: BillCategoryHelpers.color(for: $0.cat), fraction: $0.sum) }, size: 88, lineWidth: 11)
                        .overlay(
                            Text("¥\(Int(total))")
                                .font(AIATheme.Font.subhead.weight(.medium))
                        )
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<min(categories.count, 3), id: \.self) { i in
                        let item = categories[i]
                        HStack(spacing: 4) {
                            Circle().fill(BillCategoryHelpers.color(for: item.cat)).frame(width: 6, height: 6)
                            Text(item.cat).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                            Spacer()
                            Text("¥\(Int(item.sum))").font(AIATheme.Font.micro.weight(.medium))
                        }
                    }
                    if categories.isEmpty {
                        Text(LocalizedStringKey("bill.noRecords"))
                            .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                    }
                }
                .frame(width: 90)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            SegmentedPicker(options: BillFilter.allCases.map { (value: $0, label: $0.label) }, selection: $filter)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if filter == .all {
                        // 聚合入口：周期记账 / 账单导入 / 自动记账
                        NavigationLink {
                            BillToolsView()
                                .environment(\.modelContext, context)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "wand.and.stars")
                                    .font(AIATheme.Font.title3)
                                    .foregroundStyle(AIATheme.bill)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("周期记账 / 账单导入 / 自动记账")
                                        .font(AIATheme.Font.subhead.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("管理周期账单、批量导入历史账单")
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(AIATheme.Font.footnote.weight(.medium))
                                    .foregroundStyle(AIATheme.muted)
                            }
                            .padding(12)
                            .card()
                        }
                        .buttonStyle(.plain)

                        SectionTitle(text: NSLocalizedString("bill.budget", comment: ""))
                        Button {
                            editedBudget = monthlyBudget
                            showBudgetEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(String(format: NSLocalizedString("bill.monthlyBudget", comment: ""), Int(monthlyBudget)))
                                        .font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
                                    Image(systemName: "pencil")
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.muted)
                                    Spacer()
                                    Text(String(format: NSLocalizedString("bill.budgetUsed", comment: ""), Int(monthExpenseTotal / monthlyBudget * 100)))
                                        .font(AIATheme.Font.caption.weight(.medium))
                                }
                                MiniBar(value: monthExpenseTotal / monthlyBudget, color: AIATheme.bill)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        summaryCarousel
                    }

                    if filter == .calendar {
                        billCalendarView
                    } else if filter == .month {
                        VStack(alignment: .leading, spacing: 8) {
                            // 月报 / 数据导出入口：按月导出 CSV、生成月报图片分享
                            NavigationLink {
                                MonthlyReportView()
                                    .environment(\.modelContext, context)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "chart.bar.fill")
                                        .font(AIATheme.Font.title3)
                                        .foregroundStyle(AIATheme.purple)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("月报 / 数据导出")
                                            .font(AIATheme.Font.subhead.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text("按月导出 CSV、生成月报图片分享")
                                            .font(AIATheme.Font.micro)
                                            .foregroundStyle(AIATheme.muted)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(AIATheme.Font.footnote.weight(.medium))
                                        .foregroundStyle(AIATheme.muted)
                                }
                                .padding(12)
                                .card()
                            }
                            .buttonStyle(.plain)

                            // 同理：monthlyGroups 派生自 @Query，用元素遍历避免下标越界。
                            // 用 enumerated() 取 offset 作 id，避免 tuple 需 Hashable 且保证单次 render 内稳定。
                            ForEach(Array(monthlyGroups.enumerated()), id: \.offset) { _, group in
                                NavigationLink {
                                    MonthlyBillListView(year: group.year, month: group.month, bills: group.bills)
                                        .environment(\.modelContext, context)
                                } label: {
                                    monthlySummaryRow(group)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        if monthlyGroups.isEmpty {
                            // 按月查看空态：引导用户配置快捷指令自动记账
                            EmptyStateView(
                                kind: .bill,
                                title: "自动记账",
                                message: "设置快捷指令，自动记账",
                                actionTitle: "查看教程",
                                action: { NavigationRouter.shared.path.append(.autoSetup) }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if filtered.isEmpty {
                        EmptyStateView(
                            kind: .bill,
                            title: "",
                            message: "",
                            actionTitle: "查看自动记账教程",
                            action: { NavigationRouter.shared.path.append(.autoSetup) },
                            footer: "点击底部拍照、相册上传小票、账单\n或点击文字输入、语音输入\n也可使用AI快速记账哦"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SectionTitle(text: NSLocalizedString("bill.details", comment: ""))
                        // 直接遍历元素（不再用 ForEach(0..<count) + groupedByDate[i] 下标）：
                        // groupedByDate 派生自 @Query，导航 onAppear 的 RecurringBillManager.generateDue
                        // 插入账单/提醒时数组长度会变化，两次求值不一致会导致 groupedByDate[i] 越界闪退。
                        // 用 enumerated() 取 offset 作 id，避免 tuple 需 Hashable 且保证单次 render 内稳定。
                        ForEach(Array(groupedByDate.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 8) {
                                dateHeader(group.date, bills: group.bills)
                                ForEach(group.bills) { b in
                                    SelectableCard(
                                        content: groupedBillRow(b),
                                        destination: BillDetailView(bill: b)
                                    )
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            AIBottomBar(prompts: [
                AIPrompt(text: "点拍照识别、记录账单、小票", pointsTo: .camera),
                AIPrompt(text: "今天花了多少钱？点此阿宝帮你记", pointsTo: nil),
                AIPrompt(text: "点麦克风，语音记录账单", pointsTo: .mic),
                AIPrompt(text: "阿宝帮总结这个月的消费情况", pointsTo: nil),
                AIPrompt(text: "点相册上传，自动记账", pointsTo: .album)
            ])
        }
        .navigationTitle(LocalizedStringKey("tab.bill"))
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker)
        .sheet(isPresented: $showBudgetEditor) {
            VStack(spacing: 0) {
                HStack {
                    Text("修改本月预算")
                        .font(AIATheme.Font.headline.weight(.semibold))
                    Spacer()
                    Button("完成") { showBudgetEditor = false }
                        .font(AIATheme.Font.body.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                }
                .padding()

                VStack(alignment: .leading, spacing: 8) {
                    Text("当前预算")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.sub)
                    HStack {
                        Text("¥\(Int(monthlyBudget))")
                            .font(AIATheme.Font.hero.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
                .padding()
                .background(AIATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("手动设置")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.sub)
                    HStack {
                        Text("¥")
                            .font(AIATheme.Font.headline)
                            .foregroundStyle(AIATheme.muted)
                        TextField("预算金额", value: $editedBudget, format: .number)
                            .keyboardType(.numberPad)
                            .font(AIATheme.Font.headline)
                        Spacer()
                    }
                    .padding()
                    .background(AIATheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .padding()

                Spacer()

                Button {
                    monthlyBudget = editedBudget
                    showBudgetEditor = false
                } label: {
                    Text("保存")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AIATheme.blue)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .buttonStyle(.plain)
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .presentationDetents([.height(340)])
        }
    }

    private func dateHeader(_ date: Date, bills: [Bill]) -> some View {
        let expense = bills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
        let income = bills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
        let isToday = Calendar.current.isDateInToday(date)
        let dateText = isToday ? "今天 \(AppFormat.date.string(from: date))（\(weekdayText(date))）" : "\(AppFormat.date.string(from: date))（\(weekdayText(date))）"
        return HStack(spacing: 0) {
            Text(dateText)
                .font(AIATheme.Font.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("支 \(String(format: "%.2f", expense)) | 收 \(String(format: "%.2f", income))")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
    }

    private func monthlySummaryRow(_ g: (year: Int, month: Int, income: Double, expense: Double, balance: Double, bills: [Bill])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(String(g.year))年\(g.month)月")
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(g.bills.count) 笔")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(NSLocalizedString("bill.monthly.income", comment: ""))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                    Text("+\(String(format: "%.2f", g.income))")
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(AIATheme.amber)
                }
                .frame(maxWidth: .infinity)
                Divider()
                VStack(spacing: 4) {
                    Text(NSLocalizedString("bill.monthly.expense", comment: ""))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                    Text("-\(String(format: "%.2f", g.expense))")
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(AIATheme.expense)
                }
                .frame(maxWidth: .infinity)
                Divider()
                VStack(spacing: 4) {
                    Text(NSLocalizedString("bill.monthly.balance", comment: ""))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                    Text((g.balance >= 0 ? "+" : "") + String(format: "%.2f", g.balance))
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(g.balance >= 0 ? AIATheme.income : AIATheme.expense)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private func groupedBillRow(_ b: Bill) -> some View {
        HStack(spacing: 12) {
            Text(BillCategoryHelpers.icon(for: b.category))
                .font(AIATheme.Font.largeTitle)
                .frame(width: 42, height: 42)
                .background(AIATheme.bill.opacity(0.12))
                .foregroundStyle(AIATheme.bill)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(b.category.isEmpty ? NSLocalizedString("common.other", comment: "") : b.category)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(AppFormat.time.string(from: b.time)) | \(b.merchant)")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(b.isIncome ? "+\(String(format: "%.2f", b.amount))" : "-\(String(format: "%.2f", b.amount))")
                .font(AIATheme.Font.callout.weight(.semibold))
                .foregroundStyle(b.isIncome ? AIATheme.income : AIATheme.expense)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func deleteBill(_ b: Bill) {
        LocalImageStore.delete(b.imageName)
        withAnimation {
            context.delete(b)
        }
    }

    // MARK: - 账单日历视图（在日历查看）
    private var billCalendarView: some View {
        VStack(spacing: 12) {
            // 月份切换
            HStack {
                Button { billCalendarMonth = billPrevMonth } label: {
                    Image(systemName: "chevron.left")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(AIATheme.ink)
                        .frame(width: 32, height: 32)
                        .background(AIATheme.surfaceSecondary).clipShape(Circle())
                }
                Spacer()
                Text(billMonthTitle)
                    .font(AIATheme.Font.callout.weight(.medium))
                Spacer()
                Button { billCalendarMonth = billNextMonth } label: {
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(AIATheme.ink)
                        .frame(width: 32, height: 32)
                        .background(AIATheme.surfaceSecondary).clipShape(Circle())
                }
            }

            // 星期头
            HStack {
                let weekdays: [String] = [
                    NSLocalizedString("todo.calendar.weekday.sun", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.mon", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.tue", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.wed", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.thu", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.fri", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.sat", comment: "")
                ]
                ForEach(weekdays, id: \.self) { d in
                    Text(d).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub).frame(maxWidth: .infinity)
                }
            }

            // 日期网格
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                ForEach(billDaysInMonthView, id: \.self) { date in
                    if let date = date {
                        billDayCell(date)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }

            // 选中日期账单
            if let selected = billSelectedDate {
                let dayHeader = {
                    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
                    return f.string(from: selected)
                }()
                SectionTitle(text: String(format: NSLocalizedString("bill.calendar.selectedDateTitle", comment: ""), dayHeader))
                let dayBills = bills(on: selected)
                if dayBills.isEmpty {
                    Text(LocalizedStringKey("bill.calendar.noBills")).font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                } else {
                    let expense = dayBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
                    let income = dayBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: NSLocalizedString("bill.calendar.expenseTotal", comment: ""), expense))
                                .font(AIATheme.Font.caption.weight(.medium))
                                .foregroundStyle(AIATheme.expense)
                            Text(String(format: NSLocalizedString("bill.calendar.incomeTotal", comment: ""), income))
                                .font(AIATheme.Font.caption.weight(.medium))
                                .foregroundStyle(AIATheme.income)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 4)

                    ForEach(dayBills) { b in
                        SelectableCard(
                            content: groupedBillRow(b),
                            destination: BillDetailView(bill: b)
                        )
                    }
                }
            }
        }
    }

    private var billMonthTitle: String {
        let f = DateFormatter(); f.dateFormat = "yyyy MMMM"
        return f.string(from: billCalendarMonth)
    }

    private var billDaysInMonthView: [Date?] {
        let cal = Calendar.current
        guard let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: billCalendarMonth)) else { return [] }
        let weekday = cal.component(.weekday, from: firstDay)
        let daysInMonth = cal.range(of: .day, in: .month, for: billCalendarMonth)?.count ?? 0
        var days: [Date?] = Array(repeating: nil, count: weekday - 1)
        for d in 0..<daysInMonth {
            if let date = cal.date(byAdding: .day, value: d, to: firstDay) {
                days.append(cal.startOfDay(for: date))
            }
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var billPrevMonth: Date { Calendar.current.date(byAdding: .month, value: -1, to: billCalendarMonth) ?? billCalendarMonth }
    private var billNextMonth: Date { Calendar.current.date(byAdding: .month, value: 1, to: billCalendarMonth) ?? billCalendarMonth }

    private func bills(on date: Date) -> [Bill] {
        bills.filter { Calendar.current.isDate($0.time, inSameDayAs: date) }
            .sorted { $0.time > $1.time }
    }

    private func hasBills(on date: Date) -> Bool { !bills(on: date).isEmpty }

    private func billDayCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let isSelected = billSelectedDate.map { cal.isDate($0, inSameDayAs: date) } ?? false
        let isToday = cal.isDateInToday(date)
        let has = hasBills(on: date)
        return Button {
            billSelectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: date))")
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : (isToday ? AIATheme.blue : .primary))
                    .frame(width: 32, height: 32)
                    .background(isSelected ? AIATheme.blue : Color.clear)
                    .clipShape(Circle())
                Circle()
                    .fill(has ? AIATheme.bill : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(height: 42)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 待办提醒（⑥）
private enum TodoFilter: String, CaseIterable {
    case active, finished, calendar
    var label: LocalizedStringKey {
        switch self {
        case .active: return LocalizedStringKey("todo.filter.active")
        case .finished: return LocalizedStringKey("todo.filter.finished")
        case .calendar: return LocalizedStringKey("todo.filter.calendar")
        }
    }
    var rawLabel: String {
        switch self {
        case .active: return NSLocalizedString("todo.filter.active", comment: "")
        case .finished: return NSLocalizedString("todo.filter.finished", comment: "")
        case .calendar: return NSLocalizedString("todo.filter.calendar", comment: "")
        }
    }
    func titleWithCount(_ count: Int) -> String {
        switch self {
        case .active: return String(format: NSLocalizedString("todo.filter.active", comment: ""), count)
        case .finished: return String(format: NSLocalizedString("todo.filter.finished", comment: ""), count)
        case .calendar: return NSLocalizedString("todo.filter.calendar", comment: "")
        }
    }
}

struct ReminderListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Reminder> { !$0.syncDeleted }) private var reminders: [Reminder]
    @State private var filter: TodoFilter = .active
    @State private var calendarMonth = Date()
    @State private var selectedDate: Date? = Date()
    private var active: [Reminder] {
        reminders.filter { !$0.done && $0.due != nil }
            .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
    }
    private var finished: [Reminder] { reminders.filter { $0.done } }
    private var list: [Reminder] {
        switch filter { case .active: return active; case .finished: return finished; case .calendar: return [] }
    }

    private func prio(_ p: String) -> (text: String, color: Color) {
        switch p {
        case "high": return (NSLocalizedString("todo.priority.high", comment: ""), AIATheme.warn)
        case "low":  return (NSLocalizedString("todo.priority.low", comment: ""), AIATheme.sub)
        default:     return (NSLocalizedString("todo.priority.medium", comment: ""), AIATheme.amber)
        }
    }
    private var groupedByDate: [(date: Date?, reminders: [Reminder])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: list) { r -> Date? in
            r.due.map { cal.startOfDay(for: $0) }
        }
        return grouped.sorted { a, b in
            switch (a.key, b.key) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (d1?, d2?): return d1 < d2
            }
        }.map { (date: $0.key, reminders: $0.value.sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }) }
    }
    private func weekdayText(_ date: Date) -> String {
        switch Calendar.current.component(.weekday, from: date) {
        case 1: return NSLocalizedString("todo.calendar.weekday.sun", comment: "")
        case 2: return NSLocalizedString("todo.calendar.weekday.mon", comment: "")
        case 3: return NSLocalizedString("todo.calendar.weekday.tue", comment: "")
        case 4: return NSLocalizedString("todo.calendar.weekday.wed", comment: "")
        case 5: return NSLocalizedString("todo.calendar.weekday.thu", comment: "")
        case 6: return NSLocalizedString("todo.calendar.weekday.fri", comment: "")
        case 7: return NSLocalizedString("todo.calendar.weekday.sat", comment: "")
        default: return ""
        }
    }
    private func dateHeader(_ date: Date?, reminders: [Reminder]) -> some View {
        let dateText: String
        if let d = date {
            let isToday = Calendar.current.isDateInToday(d)
            dateText = isToday ? "今天 \(AppFormat.date.string(from: d))（\(weekdayText(d))）" : "\(AppFormat.date.string(from: d))（\(weekdayText(d))）"
        } else {
            dateText = "未安排"
        }
        return HStack(spacing: 0) {
            Text(dateText)
                .font(AIATheme.Font.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("\(reminders.count)项")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SegmentedPicker(options: [
                (value: TodoFilter.active, label: TodoFilter.active.titleWithCount(active.count)),
                (value: TodoFilter.finished, label: TodoFilter.finished.titleWithCount(finished.count)),
                (value: TodoFilter.calendar, label: TodoFilter.calendar.titleWithCount(0))
            ], selection: $filter)
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // 提醒设置 / 自动记待办 入口
                    Button {
                        NavigationRouter.shared.path.append(HomeRoute.todoTools)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "gearshape.2.fill")
                                .font(AIATheme.Font.title3)
                                .foregroundStyle(AIATheme.todo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("提醒设置 / 自动记待办")
                                    .font(AIATheme.Font.subhead.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("设置默认提醒时间、截屏自动识别待办")
                                    .font(AIATheme.Font.micro)
                                    .foregroundStyle(AIATheme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(AIATheme.Font.footnote.weight(.medium))
                                .foregroundStyle(AIATheme.muted)
                        }
                        .padding(12)
                        .card()
                    }
                    .buttonStyle(.plain)

                    if filter == .calendar {
                        calendarView
                    } else if list.isEmpty {
                        let emptyTitle: String = switch filter {
                        case .finished: "自动记待办"
                        case .active: "还没有待办"
                        case .calendar: ""
                        }
                        if filter == .finished {
                            // 已完成空态：引导用户配置快捷指令自动记录
                            EmptyStateView(
                                kind: .todo,
                                title: emptyTitle,
                                message: "设置快捷指令，自动记录待办",
                                actionTitle: "查看教程",
                                action: { NavigationRouter.shared.path.append(.autoSetup) }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            EmptyStateView(
                                kind: .todo,
                                title: emptyTitle,
                                message: "跟阿宝说一句话就能建待办，例如「周五提醒我交报表」。",
                                actionTitle: "叫阿宝提醒我",
                                action: { NavigationRouter.shared.navigateToChat(prefill: "2分钟后提醒我打开阿宝AI管家app") }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        // 直接遍历元素（不再用 ForEach(0..<count) + groupedByDate[i] 下标）：
                        // groupedByDate 派生自 @Query，导航 onAppear 的 RecurringBillManager.generateDue
                        // 插入账单/提醒时数组长度会变化，两次求值不一致会导致 groupedByDate[i] 越界闪退。
                        // 用 enumerated() 取 offset 作 id，避免 tuple 需 Hashable 且保证单次 render 内稳定。
                        ForEach(Array(groupedByDate.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 8) {
                                dateHeader(group.date, reminders: group.reminders)
                                ForEach(group.reminders) { r in
                                    SelectableCard(
                                        leadingAccessory: todoDoneButton(r),
                                        content: todoRowContent(r),
                                        destination: TodoDetailView(reminder: r)
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            // 禁用列表变化/空态切换的隐式动画，避免最后一条删除时动画叠加卡死。
            .animation(nil, value: list.count)
            .animation(nil, value: filter)
            AIBottomBar(prompts: [
                AIPrompt(text: "点拍照识别、记录待办", pointsTo: .camera),
                AIPrompt(text: "有什需要提醒的吗？点此阿宝帮你记", pointsTo: nil),
                AIPrompt(text: "点麦克风，语音记录待办", pointsTo: .mic),
                AIPrompt(text: "阿宝帮总结最近有什么事要做", pointsTo: nil),
                AIPrompt(text: "点相册上传，自动识别待办", pointsTo: .album)
            ])
        }
        .navigationTitle(LocalizedStringKey("tab.todo"))
    }

    // MARK: - 日历视图
    private var calendarView: some View {
        VStack(spacing: 12) {
            // 月份切换
            HStack {
                Button { calendarMonth = prevMonth } label: {
                    Image(systemName: "chevron.left")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(AIATheme.ink)
                        .frame(width: 32, height: 32)
                        .background(AIATheme.surfaceSecondary).clipShape(Circle())
                }
                Spacer()
                Text(monthTitle)
                    .font(AIATheme.Font.callout.weight(.medium))
                Spacer()
                Button { calendarMonth = nextMonth } label: {
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(AIATheme.ink)
                        .frame(width: 32, height: 32)
                        .background(AIATheme.surfaceSecondary).clipShape(Circle())
                }
            }

            // 星期头
            HStack {
                let weekdays: [String] = [
                    NSLocalizedString("todo.calendar.weekday.sun", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.mon", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.tue", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.wed", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.thu", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.fri", comment: ""),
                    NSLocalizedString("todo.calendar.weekday.sat", comment: "")
                ]
                ForEach(weekdays, id: \.self) { d in
                    Text(d).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub).frame(maxWidth: .infinity)
                }
            }

            // 日期网格
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                ForEach(daysInMonthView, id: \.self) { date in
                    if let date = date {
                        dayCell(date)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }

            // 选中日期待办
            if let selected = selectedDate {
                let dayHeader = {
                    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
                    return f.string(from: selected)
                }()
                SectionTitle(text: String(format: NSLocalizedString("todo.calendar.selectedDateTitle", comment: ""), dayHeader))
                let dayTodos = todos(on: selected)
                if dayTodos.isEmpty {
                    Text(LocalizedStringKey("todo.calendar.noTasks")).font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                } else {
                    ForEach(dayTodos) { r in
                        SelectableCard(
                            leadingAccessory: EmptyView(),
                            content: todoRowContent(r, hasDoneCircle: false),
                            destination: TodoDetailView(reminder: r)
                        )
                    }
                }
            }
        }
    }

    private var monthTitle: String {
        let f = DateFormatter(); f.dateFormat = "yyyy MMMM"
        return f.string(from: calendarMonth)
    }

    private var daysInMonthView: [Date?] {
        let cal = Calendar.current
        guard let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: calendarMonth)) else { return [] }
        let weekday = cal.component(.weekday, from: firstDay)
        let daysInMonth = cal.range(of: .day, in: .month, for: calendarMonth)?.count ?? 0
        var days: [Date?] = Array(repeating: nil, count: weekday - 1)
        for d in 0..<daysInMonth {
            if let date = cal.date(byAdding: .day, value: d, to: firstDay) {
                days.append(cal.startOfDay(for: date))
            }
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var prevMonth: Date { Calendar.current.date(byAdding: .month, value: -1, to: calendarMonth) ?? calendarMonth }
    private var nextMonth: Date { Calendar.current.date(byAdding: .month, value: 1, to: calendarMonth) ?? calendarMonth }

    private func todos(on date: Date) -> [Reminder] {
        reminders.filter { r in
            if let due = r.due, !r.done { return Calendar.current.isDate(due, inSameDayAs: date) }
            return false
        }
    }

    private func hasTodos(on date: Date) -> Bool { !todos(on: date).isEmpty }

    private func dayCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let isSelected = selectedDate.map { cal.isDate($0, inSameDayAs: date) } ?? false
        let isToday = cal.isDateInToday(date)
        let has = hasTodos(on: date)
        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: date))")
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : (isToday ? AIATheme.blue : .primary))
                    .frame(width: 32, height: 32)
                    .background(isSelected ? AIATheme.blue : Color.clear)
                    .clipShape(Circle())
                Circle()
                    .fill(has ? AIATheme.todo : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(height: 42)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 待办行
    private func todoDoneButton(_ r: Reminder) -> some View {
        // 用 Color.clear + overlay(Image) + .onTapGesture —— 显式 36×36 hit area，
        // 避免 Image 自身 hit area 不一致（之前圆圈"消失"是因为 Image 颜色 iconInactive
        // 和 NavigationLink label 的 surface 背景对比度太低，圆圈描边几乎不可见）。
        // 现在用更深的 AIATheme.muted + Color.clear 独立 hit area。
        Color.clear
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .overlay(
                Image(systemName: r.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(r.done ? AIATheme.ok : AIATheme.todo)
                    .font(AIATheme.Font.title2)
            )
            .onTapGesture {
                toggleDone(r)
            }
    }

    private func todoRowContent(_ r: Reminder, hasDoneCircle: Bool = true) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(AIATheme.Font.footnote.weight(.medium))
                    .strikethrough(r.done)
                    .foregroundStyle(r.done ? .gray : .primary)
                if let due = r.due {
                    Text(AppFormat.dateTime.string(from: due))
                        .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let p = prio(r.priority)
            Text(p.text).font(AIATheme.Font.micro).padding(.horizontal, 8).padding(.vertical, 2)
                .background(p.color.opacity(0.12)).foregroundStyle(p.color).clipShape(Capsule())
        }
        .padding(.vertical, 10)
        .padding(.leading, hasDoneCircle ? 44 : 12)
        .padding(.trailing, 12)
        .background(AIATheme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func toggleDone(_ r: Reminder) {
        let wasDone = r.done
        // 不包 withAnimation，也不主动切 filter：
        // 用户反馈点击圆圈后想停留在当前页签（如「待办」），不要自动跳到「已完成」。
        // 直接同步改 done，@Query 会在下一帧自然重 fetch 一次，当前行从列表消失即可。
        r.done.toggle()
        // 通知调度延后到下一帧，不阻塞当前点击事件。
        // 显式 context.save() 也去掉，由 SwiftData autosave 处理。
        DispatchQueue.main.async {
            if wasDone {
                // 之前已完成，现在切回未完成：重新排程提醒
                ReminderNotificationManager.schedule(r)
            } else {
                // 之前未完成，现在标记为已完成：取消提醒
                ReminderNotificationManager.cancel(r)
            }
        }
    }

    private func deleteReminder(_ r: Reminder) {
        ReminderNotificationManager.cancel(r)
        LocalImageStore.delete(r.imageName)
        withAnimation {
            context.delete(r)
        }
    }

}
