// RecordsViews.swift
// 四个模块的「记录列表」页，按《UI完整页面流.html》③饮食 ④健康 ⑤账单 ⑥待办 重做。
// 数据均来自本地 SwiftData；健康页步数/活动消耗来自 HealthManager（真机 HealthKit 生效）。
import SwiftUI
import SwiftData
import Combine
import Charts
import UIKit

// 图表用数据点
private struct ChartPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}

/// 柱状图顶部数值标注：非零才显示；千位数缩写为「k」（如 1.2k，整千显示 2k）。
private func abbreviatedCount(_ v: Double) -> String {
    let n = Int(v)
    guard n > 0 else { return "" }
    if n >= 1000 {
        let k = Double(n) / 1000
        return String(format: "%.1fk", k).replacingOccurrences(of: ".0", with: "")
    }
    return "\(n)"
}

/// 自定义「从 0 向上生长」柱状条，对齐首页 MiniBar 的 easeOut 生长观感（比 Swift Charts 在小图表里
/// 的生长更明显、更可控）。7 根柱子错峰依次长出（每根 easeOut 0.9s，整体约 1.4s 长完），无弹簧过冲。
/// `revealed` 由外部 barsRevealed 驱动（进入时延迟触发），柱高从 0 平滑生长到真实比例。
private struct GrowthBars: View {
    let data: [ChartPoint]
    var accent: Color = AIATheme.food
    var maxValue: Double
    var height: CGFloat = 70
    var revealed: Bool = false
    /// 柱顶数值是否缩写（步数用「k」；热量图传 false 展示完整整数）。
    var abbreviate: Bool = true

    private var topLabelH: CGFloat { 11 }
    private var usableH: CGFloat { height - topLabelH }

    private func topLabel(_ v: Double) -> String {
        abbreviate ? abbreviatedCount(v) : "\(Int(v))"
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(data.enumerated()), id: \.offset) { idx, p in
                    VStack(spacing: 2) {
                        Text(topLabel(p.value))
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.sub)
                            .frame(height: topLabelH)
                            .opacity(revealed ? 1 : 0)
                            .animation(.easeOut(duration: 0.4).delay(Double(idx) * 0.07 + 0.45), value: revealed)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(accent)
                            .frame(height: revealed ? barH(p.value) : 0)
                            .animation(.easeOut(duration: 0.9).delay(Double(idx) * 0.07), value: revealed)
                    }
                }
            }
            .frame(height: height)
            HStack(spacing: 6) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, p in
                    Text(p.label)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func barH(_ v: Double) -> CGFloat {
        let m = max(maxValue, 1)
        return max(CGFloat(v / m) * usableH, 2)
    }
}

private let dayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "M/d"; return f
}()

// MARK: - 饮食模块：顶部分段切换
private enum DietTab: String, CaseIterable {
    case records, preferences, analysis
    var label: String {
        switch self {
        case .records:     return "饮食记录"
        case .preferences: return "饮食喜好"
        case .analysis:    return "饮食分析"
        }
    }
}

/// 饮食分析页的统计周期（4 段固定，不区分大小写/星期起始随系统 locale）
private enum DietPeriod: String, CaseIterable {
    case thisWeek, lastWeek, thisMonth, lastMonth
    var label: String {
        switch self {
        case .thisWeek:   return "本周"
        case .lastWeek:   return "上周"
        case .thisMonth:  return "本月"
        case .lastMonth:  return "上月"
        }
    }
    /// 半开区间 [start, end)；end 不含。系统 locale 决定本周从周几开始。
    func range(now: Date = Date()) -> (Date, Date) {
        let cal = Calendar.current
        switch self {
        case .thisWeek:
            let s = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let e = cal.date(byAdding: .day, value: 7, to: s)!
            return (s, e)
        case .lastWeek:
            let thisS = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let lastS = cal.date(byAdding: .day, value: -7, to: thisS)!
            return (lastS, thisS)
        case .thisMonth:
            let s = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let e = cal.date(byAdding: .month, value: 1, to: s)!
            return (s, e)
        case .lastMonth:
            let thisS = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let lastS = cal.date(byAdding: .month, value: -1, to: thisS)!
            return (lastS, thisS)
        }
    }
}

/// 饮食喜好页：单条 Top N 排行
private struct DietFoodRank: Identifiable {
    let id = UUID()
    let rank: Int
    let name: String
    let count: Int
}

/// 饮食喜好页：记录来源拆分（AI 识别 vs 手动输入）
private struct DietSourceBreakdown {
    let aiCount: Int      // imageName 非空
    let manualCount: Int  // imageName 空
    var total: Int { aiCount + manualCount }
}

