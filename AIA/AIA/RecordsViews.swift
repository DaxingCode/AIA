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
    private var originBySyncId: [UUID: String] {
        Dictionary(uniqueKeysWithValues: foodSources.map { ($0.foodSyncId, $0.origin) })
    }
    @State private var meal: MealFilter = .lu
    @State private var selectedDate: Date = Date()
    @State private var showDatePicker: Bool = false
    @State private var showGoalEditor: Bool = false
    @State private var editedGoal: Double = 0
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
    @State private var editFood: FoodEntry? = nil

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
    private var tdeeGoalFallback: Double {
        (mifflinBMR(weightKg: weightKgDiet, heightCm: heightCmDiet, age: ageDiet, isMale: bioSexDiet == 1) ?? 0)
            * activityMultiplier(activityLevelDiet)
    }
    private var tdee: Double {
        let actual = health.restingEnergyToday + health.activeEnergyToday
        return actual > 0 ? actual : tdeeGoalFallback
    }
    /// 与首页健康卡片 / 今日预览 / 健康管理页 TDEE 圆环同源：
    /// 已接入 HealthKit 且读到数据 → 静息+活动能量；未接入 → 手动补录活动热量。
    /// 注意：本页「TDEE」列（tdee）显示的是目标值（actual 为 0 时回落到目标），
    /// 而「今日消耗」列应显示实际达成，故用 tdeeCurrentValue 与那三处对齐。
    private var usesHealthKit: Bool { health.authorized && health.isAvailable && health.hasHealthKitData }
    private var tdeeCurrentValue: Double {
        usesHealthKit ? health.restingEnergyToday + health.activeEnergyToday : Double(ManualHealthStore.shared.activeCalories(for: Date()))
    }
    private var goal: Double { goalIsCustom ? goalOverride : tdee }
    private var net: Double { selectedCalories - tdee }

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

    /// 点「常吃食物」名称：按库内每100g营养 ×100g 入库当前餐次；无匹配则热量归零（用户可改）。
    private func saveFrequentFood(_ name: String) {
        let ref = NutritionLibrary.shared.match(name, in: context)
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
                message: "到相册选一张照片，阿宝会自动识别菜名、热量和营养元素。",
                actionTitle: "到相册选一张",
                action: { showPicker = true },
                footer: "点击底部拍照、相册上传食物照片\n或点击文字输入、语音输入\n也可使用AI快速记录哦"
            )
        } else {
            ForEach(mealItems) { f in
                SelectableRow(
                    isSelecting: multiSelectMode,
                    isSelected: selectedIDs.contains(f.persistentModelID),
                    onTap: { editFood = f },
                    onLongPress: { enterFoodMultiSelect(f.persistentModelID) },
                    onToggle: { toggleFoodSelection(f.persistentModelID) },
                    onDelete: { SafeDelete.food(f, in: context) }
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
                                let sourceText = (f.imageName?.isEmpty == false)
                                    ? NSLocalizedString("food.recognized", comment: "")
                                    : NSLocalizedString("food.by_chat", comment: "")
                                // 重量（小程序记录常见，App 记录可选）：weightGram>0 时展示
                                let weightText = f.weightGram.flatMap { $0 > 0 ? "\(Int($0))g" : nil }
                                // 来源：小程序 pull 进来的记录标记「好好吃饭小程序」
                                let originLabel = (originBySyncId[f.syncId] == "miniprogram")
                                    ? "好好吃饭小程序"
                                    : nil
                                Text([f.portion, weightText, originLabel, sourceText]
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

    // MARK: - 食物信息卡（B 方案）辅助方法
    private func macroCell(_ title: String, _ value: Double, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(formatValue(value))
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(unit)
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.sub)
            }
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

                        MiniBar(value: goal > 0 ? selectedCalories / goal : 0, color: AIATheme.food)

                        // 3 列热量指标：净热量 / TDEE / 今日消耗（等宽 + 细竖线分隔）
                        HStack(spacing: 8) {
                            HStack(spacing: 0) {
                                // 净热量（英雄数字，食物色突出）
                                VStack(spacing: 2) {
                                    Text("\(Int(net))")
                                        .font(AIATheme.Font.title3.weight(.semibold))
                                        .foregroundStyle(AIATheme.food)
                                    Text(NSLocalizedString("food.netLabel", comment: ""))
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.sub)
                                }
                                .frame(maxWidth: .infinity)

                                Rectangle()
                                    .fill(AIATheme.hairline)
                                    .frame(width: 0.5, height: 32)

                                // TDEE（基础能量消耗，ink 色中性）
                                VStack(spacing: 2) {
                                    Text("\(Int(tdee))")
                                        .font(AIATheme.Font.title3.weight(.semibold))
                                        .foregroundStyle(AIATheme.ink)
                                    Text(NSLocalizedString("food.tdeeLabel", comment: ""))
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.sub)
                                }
                                .frame(maxWidth: .infinity)

                                Rectangle()
                                    .fill(AIATheme.hairline)
                                    .frame(width: 0.5, height: 32)

                                // 今日消耗（与首页健康卡片 / 今日预览 / TDEE 圆环同源：resting+active，无 HealthKit 时走手动活动热量）
                                VStack(spacing: 2) {
                                    Text("\(Int(tdeeCurrentValue))")
                                        .font(AIATheme.Font.title3.weight(.semibold))
                                        .foregroundStyle(AIATheme.ink)
                                    Text(NSLocalizedString("food.burned", comment: "") + " kcal")
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.sub)
                                }
                                .frame(maxWidth: .infinity)
                            }

                            waterCard
                        }
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

                    // Card2 · 营养构成
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: NSLocalizedString("food.nutrition", comment: ""),
                                     trailing: String(format: NSLocalizedString("food.nutritionTarget", comment: ""), 75, 220, 55))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            MacroCard(title: NSLocalizedString("food.macro.carb", comment: ""), value: "\(Int(macros.c))g", progress: macros.c / 220, color: AIATheme.amber)
                            MacroCard(title: NSLocalizedString("food.macro.protein", comment: ""), value: "\(Int(macros.p))g", progress: macros.p / 75, color: AIATheme.blue)
                            MacroCard(title: NSLocalizedString("food.macro.fat", comment: ""), value: "\(Int(macros.f))g", progress: macros.f / 55, color: AIATheme.green)
                            MacroCard(title: NSLocalizedString("food.macro.fiber", comment: ""), value: "\(Int(macros.fiber))g", progress: macros.fiber / 25, color: AIATheme.health)
                            MacroCard(title: NSLocalizedString("food.macro.sugar", comment: ""), value: "\(Int(macros.sugar))g", progress: macros.sugar / 50, color: AIATheme.food)
                            MacroCard(title: NSLocalizedString("food.macro.sodium", comment: ""), value: "\(Int(macros.sodium))mg", progress: macros.sodium / 2000, color: AIATheme.todo)
                        }
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

                    if !foods.isEmpty {
                        // Card3 · 近7日热量
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: NSLocalizedString("food.last7days", comment: ""))
                            Chart(weekData) { p in
                                LineMark(x: .value(NSLocalizedString("chart.day", comment: ""), p.label), y: .value(NSLocalizedString("chart.kcal", comment: ""), p.value))
                                    .foregroundStyle(AIATheme.food)
                                    .interpolationMethod(.monotone)
                            }
                            .frame(height: 64)
                            .chartYScale(domain: safeYDomain(weekData.map(\.value)))
                            .chartYAxis(.hidden).chartXAxis(.hidden)
                        }
                        .padding(12)
                        .card(radius: AIATheme.rMD)

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
                    }

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
                AIPrompt(text: "吃了什么美食？点此阿宝帮你记", pointsTo: nil),
                AIPrompt(text: "点麦克风，语音记录饮食", pointsTo: .mic),
                AIPrompt(text: "阿宝帮总结今天的饮食情况", pointsTo: nil),
                AIPrompt(text: "点相册上传、记录美食", pointsTo: .album)
            ], entrySource: "food")
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(LocalizedStringKey("food.navTitle"))
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
            AddFoodManualView()
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
        .sheet(item: $editFood) { food in
            EditFoodView(entry: food)
        }
        .onAppear { meal = FoodListView.defaultMeal(for: .now) }
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker)
    }

    private func weekday(for date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func deleteFood(_ f: FoodEntry) {
        // 使用 SafeDelete 软删：设置 syncDeleted=true 后由 CloudSyncManager 推送到云端，
        // 避免直接硬删导致 deleted=true 标志无法到达云端（详见 SafeDelete 注释）。
        SafeDelete.food(f, in: context)
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
    @StateObject private var health = HealthManager.shared

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

    // MARK: 圆环数据来源
    // 已接入 HealthKit 且真正读到过非零数据 → 自动同步 HealthKit 当日数据，禁止手动修改；
    // 未接入 HealthKit（模拟器/免费账号/被拒绝/无 entitlement）→ 回退到手动录入增量，点击圆环 +N。
    private var usesHealthKit: Bool { health.authorized && health.isAvailable && health.hasHealthKitData }

    private var stepsCurrentValue: Int {
        usesHealthKit ? Int(health.stepsToday) : ManualHealthStore.shared.steps(for: Date())
    }
    private var sleepCurrentValue: Double {
        let stored = healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0
        return usesHealthKit ? stored : stored + ManualHealthStore.shared.sleepHours(for: Date())
    }
    private var exerciseCurrentValue: Double {
        usesHealthKit ? health.exerciseTimeToday : health.exerciseTimeToday + Double(ManualHealthStore.shared.exerciseMinutes(for: Date()))
    }
    /// TDEE 实际达成 = 静息能量 + 活动能量。
    /// 已接入 HealthKit 且读到数据 → 自动同步；
    /// 未接入 → 回退到手动录入的活动热量（点击圆环 +100 kcal）。
    private var tdeeCurrentValue: Double {
        usesHealthKit
            ? health.restingEnergyToday + health.activeEnergyToday
            : Double(ManualHealthStore.shared.activeCalories(for: Date()))
    }

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
    /// HealthKit 已接入时禁止手动修改，直接返回。
    private func incrementMetric(_ kind: HealthMetricKind) {
        guard !usesHealthKit else { return }
        switch kind {
        case .steps: ManualHealthStore.shared.addSteps(1000, for: Date())
        case .sleep: ManualHealthStore.shared.addSleepHours(1, for: Date())
        case .exercise: ManualHealthStore.shared.addExerciseMinutes(10, for: Date())
        case .tdee: ManualHealthStore.shared.addActiveCalories(100, for: Date())
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func bumpText(_ kind: HealthMetricKind) -> String {
        switch kind {
        case .steps: return "+1000 步"
        case .sleep: return "+1 小时"
        case .exercise: return "+10 分钟"
        case .tdee: return "+100 kcal"
        }
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

    private var sleepHours: Double {
        healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0
    }
    private func stat(_ key: String) -> String {
        healths.first(where: { $0.metric.contains(key) }).map { "\($0.value)\($0.unit)" } ?? "—"
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
                VStack(alignment: .leading, spacing: 12) {
                    // 2026-07-30：重装后若云端本就没有健康数据（当初录入时未登录导致未上云），
                    // 页面会静默空白。这里在「已登录却全空」时给出明确引导：一键从云端恢复；
                    // 若恢复后仍为空，则说明云端无备份，需重新录入（本次会自动上云）。
                    if UserDefaults.standard.bool(forKey: "aia.isLoggedIn") && healths.isEmpty && stepsCurrentValue == 0 {
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
                                Text("从云端恢复数据")
                                    .font(AIATheme.Font.body.weight(.medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(10)
                                    .background(AIATheme.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                            }
                        }
                        .padding(12)
                        .background(AIATheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    // Card A · 今日概览（圆环 + 关键指标）
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            HealthRingButton(
                                kind: .steps,
                                value: stepsCurrentValue > 0 ? "\(stepsCurrentValue)" : "—",
                                caption: NSLocalizedString("health.ring.steps", comment: ""),
                                secondary: stepGoal > 0 ? "目标 \(stepGoal)" : nil,
                                progress: stepGoal > 0 ? min(Double(stepsCurrentValue) / Double(stepGoal), 1) : 0,
                                onTap: { incrementMetric(.steps) },
                                bumpText: bumpText(.steps),
                                enabled: !usesHealthKit
                            )

                            HealthRingButton(
                                kind: .sleep,
                                value: sleepCurrentValue > 0 ? String(format: "%.1f", sleepCurrentValue) : "—",
                                caption: NSLocalizedString("health.ring.sleep", comment: ""),
                                secondary: sleepGoalHours > 0 ? "目标 \(Int(sleepGoalHours))h" : nil,
                                progress: sleepGoalHours > 0 ? min(sleepCurrentValue / sleepGoalHours, 1) : 0,
                                onTap: { incrementMetric(.sleep) },
                                bumpText: bumpText(.sleep),
                                enabled: !usesHealthKit
                            )

                            HealthRingButton(
                                kind: .exercise,
                                value: exerciseCurrentValue > 0 ? "\(Int(exerciseCurrentValue))" : "—",
                                caption: NSLocalizedString("health.ring.exercise", comment: ""),
                                secondary: exerciseGoalMin > 0 ? "目标 \(Int(exerciseGoalMin))min" : nil,
                                progress: exerciseGoalMin > 0 ? min(exerciseCurrentValue / exerciseGoalMin, 1) : 0,
                                onTap: { incrementMetric(.exercise) },
                                bumpText: bumpText(.exercise),
                                enabled: !usesHealthKit
                            )

                            HealthRingButton(
                                kind: .tdee,
                                value: tdeeCurrentValue > 0 ? "\(Int(tdeeCurrentValue))" : "—",
                                caption: NSLocalizedString("health.ring.energy", comment: ""),
                                secondary: tdeeGoal > 0 ? "目标 \(Int(tdeeGoal))" : nil,
                                progress: tdeeGoal > 0 ? min(tdeeCurrentValue / tdeeGoal, 1) : 0,
                                onTap: { incrementMetric(.tdee) },
                                bumpText: bumpText(.tdee),
                                enabled: !usesHealthKit
                            )
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            Button { NavigationRouter.shared.navigate(.bodyData) } label: {
                                StatCard(value: weightDisplay, caption: NSLocalizedString("health.stat.weight", comment: ""))
                            }
                            .buttonStyle(.plain)
                            Button { NavigationRouter.shared.navigate(.bodyData) } label: {
                                StatCard(value: heightDisplay, caption: NSLocalizedString("health.stat.height", comment: ""))
                            }
                            .buttonStyle(.plain)
                            Button { NavigationRouter.shared.navigate(.bodyData) } label: {
                                StatCard(value: bmiDisplay, caption: NSLocalizedString("health.stat.bmi", comment: ""))
                            }
                            .buttonStyle(.plain)
                            StatCard(value: stat("心率"), caption: NSLocalizedString("health.stat.restingHR", comment: ""))
                        }
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

                    // Card · 健康目标（点击进入可编辑）
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
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(AIATheme.Font.caption).foregroundStyle(AIATheme.muted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 让整条横条（包含 padding 空白区）都可点击
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .card(radius: AIATheme.rMD)

                    // Card B · 近 7 日步数（由「本周步数」上移至此，替代原体重趋势模块位置）
                    VStack(alignment: .leading, spacing: 8) {
                        if !healths.isEmpty {
                            SectionTitle(text: NSLocalizedString("health.weekSteps", comment: ""))
                            Chart(weekSteps) { p in
                                BarMark(x: .value(NSLocalizedString("chart.day", comment: ""), p.label), y: .value(NSLocalizedString("chart.step", comment: ""), p.value))
                                    .foregroundStyle(AIATheme.health.opacity(0.7))
                            }
                            .frame(height: 70)
                            .chartYScale(domain: safeYDomain(weekSteps.map(\.value)))
                            .chartYAxis(.hidden).chartXAxis(.hidden)
                        }
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

                    // Card C · 睡眠阶段
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: NSLocalizedString("health.sleepStages", comment: ""))
                        CardRow(icon: "🌙", iconBG: AIATheme.surfaceSecondary, title: String(format: NSLocalizedString("health.sleep.deep", comment: ""), 1.8), subtitle: String(format: NSLocalizedString("health.sleep.deepSub", comment: ""), 25), value: "25%")
                        CardRow(icon: "💤", iconBG: AIATheme.surfaceSecondary, title: String(format: NSLocalizedString("health.sleep.light", comment: ""), 4.2), subtitle: NSLocalizedString("common.none", comment: ""), value: "58%")
                        CardRow(icon: "⚡", iconBG: AIATheme.surfaceSecondary, title: String(format: NSLocalizedString("health.sleep.rem", comment: ""), 1.2), subtitle: NSLocalizedString("health.sleep.remSub", comment: ""), value: "17%")
                    }
                    .padding(12)
                    .card(radius: AIATheme.rMD)

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
                            SelectableRow(
                                isSelecting: multiSelectMode,
                                isSelected: selectedIDs.contains(h.persistentModelID),
                                onTap: { editHealth = h },
                                onLongPress: { enterHealthMultiSelect(h.persistentModelID) },
                                onToggle: { toggleHealthSelection(h.persistentModelID) },
                                onDelete: { SafeDelete.health(h, in: context) }
                            ) {
                                HStack(spacing: 12) {
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
    @State private var billScrollPosition = ScrollPosition()

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

                // 第 2 页：本周账单 + 本年账单
                HStack(spacing: 0) {
                    summaryDonutCard(titleKey: "bill.thisWeek", bills: weekExpenseBills, mode: .week)
                    Divider().frame(height: 120)
                    summaryDonutCard(titleKey: "bill.thisYear", bills: yearExpenseBills, mode: .year)
                }
                .padding(12)
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
                VStack(alignment: .leading, spacing: 12) {
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

                    // Card · 月度预算
                    VStack(alignment: .leading, spacing: 8) {
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

                            // 同理：monthlyGroups 派生自 @Query，用元素遍历避免下标越界。
                            // 用 enumerated() 取 offset 作 id，避免 tuple 需 Hashable 且保证单次 render 内稳定。
                            ForEach(Array(monthlyGroups.enumerated()), id: \.offset) { idx, group in
                                Button {
                                    NavigationRouter.shared.navigate(.monthlyBillList(year: group.year, month: group.month))
                                } label: {
                                    monthlySummaryRow(group)
                                }
                                .buttonStyle(.plain)
                                // 月份卡片之间加 hairline 分隔，最后一张不画
                                if idx < monthlyGroups.count - 1 {
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
                        ForEach(Array(groupedByDate.enumerated()), id: \.offset) { idx, group in
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
                                        onDelete: { SafeDelete.bill(b, in: context) }
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
            AIBottomBar(prompts: [
                AIPrompt(text: "点拍照识别、记录账单、小票", pointsTo: .camera),
                AIPrompt(text: "今天花了多少钱？点此阿宝帮你记", pointsTo: nil),
                AIPrompt(text: "点麦克风，语音记录账单", pointsTo: .mic),
                AIPrompt(text: "阿宝帮总结这个月的消费情况", pointsTo: nil),
                AIPrompt(text: "点相册上传，自动记账", pointsTo: .album)
            ], entrySource: "bill")
        }
        .scrollPosition($billScrollPosition)
        .onChange(of: merchantSearchFocused) { _, focused in
            if focused {
                // 等键盘布局完成后再滚动，确保搜索框稳定停在列表区域最顶部，
                // 不被系统「最小滚动露出输入框」的键盘避让逻辑抵消。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        billScrollPosition.scrollTo(id: "billDetailTop", anchor: .top)
                    }
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(LocalizedStringKey("tab.bill"))
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
        SafeDelete.bill(b, in: context)
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
                            Button {
                                editBill = b
                            } label: {
                                groupedBillRow(b)
                            }
                            .buttonStyle(.plain)
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
    private var groupedByDate: [(date: Date?, reminders: [Reminder])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: list) { r -> Date? in
            r.due.map { cal.startOfDay(for: $0) }
        }
        // 排序方向按当前 filter 区分：
        //   - 未完成：日期升序（最早/快过期的在前——"先做快过期的"）
        //   - 已完成：日期倒序（最近完成日期在前——用户视角"最近都完成了什么"）
        let descending = filter == .finished
        return grouped.sorted { a, b in
            switch (a.key, b.key) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (d1?, d2?): return descending ? d1 > d2 : d1 < d2
            }
        }.map { (date: $0.key, reminders: $0.value.sorted {
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
                                    todoRow(r)
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
            ], entrySource: "todo")
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(LocalizedStringKey("tab.todo"))
        .toolbar {
            if !multiSelectMode {
                addTodoToolbarItem
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
                    ForEach(dayTodos) { r in
                        todoRow(r)
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
    private func todoRow(_ r: Reminder) -> some View {
        ZStack(alignment: .leading) {
            SelectableRow(
                isSelecting: multiSelectMode,
                isSelected: selectedIDs.contains(r.persistentModelID),
                onTap: { editTodo = r },
                onLongPress: { enterTodoMultiSelect(r.persistentModelID) },
                onToggle: { toggleTodoSelection(r.persistentModelID) },
                onDelete: { SafeDelete.reminder(r, in: context) }
            ) {
                todoRowContent(r)
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            todoDoneButton(r)
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
        default:
            return nil
        }
    }

    private func deleteReminder(_ r: Reminder) {
        SafeDelete.reminder(r, in: context)
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

    /// 记录来源：imageName 非空 = AI 识别；空 = 手动输入（含文字/语音/编辑）
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
                    DietTintedCard(
                        icon: "camera.fill", title: "AI 识别", count: sourceBreakdown.aiCount,
                        color: AIATheme.food, bg: AIATheme.surface
                    )
                    DietTintedCard(
                        icon: "pencil", title: "手动输入", count: sourceBreakdown.manualCount,
                        color: AIATheme.health, bg: AIATheme.surface
                    )
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
    @State private var period: DietPeriod = .thisWeek

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
                    ForEach(0..<nutritionCards.count, id: \.self) { i in
                        let c = nutritionCards[i]
                        DietNutritionCard(label: c.label, value: c.value, color: c.color)
                    }
                }

                // 底部留白
                Color.clear.frame(height: 80)
            }
            .padding(12)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(value == "—" ? AIATheme.muted : color)
            Text(label)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.sub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

enum HealthMetricKind { case steps, sleep, exercise, tdee }

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
            floats.append(RingFloatBadge())
        } label: {
            RingView(value: value, caption: caption, secondary: secondary, progress: progress,
                     color: AIATheme.health, size: 74, lineWidth: 7)
        }
        .disabled(!enabled)
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

