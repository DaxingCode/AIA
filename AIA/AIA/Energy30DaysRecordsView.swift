import SwiftUI
import SwiftData

// >>> CHANGE-[2026-08-19 14:06:49]-近30日能量页 开始
// 原因: 用户要求从饮食记录页"净热量"格跳转, 顶部展示近30天净热量汇总/摄入汇总/消耗汇总, 下方每天三列
// 回退: 删本文件 + 撤销 HomeRoute.energy30DaysRecords + ContentView 注册 + 饮食页"净热量"格跳转改回裸 VStack

/// 近 30 日能量记录页：顶部"净热量汇总 / 摄入汇总 / 消耗汇总"三块，下方倒序展示每天 净热量/摄入/消耗。
/// 消耗口径严格沿用饮食页 tdeeCurrentValue(auto: HK字典优先+落库回退, manual: ManualHealthStore.activeCalories)
/// 净热量口径: 整数减 Int(摄入) - Int(消耗), 与饮食页方案B一致
struct Energy30DaysRecordsView: View {
    @Query(filter: #Predicate<FoodEntry> { !$0.syncDeleted }) private var foods: [FoodEntry]
    private let calendar = Calendar.current
    private let daysToShow = 30
    private let health = HealthManager.shared
    private let manual = ManualHealthStore.shared

    /// 近30天汇总：净热量汇总 = 累计摄入 - 累计消耗（整数减口径）
    private var totals: (net: Int, intake: Int, burn: Int) {
        var sumIn = 0, sumOut = 0
        for day in lastNDays() {
            sumIn += intakeFor(day)
            sumOut += burnFor(day)
        }
        return (sumIn - sumOut, sumIn, sumOut)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                        .id("energyTop")
                    LazyVStack(spacing: 0) {
                        ForEach(lastNDays(), id: \.self) { day in
                            row(for: day)
                            Divider().padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .padding(.vertical, 12)
            }
            // >>> CHANGE-[2026-08-19 15:42:00]-能量页钉顶 开始
            // 原因: 进入页面时大标题转内联导航栏会触发 ScrollView 自动补偿滚动, 把顶部汇总卡推出可视区
            // 回退: 删除 onAppear 内 proxy.scrollTo + .id("energyTop") 即可恢复旧行为
            .onAppear { proxy.scrollTo("energyTop", anchor: .top) }
            // <<< CHANGE-[2026-08-19 15:42:00]-能量页钉顶 结束
        }
        .navigationTitle(NSLocalizedString("food.energy30d.title", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task { health.refreshAll() }
    }

    // MARK: - 顶部汇总卡
    private var summaryCard: some View {
        let t = totals
        return HStack(spacing: 0) {
            summaryMetric(value: t.net, label: NSLocalizedString("food.energy30d.netSum", comment: ""),
                          color: t.net >= 0 ? AIATheme.over : AIATheme.income, signed: true)
            Divider().frame(height: 44)
            summaryMetric(value: t.intake, label: NSLocalizedString("food.energy30d.inSum", comment: ""),
                          color: AIATheme.food, signed: false)
            Divider().frame(height: 44)
            summaryMetric(value: t.burn, label: NSLocalizedString("food.energy30d.outSum", comment: ""),
                          color: AIATheme.health, signed: false)
        }
        .padding(16)
        // >>> CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 开始
        // 原因: 审计P1-⑤要求卡片统一复用 .card() 组件(带描边), 替换手写 background+clipShape
        // 回退: 改回 .background(AIATheme.surfaceSecondary).clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
        .card(bg: AIATheme.surfaceSecondary, shadow: true)
        // <<< CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 结束
        .padding(.horizontal, 16)
    }

    private func summaryMetric(value: Int, label: String, color: Color, signed: Bool) -> some View {
        VStack(spacing: 4) {
            // >>> CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 开始
            // 原因: 审计P1-③字号阶梯+主次层级, label 从 micro(11) 提到 footnote(13); kcal 从第二行并入数值行
            // 回退: 改回 label 用 .micro / 单独 kcal 第二行
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(signed ? (value > 0 ? "+\(value)" : "\(value)") : "\(value)")
                    .font(AIATheme.Font.title3.weight(.semibold))
                    .foregroundStyle(color)
                Text("kcal")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            Text(label)
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.sub)
            // <<< CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 结束
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 行
    private func row(for day: Date) -> some View {
        let intake = intakeFor(day)
        let burn = burnFor(day)
        let net = max(0, intake) - max(0, burn)
        let hasAnyData = intake > 0 || burn > 0
        return HStack(spacing: 12) {
            // >>> CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 开始
            // 原因: 审计P1-③字号阶梯+信息层级, 日期改两行(subhead主行+caption星期次行), 与截图对齐
            // 回退: 改回 Text(dayLabel(day)) .font(.body) 单行
            VStack(alignment: .leading, spacing: 2) {
                Text(dayMonthDay(day))
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(.primary)
                Text(dayWeekday(day))
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.sub)
            }
            .frame(width: 72, alignment: .leading)
            // <<< CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 结束
            Spacer(minLength: 0)
            metricCell(value: net, hasData: hasAnyData, color: net >= 0 ? AIATheme.over : AIATheme.income, signed: true)
            Divider().frame(height: 24)
            // >>> CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 开始
            // 原因: 审计P0-②一致性, 摄入/消耗与顶部汇总统一语义色(food橙/health紫), 不再用 ink 灰
            // 回退: 改回 color: AIATheme.ink
            metricCell(value: intake, hasData: intake > 0, color: AIATheme.food, signed: false)
            Divider().frame(height: 24)
            metricCell(value: burn, hasData: burn > 0, color: AIATheme.health, signed: false)
            // <<< CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 结束
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metricCell(value: Int, hasData: Bool, color: Color, signed: Bool) -> some View {
        VStack(spacing: 0) {
            if !hasData {
                // >>> CHANGE-[2026-08-20 14:00:00]-[深色模式文字色整改] 开始
                // 原因: 空态"—"用 muted(dark 0x8e8e93) 深色下模糊; 改 reading(dark 0xd1d1d6) 清晰
                // 回退: 改回 AIATheme.muted
                Text("—")
                    .font(AIATheme.Font.body.weight(.medium))
                    .foregroundStyle(AIATheme.reading)
                // <<< CHANGE-[2026-08-20 14:00:00]-[深色模式文字色整改] 结束
            } else {
                Text(signed ? (value > 0 ? "+\(value)" : "\(value)") : "\(value)")
                    .font(AIATheme.Font.body.weight(.medium))
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 取数（与饮食页 tdeeCurrentValue 同口径）
    private func lastNDays() -> [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<daysToShow).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
    }

    private func intakeFor(_ day: Date) -> Int {
        foods.filter { calendar.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + Int($1.calories) }
    }

    private func burnFor(_ day: Date) -> Int {
        let tdeeSource = UserDefaults.standard.string(forKey: "aia.health.source.tdee") ?? "auto"
        let auto = tdeeSource != "manual" && health.authorized && health.isAvailable && health.hasHealthKitData
        if auto {
            let active = health.activeEnergyForDay[day] ?? manual.healthKitValue("activeCalories", for: day)
            let resting = health.restingEnergyForDay[day] ?? manual.healthKitValue("restingCalories", for: day)
            return Int(active + resting)
        }
        return manual.activeCalories(for: day)
    }

    // >>> CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 开始
    // 原因: 日期改两行展示, dayLabel 拆为 月日+星期 两个函数
    // 回退: 删掉下面两个函数, 恢复原 dayLabel 单函数
    private func dayMonthDay(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let isThisYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        f.dateFormat = isThisYear ? "M月d日" : "yyyy年M月d日"
        return f.string(from: day)
    }

    private func dayWeekday(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f.string(from: day)
    }
    // <<< CHANGE-[2026-08-19 14:22:40]-能量页UI规范化 结束
}

// <<< CHANGE-[2026-08-19 14:06:49]-近30日能量页 结束