/// 饮食喜好页：单餐次计数
private struct DietMealCount: Identifiable {
    let id = UUID()
    let meal: String    // "早餐" / "午餐" / "晚餐" / "加餐"
    let icon: String    // SF Symbol
    let count: Int
}

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
    @Environment(\.colorScheme) private var colorScheme
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \FoodEntry.date, order: .reverse) private var foods: [FoodEntry]
    @Query(filter: #Predicate<WaterLog> { !$0.syncDeleted }) private var waterLogs: [WaterLog]
    /// 饮食记录来源标记（小程序 pull 进来的记录标记 origin="miniprogram"），用于列表展示「好好吃饭小程序」。
    @Query private var foodSources: [FoodSource]
    /// 识别引擎来源标记（RecogSource 1:1 关联 FoodEntry.syncId），用于列表展示「免费版AI识别/Pro版AI…」
    @Query private var recogSources: [RecogSource]
    private var recogSourceBySyncId: [UUID: String] {
        Dictionary(uniqueKeysWithValues: recogSources.map { ($0.syncId, $0.recogSourceRaw) })
    }
    @State private var barsRevealed = false   // 近7日热量柱状图：进入时从 0 向上生长动画
    @State private var chartWeekOffset: Int = 0   // 近7日热量图翻周：0=本周，负=过去第 |n| 周
    private var originBySyncId: [UUID: String] {
        Dictionary(uniqueKeysWithValues: foodSources.map { ($0.foodSyncId, $0.origin) })
    }
    @State private var meal: MealFilter = .lu
    @State private var selectedDate: Date = Date()
    @State private var showDatePicker: Bool = false
    @State private var showGoalEditor: Bool = false
    @State private var editedGoal: Double = 0
    @State private var showCalorieGoalAlert: Bool = false   // 热量目标为 0 → 弹窗引导去健康目标页
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var showAddFood = false
    @StateObject private var health = HealthManager.shared
    @AppStorage("aia.calorieGoalOverride") private var goalOverride: Double = 0
    @AppStorage("aia.calorieGoalIsCustom") private var goalIsCustom: Bool = false
    /// 饮食模块顶部分段：记录/喜好/分析
    @State private var dietTab: DietTab = .records
    /// 水卡按压反馈（缩放 0.94→1.0 spring 回弹）
    @State private var waterPressing: Bool = false

    /// 点行直接弹出「编辑食物」sheet（取代原来的 SelectableCard→FoodDetailView 中间层）。
    /// 用 PersistentIdentifier 做绑定（而非直接持有 FoodEntry?），避免 EditFoodView 内 @Query 首次加载触发
    /// modelContext 变更通知、父视图 @Query 刷新时 FoodEntry 被 fault-in 产生 identity 抖动，导致 sheet 关闭又重开。
    @State private var editFoodID: PersistentIdentifier? = nil

    // MARK: 多选删除
    @State private var multiSelectMode = false
    @State private var selectedIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm = false

    /// 点餐次 tab / 常吃食物 chip 后，触发自动下滚到食物列表（彩色圆点图标）位置。
    /// 用计数器 nonce 而非直接 scrollTo，是因为 chip 的入库动作发生在 saveFrequentFood 内部，
    /// 那里拿不到 ScrollViewReader 的 proxy；统一在 reader 内靠 onChange(nonce) 完成滚动。
    @State private var scrollToFoodNonce: Int = 0

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
    // TDEE 实际达成 = 静息能量 + 活动能量（来自 HealthKit）；
    // 无真实数据时回落到 TDEE 目标值（BMR × 活动系数），保证饮食页目标不为 0。
    @AppStorage("aia.heightCm") private var heightCmDiet: Double = 0
    @AppStorage("aia.weightKg") private var weightKgDiet: Double = 0
    @AppStorage("aia.age") private var ageDiet: Int = 30
    @AppStorage("aia.bioSex") private var bioSexDiet: Int = 1   // 1 = 男, 0 = 女
    @AppStorage("aia.activityLevel") private var activityLevelDiet: Int = 1
    @AppStorage("aia.fitnessGoal") private var fitnessGoalDiet: String = "maintain"
    private var fitnessGoal: FitnessGoal { FitnessGoal(rawValue: fitnessGoalDiet) ?? .maintain }
    private var tdeeGoalFallback: Double {
        (mifflinBMR(weightKg: weightKgDiet, heightCm: heightCmDiet, age: ageDiet, isMale: bioSexDiet == 1) ?? 0)
            * activityMultiplier(activityLevelDiet)
    }
    private var tdee: Double {
        // TDEE 列显示「目标值」= BMR × 活动系数，与 X/Y 进度的 Y（goal 默认值）同源。
        // 与「今日消耗」列区分：今日消耗是 resting+active 的实际达成（tdeeCurrentValue）。
        // 无身体数据时 tdeeGoalFallback=0，回落到 actual，避免显示 0 也保证与 今日消耗 区分失败时仍非空。
        let target = tdeeGoalFallback
        return target > 0 ? target : (ManualHealthStore.shared.healthKitValue("activeCalories", for: Date()) + ManualHealthStore.shared.healthKitValue("restingCalories", for: Date()))
    }
    /// 与首页健康卡片 / 今日预览 / 健康管理页 TDEE 圆环同源：
    /// 已接入 HealthKit 且读到数据 → 静息+活动能量；未接入 → 手动补录活动热量。
    /// 注意：本页「TDEE」列（tdee）显示的是目标值（actual 为 0 时回落到目标），
    /// 而「今日消耗」列应显示实际达成，故用 tdeeCurrentValue 与那三处对齐。
    @AppStorage(HealthMetricKind.tdee.sourceKey) private var tdeeSource: HealthSourceMode = .auto
    // >>> CHANGE-[2026-08-19 08:23:19]-对齐TDEE消耗口径 开始
    // 原因: 原自动模式读 ManualHealthStore 的 .hk 落库槽位, 与首页宫格(492)/管理页TDEE圆环口径不一致。
    //       改为读 HealthManager 的按日期 HealthKit 字典(activeEnergyForDay/restingEnergyForDay, 近30天),
    //       与首页/管理页同源; 命中即用, 超30天或字典为空时退回 .hk 落库值兜底(不破坏历史回看)。
    // 回退: 删除本段, 恢复原判(直接读 healthKitValue("activeCalories")+healthKitValue("restingCalories")) 即可。
    private var tdeeCurrentValue: Double {
        let day = Calendar.current.startOfDay(for: selectedDate)
        if tdeeSource == .auto && health.authorized && health.isAvailable && health.hasHealthKitData {
            // HealthKit 路径：按选中日期取当天活动+静息能量（同源首页/管理页）。
            let active = HealthManager.shared.activeEnergyForDay[day]
                ?? ManualHealthStore.shared.healthKitValue("activeCalories", for: day)
            let resting = HealthManager.shared.restingEnergyForDay[day]
                ?? ManualHealthStore.shared.healthKitValue("restingCalories", for: day)
            return active + resting
        }
        // 手动补录路径：按选中日期查（ManualHealthStore 内部按 startOfDay 存）。
        return Double(ManualHealthStore.shared.activeCalories(for: day))
    }
    // <<< CHANGE-[2026-08-19 08:23:19]-对齐TDEE消耗口径 结束
    private var goal: Double { goalIsCustom ? goalOverride : tdee }

    // MARK: 营养构成建议值（随健身目标/体重/TDEE 联动，与饮食分析「目标达成」卡同源）
    // 依据：热量基准 = 自定义热量目标或 TDEE × 健身目标系数；碳水 50%、脂肪 25% 取 USDA DGA 45-65%/20-35% 中值。

    /// 建议热量 = 自定义目标（尊重用户设定，不再乘系数）或 TDEE × 目标系数。
    private var suggestedCalories: Double? {
        guard goal > 0 else { return nil }
        return goalIsCustom ? goal : goal * fitnessGoal.calorieMultiplier
    }
    /// 建议蛋白 = 体重 × g/kg（减脂 2.0 / 增肌 1.8 / 维持 1.2）。
    private var suggestedProtein: Double? {
        weightKgDiet > 0 ? weightKgDiet * fitnessGoal.proteinPerKg : nil
    }
    /// 营养构成建议值（6 元组：蛋白/碳水/脂肪/纤维/糖/钠）。
    /// - 蛋白/碳水/脂肪：有体重+热量基准时按目标系数算（碳水 50%、脂肪 25% 取 USDA DGA 中值）；
    ///   缺前提时回落硬编码通用成人参考值 75/220/55。
    /// - 纤维/糖/钠：按「建议热量」线性缩放（与饮食分析「目标达成」卡同公式），无建议热量时回落 25/50/2000。
    private var nutritionTargets: (protein: Int, carb: Int, fat: Int, fiber: Int, sugar: Int, sodium: Int) {
        if let cal = suggestedCalories, let p = suggestedProtein {
            return (
                protein: Int(p.rounded()),
                carb: Int((cal * 0.5 / 4).rounded()),
                fat: Int((cal * 0.25 / 9).rounded()),
                fiber: Int((cal * 14 / 1000).rounded()),
                sugar: Int((cal * 0.10 / 4).rounded()),
                sodium: Int(cal.rounded())   // 钠(mg) = 建议热量(kcal)：2000kcal 标准人对应 2000mg 钠
            )
        }
        return (protein: 75, carb: 220, fat: 55, fiber: 25, sugar: 50, sodium: 2000)
    }

    /// 净热量 = 今日摄入 − 今日消耗（今日消耗取 tdeeCurrentValue，与「今日消耗」列同源）
    private var net: Double { selectedCalories - tdeeCurrentValue }

    private var macros: (p: Double, c: Double, f: Double, fiber: Double, sugar: Double, sodium: Double, water: Double) {
        selectedFoods.reduce((0, 0, 0, 0, 0, 0, 0)) {
            ($0.0 + $1.protein, $0.1 + $1.carbs, $0.2 + $1.fat,
             $0.3 + $1.fiber, $0.4 + $1.sugar, $0.5 + $1.sodium, $0.6 + $1.waterIntake)
        }
    }
    /// 选中日期的 WaterLog 总和（手动 tap 加的水）
    private var manualWaterToday: Double {
        waterLogs
            .filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
            .reduce(0) { $0 + $1.amount }
    }
    /// 今日饮水（ml）= 仅统计手动加水（WaterLog）。与小程序口径统一：食物自带水分（汤/水果）作为营养明细展示，不计入饮水总量。
    private var waterIntakeToday: Double {
        manualWaterToday
    }

    /// 点 +100ml：建一条 WaterLog + 触觉反馈；SwiftData @Query 自动刷新 UI。
    /// 所有日期都可加（WaterLog 用 selectedDate 落库，manualWaterToday 按 selectedDate 统计，
    /// 显示数字会即时反映；切回"今天"看时也已合并进总数，无需额外迁移）。
    private func addWaterTap() {
        let log = WaterLog(date: selectedDate, amount: 100)
        context.insert(log)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UsageAnalytics.logAdd("water", source: "manual")
        // 手动加水后触发增量同步，绑定后小程序可见
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
    }

    /// 「饮水」卡片：自动在「正面（饮水量 + ml）」与「背面（点击 +100ml）」间循环翻转；
    /// 所有日期都可点击 + 正常显示（历史日期也能补加 +100ml，落库到 selectedDate）。
    private var waterCard: some View {
        WaterFlipCard(
            totalML: waterIntakeToday,
            onTap: addWaterTap
        )
    }

    /// 「常吃食物」快速记录区：横向一排胶囊标签，左右滑动浏览，点 chip 一键入库当前餐次。
    private var frequentFoodRegion: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(AIATheme.Font.micro.weight(.semibold))
                    .foregroundStyle(AIATheme.food)
                Text("常吃食物 · 点一下快速记录 100g")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                Text("左右滑动浏览")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(.horizontal, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(frequentFoods.enumerated()), id: \.element) { idx, name in
                        frequentFoodChip(name, highlighted: idx == 0)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }

    private func frequentFoodChip(_ name: String, highlighted: Bool) -> some View {
        let isDark = colorScheme == .dark
        let bg = isDark ? AIATheme.dietBG : AIATheme.food.opacity(highlighted ? 0.16 : 0.08)
        let fg = isDark ? AIATheme.food : AIATheme.ink
        let stroke = isDark
            ? AIATheme.food.opacity(highlighted ? 0.7 : 0.35)
            : AIATheme.food.opacity(highlighted ? 0.45 : 0.22)
        let strokeW: CGFloat = (isDark && highlighted) ? 1 : 0.5
        return Button {
            saveFrequentFood(name)
        } label: {
            Text(name)
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(fg)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(bg)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(stroke, lineWidth: strokeW))
        }
        .buttonStyle(.plain)
    }

    /// 「今日饮水」翻转卡本体：3D 翻牌 + 自动循环；尊重系统「减少动态效果」偏好。
    private struct WaterFlipCard: View {
        let totalML: Double
        let onTap: () -> Void

        @State private var flipped = false
        @State private var timer: Timer?
        /// 点击后上浮的「+100ml」飘字（支持快速多次点击，每个独立飘出）
        @State private var floats: [FloatBadge] = []
        /// 每面停留时长（秒）——正面停留 → 0.9s 翻面 → 背面停留 → 0.9s 翻回
        private let flipInterval: TimeInterval = 2.2

        var body: some View {
            Button(action: {
                onTap()
                floats.append(FloatBadge())
            }) {
                ZStack {
                    // 正面：今日饮水 + ml
                    frontFace
                        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                        .opacity(flipped ? 0 : 1)
                    // 背面：点击 +100ml
                    backFace
                        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                        .opacity(flipped ? 1 : 0)
                }
                .frame(height: 44) // 两面统一高度，翻转不跳
            }
            .buttonStyle(WaterCardButtonStyle())
            .frame(width: 86)
            .padding(.vertical, 8)
            .background(AIATheme.health.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .overlay(
                RoundedRectangle(cornerRadius: AIATheme.rMD)
                    .stroke(AIATheme.health.opacity(0.25), lineWidth: 0.5)
            )
            // 飘字层：放在 clipShape 之后，不被圆角裁切，可向卡片上方溢出
            .overlay(
                ZStack {
                    ForEach(floats) { badge in
                        FloatBadgeView(badge: badge) {
                            floats.removeAll { $0.id == badge.id }
                        }
                    }
                }
            )
            // 所有日期都可点击 + 正常显示（历史日期也能补加 +100ml）
            .onAppear(perform: startTimer)
            .onDisappear(perform: stopTimer)
        }

        /// 正面：数字（健康色）+ 单位 + 「今日饮水」小字
        private var frontFace: some View {
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(totalML))")
                        .font(AIATheme.Font.title3.weight(.semibold))
                        .foregroundStyle(AIATheme.health)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: Int(totalML))
                    Text(NSLocalizedString("food.waterUnit", comment: ""))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                }
                Text(NSLocalizedString("food.water", comment: ""))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
            }
        }

        /// 背面：圆形「+」图标 + 「点击 +100ml」提示
        private var backFace: some View {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(AIATheme.health)
                        .frame(width: 26, height: 26)
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(NSLocalizedString("food.waterTapHint", comment: ""))
                    .font(AIATheme.Font.micro.weight(.semibold))
                    .foregroundStyle(AIATheme.health)
            }
            // 预旋转 180°，抵消外层翻牌时的镜像，文字始终正向
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }

        /// 启动自动翻转定时器（所有日期均翻；仅在「减少动态效果」时停翻以尊重无障碍偏好）。
        private func startTimer() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            stopTimer()
            timer = Timer.scheduledTimer(withTimeInterval: flipInterval, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.9)) { flipped.toggle() }
            }
        }

        /// 清理定时器，避免泄漏
        private func stopTimer() {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 点击「今日饮水」后上浮的「+100ml」标记
    private struct FloatBadge: Identifiable {
        let id = UUID()
    }

    /// 单个飘字：从卡片中心向上飘起并淡出，结束后回调 onDone 移除自身
    private struct FloatBadgeView: View {
        let badge: FloatBadge
        var onDone: () -> Void
        @State private var animate = false

        var body: some View {
            Text("+100ml")
                .font(AIATheme.Font.micro.weight(.semibold))
                .foregroundStyle(AIATheme.health)
                .offset(y: animate ? -42 : 0)
                .opacity(animate ? 0 : 1)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.85)) {
                        animate = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        onDone()
                    }
                }
        }
    }

    /// 近 7 日热量柱状数据。`offset` 为 0 表示以选中日为终点的本周，负数表示过去第 |offset| 周。
    private func weekData(offset: Int = 0) -> [ChartPoint] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: selectedDate)
        let end = cal.date(byAdding: .day, value: offset * 7, to: day)!
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: end)!
            let sum = foods.filter { cal.isDate($0.date, inSameDayAs: d) }.reduce(0) { $0 + $1.calories }
            return ChartPoint(label: dayFmt.string(from: d), value: sum)
        }
    }
    private var mealItems: [FoodEntry] {
        selectedFoods.filter { $0.meal == meal.mealString }.sorted { $0.syncUpdatedAt > $1.syncUpdatedAt }
    }
    private var mealTotal: Double {
        selectedFoods.filter { $0.meal == meal.mealString }.reduce(0) { $0 + $1.calories }
    }

    /// 常吃食物：按当前餐次过滤后统计。
    /// - 早餐：只统计「早餐」历史。
    /// - 午餐/晚餐：合并统计「午餐+晚餐」历史。
    /// - 加餐：统计全部历史。
    /// 排序：前 10 个按吃过次数倒序（常吃 Top10），第 11 个起按最近一次进食时间倒序；无历史则回退默认清单。
    private static let defaultFrequentFoods = ["米饭", "鸡蛋", "牛奶", "苹果", "鸡胸肉", "面包", "面条", "牛肉", "西兰花", "香蕉"]
    private var frequentFoods: [String] {
        let source = foods.filter { f in
            switch meal {
            case .bf: return f.meal == "早餐"
            case .lu, .dn: return f.meal == "午餐" || f.meal == "晚餐"
            case .sn: return true
            }
        }
        var counts: [String: Int] = [:]
        var latestDate: [String: Date] = [:]
        for f in source {
            counts[f.name, default: 0] += 1
            if let t = latestDate[f.name] {
                if f.date > t { latestDate[f.name] = f.date }
            } else {
                latestDate[f.name] = f.date
            }
        }
        let byCount = counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            // 次数相同：按名称首字母（中文拼音 / 英文）稳定排序，避免循环切换位置
            return $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }
        let top10 = byCount.prefix(10).map { $0.key }
        let rest = byCount.dropFirst(10).sorted {
            (latestDate[$0.key] ?? .distantPast) > (latestDate[$1.key] ?? .distantPast)
        }.map { $0.key }
        let combined = top10 + rest
        return combined.isEmpty ? Self.defaultFrequentFoods : combined
    }

    /// 点「常吃食物」名称：优先用营养库每100g营养 ×100g 入库当前餐次；
    /// 库未命中时兜底复用用户最近一次同名记录的营养值（带护栏），都无则热量归零（用户可改）。
    private func saveFrequentFood(_ name: String) {
        // A 层：营养库优先（内置表 + 云端沉淀）；B 层：库不认识时复用用户历史（仅优质记录）
        let ref: FoodRef? = NutritionLibrary.shared.match(name, in: context)
            ?? lastReusableFoodRef(named: name)
        let weight = 100.0
        let ratio = weight / 100.0
        let entry = FoodEntry(
            name: name,
            calories: (ref?.kcal ?? 0) * ratio,
            protein: (ref?.protein ?? 0) * ratio,
            carbs: (ref?.carbs ?? 0) * ratio,
            fat: (ref?.fat ?? 0) * ratio,
            fiber: (ref?.fiber ?? 0) * ratio,
            sugar: (ref?.sugar ?? 0) * ratio,
            sodium: (ref?.sodium ?? 0) * ratio,
            portion: "100g",
            meal: meal.mealString,
            date: selectedDate,
            weightGram: weight,
            baseCalories: ref?.kcal,
            baseProtein: ref?.protein,
            baseCarbs: ref?.carbs,
            baseFat: ref?.fat,
            baseFiber: ref?.fiber,
            baseSugar: ref?.sugar,
            baseSodium: ref?.sodium
        )
        context.insert(entry)   // SwiftData autosave 自动持久化，无需手动 save()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // 手动新增饮食记录后触发增量同步，尽快推上云端，绑定后小程序可见
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        // 入库成功后触发自动下滚，让新记录（彩色圆点图标）进入视野
        scrollToFoodNonce += 1
    }

    /// 兜底取数（方案 B）：营养库不认识该食物时，复用用户最近一次同名饮食记录的营养值（反推每 100g）。
    /// 护栏：① 跳过「营养全为 0」的劣质记录，避免复用「鱼腐 0」这类被记错的记录导致 0 值永久固化；
    ///      ② 跳过无有效 weightGram 的记录（重量未知则无法反推每 100g 基准）。
    /// 命中后返回每 100g 的 FoodRef（字段语义与营养库一致），供 saveFrequentFood 直接复用。
    private func lastReusableFoodRef(named name: String) -> FoodRef? {
        let sorted = foods
            .filter { $0.name == name }
            .sorted { $0.date > $1.date }
        for f in sorted {
            let total = f.calories + f.protein + f.carbs + f.fat
            guard total > 0 else { continue }                  // ① 全 0 劣质记录跳过
            guard let w = f.weightGram, w > 0 else { continue } // ② 无有效重量跳过
            let r = 100.0 / w
            return FoodRef(
                name: name,
                kcal: f.calories * r,
                protein: f.protein * r,
                carbs: f.carbs * r,
                fat: f.fat * r,
                fiber: f.fiber * r,
                sugar: f.sugar * r,
                sodium: f.sodium * r
            )
        }
        return nil
    }

    /// 餐次 SegmentedPicker 用的自定义 Binding：getter 返回 meal，setter 在 SegmentedPicker 写入新值时
    /// （只在用户点击按钮时发生，SegmentedPicker 首次渲染只读不写）同步设置 meal 并递增 scrollToFoodNonce，
    /// 触发 ScrollViewReader 下滚到食物条目。避免用 .onChange(of: meal) 引入的边界误触发
    /// （首次渲染 / 状态恢复时可能误判为"变化"）。
    private var mealBinding: Binding<MealFilter> {
        Binding(
            get: { self.meal },
            set: { newValue in
                self.meal = newValue
                self.scrollToFoodNonce += 1
            }
        )
    }

    /// 当前餐次的食物记录列表区（空态 / 列表）。
    /// 单独抽成计算属性，隔离类型检查复杂度——原 body 过大 + ScrollViewReader 包裹后
    /// 触发 "the compiler is unable to type-check this expression in reasonable time"；
    /// 抽出后 body 与该属性各自独立类型检查即通过。
    /// 滚动锚点不在本区，而在 Card4（早/午/晚/加餐 标题栏所在卡）——点 tab/chip 后
    /// 滚到 Card4 顶对齐屏幕顶，餐次标题栏保持可见，下方食物条目自然进入视野。
    @ViewBuilder
    private var mealItemsSection: some View {
        if mealItems.isEmpty {
            EmptyStateView(
                kind: .diet,
                title: "这餐还没记录",
                message: "到相册选一张照片，小记会自动识别菜名、热量和营养元素。",
                actionTitle: "到相册选一张",
                action: { showPicker = true },
                footer: "点击底部拍照、相册上传食物照片\n或点击文字输入、语音输入\n也可使用AI快速记录哦"
            )
        } else {
            ForEach(mealItems) { f in
                SelectableRow(
                    isSelecting: multiSelectMode,
                    isSelected: selectedIDs.contains(f.persistentModelID),
                    onTap: { editFoodID = f.persistentModelID },
                    onLongPress: { enterFoodMultiSelect(f.persistentModelID) },
                    onToggle: { toggleFoodSelection(f.persistentModelID) },
                    onDelete: {
                        // >>> CHANGE-[2026-08-17 11:26:00]-[临时对象失效崩溃] 开始
                        // 原因：f 来自 @Query ForEach 行，多选手动删除后底层数组变动可能释放引用。回退：改回 SafeDelete.food(f, in: context)
                        SafeDelete.foodByID(f.persistentModelID, in: context)
                        // <<< CHANGE-[2026-08-17 11:26:00]-[临时对象失效崩溃] 结束
                    }
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        // hero：左食物名 + 餐次·份量；右热量大数字
                        HStack(alignment: .center, spacing: 10) {
                            Circle()
                                .fill(AIATheme.food)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name)
                                    .font(AIATheme.Font.subhead.weight(.semibold))
                                    .foregroundStyle(.primary)
                                // 来源：优先取 FoodSource 标记的来源标签；无标记（本功能上线前的老记录）兜底：
                                // 有图 → 图片识别，无图 → 好记AI帮记
                                // 副标题只显示「份量 · 来源」——`portion` 已自带单位/数字（如"200克"、"2个"），
                                // 不再追加克数段（避免"200克 · 200g"、"2个 · 2g"这种重复+单位错配）。
                                // 与对话页 ResultRowCard.foodSubtitle（ResultRowCard.swift:706、843）保持一致。
                                let originLabel: String? = {
                                    if let o = originBySyncId[f.syncId], let label = FoodSource.displayLabel(for: o) {
                                        return label
                                    }
                                    return (f.imageName?.isEmpty == false)
                                        ? NSLocalizedString("food.recognized", comment: "")
                                        : NSLocalizedString("food.by_chat", comment: "")
                                }()
                                let recogLabel = recogSourceBySyncId[f.syncId]
                                    .flatMap { RecogSource.displayLabel(for: $0) }
                                Text([f.portion, originLabel, recogLabel]
                                    .compactMap { $0?.isEmpty == true ? nil : $0 }
                                    .joined(separator: " · "))
                                    .font(AIATheme.Font.micro)
                                    .foregroundStyle(AIATheme.muted)
                            }
                            Spacer()
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(Int(f.calories))")
                                    .font(AIATheme.Font.title3.weight(.bold))
                                    .foregroundStyle(AIATheme.food)
                                    .contentTransition(.numericText())
                                Text("kcal")
                                    .font(AIATheme.Font.micro)
                                    .foregroundStyle(AIATheme.sub)
                            }
                        }

                        Divider()
                            .background(AIATheme.hairline)

                        // 6 列营养明细：碳水 / 蛋白 / 脂肪 / 纤维 / 糖 / 钠
                        HStack(spacing: 4) {
                            macroCell("碳水", f.carbs, "g")
                            macroCell("蛋白", f.protein, "g")
                            macroCell("脂肪", f.fat, "g")
                            macroCell("纤维", f.fiber, "g")
                            macroCell("糖", f.sugar, "g")
                            macroCell("钠", f.sodium, "mg")
                        }
                    }
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .card(radius: AIATheme.rMD, shadow: false)
                }
            }
        }
    }

    private var dateTitleText: String {
        let cal = Calendar.current
        if cal.isDateInToday(selectedDate) {
            return String(format: "今天 · %@ %@", AppFormat.monthDay.string(from: selectedDate), weekday(for: selectedDate))
        } else if cal.isDateInYesterday(selectedDate) {
            return String(format: "昨天 · %@ %@", AppFormat.monthDay.string(from: selectedDate), weekday(for: selectedDate))
        } else if cal.isDateInTomorrow(selectedDate) {
            return String(format: "明天 · %@ %@", AppFormat.monthDay.string(from: selectedDate), weekday(for: selectedDate))
        }
        return String(format: "%@ %@", AppFormat.monthDay.string(from: selectedDate), weekday(for: selectedDate))
    }

    private func shiftDate(by days: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    }

    // MARK: - 食物信息卡（B 方案）辅助方法
    private func macroCell(_ title: String, _ value: Double, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(formatValue(value))
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            // 整组「数值+单位」锁单行：6 列等分下极端数据（如「100mg」）也得在同一行内自压缩展示
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rXS))
    }

    /// 数值格式化：整数显示整数，否则保留 1 位小数（0 显示 0）。
    private func formatValue(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(v))"
        }
        return String(format: "%.1f", v)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部分段：饮食记录 / 饮食喜好 / 饮食分析
            SegmentedPicker(
                options: DietTab.allCases.map { (value: $0, label: $0.label) },
                selection: $dietTab
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Group {
                switch dietTab {
                case .records:
                    ScrollViewReader { proxy in
                        ScrollView {
                        // 用 LazyVStack 而非 VStack：VStack eager 渲染全部子项，
                        // 当餐次 filter 切换或新 food 入库触发 content 重建时（EmptyStateView ↔ ForEach 互换），
                        // SwiftUI 会在 content 尺寸剧烈变化时 scroll position 复位到 top（用户反馈的"点 tab / chip 跳回顶部"）。
                        // LazyVStack 只渲染可见项，content 结构变化时 scroll position 保持稳定。
                        LazyVStack(alignment: .leading, spacing: 12) {
                        // Card1 · 热量概览（日期 + 进度 + 净热量/TDEE/消耗 + 饮水）
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
                                    Pill(text: goal > 0 ? "\(Int(selectedCalories)) / \(Int(goal))" : "点击设置目标")
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

                        MiniBar(value: goal > 0 ? selectedCalories / goal : 0, color: AIATheme.food, delay: 0.15, repeatOnValueChange: true)

                        // 3 列热量指标：净热量 / TDEE / 今日消耗（等宽 + 细竖线分隔）
                        HStack(spacing: 8) {
                            HStack(spacing: 0) {
                                // >>> CHANGE-[2026-08-19 14:06:49]-净热量格跳近30日能量页 开始
                                // 原因: 用户要求点饮食页净热量格跳到近30日能量页(.energy30DaysRecords)
                                // 回退: 删 Button 包裹、恢复裸 VStack + 原整数减标记即可
                                Button {
                                    NavigationRouter.shared.navigate(.energy30DaysRecords)
                                } label: {
                                // 净热量（英雄数字，食物色突出）
                                // 整数减口径(方案B): Int(摄入)-Int(消耗)
                                VStack(spacing: 2) {
                                    Text("\(Int(selectedCalories) - Int(tdeeCurrentValue))")
                                        .font(AIATheme.Font.title3.weight(.semibold))
                                        .foregroundStyle(AIATheme.food)
                                    Text(NSLocalizedString("food.netLabel", comment: ""))
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.sub)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Rectangle()
                                    .fill(AIATheme.hairline)
                                    .frame(width: 0.5, height: 32)

                                // >>> CHANGE-[2026-08-19 08:46:49]-饮食页TDEE列改今日摄入 开始
                                // 原因: 用户要求热量概览卡中间列由"TDEE目标"改为"今日摄入"(选中日期食物卡路里总和 selectedCalories)
                                // 回退: 删除本段、恢复原判(显示 tdee + food.tdeeLabel) 即可
                                // 今日摄入（选中日期食物卡路里总和，与净热量/今日消耗同口径跟随 selectedDate）
                                // 数字用 .primary 而非 ink：见右侧今日消耗列注释，ink 在深色卡片底上对比度过低。
                                VStack(spacing: 2) {
                                    Text("\(Int(selectedCalories))")
                                        .font(AIATheme.Font.title3.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(NSLocalizedString("food.intakeLabel", comment: ""))
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.sub)
                                }
                                .frame(maxWidth: .infinity)
                                // <<< CHANGE-[2026-08-19 08:46:49]-饮食页TDEE列改今日摄入 结束

                                Rectangle()
                                    .fill(AIATheme.hairline)
                                    .frame(width: 0.5, height: 32)

                                // >>> CHANGE-[2026-08-19 13:54:25]-饮食页今日消耗跳健康管理(修正) 开始
                                // 原因: 上一版误用 .bodyData(身体数据页), 用户实际要跳首页"健康"宫格进去的"健康管理页" HealthListView, 路由 .health
                                // 回退: 改回 .bodyData 即错版; 当前 .health 正确版
                                // 今日消耗（与首页健康卡片 / 今日预览 / TDEE 圆环同源：resting+active，无 HealthKit 时走手动活动热量）
                                // 数字用 .primary 而非 ink：见 TDEE 列注释，ink 在深色卡片底上对比度过低。
                                Button {
                                    // 跳"健康管理页" HealthListView（首页 4 宫格"健康"卡进去的全屏页），不是 .bodyData(身体数据页)
                                    NavigationRouter.shared.navigate(.health)
                                } label: {
                                    VStack(spacing: 2) {
                                        Text("\(Int(tdeeCurrentValue))")
                                            .font(AIATheme.Font.title3.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(String(format: "%@ kcal", NSLocalizedString("food.burned", comment: "")))
                                            .font(AIATheme.Font.micro)
                                            .foregroundStyle(AIATheme.sub)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                // <<< CHANGE-[2026-08-19 13:54:25]-饮食页今日消耗跳健康管理(修正) 结束
                            }

                            waterCard
                        }
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

                    // Card2 · 营养构成（建议值随健身目标/体重/TDEE 联动，缺失时回落通用参考值）
                    // 拆为独立子视图避开 Swift 编译器「unable to type-check」级联（参考 ChatView.buildContext 拆分经验）。
                    let t = nutritionTargets
                    NutritionCompositionCard(targets: t, macros: macros)
                        .padding(12)
                        .card(radius: AIATheme.rMD)

                    // Card3 · 近7日热量（可左右滑动翻看过去 8 周，每屏重播生长动画）
                    VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: NSLocalizedString("food.last7days", comment: ""),
                                         trailing: chartWeekRangeLabel(offset: chartWeekOffset, base: selectedDate))
                            TabView(selection: $chartWeekOffset) {
                                ForEach(Array((-8)...0), id: \.self) { off in
                                    let data = weekData(offset: off)
                                    Group {
                                        if data.allSatisfy({ $0.value == 0 }) {
                                            Text(NSLocalizedString("food.week.empty", comment: ""))
                                                .font(AIATheme.Font.micro)
                                                .foregroundStyle(AIATheme.sub)
                                                .multilineTextAlignment(.center)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                        } else {
                                            GrowthBars(data: data,
                                                       accent: AIATheme.food,
                                                       maxValue: data.map(\.value).max() ?? 1,
                                                       revealed: barsRevealed,
                                                       abbreviate: false)
                                        }
                                    }
                                        .tag(off)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .frame(height: 100)
                            ChartPageDots(selection: chartWeekOffset, minOffset: -8, accent: AIATheme.food)
                        }
                        .padding(12)
                        .card(radius: AIATheme.rMD)
                        .onChange(of: chartWeekOffset) { _, _ in
                            // 左右滑动翻到新一周时，重置并重播从 0 向上生长动画
                            withAnimation(.none) { barsRevealed = false }
                            Task {
                                try? await Task.sleep(nanoseconds: 150_000_000)
                                barsRevealed = true
                            }
                        }

                        // Card4 · 当前餐次
                        VStack(alignment: .leading, spacing: 8) {
                            SegmentedPicker(options: MealFilter.allCases.map { (value: $0, label: $0.label) }, selection: mealBinding)

                            // 本餐热量汇总
                            HStack {
                                Text(meal.label)
                                    .font(AIATheme.Font.footnote.weight(.semibold))
                                Spacer()
                                Text("共 \(Int(mealTotal)) kcal")
                                    .font(AIATheme.Font.footnote.weight(.medium))
                                    .foregroundStyle(AIATheme.food)
                            }

                            frequentFoodRegion
                        }
                        .id("foodListTop")
                        .padding(12)
                        .card(radius: AIATheme.rMD)

                    mealItemsSection

                    // 底部占位：保证 ScrollView 内容始终足够高，使「滚到 Card4 顶」在食物条目少/为空的餐次
                    // 也能落到正确位置。否则内容过短会被 SwiftUI 钳制到最大可滚偏移，早餐（内容高）正常、
                    // 午餐/加餐（内容短）却「没滚够」——因为 Card4 顶对不到屏幕顶。
                    Color.clear
                        .frame(minHeight: 1000)
                }
                .padding()
                .onChange(of: scrollToFoodNonce) { _, _ in
                    withAnimation {
                        proxy.scrollTo("foodListTop", anchor: .top)
                    }
                }
                }
            }
        case .preferences:
            DietPreferencesView()
        case .analysis:
            DietAnalysisView()
        }
    }
            AIBottomBar(prompts: [
                AIPrompt(text: "点拍照识别、记录美食", pointsTo: .camera),
                AIPrompt(text: "吃了什么美食？点此小记帮你记", pointsTo: nil),
                AIPrompt(text: "点麦克风，语音记录饮食", pointsTo: .mic),
                AIPrompt(text: "小记帮总结今天的饮食情况", pointsTo: nil),
                AIPrompt(text: "点相册上传、记录美食", pointsTo: .album)
            ], entrySource: "food")
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(LocalizedStringKey("food.navTitle"))
        .task { UsageAnalytics.logOpen("diet") }
        .task {
            // 进入饮食页时延迟一帧触发近7日热量柱状图从 0 向上生长（立即改会被 .task 吞掉）
            try? await Task.sleep(nanoseconds: 150_000_000)
            barsRevealed = true
            // 热量目标为 0（未设置）→ 弹窗引导用户去健康目标页录入身高体重自动生成
            if goal <= 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                showCalorieGoalAlert = true
            }
        }
        .onChange(of: selectedDate) { _, _ in
            chartWeekOffset = 0
            // 切换日期时，近7日窗口与热量数据都在变，重置并重新播放从 0 向上生长动画
            withAnimation(.none) { barsRevealed = false }
            Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                barsRevealed = true
            }
        }
        .onDisappear { barsRevealed = false }
        .toolbar {
            if !multiSelectMode {
                // 日历按钮只对「饮食记录」tab 有意义（选日期看当日饮食）
                if dietTab == .records {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 4) {
                            Button { showAddFood = true } label: {
                                Image(systemName: "plus")
                                    .font(AIATheme.Font.headline.weight(.medium))
                                    .foregroundStyle(AIATheme.blue)
                            }
                            Button { showDatePicker = true } label: {
                                Image(systemName: "calendar")
                                    .font(AIATheme.Font.headline)
                                    .foregroundStyle(AIATheme.blue)
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if multiSelectMode {
                MultiSelectBottomBar(
                    count: selectedIDs.count,
                    totalCount: mealItems.count,
                    onCancel: {
                        multiSelectMode = false
                        selectedIDs.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allIDs = Set(mealItems.map(\.persistentModelID))
                        if selectedIDs.isSuperset(of: allIDs) {
                            selectedIDs.subtract(allIDs)
                        } else {
                            selectedIDs.formUnion(allIDs)
                        }
                    },
                    onDelete: {
                        guard !selectedIDs.isEmpty else { return }
                        showDeleteConfirm = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: multiSelectMode)
        .alert(NSLocalizedString("common.confirmDelete", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { }
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                batchDeleteFood()
            }
        } message: {
            Text(String(format: NSLocalizedString("common.deleteCount", comment: ""), selectedIDs.count))
        }
        .fullScreenCover(isPresented: $showAddFood) {
            AddFoodManualView(initialDate: selectedDate, initialMeal: meal.mealString)
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
                        // 记录修改时间并触发增量同步：随后经 aia_records(type:"setting") 上云，绑定后小程序可见。
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "userSettingUpdatedAt")
                        CloudSyncManager.shared.syncAfterLocalChange(context: context)
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
                        // 恢复自动同样视为一次设置变更，触发同步，让小程序也回到自动。
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "userSettingUpdatedAt")
                        CloudSyncManager.shared.syncAfterLocalChange(context: context)
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
        .sheet(item: $editFoodID) { id in
            // >>> CHANGE-[2026-08-17 17:25:00]-[编辑食物统一EditFoodSheet] 开始
            // 原因: 统一所有编辑食物入口走 EditFoodSheet wrapper（见 EditSheets.swift 同时间戳标记），
            //       替代原先内联 NavigationStack，避免其他入口漏包导致无导航栏。
            // 回退: 恢复为内联 NavigationStack 直出 EditFoodView。
            if let food = context.model(for: id) as? FoodEntry {
                EditFoodSheet(entryID: food.persistentModelID)
            }
            // <<< CHANGE-[2026-08-17 17:25:00]-[编辑食物统一EditFoodSheet] 结束
        }
        .onAppear { meal = FoodListView.defaultMeal(for: .now) }
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker, navigateToChat: true)
        // 热量目标为 0（未设置）→ 居中弹窗引导去健康目标页录入身高体重自动生成
        .centeredAlert(
            isPresented: $showCalorieGoalAlert,
            title: "亲，你还未设置每日热量目标哦",
            message: "录入身高、体重等信息，自动生成目标",
            dismissTitle: "去设置",
            onDismiss: { NavigationRouter.shared.navigate(.healthGoals) },
            secondaryTitle: "稍后"
        )
    }

    private func weekday(for date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func deleteFood(_ f: FoodEntry) {
        // 使用 SafeDelete 软删：设置 syncDeleted=true 后由 CloudSyncManager 推送到云端，
        // 避免直接硬删导致 deleted=true 标志无法到达云端（详见 SafeDelete 注释）。
        // >>> CHANGE-[2026-08-17 11:26:30]-[临时对象失效崩溃] 开始
        // 原因：f 来自 @Query 行对象，转场/@Query 刷新后可能失效。回退：改回 SafeDelete.food(f, in: context)
        SafeDelete.foodByID(f.persistentModelID, in: context)
        // <<< CHANGE-[2026-08-17 11:26:30]-[临时对象失效崩溃] 结束
    }

    // MARK: 多选删除

    private func enterFoodMultiSelect(_ id: PersistentIdentifier) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        multiSelectMode = true
        selectedIDs.insert(id)
    }

    private func toggleFoodSelection(_ id: PersistentIdentifier) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedIDs.isEmpty { multiSelectMode = false }
        } else {
            selectedIDs.insert(id)
        }
    }

    private func batchDeleteFood() {
        for id in selectedIDs {
            SafeDelete.foodByID(id, in: context)
        }
        multiSelectMode = false
        selectedIDs.removeAll()
    }
}

// MARK: - 健康管理（④）
struct HealthListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \HealthMetric.date, order: .reverse) private var healths: [HealthMetric]
    @Query(filter: #Predicate<SleepSession> { !$0.syncDeleted }, sort: \.sleepStart, order: .reverse) private var sleeps: [SleepSession]
    /// 识别引擎来源标记（RecogSource 1:1 关联 HealthMetric.syncId），用于每行显示「免费版AI识别/Pro版AI…」
    @Query private var recogSources: [RecogSource]
    private var recogSourceBySyncId: [UUID: String] {
        Dictionary(uniqueKeysWithValues: recogSources.map { ($0.syncId, $0.recogSourceRaw) })
    }
    // >>> CHANGE-[2026-08-19 12:36:16]-[健康目标页净热量方块] 开始
    // 原因: 健康管理页下方4小方块需新增"净热量"(今日摄入-今日消耗),替代原"身高"方块;与饮食页 net 同源口径
    // 回退: 删除本段 + statGrid 内净热量 StatCard 即可还原为"身高"方块
    @Query(filter: #Predicate<FoodEntry> { !$0.syncDeleted }) private var foods: [FoodEntry]
    /// 今日摄入热量 = 今日 FoodEntry.calories 求和（按日历日过滤，与饮食页 selectedFoods 同源）
    private var todayCalories: Double {
        foods.filter { Calendar.current.isDate($0.date, inSameDayAs: Date()) }
             .reduce(0) { $0 + $1.calories }
    }
    /// 净热量 = 整数(今日摄入) − 整数(今日消耗)（与饮食页净热量英雄数字同源，方案B整数减口径一致）
    private var netCalorie: Int { Int(todayCalories) - Int(tdeeCurrentValue) }
    /// 净热量展示：正数带"+"、负数"-"、零"0"，单位 kcal；无数据(0且未记录)回落"—"
    private var netCalorieDisplay: String {
        guard !todayCalories.isZero else { return "—" }
        let v = netCalorie
        return (v > 0 ? "+" : "") + "\(v) kcal"
    }
    /// 净热量颜色：医学营养界习惯——盈余(正)红、缺口(负)绿；无数据中性
    private var netCalorieColor: Color {
        if todayCalories.isZero { return AIATheme.ink }
        return netCalorie >= 0 ? AIATheme.over : AIATheme.income
    }
    // <<< CHANGE-[2026-08-19 12:36:16]-[健康目标页净热量方块] 结束

    @StateObject private var health = HealthManager.shared

    /// 当前正在进行的睡眠会话 = 仅当「最近一条」会话还在睡（wakeAt == nil）时存在。
    /// 口径收敛到 SleepSession.swift 的 `currentActiveSleepSession`，与首页共用同一份判定，避免两端走样。
    private var activeSleepSession: SleepSession? {
        currentActiveSleepSession(in: sleeps)
    }

    /// 最近一条已醒的睡眠会话（wakeAt != nil），用于「元气满满」态下方展示「上次入睡时间 + 睡眠时长」。
    /// `sleeps` 已是 @Query 倒序，取首个 wakeAt != nil 即为最近一次。
    private var lastFinishedSleepSession: SleepSession? {
        sleeps.first(where: { $0.wakeAt != nil })
    }

    /// 入睡/醒来切换：空闲→写入 sleepStart 开始睡眠；在睡→写入 wakeAt 并计算时长，自动入库 + 增量同步。
    /// 逻辑收敛到 SleepSession.swift 的 `toggleSleepSession`，与首页共用同一份实现。
    /// 这里再叠加「与首页同口径的遮罩 + toast」：刚入睡→盖睡眠遮罩；刚醒来→居中大卡 toast（与遮罩「我醒了」同款）。
    private func handleSleepToggle() {
        // toggle 返回切换后的真实结果：nil=已醒来（之前在睡），非 nil=刚入睡（新建会话）。
        // 用返回值而非 wasSleeping 快照判断：@Query 闭包快照在 iCloud 同步/冷启动延迟时
        // 可能尚未包含活跃会话，导致误判 wasSleeping=false 而不弹 toast。
        let activeAfter = toggleSleepSession(in: context, sleeps: sleeps)   // 模型变更不包 withAnimation（项目铁律）
        let didWake = (activeAfter == nil)
        let start = activeSleepSession?.sleepStart
                 ?? ContentView.activeSleepSessionStartFallback(context: context)
        if didWake {
            // 醒来：复制首页遮罩 onWake 的 toast 口径，避免两处文案/样式漂移。延后到遮罩淡出后弹。
            let toastStart = start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                ToastCenter.shared.showImportant(
                    sleepSummaryText(start: toastStart),
                    icon: "🌙",
                    accent: AIATheme.warning
                )
            }
        }
        withAnimation(.easeOut(duration: 0.35)) {
            showSleepMask = (activeAfter != nil)   // 刚入睡 → 盖遮罩；刚醒来 → 收遮罩
        }
    }

    /// 自动恢复睡眠遮罩（与首页 ContentView.restoreSleepMaskIfNeeded 同口径）：
    /// 有进行中的会话、本会话未被主动收起过、且未超 maxAutoRestoreHours 才盖；
    /// 超时视为「忘了点醒来的孤儿数据」不盖（页面按钮仍是 🌙，可自行点醒）。
    /// 冷启动/进入健康页时调用，杀 App 重开也一样生效。
    private func restoreSleepMaskIfNeeded() {
        guard !showSleepMask else { return }
        guard let active = activeSleepSession else { return }
        guard sharedSleepMaskDismissedSessionID != active.syncId else { return }
        let maxAutoRestoreHours: Double = 14
        guard Date().timeIntervalSince(active.sleepStart) < maxAutoRestoreHours * 3600 else { return }
        withAnimation(.easeOut(duration: 0.35)) { showSleepMask = true }
    }

    /// 睡眠时长小结文案（与首页 sleepStatusButton / 遮罩「我醒了」同口径，避免两处文案漂移）。
    private func sleepSummaryText(start: Date) -> String {
        let dur = Date().timeIntervalSince(start)
        let totalMin = max(0, Int(dur / 60))
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 {
            return "本次睡眠 \(h) 小时 \(m) 分钟"
        } else {
            return "本次睡眠 \(m) 分钟"
        }
    }

    private func sleepDurationText(_ s: SleepSession) -> String {
        formatDuration(sleepSessionDuration(s))
    }
    private func formatDuration(_ sec: TimeInterval) -> String {
        let h = Int(sec) / 3600
        let m = (Int(sec) % 3600) / 60
        return "\(h)h\(m)m"
    }
    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    @State private var barsRevealed = false   // 近7日步数柱状图：进入时从 0 向上生长动画
    @State private var chartWeekOffset: Int = 0   // 近7日步数图翻周：0=本周，负=过去第 |n| 周
    @State private var healthRefreshTimer: Timer?
    private let healthRefreshInterval: TimeInterval = 120   // 前台停留期间每 2 分钟刷新一次 HealthKit
    @State private var showSleepMask = false     // 健康页入睡→盖睡眠遮罩（与首页同口径）
    @State private var showHealthGoalsAlert = false  // 未录入健康目标→弹窗提醒
    // 「先用一下 App」收起记忆与首页共享（sharedSleepMaskDismissedSessionID，进程内、不持久化）：
    // 杀 App 重开 → 值重置为 nil → 只要没点醒来，重开进健康页就自动盖回。

    // 健康目标（本地 @AppStorage，与饮食 aia.calorieGoalOverride 同策略，不云同步）
    @AppStorage("aia.heightCm") private var heightCm: Double = 0
    @AppStorage("aia.weightKg") private var weightKg: Double = 0
    @AppStorage("aia.age") private var age: Int = 30
    @AppStorage("aia.bioSex") private var bioSex: Int = 1   // 1 = 男, 0 = 女
    @AppStorage("aia.activityLevel") private var activityLevel: Int = 1
    @AppStorage("aia.stepGoal") private var stepGoal: Int = 10000
    @AppStorage("aia.sleepGoalHours") private var sleepGoalHours: Double = 8
    @AppStorage("aia.exerciseGoalMin") private var exerciseGoalMin: Double = 30
    @AppStorage("aia.targetHeightCm") private var targetHeightCm: Double = 0
    @AppStorage("aia.weightGoalKg") private var weightGoalKg: Double = 65

    // 今日达成数（手动录入，HealthKit 未接入时回退到这里，按日期隔离存储在 ManualHealthStore）。

    // MARK: 圆环数据来源（逐指标切换）
    // 每个指标独立选择「自动记录（HealthKit）/ 手动记录」，默认全 auto。
    // 只有在「该指标设为 auto」且「HealthKit 真可用（已授权 + 可用 + 读到过非零数据）」时才走 HealthKit，
    // 其余回退手动录入。未连 HealthKit 时 hkUsable=false，等价于旧的全手动行为，无需迁移。
    @AppStorage(HealthMetricKind.steps.sourceKey)     private var stepsSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.sleep.sourceKey)     private var sleepSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.exercise.sourceKey)  private var exerciseSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.tdee.sourceKey)      private var tdeeSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.heartRate.sourceKey) private var heartRateSource: HealthSourceMode = .auto

    private var hkUsable: Bool { health.authorized && health.isAvailable }

    // 前台停留期间的 HealthKit 周期刷新（每 healthRefreshInterval 秒一次），离开页面必须停，避免泄漏与后台空转。
    private func startHealthRefreshTimer() {
        healthRefreshTimer?.invalidate()
        healthRefreshTimer = Timer.scheduledTimer(withTimeInterval: healthRefreshInterval, repeats: true) { _ in
            Task { @MainActor in HealthManager.shared.refreshAll() }
        }
    }
    private func stopHealthRefreshTimer() {
        healthRefreshTimer?.invalidate()
        healthRefreshTimer = nil
    }

    /// 某指标当前是否应走自动（HealthKit）记录。
    private func isAuto(_ kind: HealthMetricKind) -> Bool {
        let mode: HealthSourceMode = {
            switch kind {
            case .steps: return stepsSource
            case .sleep: return sleepSource
            case .exercise: return exerciseSource
            case .tdee: return tdeeSource
            case .heartRate: return heartRateSource
            }
        }()
        return mode == .auto && hkUsable
    }

    private var stepsCurrentValue: Int {
        isAuto(.steps) ? Int(ManualHealthStore.shared.healthKitValue("steps", for: Date())) : ManualHealthStore.shared.steps(for: Date())
    }
    private var sleepCurrentValue: Double {
        if isAuto(.sleep) {
            // 自动模式：优先读 HealthKit 落库值（.hk 槽位，已持久化），兼容旧 HealthMetric 体检记录兜底。
            let hk = ManualHealthStore.shared.healthKitValue("sleep", for: Date())
            if hk > 0 { return hk }
            return healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0
        }
        // 手动模式：与圆环完成数据、首页「昨晚睡眠」同源（详见 manualSleepTotalHours）
        return manualSleepTotalHours(sleeps: sleeps, healths: healths, on: Date())
    }
    private var exerciseCurrentValue: Double {
        isAuto(.exercise)
            ? ManualHealthStore.shared.healthKitValue("exercise", for: Date())
            : health.exerciseTimeToday + Double(ManualHealthStore.shared.exerciseMinutes(for: Date()))
    }
    // >>> CHANGE-[2026-08-19 12:55:00]-对齐全App今日消耗口径 开始
    // 原因: 原写法读 HealthManager 实时 restingEnergyToday+activeEnergyToday, 与饮食页(按 selectedDate 查字典)口径差 55kcal → 净热量两页不一致
    //       改与饮食页 RecordsViews:273 完全同源: 自动模式按 Date() 查 activeEnergyForDay/restingEnergyForDay 字典, 空时回退 .hk 落库值;
    //       手动模式按 Date() 查 ManualHealthStore。
    // 回退: 删除本段, 恢复原判(HealthManager.shared.restingEnergyToday + activeEnergyToday) 即可。
    private var tdeeCurrentValue: Double {
        let day = Calendar.current.startOfDay(for: Date())
        if isAuto(.tdee) && HealthManager.shared.isAvailable && HealthManager.shared.hasHealthKitData {
            let active = HealthManager.shared.activeEnergyForDay[day]
                ?? ManualHealthStore.shared.healthKitValue("activeCalories", for: day)
            let resting = HealthManager.shared.restingEnergyForDay[day]
                ?? ManualHealthStore.shared.healthKitValue("restingCalories", for: day)
            return active + resting
        }
        return Double(ManualHealthStore.shared.activeCalories(for: day))
    }
    // <<< CHANGE-[2026-08-19 12:55:00]-对齐全App今日消耗口径 结束

    /// 能量圆环目标 = 每日总消耗 TDEE（BMR × 活动系数），与健康目标页 TDEE 数值同步。
    private var tdeeGoal: Double {
        (mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: age, isMale: bioSex == 1) ?? 0)
            * activityMultiplier(activityLevel)
    }
    /// 目标 BMI = 目标体重 / 目标身高²；任一未填返回 nil。
    private var targetBmi: Double? {
        guard targetHeightCm > 0, weightGoalKg > 0 else { return nil }
        let m = targetHeightCm / 100
        return weightGoalKg / (m * m)
    }

    /// 点击圆环自增：步数 +1000 / 睡眠 +1h / 运动 +10min，并触发轻触震动。
    /// 自动记录（HealthKit）模式下不写入数据，而是弹出「是否切换为手动记录」确认框。
    private func incrementMetric(_ kind: HealthMetricKind) {
        if isAuto(kind) {
            alertMetricKind = kind
            alertMetricTitle = kind.title
            showAutoModeAlert = true
            return
        }
        switch kind {
        case .steps: ManualHealthStore.shared.addSteps(1000, for: Date())
        case .sleep: ManualHealthStore.shared.addSleepHours(1, for: Date())
        case .exercise: ManualHealthStore.shared.addExerciseMinutes(10, for: Date())
        case .tdee: ManualHealthStore.shared.addActiveCalories(100, for: Date())
        case .heartRate: break   // 2026-08-19：静息心率方块已改为跳记录页, 不再此处弹 sheet
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func bumpText(_ kind: HealthMetricKind) -> String {
        switch kind {
        case .steps: return "+1000 步"
        case .sleep: return "+1 小时"
        case .exercise: return "+10 分钟"
        case .tdee: return "+100 kcal"
        case .heartRate: return ""
        }
    }

    /// 圆环主行/副行文案：优先实际值；无数据但有目标时，目标顶替为主行（无副行）；
    /// 都没值显示「—」。对应未授权/无数据时圆环显示「目标 X」+ caption 的需求（2026-08-01），
    /// 与右图"未连接"态保持一致——不再出现「— / 目标 12000」这种两行杂糅的渲染。
    private func ringLines(current: String, hasData: Bool, goal: Int, unit: String? = nil) -> (value: String, secondary: String?) {
        // 「目标 X」永远走 secondary 副行（micro 小字），避免无数据时把长串「目标 X」塞进
        // value 主行（body 中等字重）导致被放大、视觉突兀（2026-08-01）。
        let goalText = goal > 0 ? "目标 \(goal)\(unit ?? "")" : nil
        if hasData {
            return (current, goalText)
        }
        if goalText != nil {
            return ("—", goalText)
        }
        return ("—", nil)
    }

    // 身高/体重/BMI 优先用用户档案（@AppStorage），未设置则回退到健康记录。
    private var weightDisplay: String {
        weightKg > 0 ? String(format: "%.1fkg", weightKg) : stat("体重")
    }
    private var heightDisplay: String {
        // 2026-07-30：身高保留一位小数会被截断成 "165.0cm" 在窄卡片里换行；统一取整 + 自动去 ".0"
        // 与体重 ("58.0kg") 风格统一，且更稳。同时回退到健康记录时也剥掉 ".0"。
        if heightCm > 0 {
            let rounded = heightCm.rounded()
            return rounded == floor(rounded) ? "\(Int(rounded))cm" : String(format: "%.1fcm", rounded)
        }
        let raw = stat("身高")
        return raw.replacingOccurrences(of: ".0cm", with: "cm")
    }
    private var bmiDisplay: String {
        guard heightCm > 0, weightKg > 0 else { return stat("BMI") }
        let m = heightCm / 100
        return String(format: "%.1f", weightKg / (m * m))
    }

    // MARK: 编辑 + 多选删除
    @State private var editHealth: HealthMetric? = nil
    @State private var multiSelectMode = false
    @State private var selectedIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm = false
    @State private var showSourceSettings = false   // 数据来源设置面板
    @State private var showRestingHRInput = false    // 静息心率录入 sheet
    @State private var showAutoModeAlert = false     // 自动记录模式点击圆环的切换确认弹窗
    @State private var alertMetricKind: HealthMetricKind? = nil
    @State private var alertMetricTitle: String = ""

    private var sleepHours: Double {
        healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0
    }
    private func stat(_ key: String) -> String {
        // 静息心率：自动模式下若 HealthKit 已读到值，优先显示 HealthKit 数据；
        // 手动模式优先读 ManualHealthStore（HealthKit 静息心率不回写 healths 表，否则永远 "—"）。
        if key == "心率" {
            if isAuto(.heartRate) {
                let hk = ManualHealthStore.shared.healthKitValue("heartRate", for: Date())
                if hk > 0 { return "\(Int(hk))bpm" }
            }
            let manual = ManualHealthStore.shared.restingHeartRate(for: Date())
            if manual > 0 { return "\(manual)bpm" }
        }
        return healths.first(where: { $0.metric.contains(key) }).map { "\($0.value)\($0.unit)" } ?? "—"
    }
    /// 近 7 日步数柱状数据。`offset` 为 0 表示本周，负数表示过去第 |offset| 周。
    private func weekSteps(offset: Int = 0) -> [ChartPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: offset * 7, to: today)!
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: end)!
            let dayStart = cal.startOfDay(for: d)
            let v: Double
            if isAuto(.steps) {
                // 已接 HealthKit：读 .hk 落库值（按天持久化，今天+历史 6 天同源）
                v = ManualHealthStore.shared.healthKitValue("steps", for: dayStart)
            } else {
                // 未接 HealthKit：按天回落到手动步数（ManualHealthStore 已按天存）
                v = Double(ManualHealthStore.shared.steps(for: dayStart))
            }
            return ChartPoint(label: dayFmt.string(from: d), value: v)
        }
    }

    /// 近 7 日运动时长（分钟）柱状数据。与 `weekSteps` 同源的翻周/生长逻辑。
    private func weekExercise(offset: Int = 0) -> [ChartPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: offset * 7, to: today)!
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: end)!
            let dayStart = cal.startOfDay(for: d)
            let v: Double
            if isAuto(.exercise) {
                // 已接 HealthKit：读 .hk 落库值（按天持久化，今天+历史 6 天同源）
                v = ManualHealthStore.shared.healthKitValue("exercise", for: dayStart)
            } else {
                // 未接 HealthKit：按天回落到手动运动（ManualHealthStore 已按天存）
                v = Double(ManualHealthStore.shared.exerciseMinutes(for: dayStart))
            }
            return ChartPoint(label: dayFmt.string(from: d), value: v)
        }
    }

    /// 近 7 日睡眠时长（小时）柱状数据。与 `weekSteps` 同源的翻周/生长逻辑。
    private func weekSleep(offset: Int = 0) -> [ChartPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: offset * 7, to: today)!
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: end)!
            let dayStart = cal.startOfDay(for: d)
            let v: Double
            if isAuto(.sleep) {
                // 已接 HealthKit：取 sleepLast7Days 缓存（含今天）
                v = health.sleepLast7Days[dayStart] ?? 0
            } else {
                // 未接 HealthKit：按天回落到手动睡眠（SleepSession + 手动点击；今天额外并入「睡眠」度量以与圆环同源）
                v = manualSleepForDay(d)
            }
            return ChartPoint(label: dayFmt.string(from: d), value: v)
        }
    }

    /// 是否展示「云端还没有你的健康数据」引导。
    /// 口径必须与页面实际展示的数据源一致：仅当 已登录 + HealthMetric 表空 + 今天步数 0，
    /// 且 用户档案未填身高/体重（否则 BMI 卡片会展示）+ 近 9 日无任何历史步数/运动/睡眠数据时，
    /// 页面才会真正静默空白，此时才提示从云端恢复。
    private var shouldShowCloudRestoreHint: Bool {
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return false }
        guard healths.isEmpty else { return false }
        guard stepsCurrentValue == 0 else { return false }
        // 用户档案已填身高/体重 → 页面至少展示 BMI 卡片，不算空
        guard weightKg <= 0 || heightCm <= 0 else { return false }
        // 近 9 日（含今天）任意一天有步数/运动/睡眠历史 → 页面有图表，不算空
        let hasHistory = (0...8).contains { off in
            weekSteps(offset: -off).contains { $0.value > 0 }
            || weekExercise(offset: -off).contains { $0.value > 0 }
            || weekSleep(offset: -off).contains { $0.value > 0 }
        }
        guard !hasHistory else { return false }
        return true
    }

    /// 手动模式下某天的睡眠时长（小时）：复用 manualSleepTotalHours，与首页「昨晚睡眠」/ 健康页睡眠圆环同源——
    /// 今天并入「睡眠」度量残留(includeStored:true)，历史日期不并入(includeStored:false)，避免旧日期被今天残留污染。
    private func manualSleepForDay(_ d: Date) -> Double {
        manualSleepTotalHours(sleeps: sleeps, healths: healths, on: d, includeStored: Calendar.current.isDateInToday(d))
    }

    /// 近 7 日运动时长卡片（复用 Card B 的翻周与生长动画逻辑；与步数共用 chartWeekOffset 保持翻周联动）
    private var exerciseWeekCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "近 7 日运动时长",
                         trailing: chartWeekRangeLabel(offset: chartWeekOffset, base: Date()),
                         systemImage: "figure.run")
            TabView(selection: $chartWeekOffset) {
                ForEach(Array((-8)...0), id: \.self) { off in
                    let data = weekExercise(offset: off)
                    Group {
                        if data.allSatisfy({ $0.value == 0 }) {
                            Text(isAuto(.exercise)
                                 ? "未从Apple健康获取到数据，可点右上角「设置」换成手动记录"
                                 : "未从Apple健康获取到数据，可点上方圆环手动记录")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.sub)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        } else {
                            GrowthBars(data: data,
                                       accent: AIATheme.health,
                                       maxValue: data.map(\.value).max() ?? 1,
                                       revealed: barsRevealed)
                        }
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 100)
            ChartPageDots(selection: chartWeekOffset, minOffset: -8, accent: AIATheme.health)
        }
        .padding(12)
        .card(radius: AIATheme.rMD)
    }

    /// 近 7 日睡眠时长卡片（复用 Card B 的翻周与生长动画逻辑；与步数共用 chartWeekOffset 保持翻周联动）
    private var sleepWeekCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "近 7 日睡眠时长",
                         trailing: chartWeekRangeLabel(offset: chartWeekOffset, base: Date()),
                         systemImage: "moon.zzz.fill")
            TabView(selection: $chartWeekOffset) {
                ForEach(Array((-8)...0), id: \.self) { off in
                    let data = weekSleep(offset: off)
                    Group {
                        if data.allSatisfy({ $0.value == 0 }) {
                            Text(isAuto(.sleep)
                                 ? "未从Apple健康获取到数据，可点右上角「设置」换成手动记录"
                                 : "未从Apple健康获取到数据，可点上方圆环手动记录")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.sub)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        } else {
                            GrowthBars(data: data,
                                       accent: AIATheme.health,
                                       maxValue: data.map(\.value).max() ?? 1,
                                       revealed: barsRevealed)
                        }
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 100)
            ChartPageDots(selection: chartWeekOffset, minOffset: -8, accent: AIATheme.health)
        }
        .padding(12)
        .card(radius: AIATheme.rMD)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 2026-07-30：重装后若云端本就没有健康数据（当初录入时未登录导致未上云），
                    // 页面会静默空白。这里在「已登录却全空」时给出明确引导：一键从云端恢复；
                    // 若恢复后仍为空，则说明云端无备份，需重新录入（本次会自动上云）。
                    // 2026-08-03 修正：空态口径必须与页面实际展示的数据源一致——
                    // 体重/身高/BMI 来自用户档案 @AppStorage，历史步数/运动/睡眠走手动/HealthKit，
                    // 这些都不进 healths 表也不看今天步数，但只要任意一项有值页面就不会空白，
                    // 故需一并纳入判断，避免「有数据还提示没数据」的乌龙。
                    if shouldShowCloudRestoreHint {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.title2)
                                    .foregroundStyle(AIATheme.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("云端还没有你的健康数据")
                                        .font(AIATheme.Font.body.weight(.semibold))
                                    Text("可能当初录入时还未登录，数据没能备份。点下方按钮从云端恢复；若恢复后仍为空，请重新录入一次（这次会自动上云）。")
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.muted)
                                }
                            }
                            Button {
                                CloudSyncManager.shared.syncAfterLogin(context: context)
                            } label: {
                                Text(CloudSyncManager.canPerformCloudSync ? "从云端恢复数据" : (CloudSyncManager.autoSync ? "会员已过期" : "自动同步已关闭"))
                                    .font(AIATheme.Font.body.weight(.medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(10)
                                    .background(CloudSyncManager.canPerformCloudSync ? AIATheme.blue : AIATheme.muted)
                                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                            }
                            .disabled(!CloudSyncManager.canPerformCloudSync)
                        }
                        .padding(12)
                        .background(AIATheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    // Card A · 今日概览（圆环 + 关键指标）
                    VStack(alignment: .leading, spacing: 12) {
                        // 目标兜底：未手动设置或计算出 0（常见：未填体重/身高 → TDEE 算出 0）时，
                        // 回退到系统默认目标，避免圆环出现「— / 目标为空」状态（2026-08-01）。
                        let effectiveStepGoal     = stepGoal > 0 ? stepGoal : 10000
                        let effectiveSleepGoal    = sleepGoalHours > 0 ? sleepGoalHours : 8
                        let effectiveExerciseGoal = exerciseGoalMin > 0 ? exerciseGoalMin : 30
                        let effectiveTdeeGoal     = tdeeGoal > 0 ? Int(tdeeGoal) : 2000

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            let stepsRing = ringLines(current: "\(stepsCurrentValue)", hasData: stepsCurrentValue > 0, goal: effectiveStepGoal)
                            HealthRingButton(
                                kind: .steps,
                                value: stepsRing.value,
                                caption: NSLocalizedString("health.ring.steps", comment: ""),
                                secondary: stepsRing.secondary,
                                progress: effectiveStepGoal > 0 ? min(Double(stepsCurrentValue) / Double(effectiveStepGoal), 1) : 0,
                                onTap: { incrementMetric(.steps) },
                                bumpText: bumpText(.steps),
                                enabled: !isAuto(.steps)
                            )

                            let sleepRing = ringLines(
                                current: String(format: "%.1f", sleepCurrentValue),
                                hasData: sleepCurrentValue > 0,
                                goal: Int(effectiveSleepGoal),
                                unit: "h"
                            )
                            HealthRingButton(
                                kind: .sleep,
                                value: sleepRing.value,
                                caption: NSLocalizedString("health.ring.sleep", comment: ""),
                                secondary: sleepRing.secondary,
                                progress: effectiveSleepGoal > 0 ? min(sleepCurrentValue / effectiveSleepGoal, 1) : 0,
                                onTap: { incrementMetric(.sleep) },
                                bumpText: bumpText(.sleep),
                                enabled: !isAuto(.sleep)
                            )

                            let exerciseRing = ringLines(
                                current: "\(Int(exerciseCurrentValue))",
                                hasData: exerciseCurrentValue > 0,
                                goal: Int(effectiveExerciseGoal),
                                unit: "min"
                            )
                            HealthRingButton(
                                kind: .exercise,
                                value: exerciseRing.value,
                                caption: NSLocalizedString("health.ring.exercise", comment: ""),
                                secondary: exerciseRing.secondary,
                                progress: effectiveExerciseGoal > 0 ? min(exerciseCurrentValue / effectiveExerciseGoal, 1) : 0,
                                onTap: { incrementMetric(.exercise) },
                                bumpText: bumpText(.exercise),
                                enabled: !isAuto(.exercise)
                            )

                            let tdeeRing = ringLines(
                                current: "\(Int(tdeeCurrentValue))",
                                hasData: tdeeCurrentValue > 0,
                                goal: effectiveTdeeGoal
                            )
                            HealthRingButton(
                                kind: .tdee,
                                value: tdeeRing.value,
                                caption: NSLocalizedString("health.ring.energy", comment: ""),
                                secondary: tdeeRing.secondary,
                                progress: Double(effectiveTdeeGoal) > 0 ? min(tdeeCurrentValue / Double(effectiveTdeeGoal), 1) : 0,
                                onTap: { incrementMetric(.tdee) },
                                bumpText: bumpText(.tdee),
                                enabled: !isAuto(.tdee)
                            )
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            // >>> CHANGE-[2026-08-19 12:36:16]-[健康目标页净热量方块] 开始
                            // 顺序调整: 体重 → BMI → 静息心率 → 净热量(替代身高);净热量跳饮食页
                            Button { NavigationRouter.shared.navigate(.bodyData) } label: {
                                StatCard(value: weightDisplay, caption: NSLocalizedString("health.stat.weight", comment: ""))
                            }
                            .buttonStyle(.plain)
                            Button { NavigationRouter.shared.navigate(.bodyData) } label: {
                                StatCard(value: bmiDisplay, caption: NSLocalizedString("health.stat.bmi", comment: ""))
                            }
                            .buttonStyle(.plain)
                            Button {
                                // 跳转到静息心率每天记录页（最近90天，自动/手动均可点进去录入或覆盖）
                                NavigationRouter.shared.navigate(.restingHeartRateRecords)
                            } label: {
                                StatCard(value: stat("心率"), caption: NSLocalizedString("health.stat.restingHR", comment: ""))
                            }
                            .buttonStyle(.plain)
                            Button { NavigationRouter.shared.navigate(.diet) } label: {
                                StatCard(value: netCalorieDisplay,
                                         caption: NSLocalizedString("health.stat.netCalorie", comment: ""),
                                         valueColor: netCalorieColor)
                            }
                            .buttonStyle(.plain)
                            // <<< CHANGE-[2026-08-19 12:36:16]-[健康目标页净热量方块] 结束
                        }
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

                    // Card · 健康目标 + 睡眠按钮：拆成两个等宽格子并排
                    HStack(spacing: 10) {
                        // 左格：健康目标，点击进入可编辑
                        Button { NavigationRouter.shared.navigate(.healthGoals) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "target")
                                    .font(AIATheme.Font.title3)
                                    .foregroundStyle(AIATheme.health)
                                    .frame(width: 34, height: 34)
                                    .background(AIATheme.healthBG)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("健康目标").font(AIATheme.Font.footnote.weight(.medium))
                                    Text("体重 \(weightGoalKg > 0 ? String(format: "%.1f", weightGoalKg) : "—")kg · BMI \(targetBmi.map { String(format: "%.1f", $0) } ?? "—") · 运动 \(Int(exerciseGoalMin))min")
                                        .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .card(radius: AIATheme.rMD)

                        // 右格：睡眠状态切换按钮（独立格子，填满整个模块；背景色铺满，不与左格嵌套）
                        SleepToggleButton(activeSession: activeSleepSession,
                                          lastFinishedSession: lastFinishedSleepSession,
                                          onToggle: handleSleepToggle)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Card B · 近 7 日步数（可左右滑动翻看过去 8 周，每屏重播生长动画）
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: NSLocalizedString("health.weekSteps", comment: ""),
                                     trailing: chartWeekRangeLabel(offset: chartWeekOffset, base: Date()))
                        TabView(selection: $chartWeekOffset) {
                            ForEach(Array((-8)...0), id: \.self) { off in
                                let data = weekSteps(offset: off)
                                Group {
                                    if data.allSatisfy({ $0.value == 0 }) {
                                        Text(isAuto(.steps)
                                             ? "未从Apple健康获取到数据，可点右上角「设置」换成手动记录"
                                             : "未从Apple健康获取到数据，可点上方圆环手动记录")
                                            .font(AIATheme.Font.micro)
                                            .foregroundStyle(AIATheme.sub)
                                            .multilineTextAlignment(.center)
                                            .frame(height: 70)
                                    } else {
                                        GrowthBars(data: data,
                                                   accent: AIATheme.health,
                                                   maxValue: data.map(\.value).max() ?? 1,
                                                   revealed: barsRevealed)
                                    }
                                }
                                .tag(off)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 100)
                        ChartPageDots(selection: chartWeekOffset, minOffset: -8, accent: AIATheme.health)
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)
                    .onChange(of: chartWeekOffset) { _, _ in
                        withAnimation(.none) { barsRevealed = false }
                        Task {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            barsRevealed = true
                        }
                    }

                    // Card B2 · 近 7 日运动时长
                    exerciseWeekCard

                    // Card B3 · 近 7 日睡眠时长
                    sleepWeekCard

                    // Card C · 最近睡眠（真实数据来自 SleepSession；深/浅/REM 待接入 HealthKit 睡眠分析）
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(text: "最近睡眠")
                        if let s = sleeps.first {
                            // 顶部：总时长（在睡=实时；已醒=记录值）+ 入睡/醒来时间
                            HStack(alignment: .bottom, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.wakeAt == nil ? "正在睡" : "睡眠时长")
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.sub)
                                    Text(sleepDurationText(s))
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(AIATheme.health)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("入睡").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                                        Text(timeText(s.sleepStart)).font(AIATheme.Font.footnote.weight(.medium))
                                    }
                                    if let w = s.wakeAt {
                                        HStack(spacing: 4) {
                                            Text("醒来").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                                            Text(timeText(w)).font(AIATheme.Font.footnote.weight(.medium))
                                        }
                                    }
                                }
                            }
                            Divider().padding(.vertical, 2)
                            // 深/浅/REM：真实分期需 HealthKit 睡眠分析，暂显示占位
                            CardRow(icon: "🌙", iconBG: AIATheme.surfaceSecondary, title: "深睡", subtitle: "待接入睡眠分析", value: "—")
                            CardRow(icon: "💤", iconBG: AIATheme.surfaceSecondary, title: "浅睡", subtitle: "待接入睡眠分析", value: "—")
                            CardRow(icon: "⚡", iconBG: AIATheme.surfaceSecondary, title: "REM", subtitle: "待接入睡眠分析", value: "—")
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "moon.zzz.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(AIATheme.health.opacity(0.6))
                                Text("还没有睡眠记录")
                                    .font(AIATheme.Font.footnote.weight(.medium))
                                Text("点上方「入睡」按钮开始记录，醒来点「醒来」自动记时长。")
                                    .font(AIATheme.Font.micro)
                                    .foregroundStyle(AIATheme.sub)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

                    SectionTitle(text: "健康记录")
                    if healths.isEmpty {
                        EmptyStateView(
                            kind: .health,
                            title: "还没有健康记录",
                            message: "连接 iPhone 健康，或手动记录体重、睡眠、心率，小记帮你画出趋势。"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ForEach(healths) { h in
                            SelectableRow(
                                isSelecting: multiSelectMode,
                                isSelected: selectedIDs.contains(h.persistentModelID),
                                onTap: { editHealth = h },
                                onLongPress: { enterHealthMultiSelect(h.persistentModelID) },
                                onToggle: { toggleHealthSelection(h.persistentModelID) },
                                onDelete: {
                                // >>> CHANGE-[2026-08-17 11:27:00]-[临时对象失效崩溃] 开始
                                // 原因：h 来自 @Query ForEach 行，多选手动删除后底层数组变动可能释放引用。回退：改回 SafeDelete.health(h, in: context)
                                SafeDelete.healthByID(h.persistentModelID, in: context)
                                // <<< CHANGE-[2026-08-17 11:27:00]-[临时对象失效崩溃] 结束
                            }
                            ) {
                                HStack(spacing: 12) {
                                    Image(systemName: "heart.circle").foregroundStyle(AIATheme.health)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(h.metric).font(AIATheme.Font.footnote.weight(.medium))
                                            if let raw = recogSourceBySyncId[h.syncId],
                                               let label = RecogSource.displayLabel(for: raw) {
                                                Text(label)
                                                    .font(AIATheme.Font.micro.weight(.medium))
                                                    .foregroundStyle(AIATheme.sub)
                                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                                    .background(AIATheme.surfaceSecondary)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(AppFormat.dateTime.string(from: h.date)).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                                    }
                                    Spacer()
                                    Text("\(h.value)\(h.unit)").font(AIATheme.Font.footnote.weight(.medium))
                                }
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .background(AIATheme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }
                .padding()
            }
            AIBottomBar(entrySource: "health")
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(LocalizedStringKey("health.navTitle"))
        // 睡眠遮罩出现时，临时收起导航栏的返回 + 右上齿轮按钮，避免用户点出/打断睡眠遮罩
        .navigationBarBackButtonHidden(showSleepMask)
        .toolbar {
            if !showSleepMask {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSourceSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(AIATheme.Font.body)
                            .foregroundStyle(AIATheme.health)
                    }
                }
            }
        }
        .sheet(isPresented: $showSourceSettings) {
            HealthSourceSettingsView()
        }
        // 自动记录模式下点击圆环：提示并询问是否切换为手动记录模式（仅该指标单独切换）
        .centeredAlert(
            isPresented: $showAutoModeAlert,
            title: "",
            message: "当前是 Apple 健康「自动记录」模式，点击不会增加数据。\n是否要切换成「手动记录」模式？",
            dismissTitle: "保持自动",
            onDismiss: { showAutoModeAlert = false },
            secondaryTitle: "换成手动",
            onSecondary: {
                showAutoModeAlert = false
                guard let kind = alertMetricKind else { return }
                // 仅把被点击的这一个指标切到手动，其余圆环不受影响。
                switch kind {
                case .steps: stepsSource = .manual
                case .sleep: sleepSource = .manual
                case .exercise: exerciseSource = .manual
                case .tdee: tdeeSource = .manual
                case .heartRate: heartRateSource = .manual
                }
                let toastMsg: String = (kind == .heartRate)
                    ? "已换成手动记录模式，点击「静息心率」方块即可记录数据。"
                    : "已换成手动记录模式，点击圆环可记录数据。"
                ToastCenter.shared.showImportant(
                    toastMsg,
                    icon: "hand.tap.fill",
                    accent: AIATheme.health
                )
            }
        )
        .task {
            UsageAnalytics.logOpen("health")
            health.refreshAll()          // 原只拉步数，现拉全部 6 项
            // 睡眠模式恢复：只要还有没点「醒来」的会话（未超 14h、本会话未主动收起），
            // 每次进入健康页都自动盖回遮罩——杀 App 重开也不例外（与首页冷启动恢复同口径）。
            restoreSleepMaskIfNeeded()
            startHealthRefreshTimer()    // 启动前台周期刷新
            // 延迟一帧再触发近7日步数柱状图从 0 向上生长（立即改会被 .task 吞掉）
            try? await Task.sleep(nanoseconds: 150_000_000)
            barsRevealed = true
            // 未录入健康目标（身高或体重任一为 0）→ 弹窗提醒
            if heightCm <= 0 || weightKg <= 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                showHealthGoalsAlert = true
            }
        }
        .onChange(of: health.authorized) { _, authorized in
            // 授权可能在进入本页后才完成，补齐定时器启动
            if authorized { startHealthRefreshTimer() }
        }
        .onDisappear {
            barsRevealed = false
            stopHealthRefreshTimer()     // 离开页面必须停，避免泄漏与后台空转
        }
        // 冷启动/首拉时 SleepSession 可能还在云端同步途中，@Query 到位后补盖一次
        // （restore 内部有 dismissed/14h/无会话多重守卫，不会被正常操作误盖）。
        .onChange(of: sleeps.count) { _, _ in
            restoreSleepMaskIfNeeded()
        }
        // 未录入健康目标提醒弹窗（身高或体重任一为 0 即弹，每次进入都判断）
        // 用自定义居中弹窗取代系统 .alert（iOS 26 系统 alert 文字强制左对齐，无法居中）
        .overlay(alignment: .center) {
            if showHealthGoalsAlert {
                ZStack {
                    // 半透明遮罩，点遮罩也可关
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture { showHealthGoalsAlert = false }

                    VStack(spacing: 14) {
                        Text("亲，你还没设定健康目标哦")
                            .font(AIATheme.Font.headline)
                            .foregroundStyle(AIATheme.reading)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Text("快去录入，开始管理运动、睡眠和健康吧")
                            .font(AIATheme.Font.subhead)
                            .foregroundStyle(AIATheme.sub)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)

                        HStack(spacing: 12) {
                            Button {
                                showHealthGoalsAlert = false
                            } label: {
                                Text("稍后")
                                    .font(AIATheme.Font.subhead)
                                    .foregroundStyle(AIATheme.sub)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(AIATheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: AIATheme.rSM))
                            }

                            Button {
                                showHealthGoalsAlert = false
                                NavigationRouter.shared.navigate(.healthGoals)
                            } label: {
                                Text("去录入")
                                    .font(AIATheme.Font.subhead.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(AIATheme.health, in: RoundedRectangle(cornerRadius: AIATheme.rSM))
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(20)
                    .background(AIATheme.surface, in: RoundedRectangle(cornerRadius: AIATheme.rLG))
                    .shadow(color: AIATheme.cardShadowStrong, radius: AIATheme.cardShadowRadius, y: AIATheme.cardShadowY)
                    .padding(.horizontal, 36)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: showHealthGoalsAlert)
            }
        }
        .overlay(alignment: .bottom) {
            if multiSelectMode {
                MultiSelectBottomBar(
                    count: selectedIDs.count,
                    totalCount: healths.count,
                    onCancel: {
                        multiSelectMode = false
                        selectedIDs.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allIDs = Set(healths.map(\.persistentModelID))
                        if selectedIDs.isSuperset(of: allIDs) {
                            selectedIDs.subtract(allIDs)
                        } else {
                            selectedIDs.formUnion(allIDs)
                        }
                    },
                    onDelete: {
                        guard !selectedIDs.isEmpty else { return }
                        showDeleteConfirm = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: multiSelectMode)
        .sheet(item: $editHealth) { h in
            EditHealthView(metric: h)
        }
        .alert(NSLocalizedString("common.confirmDelete", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { }
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                batchDeleteHealth()
            }
        } message: {
            Text(String(format: NSLocalizedString("common.deleteCount", comment: ""), selectedIDs.count))
        }
        .overlay {
            // 睡眠遮罩：与首页同口径。健康页入睡→盖遮罩；遮罩「我醒了」→居中大卡 toast；
            // 「先用一下 App」→仅收遮罩不结束睡眠。本页被 push 于首页同一 NavigationStack，
            // 其 GlobalToastOverlay 在健康页同样可见，无需重复挂载。
            if showSleepMask {
                SleepMaskOverlay(
                    session: activeSleepSession,
                    show: showSleepMask,
                    onWake: {
                        // toggle 返回 nil=确实醒来（之前在睡）；用 fallback 取 sleepStart 保证文案准确，
                        // 不再依赖 activeSleepSession 闭包快照（iCloud/冷启动延迟时可能取不到）。
                        let _ = toggleSleepSession(in: context, sleeps: sleeps)
                        let start = ContentView.activeSleepSessionStartFallback(context: context)
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.3)) { showSleepMask = false }
                            // 延后到遮罩淡出后弹 toast，避免被遮罩盖住。
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                ToastCenter.shared.showImportant(
                                    sleepSummaryText(start: start),
                                    icon: "🌙",
                                    accent: AIATheme.warning
                                )
                            }
                        }
                    },
                    onDismiss: {
                        // 「先用一下 App」：不结束睡眠，仅收起遮罩；
                        // 记住本次会话已主动收起（与首页共享）→ 同一睡眠内两页都不再自动盖回。
                        sharedSleepMaskDismissedSessionID = activeSleepSession?.syncId
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.3)) { showSleepMask = false }
                        }
                    }
                )
                .transition(.opacity)
            }
        }
    }

    private func deleteHealth(_ h: HealthMetric) {
        SafeDelete.health(h, in: context)
    }

    // MARK: 多选删除

    private func enterHealthMultiSelect(_ id: PersistentIdentifier) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        multiSelectMode = true
        selectedIDs.insert(id)
    }

    private func toggleHealthSelection(_ id: PersistentIdentifier) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedIDs.isEmpty { multiSelectMode = false }
        } else {
            selectedIDs.insert(id)
        }
    }

    private func batchDeleteHealth() {
        for id in selectedIDs {
            SafeDelete.healthByID(id, in: context)
        }
        multiSelectMode = false
        selectedIDs.removeAll()
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

/// 健康页横条右侧的睡眠切换按钮：空闲显示「😴 入睡」（紫），在睡显示「☀️ 醒来 + 已睡时长」（琥珀）。
/// 独立 Button，不嵌套在左侧健康目标按钮内（项目铁律：Button 不嵌 Button）。
/// 用 TimelineView 每 1s 重渲一次，使「已睡时长」在睡眠中实时走动。
private struct SleepToggleButton: View {
    let activeSession: SleepSession?
    /// 已醒的最近一条睡眠会话，用于「元气满满」态下方显示「上次入睡时间 + 睡眠时长」。
    let lastFinishedSession: SleepSession?
    let onToggle: () -> Void

    /// 「正在睡」= 有进行中的会话。
    /// activeSession 由父视图 `HealthListView.activeSleepSession` 提供，已过滤掉 wakeAt != nil 的旧数据，
    /// 所以这里只需判断非空即可——原写法 `activeSession?.wakeAt == nil` 会在 activeSession 为 nil
    /// （空闲 / 刚醒来）时也返回 true（nil == nil），导致醒来后按钮仍显示「正在梦乡里」。
    private var isSleeping: Bool { activeSession != nil }
    /// 状态色：空闲=紫（AIATheme.health），在睡=琥珀（AIATheme.warning）。
    private var accentColor: Color { isSleeping ? AIATheme.warning : AIATheme.health }

    @State private var flipped = false
    @State private var timer: Timer?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Button(action: {
                onToggle()
                flipped = false
            }) {
                ZStack {
                    frontFace
                        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                        .opacity(flipped ? 0 : 1)
                    backFace
                        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                        .opacity(flipped ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AIATheme.rMD, style: .continuous)
                        .stroke(accentColor.opacity(0.25), lineWidth: 0.5)
                )
            }
            .buttonStyle(WaterCardButtonStyle())
        }
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    private var frontFace: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                // 图标语义是「当前状态」：在睡=moon（梦乡里），空闲=sun（元气满满）。
                Image(systemName: isSleeping ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 24, height: 24)
                    .background(accentColor.opacity(0.18))
                    .clipShape(Circle())
                Text(isSleeping ? "正在梦乡里💤" : "元气满满")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(accentColor)
            }
            if isSleeping, let start = activeSession?.sleepStart {
                Text(formatSleepDuration(Date().timeIntervalSince(start)))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(accentColor.opacity(0.8))
            } else if !isSleeping, let last = lastFinishedSession {
                // 空闲态（元气满满）：下方一行小字 = 上次入睡时间 + 上次睡眠时长
                Text("上次入睡 \(formatClock(last.sleepStart)) · \(formatSleepDuration(sleepSessionDuration(last)))")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(accentColor.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backFace: some View {
        VStack(spacing: 4) {
            Image(systemName: isSleeping ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 24, height: 24)
                .background(accentColor.opacity(0.18))
                .clipShape(Circle())
            Text(isSleeping ? "点击起床" : "点击入睡")
                .font(AIATheme.Font.footnote.weight(.semibold))
                .foregroundStyle(accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
    }

    private func startTimer() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.9)) { flipped.toggle() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 把 Date 格式化为「HH:mm」，用于「上次入睡时间」展示。
    private func formatClock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func formatSleepDuration(_ sec: TimeInterval) -> String {
        let total = Int(sec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return "\(h)h\(m)m\(s)s"
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
    /// 点击账单记录直接弹出「编辑账单」页（sheet 呈现 EditBillView，与其设计意图一致）
    @State private var editBill: Bill? = nil
    /// 右上角加号 → 弹出「添加账单」页（与编辑共用 EditBillView，加 isAdding: true）
    @State private var addBillDraft: Bill? = nil

    // MARK: 多选删除
    @State private var multiSelectMode = false
    @State private var selectedIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm = false

    // MARK: 商户搜索筛选（仅「全部」标签的账单详情列表）
    @State private var merchantQuery: String = ""
    @FocusState private var merchantSearchFocused: Bool
    /// 商户搜索框获得焦点时，把搜索框滚到列表顶部（ScrollViewReader + nonce 计数器触发，
    /// 兼容 iOS 17，避免用 iOS 18 的 ScrollPosition）。非 0 才滚动，避免首次渲染误触发。
    @State private var scrollToBillTopNonce: Int = 0
    /// 近7日消费柱状图生长动画触发标志（进入延迟触发、离开重置，便于重播）。
    @State private var barsRevealed = false
    @State private var chartWeekOffset: Int = 0   // 近7日消费图翻周：0=本周，负=过去第 |n| 周

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

    /// 近 7 日每日消费（支出，不含收入），用于「近7日消费」柱状图。
    /// 顺序与热量/步数图一致：左旧 → 右今（index 0 = 6 天前，index 6 = 今天）。
    /// 近 7 日消费柱状数据。`offset` 为 0 表示本周，负数表示过去第 |offset| 周。
    private func weekSpend(offset: Int = 0) -> [ChartPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: offset * 7, to: today)!
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: end)!
            let start = cal.startOfDay(for: d)
            let endDay = cal.date(byAdding: .day, value: 1, to: start)!
            let sum = bills.filter { !$0.isIncome && $0.time >= start && $0.time < endDay }
                            .reduce(0) { $0 + $1.amount }
            return ChartPoint(label: dayFmt.string(from: d), value: sum)
        }
    }

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
        case .all: return bills            // 全部历史账单（替代 monthBills）
        case .month, .calendar: return monthBills
        }
    }
    /// 商户搜索筛选后的账单列表（跨月搜索）：
    /// - 搜索词为空 → 沿用当前「全部」标签的本月账单（filtered），保持原有行为；
    /// - 搜索词非空 → 在全部历史账单中，按以下字段（不区分大小写）匹配：
    ///   商户、分类、备注（字符串包含）；金额（数值相等，容差 0.005，或格式化字符串包含）；
    ///   消费日期、消费时间（按当前区域格式化后包含）。
    private static let searchDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = Locale.current
        return f
    }()
    private static let searchTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.locale = Locale.current
        return f
    }()
    private var merchantFilteredBills: [Bill] {
        let q = merchantQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return filtered }
        let qAmount = Double(q)
        return bills.filter { bill in
            if bill.merchant.localizedCaseInsensitiveContains(q) { return true }
            if bill.category.localizedCaseInsensitiveContains(q) { return true }
            if bill.note.localizedCaseInsensitiveContains(q) { return true }
            if let qAmount, abs(bill.amount - qAmount) < 0.005 { return true }
            if String(format: "%.2f", bill.amount).localizedCaseInsensitiveContains(q) { return true }
            if Self.searchDateFmt.string(from: bill.time).localizedCaseInsensitiveContains(q) { return true }
            if Self.searchTimeFmt.string(from: bill.time).localizedCaseInsensitiveContains(q) { return true }
            return false
        }
    }
    private var groupedByDate: [(date: Date, bills: [Bill])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: merchantFilteredBills) { cal.startOfDay(for: $0.time) }
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

    // MARK: - 顶部圆环轮播（两页，左右滑动切换）
    // 2026-08-13：改用 ScrollView(.horizontal, paging) 替代 TabView(.page)。
    // 根因：TabView(.page) 的翻页拖拽手势与内部圆环 Button 的点击手势在老芯片(A12/XS Max)上竞争，
    // 表现为第 2 页左半边「本周账单」点不动。ScrollView 的分页手势更轻、不会吞内部 Button 点击。
    @State private var carouselID: Int? = 0
    private var summaryCarousel: some View {
        // 2026-08-13 二次修正：弃用手算 pageW，改用项目内已验证的标准 paging 写法
        // （.scrollTargetLayout + .containerRelativeFrame(.horizontal) + .scrollPosition(id:)，
        // 参考 AdBanner.swift 250-262 行）。
        // 根因：手算 pageW 依赖外层 .padding(12) 的精确尺寸，一旦容器再有额外 padding（如父级
        // 卡片或屏幕安全区不同）就错位，导致第 1 页 HStack 比可视区宽或窄，左卡右卡分摊不均、Divider 偏。
        // containerRelativeFrame 让 SwiftUI 自动让每页 = ScrollView 可视区宽，根本不存在算错问题。
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    // 第 1 页：今日账单 + 本月账单
                    HStack(spacing: 0) {
                        summaryDonutCard(titleKey: "bill.today", bills: todayExpenseBills, mode: .week)
                            .frame(maxWidth: .infinity)
                        Divider().frame(width: 1, height: 120)
                        summaryDonutCard(titleKey: "bill.thisMonth", bills: monthExpenseBills, mode: .month)
                            .frame(maxWidth: .infinity)
                    }
                    .containerRelativeFrame(.horizontal)
                    .frame(height: 160)
                    .id(0)

                    // 第 2 页：本周账单 + 本年账单
                    HStack(spacing: 0) {
                        summaryDonutCard(titleKey: "bill.thisWeek", bills: weekExpenseBills, mode: .week)
                            .frame(maxWidth: .infinity)
                        Divider().frame(width: 1, height: 120)
                        summaryDonutCard(titleKey: "bill.thisYear", bills: yearExpenseBills, mode: .year)
                            .frame(maxWidth: .infinity)
                    }
                    .containerRelativeFrame(.horizontal)
                    .frame(height: 160)
                    .id(1)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $carouselID)
            .frame(height: 160)

            // 底部小圆点指示当前页
            HStack(spacing: 6) {
                ForEach(0..<2) { i in
                    Circle()
                        .fill((carouselID ?? 0) == i ? AIATheme.bill : AIATheme.muted.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }

            Text(NSLocalizedString("bill.carousel.hint", comment: ""))
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
    }

    private func summaryDonutCard(titleKey: String, bills: [Bill], mode: BillDashboardMode) -> some View {
        let categories = expenseByCategory(for: bills)
        let total = bills.reduce(0) { $0 + $1.amount }
        return Button { NavigationRouter.shared.navigate(.billDashboard(mode)) } label: {
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
                    ForEach(Array(categories.prefix(3)), id: \.cat) { item in
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
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(spacing: 0) {
            SegmentedPicker(options: BillFilter.allCases.map { (value: $0, label: $0.label) }, selection: $filter)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 6)

            ScrollViewReader { billProxy in
                ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if filter == .all {
                        // 聚合入口：周期记账 / 账单导入 / 自动记账
                        // 2026-07-24：改编程式 push 走根 NavigationStack(path:)，跟 TodoToolsView 入口同源。
                        // 根因：原闭包 NavigationLink 把 BillToolsView 推到 BillListView 子栈，
                        // 但 BillToolsView 内部 path.append(.autoSetup) 改的是根栈 → BillToolsView 从根栈消失，
                        // 自动截屏识别返回时直接回 BillListView，绕过了「记账工具」。
                        Button {
                            NavigationRouter.shared.navigate(HomeRoute.billTools)
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

                    // Card · 月度预算（去掉「预算」标题，收紧内边距让卡片更矮）
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            editedBudget = monthlyBudget
                            showBudgetEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(String(format: NSLocalizedString("bill.monthlyBudget", comment: ""), Int(monthlyBudget)))
                                        .font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
                                    Image(systemName: "pencil")
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.muted)
                                    Spacer()
                                    Text(String(format: NSLocalizedString("bill.budgetUsed", comment: ""), monthlyBudget > 0 ? Int(monthExpenseTotal / monthlyBudget * 100) : 0))
                                        .font(AIATheme.Font.caption.weight(.medium))
                                }
                                MiniBar(value: monthlyBudget > 0 ? monthExpenseTotal / monthlyBudget : 0, color: AIATheme.bill)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

                        summaryCarousel
                            .padding(12)
                            .card(radius: AIATheme.rMD)

                    // Card · 近7日消费（可左右滑动翻看过去 8 周，每屏重播生长动画）
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: NSLocalizedString("bill.last7days", comment: ""),
                                     trailing: chartWeekRangeLabel(offset: chartWeekOffset, base: Date()))
                        TabView(selection: $chartWeekOffset) {
                            ForEach(Array((-8)...0), id: \.self) { off in
                                let data = weekSpend(offset: off)
                                Group {
                                    if data.allSatisfy({ $0.value == 0 }) {
                                        Text(NSLocalizedString("bill.week.empty", comment: ""))
                                            .font(AIATheme.Font.micro)
                                            .foregroundStyle(AIATheme.sub)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                    } else {
                                        GrowthBars(data: data,
                                                   accent: AIATheme.bill,
                                                   maxValue: data.map(\.value).max() ?? 1,
                                                   revealed: barsRevealed,
                                                   abbreviate: false)
                                    }
                                }
                                .tag(off)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 100)
                        ChartPageDots(selection: chartWeekOffset, minOffset: -8, accent: AIATheme.bill)
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)
                    .task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        barsRevealed = true
                    }
                    .onChange(of: chartWeekOffset) { _, _ in
                        withAnimation(.none) { barsRevealed = false }
                        Task {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            barsRevealed = true
                        }
                    }
                    .onDisappear { barsRevealed = false }
                    }

                    // 商户搜索框：仅「全部」标签可见，作用于账单详情列表（跨月搜索），置于账单列表区域顶部
                    if filter == .all {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(AIATheme.Font.callout)
                                .foregroundStyle(AIATheme.sub)
                            ZStack(alignment: .leading) {
                                if merchantQuery.isEmpty {
                                    Text(NSLocalizedString("bill.searchMerchant", comment: ""))
                                        .font(AIATheme.Font.body)
                                        .foregroundStyle(AIATheme.sub)
                                        .allowsHitTesting(false)
                                }
                                TextField("", text: $merchantQuery)
                                    .font(AIATheme.Font.body)
                                    .foregroundStyle(.primary)
                                    .focused($merchantSearchFocused)
                                    .textInputAutocapitalization(.never)
                                    .frame(maxWidth: .infinity)
                            }
                            if !merchantQuery.isEmpty {
                                Button {
                                    merchantQuery = ""
                                    merchantSearchFocused = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(AIATheme.Font.title3)
                                        .foregroundStyle(AIATheme.sub)
                                }
                            }
                        }
                        .padding(12)
                        .background(AIATheme.surface)
                        .overlay(RoundedRectangle(cornerRadius: AIATheme.rSM).stroke(AIATheme.hairline, lineWidth: 1).allowsHitTesting(false))
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                        .padding(.bottom, 8)
                        .id("billDetailTop")
                    }

                    if filter == .calendar {
                        billCalendarView
                    } else if filter == .month {
                        VStack(alignment: .leading, spacing: 8) {
                            // 月报 / 数据导出入口：按月导出 CSV、生成月报图片分享
                            Button {
                                NavigationRouter.shared.navigate(.monthlyReport)
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

                            // monthlyGroups 派生自 @Query，数组长度变化时用元素遍历避免下标越界。
                            // 用 (year*100+month) 作稳定唯一 id，不用 offset（数组缩短时旧索引会访问越界）。
                            ForEach(monthlyGroups.map { g in (id: g.year * 100 + g.month, group: g) }, id: \.id) { item in
                                Button {
                                    NavigationRouter.shared.navigate(.monthlyBillList(year: item.group.year, month: item.group.month))
                                } label: {
                                    monthlySummaryRow(item.group)
                                }
                                .buttonStyle(.plain)
                                // 月份卡片之间加 hairline 分隔，最后一张不画
                                if item.id != monthlyGroups.last.map({ $0.year * 100 + $0.month }) {
                                    Rectangle()
                                        .fill(AIATheme.hairline)
                                        .frame(height: 0.7)
                                        .padding(.horizontal, 12)
                                }
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
                                action: { NavigationRouter.shared.navigate(.autoSetup) }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if merchantFilteredBills.isEmpty {
                        if !merchantQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // 搜索无结果：展示按商户名搜索的空态
                            VStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 40))
                                    .foregroundStyle(AIATheme.muted)
                                Text(String(format: NSLocalizedString("bill.searchEmpty", comment: ""), merchantQuery))
                                    .font(AIATheme.Font.subhead)
                                    .foregroundStyle(AIATheme.muted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            EmptyStateView(
                                kind: .bill,
                                title: "",
                                message: "",
                                actionTitle: "查看自动记账教程",
                                action: { NavigationRouter.shared.navigate(.autoSetup) },
                                footer: "点击底部拍照、相册上传小票、账单\n或点击文字输入、语音输入\n也可使用AI快速记账哦"
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        // 直接遍历元素（不再用 ForEach(0..<count) + groupedByDate[i] 下标）：
                        // groupedByDate 派生自 @Query，导航 onAppear 的 RecurringBillManager.generateDue
                        // 插入账单/提醒时数组长度会变化，两次求值不一致会导致 groupedByDate[i] 越界闪退。
                        // 用 enumerated() 取 offset 作 id，避免 tuple 需 Hashable 且保证单次 render 内稳定。
                        ForEach(Array(groupedByDate.enumerated()), id: \.element.date) { idx, group in
                            // 日期组之间加 hairline 分隔（第一个不加，避免与上方"账单详情"标题区冲突）
                            if idx > 0 {
                                Rectangle()
                                    .fill(AIATheme.hairline)
                                    .frame(height: 0.7)
                                    .padding(.top, 14)
                                    .padding(.bottom, 2)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                dateHeader(group.date, bills: group.bills)
                                ForEach(Array(group.bills.enumerated()), id: \.element.persistentModelID) { idx, b in
                                    SelectableRow(
                                        isSelecting: multiSelectMode,
                                        isSelected: selectedIDs.contains(b.persistentModelID),
                                        onTap: { editBill = b },
                                        onLongPress: { enterMultiSelect(b.persistentModelID) },
                                        onToggle: { toggleSelection(b.persistentModelID) },
                                        onDelete: {
                                            SafeDelete.billByID(b.persistentModelID, in: context)
                                            CloudSyncManager.shared.syncAfterLocalChange(context: context)
                                        }
                                    ) {
                                        groupedBillRow(b)
                                    }
                                    // 行间分隔：让位 62pt（icon 42 + 间距 12 + 缓冲 8），最后一行不画
                                    if idx < group.bills.count - 1 {
                                        Rectangle()
                                            .fill(AIATheme.hairline)
                                            .frame(height: 0.7)
                                            .padding(.leading, 62)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .onChange(of: scrollToBillTopNonce) { _, _ in
                guard scrollToBillTopNonce != 0 else { return }
                // 等键盘布局完成后再滚动，确保搜索框稳定停在列表区域最顶部，
                // 不被系统「最小滚动露出输入框」的键盘避让逻辑抵消。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        billProxy.scrollTo("billDetailTop", anchor: .top)
                    }
                }
            }
            }
            AIBottomBar(prompts: [
                AIPrompt(text: "点拍照识别、记录账单、小票", pointsTo: .camera),
                AIPrompt(text: "今天花了多少钱？点此小记帮你记", pointsTo: nil),
                AIPrompt(text: "点麦克风，语音记录账单", pointsTo: .mic),
                AIPrompt(text: "小记帮总结这个月的消费情况", pointsTo: nil),
                AIPrompt(text: "点相册上传，自动记账", pointsTo: .album)
            ], entrySource: "bill")
        }
        .onChange(of: merchantSearchFocused) { _, focused in
            if focused {
                // 触发 ScrollViewReader 滚到搜索框顶部（billProxy 在 reader 内处理）。
                scrollToBillTopNonce += 1
            }
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(LocalizedStringKey("tab.bill"))
        .task { UsageAnalytics.logOpen("bill") }
        .toolbar {
            if !multiSelectMode {
                // 右上角 + 号 → 手动添加账单（与编辑账单共用 EditBillView，加 isAdding: true 切换 title + 隐藏删除按钮）
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addNewBill() } label: {
                        Image(systemName: "plus")
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(AIATheme.blue)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if multiSelectMode {
                MultiSelectBottomBar(
                    count: selectedIDs.count,
                    totalCount: groupedByDate.reduce(0) { $0 + $1.bills.count },
                    onCancel: {
                        multiSelectMode = false
                        selectedIDs.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allIDs = Set(groupedByDate.flatMap(\.bills).map(\.persistentModelID))
                        if selectedIDs.isSuperset(of: allIDs) {
                            selectedIDs.subtract(allIDs)
                        } else {
                            selectedIDs.formUnion(allIDs)
                        }
                    },
                    onDelete: {
                        guard !selectedIDs.isEmpty else { return }
                        showDeleteConfirm = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: multiSelectMode)
        .alert(NSLocalizedString("common.confirmDelete", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { }
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                batchDelete()
            }
        } message: {
            Text(String(format: NSLocalizedString("common.deleteCount", comment: ""), selectedIDs.count))
        }
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker, navigateToChat: true)
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
        // 点击空白处收起商户搜索键盘（点击 TextField / 按钮等可交互控件不会触发）
        .onTapGesture {
            merchantSearchFocused = false
        }
        // 点击账单记录直接弹出「编辑账单」页（EditBillView 自带 NavigationStack，作为 sheet 呈现最契合其设计）
        .sheet(item: $editBill) { b in
            EditBillView(bill: b)
        }
        // 右上角 + 号 → 手动添加账单（草稿 Bill 已在 addNewBill 时软删除，@Query 过滤掉；保存时复活）
        .sheet(item: $addBillDraft) { b in
            EditBillView(bill: b, isAdding: true)
        }
    }

    /// 右上角 + 号 action：创建临时草稿 Bill（syncDeleted=true 软删除，被 @Query 谓词过滤，sheet 期间背景不显示空账单）→ 存到 addBillDraft 触发 sheet
    private func addNewBill() {
        let draft = Bill(
            merchant: "",
            amount: 0,
            category: "餐饮",  // 默认"餐饮"（icon=😋），最常用；用户可在 sheet 内改其他
            time: .now,
            confirmed: true
        )
        draft.syncDeleted = true  // 软删除：@Query #Predicate { !$0.syncDeleted } 过滤掉，sheet 期间账单列表背景干净
        context.insert(draft)
        addBillDraft = draft
    }

    // MARK: 多选删除

    private func enterMultiSelect(_ id: PersistentIdentifier) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        multiSelectMode = true
        selectedIDs.insert(id)
    }

    private func toggleSelection(_ id: PersistentIdentifier) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedIDs.isEmpty { multiSelectMode = false }
        } else {
            selectedIDs.insert(id)
        }
    }

    private func batchDelete() {
        for id in selectedIDs {
            SafeDelete.billByID(id, in: context)
        }
        multiSelectMode = false
        selectedIDs.removeAll()
    }

    private func dateHeader(_ date: Date, bills: [Bill]) -> some View {
        let expense = bills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
        let income = bills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
        let isToday = Calendar.current.isDateInToday(date)
        let dateText = isToday ? "今天 \(AppFormat.monthDay.string(from: date))（\(weekdayText(date))）" : "\(AppFormat.monthDay.string(from: date))（\(weekdayText(date))）"
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
                Text("\(AppFormat.hourMinute.string(from: b.time)) | \(b.merchant)")
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
        SafeDelete.billByID(b.persistentModelID, in: context)
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
    }

    // MARK: - 账单日历视图（在日历查看）
    private var billCalendarView: some View {
        VStack(spacing: 12) {
            // 月份切换
            HStack {
                Button { billCalendarMonth = billPrevMonth } label: {
                    Image(systemName: "chevron.left")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                        .frame(width: 36, height: 36)
                        .background(AIATheme.blue.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(billMonthTitle)
                    .font(AIATheme.Font.callout.weight(.medium))
                .buttonStyle(.plain)
                Spacer()
                Button { billCalendarMonth = billNextMonth } label: {
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                        .frame(width: 36, height: 36)
                        .background(AIATheme.blue.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
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
            // 2026-07-29：同待办日历 —— [Date?] 的多个 nil 用 id: \.self 会重复 ID，
            // 导致月末行点击后选中态不重绘，必须用 offset 作 id。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                ForEach(Array(billDaysInMonthView.enumerated()), id: \.offset) { _, date in
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
                VStack(alignment: .leading, spacing: 8) {
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

                        // 选中日期账单列表：行间 hairline 分隔（深色模式 0.7pt 物理宽度足够醒目）
                        ForEach(Array(dayBills.enumerated()), id: \.element.persistentModelID) { idx, b in
                            SelectableRow(
                                isSelecting: false,
                                isSelected: false,
                                onTap: { editBill = b },
                                onToggle: {},
                                onDelete: { deleteBill(b) }
                            ) {
                                groupedBillRow(b)
                            }
                            // 行间分隔：让位 62pt（icon 42 + 间距 12 + 缓冲 8），最后一行不画
                            if idx < dayBills.count - 1 {
                                Rectangle()
                                    .fill(AIATheme.hairline)
                                    .frame(height: 0.7)
                                    .padding(.leading, 62)
                            }
                        }
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
    /// 识别来源标记（RecogSource 1:1 关联 Reminder.syncId），用于每行显示「免费版AI识别/Pro版AI…」
    @Query private var recogSources: [RecogSource]
    private var recogSourceBySyncId: [UUID: String] {
        Dictionary(uniqueKeysWithValues: recogSources.map { ($0.syncId, $0.recogSourceRaw) })
    }
    @State private var filter: TodoFilter = .active
    @State private var calendarMonth = Date()
    @State private var selectedDate: Date? = Date()
    /// 点行触发的「编辑待办」sheet（2026-07-24：从 navigationDestination 推页改为 .sheet 弹起，
    /// 与「编辑账单」一致；首页行点击走 EditTodoSheet，与 AllRecordsView 入口统一为 sheet 体验）
    @State private var editTodo: Reminder?
    /// 右上角 + 号触发的「添加待办」sheet（仿 BillListView.addBillDraft：草稿 Reminder syncDeleted=true
    /// 被 @Query 过滤，sheet 期间背景干净；保存时 syncDeleted=false 复活显示）
    @State private var addTodoDraft: Reminder?

    // MARK: 多选删除
    @State private var multiSelectMode = false
    @State private var selectedIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm = false

    // MARK: 长按拖动改期（方案 A：长按整行 = 抬起，拖到日期 header 改 due）
    /// key=TodoGroup?：
    ///   - .day(d) 表示某天的 header
    ///   - .overdue 表示「已逾期事件」header
    ///   - nil 表示「未安排」组
    /// 收集各 header 的全局矩形，拖动中实时命中检测。
    private struct TodoHeaderFrameKey: PreferenceKey {
        static var defaultValue: [TodoGroup?: CGRect] { [:] }
        static func reduce(value: inout [TodoGroup?: CGRect], nextValue: () -> [TodoGroup?: CGRect]) {
            for (k, v) in nextValue() { value[k] = v }
        }
    }
    /// 收集每个待办行的全局矩形 + 所属分组，用于拖动时计算「行级插入点」，
    /// 从而实现「拖动时其余行实时让位（live reflow）」的直观反馈。
    /// 用显式结构体（而非元组）承载：Swift 中元组不遵守 Equatable 协议，
    /// 会导致 [String: Tuple] 无法满足 onPreferenceChange 要求的 Equatable。
    private struct TodoRowFrame: Equatable {
        let frame: CGRect
        let group: TodoGroup
    }
    private struct TodoRowFrameKey: PreferenceKey {
        static var defaultValue: [String: TodoRowFrame] { [:] }
        static func reduce(value: inout [String: TodoRowFrame],
                          nextValue: () -> [String: TodoRowFrame]) {
            for (k, v) in nextValue() { value[k] = v }
        }
    }
    @State private var draggingSyncId: String? = nil   // 正在拖动改期的待办 syncId
    @State private var isDragging = false
    @State private var hoverGroup: TodoGroup?? = nil    // 当前悬停的组（外层 nil=未悬停在任何 header；内层 nil=未安排组）
    @State private var hoveringHeader = false           // 是否真的悬停在某个 header 上
    @State private var headerFrames: [TodoGroup?: CGRect] = [:]
    // 行级实时让位（live reflow）所需状态：
    @State private var rowFrames: [String: TodoRowFrame] = [:]
    @State private var dragLocation: CGPoint = .zero      // 手指当前全局坐标（LongPressDragView.onChanged）
    @State private var dragStartLocation: CGPoint = .zero  // 长按成立时手指坐标，用于判定"是否已移动"
    @State private var dragGrabOffset: CGSize = .zero      // 手指相对行中心的偏移，浮起卡片保持该相对关系避免跳位
    @State private var dropIndex: DropIndex? = nil  // 目标插入点（所在组 + 组内索引）
    @State private var draggedRowHeight: CGFloat = 56     // 被拖行高度，用于让位位移量
    @State private var longPressArmed = false           // 长按成立后临时启用改期拖拽（默认 false → 不挂任何手势，滚动不受扰）
    private var active: [Reminder] {
        // 含「未安排截止」的待办：due == nil 的也保留在底部，以保持与首页宫格 `recentTodos` 的来源一致。
        // 这样「测试不提醒」这种测试用例在两个地方都能看到、能删能改。
        reminders.filter { !$0.done }
            .sorted { a, b in
                switch (a.due, b.due) {
                case (nil, nil):   return a.title < b.title
                case (nil, _):     return false   // 无 due 排到底部
                case (_, nil):     return true
                case let (d1?, d2?): return d1 < d2
                }
            }
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
    /// 待办分组键：`overdue`(已逾期) / `day(Date)`(某天) / `unscheduled`(未安排)。
    /// overdue 永远是第一组、unscheduled 永远是最后一组；中间按日期排序。
    /// 拖拽时的目标插入点（所在组 + 组内索引）。用显式结构体以满足 Equatable，
    /// 供 `.animation(value:)` 使用（匿名标签元组 `(group:at:)` 不自动遵守 Equatable）。
    private struct DropIndex: Equatable {
        let group: TodoGroup
        let at: Int
    }
    private enum TodoGroup: Hashable {
        case overdue
        case day(Date)
        case unscheduled
    }

    private var groupedByDate: [(group: TodoGroup, reminders: [Reminder])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // 排序方向按当前 filter 区分：
        //   - 未完成：日期升序（最早/快过期的在前——"先做快过期的"）
        //   - 已完成：日期倒序（最近完成日期在前——用户视角"最近都完成了什么"）
        let descending = filter == .finished
        // 已完成项不存在"逾期"概念（逾期描述的是「截止日早于今天」，
        // 已完成项的 due 是历史截止日，按"今天"比对总会落在 overdue，体感违和），
        // 所以只在未完成列表里走 .overdue 分支；已完成列表全部按 due 日期正常分组。
        let showOverdue = filter != .finished
        let grouped = Dictionary(grouping: list) { r -> TodoGroup in
            guard let due = r.due else { return .unscheduled }
            let day = cal.startOfDay(for: due)
            if showOverdue && day < today { return .overdue }
            return .day(day)
        }
        return grouped.sorted { a, b in
            switch (a.key, b.key) {
            case (.overdue, .overdue): return false
            case (.overdue, _): return true                          // 已逾期永远在最前
            case (_, .overdue): return false
            case (.unscheduled, .unscheduled): return false
            case (.unscheduled, _): return false                    // 未安排永远在最底
            case (_, .unscheduled): return true
            case let (.day(d1), .day(d2)): return descending ? d1 > d2 : d1 < d2
            default: return false
            }
        }.map { (group: $0.key, reminders: $0.value.sorted {
            // 同组内：未完成升序（早 due 先）、已完成倒序（晚 due 后完成的在前）
            let l = ($0.due ?? .distantPast), r = ($1.due ?? .distantPast)
            return descending ? l > r : l < r
        }) }
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
    @ViewBuilder
    private func dateHeader(_ group: TodoGroup, reminders: [Reminder]) -> some View {
        switch group {
        case .overdue:
            // 「已逾期事件」是计算状态，但仍可作为长按拖拽目标：
            // 拖到这儿等于"恢复一个逾期项到逾期区"——通常不会有人这么干，但实现上跟其他 header 一致。
            let highlighted = isDragging && hoveringHeader && hoverGroup == .some(.overdue)
            HStack(spacing: 0) {
                Text("已逾期事件")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(highlighted ? AIATheme.over.opacity(0.85) : AIATheme.over)
                Spacer()
                Text("\(reminders.count)项")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(.vertical, 4)
            .background(highlighted ? AIATheme.over.opacity(0.12) : Color.clear)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TodoHeaderFrameKey.self, value: [TodoGroup.overdue: geo.frame(in: .global)])
                }
            )
        case .day(let date):
            let isToday = Calendar.current.isDateInToday(date)
            let dateText = isToday ? "今天 \(AppFormat.monthDay.string(from: date))（\(weekdayText(date))）" : "\(AppFormat.monthDay.string(from: date))（\(weekdayText(date))）"
            let highlighted = isDragging && hoveringHeader && hoverGroup == .some(.day(date))
            HStack(spacing: 0) {
                Text(dateText)
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(highlighted ? AIATheme.blue : .primary)
                Spacer()
                Text("\(reminders.count)项")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(.vertical, 4)
            .background(highlighted ? AIATheme.blue.opacity(0.12) : Color.clear)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TodoHeaderFrameKey.self, value: [TodoGroup.day(date): geo.frame(in: .global)])
                }
            )
        case .unscheduled:
            let highlighted = isDragging && hoveringHeader && hoverGroup == .some(nil)
            HStack(spacing: 0) {
                Text("未安排")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(highlighted ? AIATheme.blue : .primary)
                Spacer()
                Text("\(reminders.count)项")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(.vertical, 4)
            .background(highlighted ? AIATheme.blue.opacity(0.12) : Color.clear)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TodoHeaderFrameKey.self, value: [nil: geo.frame(in: .global)])
                }
            )
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

            todoListView()
            AIBottomBar(prompts: [
                AIPrompt(text: "点拍照识别、记录待办", pointsTo: .camera),
                AIPrompt(text: "有什需要提醒的吗？点此小记帮你记", pointsTo: nil),
                AIPrompt(text: "点麦克风，语音记录待办", pointsTo: .mic),
                AIPrompt(text: "小记帮总结最近有什么事要做", pointsTo: nil),
                AIPrompt(text: "点相册上传，自动识别待办", pointsTo: .album)
            ], entrySource: "todo")
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(LocalizedStringKey("tab.todo"))
        .task { UsageAnalytics.logOpen("todo") }
        .toolbar {
            if !multiSelectMode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        multiSelectMode = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(AIATheme.blue)
                    }
                }
                addTodoToolbarItem
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        multiSelectMode = false
                        selectedIDs.removeAll()
                    } label: {
                        Text("取消").font(AIATheme.Font.body.weight(.semibold)).foregroundStyle(AIATheme.blue)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if multiSelectMode {
                MultiSelectBottomBar(
                    count: selectedIDs.count,
                    totalCount: list.count,
                    onCancel: {
                        multiSelectMode = false
                        selectedIDs.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allIDs = Set(list.map(\.persistentModelID))
                        if selectedIDs.isSuperset(of: allIDs) {
                            selectedIDs.subtract(allIDs)
                        } else {
                            selectedIDs.formUnion(allIDs)
                        }
                    },
                    onDelete: {
                        guard !selectedIDs.isEmpty else { return }
                        showDeleteConfirm = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: multiSelectMode)
        .alert(NSLocalizedString("common.confirmDelete", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { }
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                batchDeleteTodo()
            }
        } message: {
            Text(String(format: NSLocalizedString("common.deleteCount", comment: ""), selectedIDs.count))
        }
        // 点行 → 弹「编辑待办」sheet（与「编辑账单」一致：从下方弹出，背景能看到首页；
        // sheet 顶左「取消」/ 顶右「保存」由 EditTodoView.toolbar 提供）
        .sheet(item: $editTodo) { r in
            EditTodoSheet(reminder: r)
        }
        // 右上角 + 号 → 弹「添加待办」sheet（isAdding=true：title="添加待办" + 隐藏删除按钮）
        .sheet(item: $addTodoDraft) { r in
            EditTodoSheet(reminder: r, isAdding: true)
        }
    }

    /// 右上角 + 号 → 手动添加待办 toolbar（与 BillListView 蓝「+」同款；拆出独立 ToolbarContent 子 view
    /// 帮编译器避开 toolbar/Sheet 链路过长导致的 type-check timeout）
    @ToolbarContentBuilder
    private var addTodoToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { addNewTodo() } label: {
                Image(systemName: "plus")
                    .font(AIATheme.Font.body.weight(.semibold))
                    .foregroundStyle(AIATheme.blue)
            }
        }
    }

    /// 右上角 + 号 action：创建临时草稿 Reminder（syncDeleted=true 软删除，被 @Query 谓词过滤，
    /// sheet 期间背景不显示空待办）→ 存到 addTodoDraft 触发 sheet
    private func addNewTodo() {
        let draft = Reminder(title: "")
        draft.syncDeleted = true
        context.insert(draft)
        addTodoDraft = draft
    }

    // MARK: 多选删除

    private func enterTodoMultiSelect(_ id: PersistentIdentifier) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        multiSelectMode = true
        selectedIDs.insert(id)
    }

    private func toggleTodoSelection(_ id: PersistentIdentifier) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedIDs.isEmpty { multiSelectMode = false }
        } else {
            selectedIDs.insert(id)
        }
    }

    private func batchDeleteTodo() {
        for id in selectedIDs {
            SafeDelete.reminderByID(id, in: context)
        }
        multiSelectMode = false
        selectedIDs.removeAll()
    }

    // MARK: - 日历视图
    private var calendarView: some View {
        VStack(spacing: 12) {
            // 月份切换
            HStack {
                Button { calendarMonth = prevMonth } label: {
                    Image(systemName: "chevron.left")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                        .frame(width: 36, height: 36)
                        .background(AIATheme.blue.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(monthTitle)
                    .font(AIATheme.Font.callout.weight(.medium))
                Spacer()
                Button { calendarMonth = nextMonth } label: {
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                        .frame(width: 36, height: 36)
                        .background(AIATheme.blue.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
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
            // 2026-07-29：id 必须用 offset —— daysInMonthView 是 [Date?]，月首/月尾的多个 nil
            // 用 id: \.self 会产生重复 ID，SwiftUI diff 错乱导致月末行（如 30/31）点击后
            // selectedDate 已变但 cell 不重绘（不出蓝圈）。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                ForEach(Array(daysInMonthView.enumerated()), id: \.offset) { _, date in
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
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: String(format: NSLocalizedString("todo.calendar.selectedDateTitle", comment: ""), dayHeader))
                    let dayTodos = todos(on: selected)
                    if dayTodos.isEmpty {
                        Text(LocalizedStringKey("todo.calendar.noTasks")).font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    } else {
                    ForEach(Array(dayTodos.enumerated()), id: \.element.persistentModelID) { idx, r in
                        todoRow(r, group: .day(selected), indexInGroup: idx)
                    }
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
    /// 单行待办卡：ZStack 分层（与 ValueSelectableCard 同款结构，但触发方式从
    /// NavigationLink(value:) 推 path 改为 .sheet 弹起）：
    ///   底层：卡主体（todoRowContent 自身带 44pt 左 padding 给圆圈让位），
    ///          整张可点 → editTodo = r 触发 sheet
    ///   顶层：左侧完成圆圈 todoDoneButton（Color.clear 36×36 独立 hit area
    ///          拦截点击，不穿透到下层卡主体）
    /// 抽成独立 helper（不在 body 内联 ZStack）—— 加 toolbar + 双 sheet 后 body modifier 链
    /// 总深度让 Swift 编译器类型推断超时（2026-07-24 踩坑）。
    @ViewBuilder
    private func todoRow(_ r: Reminder, group: TodoGroup, indexInGroup: Int) -> some View {
        // 长按整行起拖：改用 UIKit 的 `LongPressDragView`（单一 UILongPressGestureRecognizer
        // 承担「长按判定 + 后续拖动」两个阶段），SwiftUI 手势的三种写法均已失败，见
        // LongPressDragView.swift 文件头的踩坑记录。
        //
        // 行为：长按 0.5s 内不 claim 事件 → ScrollView 上下滚动 100% 正常；
        //      长按成立(.began) → onDragBegan 起拖；手指移动(.changed) → onDragChanged 更新插入点；
        //      松手(.ended/.cancelled) → onDragEnded 落位。
        let lifted = isDragging && draggingSyncId == r_escapedSyncId(r)
        let pushDown = shouldPushDown(group: group, index: indexInGroup)
        ZStack(alignment: .leading) {
            SelectableRow(
                isSelecting: multiSelectMode,
                isSelected: selectedIDs.contains(r.persistentModelID),
                onTap: { editTodo = r },
                // 长按已由 UIKit LongPressDragView 统一接管（长按=起拖改期），
                // 不传 onLongPress → SelectableRow 内部不挂 SwiftUI 长按手势，
                // 避免两个 0.5s 长按互抢 touch、并消除重复震动。
                onToggle: { toggleTodoSelection(r.persistentModelID) },
                onDelete: {
                    // >>> CHANGE-[2026-08-17 11:28:00]-[临时对象失效崩溃] 开始
                    // 原因：r 来自 @Query ForEach 行，多选手动删除后底层数组变动可能释放引用。回退：改回 SafeDelete.reminder(r, in: context)
                    SafeDelete.reminderByID(r.persistentModelID, in: context)
                    // <<< CHANGE-[2026-08-17 11:28:00]-[临时对象失效崩溃] 结束
                },
                // 长按起拖中摘掉本行左滑手势，避免水平拖动同时误露「删除」按钮
                disableSwipe: longPressArmed
            ) {
                todoRowContent(r)
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TodoRowFrameKey.self,
                        value: [r.syncId.uuidString: TodoRowFrame(frame: geo.frame(in: .global), group: group)]
                    )
                }
            )
            todoDoneButton(r)

            // UIKit 长按起拖：挂在最上层。本 view 始终 hitTest→self（始终在响应链里），
            // 长按手势才收得到 began/changed；点击/左滑/滚动靠 gr.cancelsTouchesInView=false
            // 透传给下层 SelectableRow，不靠 hitTest 拦截，故三态并存。allowsHitTesting(true)
            // 仅为默认开启，无副作用。
            LongPressDragView(
                isEnabled: !multiSelectMode,
                onBegan: { loc in beginTodoDrag(r, at: loc) },
                onChanged: { loc in updateTodoDrag(r, at: loc) },
                onEnded: { _ in endTodoDrag(r) }
            )
            .allowsHitTesting(true)
        }
        // 浮起 + live reflow：被拖行原位置留淡影，插入点之后的同行实时下移让位。
        .scaleEffect(lifted ? 1.03 : 1.0)
        .opacity(lifted ? 0.35 : 1.0)
        .offset(y: pushDown ? draggedRowHeight : 0)
        .shadow(color: lifted ? .black.opacity(0.15) : .clear, radius: 8, y: 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDragging)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dropIndex)
    }

    // MARK: - 待办改期拖拽：三阶段处理（由 LongPressDragView 的 UIKit 手势驱动）

    /// 长按成立：标记本行为「拖拽中」，记录行高与起始位置。此时手指尚未移动，
    /// 不立即 `isDragging=true`（浮起留到确实移动 >=10pt 后，避免纯长按误浮起）。
    private func beginTodoDrag(_ r: Reminder, at loc: CGPoint) {
        guard !multiSelectMode else { return }
        longPressArmed = true
        draggingSyncId = r.syncId.uuidString
        let f = rowFrames[r.syncId.uuidString]?.frame
        draggedRowHeight = f?.height ?? 56
        // 记录长按成立时的手指坐标作为位移基准（原代码错用行中心 midX/midY，
        // 导致手指按在行左右两端时 moved 一上来就 >10 或永远不达标，卡片浮不起来）
        dragStartLocation = loc
        // 手指相对行中心的偏移：浮起卡片保持该相对关系，不会瞬间跳到手指中心
        dragGrabOffset = f.map { CGSize(width: $0.midX - loc.x, height: $0.midY - loc.y) } ?? .zero
        dragLocation = loc
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 长按成立后手指移动：超过 10pt 才真正浮起，并实时计算插入点（行间 or 组 header）。
    private func updateTodoDrag(_ r: Reminder, at loc: CGPoint) {
        guard longPressArmed, !multiSelectMode else { return }
        guard draggingSyncId == r.syncId.uuidString else { return }

        if !isDragging {
            // 与长按成立时的手指坐标比较（而非行中心），阈值降到 6pt：
            // 长按后手指本就基本静止，10pt 在慢速拖动时迟迟不达标，表现就是
            // "有震动但卡片不浮起"。
            let moved = hypot(loc.x - dragStartLocation.x, loc.y - dragStartLocation.y)
            guard moved >= 6 else { return }
            isDragging = true
        }
        dragLocation = loc

        // —— 行级插入点：优先看落在哪两行之间；否则回退到整组 header ——
        var hit: (sid: String, frame: CGRect, group: TodoGroup)? = nil
        for (sid, val) in rowFrames where val.frame.contains(loc) {
            hit = (sid, val.frame, val.group); break
        }
        if let h = hit {
            let upper = loc.y < h.frame.midY
            let grp = groupedByDate.first { $0.group == h.group }?.reminders ?? []
            if let idx = grp.firstIndex(where: { $0.syncId.uuidString == h.sid }) {
                dropIndex = DropIndex(group: h.group, at: upper ? idx : idx + 1)
                hoverGroup = h.group
                hoveringHeader = false
            }
        } else {
            var g: TodoGroup?? = .none
            for (key, fr) in headerFrames where fr.contains(loc) { g = .some(key); break }
            if let gg = g {
                let resolvedGroup: TodoGroup = gg ?? .unscheduled
                dropIndex = DropIndex(group: resolvedGroup, at: 0)
                hoverGroup = gg
                hoveringHeader = true
            } else {
                dropIndex = nil
                hoverGroup = nil
                hoveringHeader = false
            }
        }
    }

    /// 松手/取消：若确实拖动过且悬停在某组上则改期，随后清空全部拖拽状态。
    private func endTodoDrag(_ r: Reminder) {
        guard draggingSyncId == r.syncId.uuidString else { return }
        if let target = hoverGroup, isDragging {
            moveDue(r, to: target)
        }
        draggingSyncId = nil
        dropIndex = nil
        hoverGroup = nil
        hoveringHeader = false
        isDragging = false
        longPressArmed = false
        dragGrabOffset = .zero
        dragStartLocation = .zero
    }

    /// 取待办 syncId 字符串，用于「当前抬起行」判定（避免直接在绑定闭包里反复取 uuidString）。
    private func r_escapedSyncId(_ r: Reminder) -> String { r.syncId.uuidString }

    /// 当前行是否应「下移让位」：拖动中且本行位于目标插入点之后（同组）。
    private func shouldPushDown(group: TodoGroup, index: Int) -> Bool {
        guard let drop = dropIndex, drop.group == group, isDragging else { return false }
        return index >= drop.at
    }

    /// 拖动时浮起的待办快照。定位交给外层 overlay 的 GeometryReader（同源测量全局原点），
    /// 这里只负责渲染 + 宽度，不再做坐标换算，避免与原点的两套坐标系错位导致卡片偏离手指。
    @ViewBuilder
    private func draggedRowOverlay() -> some View {
        if isDragging,
           let sid = draggingSyncId,
           let rem = list.first(where: { $0.syncId.uuidString == sid }),
                   let fr = rowFrames[sid] {
                    todoRowContent(rem)
                        .frame(width: fr.frame.width)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .scaleEffect(1.02)
        }
    }

    /// 待办列表主体（ScrollView）。抽成独立函数以规避 body 的 modifier 链类型推断超时。
    private func todoListView() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // 提醒设置 / 自动记待办 入口
                Button {
                    NavigationRouter.shared.navigate(HomeRoute.todoTools)
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
                            action: { NavigationRouter.shared.navigate(.autoSetup) }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyStateView(
                            kind: .todo,
                            title: emptyTitle,
                            message: "跟小记说一句话就能建待办，例如「周五提醒我交报表」。",
                            actionTitle: "叫小记提醒我",
                            action: { NavigationRouter.shared.navigateToChat(prefill: "2分钟后提醒我打开「好记」App") }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // 直接遍历元素（不再用 ForEach(0..<count) + groupedByDate[i] 下标）：
                    // groupedByDate 派生自 @Query，导航 onAppear 的 RecurringBillManager.generateDue
                    // 插入账单/提醒时数组长度会变化，两次求值不一致会导致 groupedByDate[i] 越界闪退。
                    // 用 group 本身作 id（TodoGroup 已 Hashable，分组结果中每个 group 值唯一），
                    // 避免用 \.offset 作 id 在 @Query 异步填充/同步刷新导致组数变化时 SwiftUI diff 越界崩溃。
                    ForEach(Array(groupedByDate.enumerated()), id: \.element.group) { _, group in
                        VStack(alignment: .leading, spacing: 8) {
                            dateHeader(group.group, reminders: group.reminders)
                            ForEach(Array(group.reminders.enumerated()), id: \.element.persistentModelID) { idx, r in
                                todoRow(r, group: group.group, indexInGroup: idx)
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
        .onPreferenceChange(TodoHeaderFrameKey.self) { headerFrames = $0 }
        .onPreferenceChange(TodoRowFrameKey.self) { rowFrames = $0 }
        // 浮起快照覆盖层：用 overlay 自身的 GeometryReader 测量全局原点，
        // 与 .position 定位坐标系严格同源，滚动/刷新都不会产生累积偏移。
        .overlay {
            GeometryReader { gp in
                let origin = gp.frame(in: .global).origin
                draggedRowOverlay()
                    .position(x: dragLocation.x - origin.x + dragGrabOffset.width,
                              y: dragLocation.y - origin.y + dragGrabOffset.height)
            }
        }
    }

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
                    .foregroundStyle(r.done ? AIATheme.sub : .primary)
                HStack(spacing: 4) {
                    if let due = r.due {
                        Text(AppFormat.dateTime.string(from: due))
                            .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                    } else {
                        Text("未安排")
                            .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                    }
                    if let raw = recogSourceBySyncId[r.syncId],
                       let label = RecogSource.displayLabel(for: raw) {
                        Text(label)
                            .font(AIATheme.Font.micro.weight(.medium))
                            .foregroundStyle(AIATheme.sub)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(AIATheme.surfaceSecondary)
                            .clipShape(Capsule())
                    }
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
        .card(radius: AIATheme.rMD, shadow: false)
    }

    private func toggleDone(_ r: Reminder) {
        let wasDone = r.done
        // 触觉反馈（双向语义区分）：
        //   未完成 → 完成：用 .success 通知反馈（强烈三段式，标志「任务完成」）
        //   完成 → 未完成：用 .light 触觉（轻触，反向操作不打扰）
        // 与现有项目震动规范对齐（ChatView/MerchantRuleViews/MonthlyBillListView 都是 success+light 配对）
        if wasDone {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        // 不包 withAnimation，也不主动切 filter：
        // 用户反馈点击圆圈后想停留在当前页签（如「待办」），不要自动跳到「已完成」。
        // 直接同步改 done，@Query 会在下一帧自然重 fetch 一次，当前行从列表消失即可。
        r.done.toggle()
        if !wasDone { UsageAnalytics.log("todo_done") }
        // 通知调度延后到下一帧，不阻塞当前点击事件。
        // 显式 context.save() 也去掉，由 SwiftData autosave 处理。
        DispatchQueue.main.async {
            if wasDone {
                // 之前已完成，现在切回未完成：重新排程提醒
                ReminderNotificationManager.schedule(r)
            } else {
                // 之前未完成，现在标记为已完成：取消提醒
                ReminderNotificationManager.cancel(r)
                // 如果是重复待办，自动创建下一个周期的新实例
                createNextRepeatReminder(r)
            }
        }
    }

    /// 长按拖动改期：保留原时分秒，仅换日期；remindTimes 按偏移量同步。
    /// target 为 TodoGroup?：
    ///   - .day(d) → 把 due 改为 d 当天（保留时分秒）
    ///   - .overdue → 「已逾期事件」是计算状态，没有具体日期目标，保持原 due 不变（无副作用）。
    ///   - nil → 拖到「未安排」组，清空 due 与提醒。
    private func moveDue(_ r: Reminder, to target: TodoGroup?) {
        let cal = Calendar.current
        var changed = false
        switch target {
        case .some(.day(let date)):
            let day = cal.startOfDay(for: date)
            if let old = r.due {
                let t = cal.dateComponents([.hour, .minute, .second], from: old)
                guard let newDue = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: t.second ?? 0, of: day) else { return }
                let delta = newDue.timeIntervalSince(old)
                r.due = newDue
                if !r.remindTimes.isEmpty {
                    r.remindTimes = r.remindTimes.map { $0.addingTimeInterval(delta) }
                }
                changed = true
            } else {
                // 原「未安排」→ 拖到具体某天，默认 9:00
                r.due = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)
                changed = true
            }
        case .some(.overdue):
            // 已逾期是显示分组（按"截止日<今天"过滤得到），不是日期目标；
            // 拖到此区不改 due。给一个轻微震动确认意图但不弹成功提示。
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        case .some(.unscheduled), .none:
            // PreferenceKey 实际只会上报 .day/.overdue/nil 三种 key，
            // 不会上来 .some(.unscheduled)；但保持 switch 穷尽（多兜一个分支）。
            r.due = nil
            r.remindTimes = []
            changed = true
        }
        guard changed else { return }
        r.syncUpdatedAt = .now
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // 副作用延后到下一帧，不阻塞拖动手势；
        // 不主动 context.save()，由 SwiftData autosave 持久化，@Query 自动重分组。
        DispatchQueue.main.async {
            if r.due != nil { ReminderNotificationManager.schedule(r) }
            else { ReminderNotificationManager.cancel(r) }
        }
    }

    /// 标记重复待办为已完成时，自动生成下一周期的新实例。
    /// - daily：下一天同一时间
    /// - weekly：下一周同一天同一时间
    /// - monthly：下一月同一天同一时间
    private func createNextRepeatReminder(_ r: Reminder) {
        let rule = r.repeatRule.trimmingCharacters(in: .whitespaces)
        guard rule != "none", !rule.isEmpty, let due = r.due else { return }
        guard let nextDue = nextDueDate(from: due, rule: rule) else { return }

        let next = Reminder(
            title: r.title,
            due: nextDue,
            repeatRule: rule,
            priority: r.priority,
            done: false
        )
        // 复制提醒时间配置
        let times = r.remindTimes.isEmpty ? (r.remindAt.map { [$0] } ?? []) : r.remindTimes
        if !times.isEmpty {
            // 根据新的 due 重新计算 remindTimes
            let diffs = times.compactMap { t -> TimeInterval? in
                guard let oldDue = r.due else { return nil }
                return t.timeIntervalSince(oldDue)
            }
            if !diffs.isEmpty {
                next.remindTimes = diffs.map { nextDue.addingTimeInterval($0) }
            }
        }
        DefaultReminderSettings.shared.apply(to: next)

        context.insert(next)
        ReminderNotificationManager.schedule(next)
        // 由 SwiftData autosave 持久化
    }

    private func nextDueDate(from due: Date, rule: String) -> Date? {
        let cal = Calendar.current
        switch rule {
        case "daily":
            return cal.date(byAdding: .day, value: 1, to: due)
        case "weekly":
            return cal.date(byAdding: .weekOfYear, value: 1, to: due)
        case "biweekly":
            return cal.date(byAdding: .weekOfYear, value: 2, to: due)
        case "monthly":
            return cal.date(byAdding: .month, value: 1, to: due)
        case "bimonthly":
            return cal.date(byAdding: .month, value: 2, to: due)
        case "quarterly":
            return cal.date(byAdding: .month, value: 3, to: due)
        case "semiannual":
            return cal.date(byAdding: .month, value: 6, to: due)
        case "yearly":
            return cal.date(byAdding: .year, value: 1, to: due)
        default:
            return nil
        }
    }

    private func deleteReminder(_ r: Reminder) {
        // >>> CHANGE-[2026-08-17 11:27:30]-[临时对象失效崩溃] 开始
        // 原因：r 来自 @Query 行对象，转场/@Query 刷新后可能失效。回退：改回 SafeDelete.reminder(r, in: context)
        SafeDelete.reminderByID(r.persistentModelID, in: context)
        // <<< CHANGE-[2026-08-17 11:27:30]-[临时对象失效崩溃] 结束
    }

}

// MARK: - 饮食喜好页（严格按 AIATheme 令牌：hero + Top 5 + 来源 + 餐次）
private struct DietPreferencesView: View {
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \FoodEntry.date, order: .reverse)
    private var foods: [FoodEntry]

    /// Top 5 最常吃的食物：按 name 分组计数、倒序、取前 5；饮用水不属于饮食，单独分类，不进入此排行
    private var topFoods: [DietFoodRank] {
        let nonWaterFoods = foods.filter { $0.name != "饮用水" }
        let counts = Dictionary(grouping: nonWaterFoods, by: \.name).mapValues { $0.count }
        return counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            // 次数相同：按名称首字母（中文拼音 / 英文）稳定排序，避免每次数据变动循环切换位置
            return $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }
        .prefix(5)
        .enumerated()
        .map { idx, kv in DietFoodRank(rank: idx + 1, name: kv.key, count: kv.value) }
    }

    /// 记录来源：imageName 非空 = 图片识别记录；空 = 语音、文字记录（含手动编辑）
    private var sourceBreakdown: DietSourceBreakdown {
        let ai = foods.filter { ($0.imageName?.isEmpty == false) }.count
        return DietSourceBreakdown(aiCount: ai, manualCount: foods.count - ai)
    }

    /// 各餐次记录：4 个固定餐次，缺数据时 count=0（仍显示卡片，不隐藏）
    private var mealCounts: [DietMealCount] {
        [
            DietMealCount(meal: "早餐", icon: "sunrise.fill",   count: foods.filter { $0.meal == "早餐" }.count),
            DietMealCount(meal: "午餐", icon: "sun.max.fill",   count: foods.filter { $0.meal == "午餐" }.count),
            DietMealCount(meal: "晚餐", icon: "moon.fill",      count: foods.filter { $0.meal == "晚餐" }.count),
            DietMealCount(meal: "加餐", icon: "leaf.fill",      count: foods.filter { $0.meal == "加餐" }.count)
        ]
    }

    /// 累计热量（kcal）— hero 大数字
    private var totalCalories: Int {
        Int(foods.reduce(0) { $0 + $1.calories })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Hero 摘要卡：满宽、dietBG 底、icon+label+大数字（对齐首页 4 宫格的视觉语言）
                DietPreferencesHero(total: foods.count, calories: totalCalories)

                // 2. Top 5
                SectionTitle(text: "最常吃的食物 Top 5", trailing: nil)
                if topFoods.isEmpty {
                    DietPreferencesEmptyCard(text: "还没有食物记录\n先去「饮食记录」页拍一张试试")
                } else {
                    VStack(spacing: 0) {
                        ForEach(topFoods) { rank in
                            DietRankRow(rank: rank)
                            if rank.id != topFoods.last?.id {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }
                    .card(radius: AIATheme.rMD, shadow: false)
                }

                // 3. 记录来源
                SectionTitle(text: "记录来源", trailing: nil)
                HStack(spacing: 8) {
                    // >>> CHANGE-[2026-08-19 11:08:37]-[饮食偏好文案] 开始
                    // 原因: 用户要求"AI 识别"改"图片识别记录"，"手动输入"改"语音、文字记录"
                    // 回退: 恢复 title 为原 "AI 识别" / "手动输入" 即可
                    DietTintedCard(
                        icon: "camera.fill", title: "图片自动记录", count: sourceBreakdown.aiCount,
                        color: AIATheme.food, bg: AIATheme.surface
                    )
                    DietTintedCard(
                        icon: "pencil", title: "语音/文字自动记录", count: sourceBreakdown.manualCount,
                        color: AIATheme.health, bg: AIATheme.surface
                    )
                    // <<< CHANGE-[2026-08-19 11:08:37]-[饮食偏好文案] 结束
                }

                // 4. 各餐次记录
                SectionTitle(text: "各餐次记录", trailing: nil)
                HStack(spacing: 8) {
                    ForEach(mealCounts) { item in
                        DietTintedCard(
                            icon: item.icon, title: item.meal, count: item.count,
                            color: AIATheme.food, bg: AIATheme.surface
                        )
                    }
                }

                // 底部留白，避免被悬浮胶囊压住
                Color.clear.frame(height: 80)
            }
            .padding(12)
        }
    }
}

/// 饮食喜好：Hero 摘要（满宽，dietBG 底，icon+label+大数字）
private struct DietPreferencesHero: View {
    let total: Int
    let calories: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(AIATheme.Font.title3)
                    .foregroundStyle(AIATheme.food)
                Text("我的饮食记录")
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(total)")
                    .font(AIATheme.Font.ultra.weight(.semibold))
                    .foregroundStyle(AIATheme.food)
                Text("条")
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(AIATheme.sub)
                Spacer()
                Text("累计 \(calories) kcal")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rMD)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
    }
}

/// 饮食喜好：空态卡（白底，居中提示，对齐 EmptyStateView 风格但更紧凑）
private struct DietPreferencesEmptyCard: View {
    let text: String
    var body: some View {
        VStack(spacing: 4) {
            ForEach(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init), id: \.self) { line in
                Text(line)
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(AIATheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .card(radius: AIATheme.rMD, shadow: false)
    }
}

/// 饮食喜好：单条 Top N 行。1-3 名橙色实心 badge，4-5 名灰底
private struct DietRankRow: View {
    let rank: DietFoodRank
    var isTopThree: Bool { rank.rank <= 3 }
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(isTopThree ? AIATheme.food : AIATheme.fillSoft)
                Text("\(rank.rank)")
                    .font(AIATheme.Font.caption.weight(.semibold))
                    // 4-5 名 badge 数字用 .primary：保证深色模式下与 fillSoft 底有足够对比
                    .foregroundStyle(isTopThree ? .white : .primary)
            }
            .frame(width: 24, height: 24)
            Text(rank.name)
                .font(AIATheme.Font.footnote.weight(.medium))
                // 食物名用 .primary 而非 AIATheme.ink：ink 在 dark 模式值为 0x2c2c2e
                // （设计用于深色按钮背景，非通用正文色），在深灰卡片底上与背景同色而"消失"。
                // .primary 会自动深浅适配（light→黑 / dark→白），始终保持最高对比度。
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(rank.count) 次")
                .font(AIATheme.Font.footnote.weight(.medium))
                // 前 3 名保留食物语义橙；后 2 名改用 sub（dark:0xa1a1a6），相比 muted(0x8e8e93) 提亮一档
                .foregroundStyle(isTopThree ? AIATheme.food : AIATheme.sub)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// 饮食喜好：来源/餐次通用白底卡（icon+label+大数字，文字色保留语义，白底 + hairline 描边区分区块）
private struct DietTintedCard: View {
    let icon: String
    let title: String
    let count: Int
    let color: Color
    let bg: Color
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(AIATheme.Font.body.weight(.medium))
                .foregroundStyle(color)
            Text("\(count)")
                .font(AIATheme.Font.title2.weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.sub)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rMD)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - 饮食分析页（严格按 AIATheme 令牌：周期选择 + hero + 3 列概况 + 3 列营养网格）
private struct DietAnalysisView: View {
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \FoodEntry.date, order: .reverse)
    private var foods: [FoodEntry]
    @Query(filter: #Predicate<WaterLog> { !$0.syncDeleted }) private var waterLogs: [WaterLog]
    @Query(filter: #Predicate<HealthMetric> { !$0.syncDeleted }, sort: \HealthMetric.date, order: .reverse)
    private var healthMetrics: [HealthMetric]
    @State private var period: DietPeriod = .thisWeek

    // 目标达成层依赖：健身目标（BodyDataView 选择）+ TDEE 五件套（与饮食记录页/健康目标页同键）
    @AppStorage("aia.fitnessGoal") private var fitnessGoalRaw: String = "maintain"
    @AppStorage("aia.heightCm") private var heightCm: Double = 0
    @AppStorage("aia.weightKg") private var weightKg: Double = 0
    @AppStorage("aia.age") private var age: Int = 30
    @AppStorage("aia.bioSex") private var bioSex: Int = 1
    @AppStorage("aia.activityLevel") private var activityLevel: Int = 1
    @StateObject private var health = HealthManager.shared

    // MARK: - 目标达成计算

    private var goal: FitnessGoal { FitnessGoal(rawValue: fitnessGoalRaw) ?? .maintain }

    /// 当前体重：@AppStorage 优先，无则回落到 HealthMetric 最新体重记录（与身体数据页同口径）。
    private var weightForGoal: Double? {
        if weightKg > 0 { return weightKg }
        return healthMetrics.first { $0.metric.contains("体重") || $0.metric.lowercased().contains("weight") }
            .flatMap { Double($0.value) }
    }

    /// TDEE：与饮食记录页同源（RecordsViews.tdee / tdeeGoalFallback = BMR × 活动系数，目标值）。
    // >>> CHANGE-[2026-08-19 09:44:01]-分析页目标对齐记录页 开始
    // 原因: 原写法用「今日 activeCalories+restingCalories」当 TDEE,早晨 actual≈34 时
    //       calorieTarget=34×系数=34,饮食分析页"目标热量"错成 34 kcal,与饮食记录页 1731 不齐平。
    // 修法: 改用 BMR × 活动系数(目标值),与 RecordsViews.tdee 同源,两页目标口径一致。
    // 回退: 删本段,恢复原判(读 healthKitValue("activeCalories")+healthKitValue("restingCalories")) 即可。
    private var tdeeValue: Double {
        (mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: age, isMale: bioSex == 1) ?? 0)
            * activityMultiplier(activityLevel)
    }
    // <<< CHANGE-[2026-08-19 09:44:01]-分析页目标对齐记录页 结束

    /// 目标热量 = TDEE × 目标系数（TDEE 为 0 视为不可用）
    private var calorieTarget: Double? {
        tdeeValue > 0 ? tdeeValue * goal.calorieMultiplier : nil
    }

    /// 目标蛋白 = 体重 × g/kg（体重缺失时不可用）
    private var proteinTarget: Double? {
        weightForGoal.map { $0 * goal.proteinPerKg }
    }

    /// 周期日均摄入（热量 kcal / 蛋白 g / 纤维·糖·钠），与 nutritionCards 同口径
    // >>> CHANGE-[2026-08-19 10:44:39]-目标达成补碳水脂肪 开始
    // 原因: 饮食分析页"目标达成"模块原只展示热量/蛋白/纤维/糖/钠 5 行,缺碳水/脂肪两行。
    // 修法: periodAvg 补算 carb/fat 周均,供 GoalCheckCard 新增两行使用。
    // 回退: 删本段,恢复原判(5 元组 periodAvg 无 carb/fat)。
    private var periodAvg: (cal: Double, protein: Double, carb: Double, fat: Double, fiber: Double, sugar: Double, sodium: Double) {
        let (s, e) = period.range()
        let dayCount = max(1, Calendar.current.dateComponents([.day], from: s, to: e).day ?? 1)
        var calSum = 0.0, proteinSum = 0.0, carbSum = 0.0, fatSum = 0.0, fiberSum = 0.0, sugarSum = 0.0, sodiumSum = 0.0
        for f in periodFoods {
            calSum += f.calories
            proteinSum += f.protein
            carbSum += f.carbs
            fatSum += f.fat
            fiberSum += f.fiber
            sugarSum += f.sugar
            sodiumSum += f.sodium
        }
        let dc = Double(dayCount)
        return (cal: calSum / dc, protein: proteinSum / dc, carb: carbSum / dc, fat: fatSum / dc,
                fiber: fiberSum / dc, sugar: sugarSum / dc, sodium: sodiumSum / dc)
    }
    // <<< CHANGE-[2026-08-19 10:44:39]-目标达成补碳水脂肪 结束

    /// 当前周期内的食物（半开区间 [start, end)）
    private var periodFoods: [FoodEntry] {
        let (s, e) = period.range()
        return foods.filter { $0.date >= s && $0.date < e }
    }

    /// 当前周期内的手动饮水（tap 加的水）总和（ml）
    private var periodManualWater: Double {
        let (s, e) = period.range()
        return waterLogs
            .filter { $0.date >= s && $0.date < e }
            .reduce(0) { $0 + $1.amount }
    }

    /// 周期汇总：去重天数 / 总条数 / 餐次种类数
    private var overview: (days: Int, total: Int, meals: Int) {
        let cal = Calendar.current
        let days = Set(periodFoods.map { cal.startOfDay(for: $0.date) }).count
        let mealSet = Set(periodFoods.map { $0.meal }.filter { !$0.isEmpty })
        return (days, periodFoods.count, mealSet.count)
    }

    /// 周期总热量（kcal），hero 大数字
    private var totalCalories: Int {
        Int(periodFoods.reduce(0) { $0 + $1.calories })
    }

    /// 8 维平均每日营养：全部已建模，不再使用占位符
    /// 颜色：前 4 项按宏量素语义色；后 4 项同色
    private var nutritionCards: [(label: String, value: String, color: Color)] {
        let (s, e) = period.range()
        let dayCount = max(1, Calendar.current.dateComponents([.day], from: s, to: e).day ?? 1)
        let sum = periodFoods.reduce((cal: 0.0, p: 0.0, c: 0.0, f: 0.0, fiber: 0.0, sugar: 0.0, sodium: 0.0, water: 0.0)) { acc, f in
            (acc.cal + f.calories, acc.p + f.protein, acc.c + f.carbs, acc.f + f.fat,
             acc.fiber + f.fiber, acc.sugar + f.sugar, acc.sodium + f.sodium, acc.water + f.waterIntake)
        }
        // 饮水口径统一：仅统计手动加水（WaterLog），不含食物自带水分，与小程序对齐。
        let waterSum = periodManualWater
        let d = Double(dayCount)
        return [
            ("热量(kcal)",  String(format: "%.0f", sum.cal / d), AIATheme.food),
            ("蛋白质(g)",   String(format: "%.1f", sum.p   / d), AIATheme.blue),
            ("碳水(g)",     String(format: "%.1f", sum.c   / d), AIATheme.amber),
            ("脂肪(g)",     String(format: "%.1f", sum.f   / d), AIATheme.green),
            ("膳食纤维(g)", String(format: "%.1f", sum.fiber / d), AIATheme.health),
            ("糖(g)",       String(format: "%.1f", sum.sugar / d), AIATheme.food),
            ("钠(mg)",      String(format: "%.0f", sum.sodium / d), AIATheme.todo),
            ("饮水(ml)",    String(format: "%.0f", waterSum / d), AIATheme.blue)
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. 周期选择（项目自带 SegmentedPicker）
                SegmentedPicker(
                    options: DietPeriod.allCases.map { (value: $0, label: $0.label) },
                    selection: $period
                )

                // 2. Hero 周期摘要：满宽、dietBG 底、大数字（与饮食喜好 hero 同款语言）
                DietAnalysisHero(period: period, total: overview.total, calories: totalCalories)

                // 3. 记录概况：3 列染色卡
                SectionTitle(text: "记录概况", trailing: nil)
                HStack(spacing: 8) {
                    DietTintedCard(
                        icon: "calendar", title: "记录天数", count: overview.days,
                        color: AIATheme.food, bg: AIATheme.surface
                    )
                    DietTintedCard(
                        icon: "list.bullet", title: "总记录条数", count: overview.total,
                        color: AIATheme.health, bg: AIATheme.surface
                    )
                    DietTintedCard(
                        icon: "fork.knife", title: "餐次种类", count: overview.meals,
                        color: AIATheme.bill, bg: AIATheme.surface
                    )
                }

                // 4. 平均每日营养摄入：3 列网格（与饮食记录页 MacroCard 网格列数一致）
                SectionTitle(text: "平均每日营养摄入", trailing: "基于周期内记录自动计算")
                LazyVGrid(columns: [
                    GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
                ], spacing: 8) {
                    ForEach(nutritionCards, id: \.label) { c in
                        DietNutritionCard(label: c.label, value: c.value, color: c.color)
                    }
                }

                // 5. 目标达成（减脂/增肌/维持 对比层）：热量/蛋白目标 = TDEE × 系数 / 体重 × g/kg；
                //    纤维/糖/钠目标按「目标热量（calorieTarget = TDEE × 系数，即本卡顶部显示的“目标热量”）」线性缩放，与热量行同源一致。
                SectionTitle(text: NSLocalizedString("diet.analysis.goalTarget", comment: ""), trailing: nil)
                if let cal = calorieTarget {
                    GoalCheckCard(
                        goal: goal,
                        calorieTarget: calorieTarget,
                        proteinTarget: proteinTarget,
                        avgCal: periodAvg.cal,
                        avgProtein: periodAvg.protein,
                        avgCarb: periodAvg.carb,
                        avgFat: periodAvg.fat,
                        fiberTarget: cal * 14 / 1000,
                        sugarTarget: cal * 0.10 / 4,
                        // 钠按目标热量线性缩放：2000kcal 标准人对应 2000mg 钠，即 钠(mg) = 目标热量(kcal)。
                        // 用户原公式「建议热量 × 1000 ÷ 2000 × 2000」字面化简 = 目标热量 × 1000（2000kcal→2,000,000mg，不符合实际），
                        // 此处按营养学合理口径实现（如需严格按字面请改为 `cal * 1000`）。
                        sodiumTarget: cal,
                        // >>> CHANGE-[2026-08-19 10:44:39]-目标达成补碳水脂肪 开始
                        // 碳水 = 目标热量 × 50% ÷ 4;脂肪 = 目标热量 × 25% ÷ 9（与饮食记录页 nutritionTargets 同源）。
                        carbTarget: cal * 0.50 / 4,
                        fatTarget: cal * 0.25 / 9,
                        // <<< CHANGE-[2026-08-19 10:44:39]-目标达成补碳水脂肪 结束
                        avgFiber: periodAvg.fiber,
                        avgSugar: periodAvg.sugar,
                        avgSodium: periodAvg.sodium,
                        headerCalorie: cal
                    )
                } else {
                    DietAnalysisNoWeightCard()
                }

                // 底部留白
                Color.clear.frame(height: 80)
            }
            .padding(12)
        }
    }
}

/// 饮食分析：体重缺失时的降级提示卡
private struct DietAnalysisNoWeightCard: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.warn)
            Text(NSLocalizedString("diet.analysis.noWeight", comment: ""))
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.sub)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rMD)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
    }
}

/// 饮食分析：目标达成卡（减脂/增肌/维持 × 实际摄入对比）
/// 顶行 = 目标标识 + 目标热量；下方两行进度条分别对比热量与蛋白。
/// 热量状态：ratio <0.95 偏低(warn) / 0.95~1.05 达标(ok) / >1.05 超出(over)
/// 蛋白状态：实际 ≥ 推荐 达标(ok)，否则 偏低(warn)
private struct GoalCheckCard: View {
    let goal: FitnessGoal
    let calorieTarget: Double?      // 热量目标（TDEE × 系数），无 TDEE 时为 nil
    let proteinTarget: Double?      // 蛋白目标（体重 × g/kg），无体重时为 nil
    // >>> CHANGE-[2026-08-19 10:44:39]-目标达成补碳水脂肪 开始
    // 原因: GoalCheckCard 原缺碳水/脂肪两行的目标值与周均,这里补 4 个字段。
    // 回退: 删本段 4 行字段(avgCarb/avgFat/carbTarget/fatTarget)。
    let avgCal: Double
    let avgProtein: Double
    let avgCarb: Double
    let avgFat: Double
    // 以下五项目标按「建议热量」线性缩放（与体重/TDEE 无关，goal > 0 即可用）
    let fiberTarget: Double
    let sugarTarget: Double
    let sodiumTarget: Double
    let carbTarget: Double          // 碳水 = 目标热量 × 0.50 ÷ 4（与饮食记录页 carb 公式同源）
    let fatTarget: Double           // 脂肪 = 目标热量 × 0.25 ÷ 9（与饮食记录页 fat 公式同源）
    let avgFiber: Double
    let avgSugar: Double
    let avgSodium: Double
    let headerCalorie: Double       // 顶部「目标热量」显示用（calorieTarget ?? 建议热量）
    // <<< CHANGE-[2026-08-19 10:44:39]-目标达成补碳水脂肪 结束

    private var calState: (label: String, color: Color) {
        guard let ct = calorieTarget, ct > 0 else { return (NSLocalizedString("diet.analysis.goalLow", comment: ""), AIATheme.warn) }
        let ratio = avgCal / ct
        if ratio < 0.95 { return (NSLocalizedString("diet.analysis.goalLow", comment: ""), AIATheme.warn) }
        if ratio > 1.05 { return (NSLocalizedString("diet.analysis.goalOver", comment: ""), AIATheme.over) }
        return (NSLocalizedString("diet.analysis.goalMet", comment: ""), AIATheme.ok)
    }
    private var proteinState: (label: String, color: Color) {
        guard let pt = proteinTarget, pt > 0 else { return (NSLocalizedString("diet.analysis.goalLow", comment: ""), AIATheme.warn) }
        return avgProtein >= pt
            ? (NSLocalizedString("diet.analysis.goalMet", comment: ""), AIATheme.ok)
            : (NSLocalizedString("diet.analysis.goalLow", comment: ""), AIATheme.warn)
    }
    /// 通用达标状态：lowerIsBetter=true 表示「越低越好」（糖/钠上限），false 表示「越高越好」（纤维下限）
    private func macroState(actual: Double, target: Double, lowerIsBetter: Bool) -> (label: String, color: Color) {
        guard target > 0 else { return (NSLocalizedString("diet.analysis.goalLow", comment: ""), AIATheme.warn) }
        if lowerIsBetter {
            return actual <= target * 1.05
                ? (NSLocalizedString("diet.analysis.goalMet", comment: ""), AIATheme.ok)
                : (NSLocalizedString("diet.analysis.goalOver", comment: ""), AIATheme.over)
        } else {
            return actual >= target * 0.95
                ? (NSLocalizedString("diet.analysis.goalMet", comment: ""), AIATheme.ok)
                : (NSLocalizedString("diet.analysis.goalLow", comment: ""), AIATheme.warn)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: goal.icon)
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(AIATheme.health)
                Text(goal.label)
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(String(format: "%@ %d kcal/天",
                            NSLocalizedString("diet.analysis.calorieTarget", comment: ""),
                            Int(headerCalorie)))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let ct = calorieTarget {
                goalRow(
                    label: NSLocalizedString("diet.analysis.calorieTarget", comment: ""),
                    detail: String(format: "%.0f / %.0f kcal", avgCal, ct),
                    ratio: ct > 0 ? min(avgCal / ct, 1) : 0,
                    badge: calState.label,
                    color: calState.color
                )
            }
            if let pt = proteinTarget {
                goalRow(
                    label: NSLocalizedString("diet.analysis.proteinTarget", comment: ""),
                    detail: String(format: "%.1f / %.1f g", avgProtein, pt),
                    ratio: pt > 0 ? min(avgProtein / pt, 1) : 0,
                    badge: proteinState.label,
                    color: proteinState.color
                )
            }
            // >>> CHANGE-[2026-08-19 10:44:39]-目标达成补碳水脂肪 开始
            // 原因: 补碳水/脂肪两行,与饮食记录页 6 元组顺序(蛋白→碳水→脂肪→纤维→糖→钠)一致;
            //       碳水/脂肪属「越高越好」,lowerIsBetter=false;目标与记录页同源(cal×0.5/4、cal×0.25/9)。
            // 回退: 删本段两 goalRow。
            let carbSt = macroState(actual: avgCarb, target: carbTarget, lowerIsBetter: false)
            goalRow(
                label: NSLocalizedString("food.macro.carb", comment: ""),
                detail: String(format: "%.1f / %.1f g", avgCarb, carbTarget),
                ratio: carbTarget > 0 ? min(avgCarb / carbTarget, 1) : 0,
                badge: carbSt.label,
                color: carbSt.color
            )
            let fatSt = macroState(actual: avgFat, target: fatTarget, lowerIsBetter: false)
            goalRow(
                label: NSLocalizedString("food.macro.fat", comment: ""),
                detail: String(format: "%.1f / %.1f g", avgFat, fatTarget),
                ratio: fatTarget > 0 ? min(avgFat / fatTarget, 1) : 0,
                badge: fatSt.label,
                color: fatSt.color
            )
            // <<< CHANGE-[2026-08-19 10:44:39]-目标达成补碳水脂肪 结束
            // 按建议热量线性缩放的三项微量营养素目标
            let fiberSt = macroState(actual: avgFiber, target: fiberTarget, lowerIsBetter: false)
            goalRow(
                label: NSLocalizedString("food.macro.fiber", comment: ""),
                detail: String(format: "%.1f / %.1f g", avgFiber, fiberTarget),
                ratio: fiberTarget > 0 ? min(avgFiber / fiberTarget, 1) : 0,
                badge: fiberSt.label,
                color: fiberSt.color
            )
            let sugarSt = macroState(actual: avgSugar, target: sugarTarget, lowerIsBetter: true)
            goalRow(
                label: NSLocalizedString("food.macro.sugar", comment: ""),
                detail: String(format: "%.1f / %.1f g", avgSugar, sugarTarget),
                ratio: sugarTarget > 0 ? min(avgSugar / sugarTarget, 1) : 0,
                badge: sugarSt.label,
                color: sugarSt.color
            )
            let sodiumSt = macroState(actual: avgSodium, target: sodiumTarget, lowerIsBetter: true)
            goalRow(
                label: NSLocalizedString("food.macro.sodium", comment: ""),
                detail: String(format: "%.0f / %.0f mg", avgSodium, sodiumTarget),
                ratio: sodiumTarget > 0 ? min(avgSodium / sodiumTarget, 1) : 0,
                badge: sodiumSt.label,
                color: sodiumSt.color
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rMD)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
    }

    private func goalRow(label: String, detail: String, ratio: Double, badge: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
                    .lineLimit(1)
                Spacer()
                Text(detail)
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(badge)
                    .font(AIATheme.Font.micro.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AIATheme.fillSoft)
                    Capsule()
                        .fill(color)
                        .frame(width: max(6, min(CGFloat(ratio), 1) * geo.size.width))
                }
            }
            .frame(height: 6)
        }
    }
}

/// 饮食分析：Hero 摘要（满宽，dietBG 底，周期 + 大数字 + 总条数 + 累计热量）
private struct DietAnalysisHero: View {
    let period: DietPeriod
    let total: Int
    let calories: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(AIATheme.Font.title3)
                    .foregroundStyle(AIATheme.food)
                Text("\(period.label)饮食分析")
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                Spacer()
                Text("共 \(total) 条")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(calories)")
                    .font(AIATheme.Font.ultra.weight(.semibold))
                    .foregroundStyle(AIATheme.food)
                Text("kcal")
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(AIATheme.sub)
                Spacer()
                Text("周期总摄入")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rMD)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
    }
}

/// 饮食分析：营养摄入单格（左对齐大数字 + 标签；"—" 走 muted 弱化；与饮食记录页 MacroCard 同款语法）
private struct DietNutritionCard: View {
    let label: String
    let value: String
    let color: Color
    // >>> CHANGE-[2026-08-19 10:09:11]-营养宫格居中 开始
    // 原因: 平均每日营养摄入模块 8 个宫格内容原左对齐,用户要求改居中对齐。
    // 修法: VStack alignment 与 frame alignment 由 .leading 改 .center。
    // 回退: 两处 .center 改回 .leading 即可。
    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(value)
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(value == "—" ? AIATheme.muted : color)
            Text(label)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.sub)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // <<< CHANGE-[2026-08-19 10:09:11]-营养宫格居中 结束
        .padding(12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rMD)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
    }
}

/// 水卡按压样式：按下 scale 0.94，松手 spring 回弹；同时背景 opacity 从 0.12→0.22，
/// 让 tap 的视觉反馈比 PressableCardStyle 更明显（用户操作简单、反馈要足）。
private struct WaterCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - 健康圆环点击自增按钮（与「饮水 +100ml」同交互逻辑）
//
// 复用 `WaterCardButtonStyle` 实现按压下沉 0.94 + spring 回弹；点击 → onTap 自增 + 轻触震动，
// 同时上浮一个「+N 单位」飘字（仿饮水卡 FloatBadge，圆环在 Grid 内，飘字向上溢出不被裁切）。
// 用 `HealthMetricKind` 区分三环（与 HealthMetric @Model 命名区分，避免冲突）。

enum HealthMetricKind: String {
    case steps, sleep, exercise, tdee, heartRate

    var title: String {
        switch self {
        case .steps: return "步数"
        case .sleep: return "睡眠"
        case .exercise: return "运动"
        case .tdee: return "总消耗"
        case .heartRate: return "静息心率"
        }
    }
    /// 拼接 @AppStorage 的 key，便于每个指标单独持久化数据来源。
    var sourceKey: String { "aia.health.source." + self.rawValue }
}

/// 每个健康指标的数据来源：自动记录（同步 HealthKit）/ 手动记录（沿用原手动录入）。
enum HealthSourceMode: String {
    case auto, manual
}

// MARK: - 健康数据来源设置面板
// 逐指标切换「自动记录（HealthKit）/ 手动记录」，持久化到 @AppStorage（key 见 HealthMetricKind.sourceKey）。
// 未连接 HealthKit 时「自动」实际会回退手动，故给出提示；自动模式下圆环 / +N 入口已在 HealthListView 被禁用。
private struct HealthSourceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var health = HealthManager.shared

    @AppStorage(HealthMetricKind.steps.sourceKey)     private var stepsSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.sleep.sourceKey)     private var sleepSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.exercise.sourceKey)  private var exerciseSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.tdee.sourceKey)      private var tdeeSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.heartRate.sourceKey) private var heartRateSource: HealthSourceMode = .auto

    private func binding(for kind: HealthMetricKind) -> Binding<HealthSourceMode> {
        switch kind {
        case .steps: return $stepsSource
        case .sleep: return $sleepSource
        case .exercise: return $exerciseSource
        case .tdee: return $tdeeSource
        case .heartRate: return $heartRateSource
        }
    }

    // MARK: HealthKit 授权状态卡：已授权绿标 / 未授权可点授权 / 失败黄标可重试 / 不可用置灰
    private var authorizationCard: some View {
        let isUnavailable = !health.isAvailable
        let isFailed = health.authorizationFailed
        let isAuthorized = health.isActuallyAuthorized

        let title: String
        let subtitle: String
        let icon: String
        let accent: Color

        if isUnavailable {
            title = "Apple 健康不可用"
            subtitle = "当前设备或模拟器不支持 HealthKit，无法使用自动记录。"
            icon = "heart.slash"
            accent = AIATheme.muted
        } else if isAuthorized {
            title = "Apple 健康已授权"
            subtitle = "本 App 可自动同步步数、睡眠、运动、心率等数据。"
            icon = "heart.fill"
            accent = AIATheme.ok
        } else if isFailed {
            title = "Apple 健康未授权"
            subtitle = "请点击前往「设置」页面搜索「健康」，然后点击「数据访问与设备」找到「好记AI」完成授权。"
            icon = "exclamationmark.triangle.fill"
            accent = AIATheme.warning
        } else {
            title = "点击连接 Apple 健康"
            subtitle = "点击前往「设置」页面搜索「健康」，然后点击「数据访问与设备」找到「好记AI」完成授权。"
            icon = "heart"
            accent = AIATheme.health
        }

        return Button {
            guard !isUnavailable, !isAuthorized else { return }
            // 统一走 requestAuthorizationForSettings：
            // - 未拒绝过 → 弹出 HealthKit 系统授权框
            // - 已撤销过（.sharingDenied）→ 内部检测到，直接引导去系统设置手动开启
            // - 回调静默失败（ok=false）→ 兜底自动跳系统设置
            HealthManager.shared.requestAuthorizationForSettings()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }

                Spacer()

                if isAuthorized {
                    Text("已授权")
                        .font(AIATheme.Font.micro.weight(.semibold))
                        .foregroundStyle(AIATheme.ok)
                } else if !isUnavailable {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AIATheme.iconInactive)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, AIATheme.rMD)
        }
        .disabled(isUnavailable || isAuthorized)
        .buttonStyle(PressableCardStyle())
        .contentShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
        .card()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    authorizationCard
                }

                Section {
                    ForEach([HealthMetricKind.steps,
                             .sleep,
                             .exercise,
                             .tdee,
                             .heartRate], id: \.self) { kind in
                        HStack {
                            Text(kind.title)
                                .font(AIATheme.Font.body)
                            Spacer()
                            Picker("", selection: binding(for: kind)) {
                                Text("自动记录").tag(HealthSourceMode.auto)
                                Text("手动记录").tag(HealthSourceMode.manual)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 168)
                        }
                    }
                } header: {
                    Text("数据来源")
                } footer: {
                    Text("选择「自动记录」，则会自动同步 Apple 健康（HealthKit）数据；选择「手动记录」，需返回健康管理页点击对应模块录入数据，例如点击「睡眠圆环」即可记录睡眠时长。")
                }
            }
            .navigationTitle("健康管理数据来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(AIATheme.Font.body.weight(.semibold))
                }
            }
        }
    }
}

private struct HealthRingButton: View {
    let kind: HealthMetricKind
    let value: String
    let caption: String
    var secondary: String? = nil      // 目标值副行（与健康目标页同步）
    let progress: Double
    var onTap: () -> Void
    let bumpText: String
    var enabled: Bool = true

    @State private var floats: [RingFloatBadge] = []

    var body: some View {
        Button {
            onTap()
            // 仅在手动（可录入）模式下飘 +N 字；自动模式不写入数据、不飘字。
            if enabled {
                floats.append(RingFloatBadge())
            }
        } label: {
            RingView(value: value, caption: caption, secondary: secondary, progress: progress,
                     color: AIATheme.health, size: 74, lineWidth: 7)
        }
        .buttonStyle(WaterCardButtonStyle())
        .overlay(
            ZStack {
                ForEach(floats) { badge in
                    RingFloatBadgeView(text: bumpText, badge: badge) {
                        floats.removeAll { $0.id == badge.id }
                    }
                }
            }
        )
    }
}

/// 点击圆环后上浮的「+N 单位」标记（仿 FloatBadge，支持传入文案）
private struct RingFloatBadge: Identifiable {
    let id = UUID()
}

private struct RingFloatBadgeView: View {
    let text: String
    let badge: RingFloatBadge
    var onDone: () -> Void
    @State private var animate = false

    var body: some View {
        Text(text)
            .font(AIATheme.Font.micro.weight(.semibold))
            .foregroundStyle(AIATheme.health)
            .offset(y: animate ? -46 : 0)
            .opacity(animate ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.85)) {
                    animate = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    onDone()
                }
            }
    }
}

// MARK: - 柱状图翻周辅助（饮食 / 健康 / 账单三图共用）

/// 底部小圆点指示器：高亮当前所在周（`selection` 为 0 表示本周，负数表示过去第 |n| 周）。
private struct ChartPageDots: View {
    let selection: Int
    let minOffset: Int
    let accent: Color

    private var count: Int { (0 - minOffset) + 1 }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                let off = minOffset + i
                Circle()
                    .fill(off == selection ? accent : AIATheme.muted.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

/// 当前翻到的周范围文字：`offset` 为 0 显示「本周」，历史周显示「M/d–M/d」
/// （`base` 为窗口终点锚定的日，饮食页=选中日，健康/账单页=今天）。
private func chartWeekRangeLabel(offset: Int, base: Date) -> String {
    let cal = Calendar.current
    let end = cal.date(byAdding: .day, value: offset * 7, to: cal.startOfDay(for: base))!
    let start = cal.date(byAdding: .day, value: -6, to: end)!
    if offset == 0 {
        return ""
    }
    return "\(dayFmt.string(from: start))–\(dayFmt.string(from: end))"
}

// MARK: - 饮食记录：营养构成卡（标题 + 6 个 MacroCard，每卡显示「实际 / 建议」+ 进度条）
/// 整体抽为独立子视图，避开父级 body 表达式在 Swift 编译器里的「unable to type-check」级联卡死。
/// - targets：6 元建议量（蛋白/碳水/脂肪/纤维/糖/钠）
/// - macros：7 元今日实际摄入（蛋白/碳水/脂肪/纤维/糖/钠/水）
private struct NutritionCompositionCard: View {
    let targets: (protein: Int, carb: Int, fat: Int, fiber: Int, sugar: Int, sodium: Int)
    let macros: (p: Double, c: Double, f: Double, fiber: Double, sugar: Double, sodium: Double, water: Double)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 建议量已下沉到各 MacroCard 标题后，顶部 trailing 汇总行移除
            SectionTitle(text: NSLocalizedString("food.nutrition", comment: ""), trailing: nil)
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                MacroCard(title: NSLocalizedString("food.macro.carb", comment: ""),
                          value: valueText(macros.c, "g"),
                          targetText: valueText(Double(targets.carb), "g"),
                          progress: progress(actual: macros.c, target: targets.carb),
                          color: AIATheme.amber)
                MacroCard(title: NSLocalizedString("food.macro.protein", comment: ""),
                          value: valueText(macros.p, "g"),
                          targetText: valueText(Double(targets.protein), "g"),
                          progress: progress(actual: macros.p, target: targets.protein),
                          color: AIATheme.blue)
                MacroCard(title: NSLocalizedString("food.macro.fat", comment: ""),
                          value: valueText(macros.f, "g"),
                          targetText: valueText(Double(targets.fat), "g"),
                          progress: progress(actual: macros.f, target: targets.fat),
                          color: AIATheme.green)
                MacroCard(title: NSLocalizedString("food.macro.fiber", comment: ""),
                          value: valueText(macros.fiber, "g"),
                          targetText: valueText(Double(targets.fiber), "g"),
                          progress: progress(actual: macros.fiber, target: targets.fiber),
                          color: AIATheme.health)
                MacroCard(title: NSLocalizedString("food.macro.sugar", comment: ""),
                          value: valueText(macros.sugar, "g"),
                          targetText: valueText(Double(targets.sugar), "g"),
                          progress: progress(actual: macros.sugar, target: targets.sugar),
                          color: AIATheme.food)
                MacroCard(title: NSLocalizedString("food.macro.sodium", comment: ""),
                          value: valueText(macros.sodium, "mg"),
                          targetText: valueText(Double(targets.sodium), "mg"),
                          progress: progress(actual: macros.sodium, target: targets.sodium),
                          color: AIATheme.todo)
            }
        }
    }

    private func valueText(_ value: Double, _ unit: String) -> String {
        String(Int(value.rounded())) + unit
    }
    private func progress(actual: Double, target: Int) -> Double {
        target > 0 ? actual / Double(target) : 0
    }
}

