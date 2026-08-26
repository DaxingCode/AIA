// BodyDataView.swift
// 身体数据记录：当前身高/体重/BMI 顶部大卡 + 历史记录按日列表 + 右下浮动 + 手动输入。
// 数据来源 SwiftData 的 HealthMetric（metric 为"身高"/"体重"/"BMI"，中英文兼容）。
// 配色使用 AIATheme.health（紫），与「健康主题」统一。
import SwiftUI
import SwiftData

/// 健身目标：HealthGoalsView 选择，DietAnalysisView 消费；存储键 aia.fitnessGoal，走 profile 通道跨设备同步。
enum FitnessGoal: String, CaseIterable {
    case cut, bulk, maintain

    var label: String {
        switch self {
        case .cut:      return NSLocalizedString("fitness.goal.cut", comment: "")
        case .bulk:     return NSLocalizedString("fitness.goal.bulk", comment: "")
        case .maintain: return NSLocalizedString("fitness.goal.maintain", comment: "")
        }
    }
    var icon: String {
        switch self {
        case .cut:      return "flame.fill"
        case .bulk:     return "dumbbell.fill"
        case .maintain: return "target"
        }
    }
    /// 每日目标热量 = TDEE × 系数：减脂 -18% 缺口 / 增肌 +10% 盈余 / 维持持平。
    /// 依据：主流文献推荐缺口 10–25%（Helms et al. 2014）取中上、盈余 10–20% 取下沿。
    var calorieMultiplier: Double {
        switch self {
        case .cut:      return 0.82
        case .bulk:     return 1.10
        case .maintain: return 1.0
        }
    }
    /// 蛋白质推荐 g/kg 体重：减脂高蛋白 2.0（防肌肉流失）/ 增肌 1.8 / 维持 1.2。
    var proteinPerKg: Double {
        switch self {
        case .cut:      return 2.0
        case .bulk:     return 1.8
        case .maintain: return 1.2
        }
    }
}

struct BodyDataView: View {
    @Query(filter: #Predicate<HealthMetric> { !$0.syncDeleted }, sort: \HealthMetric.date, order: .reverse) private var allHealths: [HealthMetric]
    @Environment(\.modelContext) private var context
    @AppStorage("aia.heightCm") private var heightCm: Double = 0
    @AppStorage("aia.weightKg") private var weightKg: Double = 0

    @State private var showAddSheet = false
    // 多选删除（与商户规则页一致：SelectableRow + MultiSelectBottomBar）
    @State private var multiSelectMode = false
    @State private var selectedDates = Set<Date>()
    @State private var showMultiDeleteConfirm = false

    private var bodyHealths: [HealthMetric] {
        allHealths.filter {
            let m = $0.metric
            let lc = m.lowercased()
            return m.contains("身高") || lc.contains("height")
                || m.contains("体重") || lc.contains("weight")
                || m.contains("BMI")
        }
    }
    /// 当前身高：优先取 @AppStorage 当前值（与健康目标页共享，双向同步），无则回落到 HealthMetric 最新记录。
    private var currentHeight: Double? {
        if heightCm > 0 { return heightCm }
        return bodyHealths.first { $0.metric.contains("身高") || $0.metric.lowercased().contains("height") }
            .flatMap { Double($0.value) }
    }
    /// 当前体重：同上，优先 @AppStorage。
    private var currentWeight: Double? {
        if weightKg > 0 { return weightKg }
        return bodyHealths.first { $0.metric.contains("体重") || $0.metric.lowercased().contains("weight") }
            .flatMap { Double($0.value) }
    }
    /// 当前 BMI：与健康目标页一致，优先由 @AppStorage 当前身高/体重计算；无则回落到 HealthMetric。
    private var currentBMI: Double? {
        if heightCm > 0, weightKg > 0 {
            return weightKg / ((heightCm / 100) * (heightCm / 100))
        }
        if let b = bodyHealths.first(where: { $0.metric.contains("BMI") }).flatMap({ Double($0.value) }) {
            return b
        }
        if let h = currentHeight, let w = currentWeight, h > 0 {
            return w / ((h / 100) * (h / 100))
        }
        return nil
    }

    /// 历史记录按"保存时刻"分组：每次保存插入的 3 条 HealthMetric（身高/体重/BMI）共享同一 Date，
    /// 因此按精确 date 分组即可让每次保存显示为独立一行（多次保存即多条记录）。
    /// 但「图片识别」路径（RecognitionSaver/ResultConfirmView）会对 healthList 里每条指标
    /// 单独创建 1 条 HealthMetric，与手动输入的"3 条共享 Date"批次混在一起时会出现「缺数据」视觉碎片。
    /// 解决：分组建完后，再合并相邻 ≤ 60 秒的批次（视为同一事件），缺失值沿用老批次，新批次覆盖。
    private var historyByDay: [DayGroup] {
        // 原始批次：按精确 date 分组（同一 Date 即同一保存批次）。
        let raw = Dictionary(grouping: bodyHealths) { $0.date }
            .keys.sorted(by: >)
            .map { savedAt in
                let items = bodyHealths.filter { $0.date == savedAt }
                let h = items.first(where: { $0.metric.contains("身高") || $0.metric.lowercased().contains("height") })
                    .flatMap { Double($0.value) }
                let w = items.first(where: { $0.metric.contains("体重") || $0.metric.lowercased().contains("weight") })
                    .flatMap { Double($0.value) }
                let b: Double? = {
                    if let v = items.first(where: { $0.metric.contains("BMI") }).flatMap({ Double($0.value) }) {
                        return v
                    }
                    if let hh = h, let ww = w, hh > 0 {
                        return ww / ((hh / 100) * (hh / 100))
                    }
                    return nil
                }()
                return DayGroup(day: savedAt, time: savedAt, height: h, weight: w, bmi: b)
            }
        return mergeAdjacentBatches(raw, window: 60)
    }

    /// 合并相邻且时间间隔 ≤ window 的批次；视为同一事件：
    /// - 缺失字段沿用老批次的值；
    /// - 双方都有的字段取新批次（时间更近）的值；
    /// - 合并后日期沿用较早的批次，时间用较晚的批次（更接近"最后修改时间"）。
    private func mergeAdjacentBatches(_ raw: [DayGroup], window: TimeInterval) -> [DayGroup] {
        let ascending = raw.sorted(by: { $0.day < $1.day })
        var merged: [DayGroup] = []
        for batch in ascending {
            if let last = merged.last,
               batch.day.timeIntervalSince(last.day) <= window {
                let m = DayGroup(
                    day: last.day,
                    time: batch.time,
                    height: batch.height ?? last.height,
                    weight: batch.weight ?? last.weight,
                    bmi: batch.bmi ?? last.bmi
                )
                merged[merged.count - 1] = m
            } else {
                merged.append(batch)
            }
        }
        return merged.reversed()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 12) {
                    currentCard
                    historyCard
                }
                .padding()
                .padding(.bottom, 80)   // 给浮动按钮留位置
            }

            // 右下浮动 + 按钮
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(AIATheme.health)
                    .clipShape(Circle())
                    .shadow(color: AIATheme.health.opacity(0.4), radius: 6, y: 3)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 24)
            .accessibilityLabel("新增身体数据")
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle("身体数据")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddSheet) {
            BodyDataAddSheet(
                initialHeight: currentHeight,
                initialWeight: currentWeight
            ) { h, w in
                save(height: h, weight: w)
            }
            .presentationDetents([.medium])
        }
        .overlay(alignment: .bottom) {
            if multiSelectMode {
                MultiSelectBottomBar(
                    count: selectedDates.count,
                    totalCount: historyByDay.count,
                    onCancel: {
                        multiSelectMode = false
                        selectedDates.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allDates = Set(historyByDay.map { $0.day })
                        if selectedDates.isSuperset(of: allDates) {
                            selectedDates.subtract(allDates)
                        } else {
                            selectedDates.formUnion(allDates)
                        }
                    },
                    onDelete: {
                        guard !selectedDates.isEmpty else { return }
                        showMultiDeleteConfirm = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: multiSelectMode)
        .alert(
            NSLocalizedString("common.confirmDelete", comment: ""),
            isPresented: $showMultiDeleteConfirm
        ) {
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { }
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                deleteSelectedGroups()
            }
        } message: {
            Text(String(format: NSLocalizedString("common.deleteCount", comment: ""), selectedDates.count))
        }
    }

    // MARK: - 当前数据卡（紫底，三列）

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前数据")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 0) {
                currentColumn(value: currentHeight.map { String(format: "%.0f", $0) } ?? "—",
                              unit: "cm", label: "身高")
                divider
                currentColumn(value: currentWeight.map { String(format: "%.1f", $0) } ?? "—",
                              unit: "kg", label: "体重")
                divider
                currentColumn(value: currentBMI.map { String(format: "%.1f", $0) } ?? "—",
                              unit: "", label: "BMI")
            }
            // >>> CHANGE-[2026-08-26 14:05:00]-BMI加WHO来源引用 开始
            bmiSourceLink
            // <<< CHANGE-[2026-08-26 14:05:00]-BMI加WHO来源引用 结束
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(AIATheme.health)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // >>> CHANGE-[2026-08-26 14:05:00]-BMI加WHO来源引用 开始
    // 原因: 审核员据 Guideline 1.4.1 要求健康/医疗计算必须展示数据来源引用（BMI 属此类）。原 BMI 仅公式展示，无来源链接。
    // 回退: 删除下方 bmiSourceLink 视图 + 在调用处移除即可
    private var bmiSourceLink: some View {
        Link("BMI 依据 WHO 标准计算", destination: URL(string: "https://www.who.int/europe/news-room/fact-sheets/item/body-mass-index-(bmi)")!)
            .font(AIATheme.Font.micro)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.top, 4)
    }
    // <<< CHANGE-[2026-08-26 14:05:00]-BMI加WHO来源引用 结束

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.3))
            .frame(width: 0.5, height: 44)
    }

    private func currentColumn(value: String, unit: String, label: String) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(value)
                .font(AIATheme.Font.title2.weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
            HStack(alignment: .center, spacing: 4) {
                Text(unit).font(AIATheme.Font.micro)
                Text(label).font(AIATheme.Font.micro)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 历史记录

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("历史记录")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(.primary)
            if historyByDay.isEmpty {
                Text("还没有身体数据记录，点右下角 + 添加第一条")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
            } else {
                ForEach(historyByDay, id: \.day) { group in
                    SelectableRow(
                        isSelecting: multiSelectMode,
                        isSelected: selectedDates.contains(group.day),
                        onTap: { },
                        onLongPress: { enterMultiSelect(group.day) },
                        onToggle: { toggleSelection(group.day) },
                        onDelete: { deleteGroup(group) }
                    ) {
                        HistoryRow(group: group)
                    }
                }
                .padding(.bottom, multiSelectMode ? 90 : 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 保存

    private func save(height: Double, weight: Double) {
        let now = Date()
        do {
            let h1 = HealthMetric()
            h1.metric = "身高"; h1.value = String(format: "%.1f", height); h1.unit = "cm"; h1.date = now
            context.insert(h1)
            let h2 = HealthMetric()
            h2.metric = "体重"; h2.value = String(format: "%.1f", weight); h2.unit = "kg"; h2.date = now
            context.insert(h2)
            let m = height / 100
            let bmi = m > 0 ? weight / (m * m) : 0
            let h3 = HealthMetric()
            h3.metric = "BMI"; h3.value = String(format: "%.1f", bmi); h3.unit = ""; h3.date = now
            context.insert(h3)
        }
        heightCm = height
        weightKg = weight
        showAddSheet = false
        UsageAnalytics.logAdd("health", source: "manual")
        // 录入身高/体重/BMI 后立即触发增量同步，绑定后小程序可见
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
    }

    // MARK: - 多选删除（与商户规则页同构：长按入多选、左滑单删、底栏批量删）

    private func enterMultiSelect(_ date: Date) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        multiSelectMode = true
        selectedDates.insert(date)
    }

    private func toggleSelection(_ date: Date) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedDates.contains(date) {
            selectedDates.remove(date)
            if selectedDates.isEmpty { multiSelectMode = false }
        } else {
            selectedDates.insert(date)
        }
    }

    /// 删除某次保存批次（共享同一 date 的 3 条 HealthMetric：身高/体重/BMI）。
    private func deleteGroup(_ group: DayGroup) {
        let target = group.day
        let batch = allHealths.filter { $0.date == target }
        // >>> CHANGE-[2026-08-17 11:24:00]-[临时对象失效崩溃] 开始
        // 原因：batch 来自 @Query 数组 allHealths，循环软删期间若 @Query 刷新会释放引用 → 下一帧访问失效对象。
        // 回退：改回 for h in batch { SafeDelete.health(h, in: context) }
        for h in batch {
            SafeDelete.healthByID(h.persistentModelID, in: context)
        }
        // <<< CHANGE-[2026-08-17 11:24:00]-[临时对象失效崩溃] 结束
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
    }

    private func deleteSelectedGroups() {
        let targets = selectedDates
        for group in historyByDay where targets.contains(group.day) {
            let batch = allHealths.filter { $0.date == group.day }
            // >>> CHANGE-[2026-08-17 11:24:30]-[临时对象失效崩溃] 开始
            // 同 deleteGroup 理由
            for h in batch {
                SafeDelete.healthByID(h.persistentModelID, in: context)
            }
            // <<< CHANGE-[2026-08-17 11:24:30]-[临时对象失效崩溃] 结束
        }
        multiSelectMode = false
        selectedDates.removeAll()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
    }
}

/// 一次测量（按日聚合）。
private struct DayGroup: Identifiable {
    let id = UUID()
    let day: Date
    let time: Date
    let height: Double?
    let weight: Double?
    let bmi: Double?
}

private struct HistoryRow: View {
    let group: DayGroup

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dayFmt.string(from: group.day))
                    .font(AIATheme.Font.footnote.weight(.medium))
                Text(Self.timeFmt.string(from: group.time))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
            }
            Spacer()
            HStack(spacing: 14) {
                valueCol(value: group.height.map { String(format: "%.1f", $0) } ?? "—", unit: "cm")
                valueCol(value: group.weight.map { String(format: "%.1f", $0) } ?? "—", unit: "kg")
                valueCol(value: group.bmi.map { String(format: "%.1f", $0) } ?? "—", unit: "BMI")
            }
        }
        .padding(10)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func valueCol(value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(AIATheme.Font.footnote.weight(.semibold))
                .foregroundStyle(AIATheme.health)
                .monospacedDigit()
            Text(unit)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
    }
}

// MARK: - 手动输入身高/体重 sheet

private struct BodyDataAddSheet: View {
    var initialHeight: Double? = nil
    var initialWeight: Double? = nil
    var onSave: (Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var heightText: String = ""
    @State private var weightText: String = ""

    /// 把 Double 默认值格式化为可编辑文本（去除无意义的 `.0`，体重保留 1 位小数）。
    private func format(_ value: Double?, trimToInt: Bool) -> String {
        guard let v = value, v > 0 else { return "" }
        if trimToInt {
            return v.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", v)
                : String(format: "%.1f", v)
        }
        return String(format: "%.1f", v)
    }

    private var canSave: Bool {
        let h = Double(heightText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let w = Double(weightText.replacingOccurrences(of: ",", with: ".")) ?? 0
        return (100...230).contains(h) && (30...250).contains(w)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("新增身体数据").font(AIATheme.Font.headline.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }.foregroundStyle(AIATheme.sub)
            }
            .padding()

            VStack(spacing: 10) {
                inputRow(label: "身高", unit: "cm", text: $heightText)
                inputRow(label: "体重", unit: "kg", text: $weightText)
            }
            .padding(.horizontal)

            Button {
                let h = Double(heightText.replacingOccurrences(of: ",", with: ".")) ?? 0
                let w = Double(weightText.replacingOccurrences(of: ",", with: ".")) ?? 0
                guard (100...230).contains(h), (30...250).contains(w) else { return }
                onSave(h, w)
            } label: {
                Text("保存")
                    .font(AIATheme.Font.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canSave ? AIATheme.health : AIATheme.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            .disabled(!canSave)

            Spacer()
        }
        .padding(.top, 8)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            // 默认带入当前身高/体重（如有），用户可自由修改
            if heightText.isEmpty { heightText = format(initialHeight, trimToInt: true) }
            if weightText.isEmpty { weightText = format(initialWeight, trimToInt: false) }
        }
    }

    private func inputRow(label: String, unit: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).font(AIATheme.Font.footnote.weight(.medium))
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
                .font(AIATheme.Font.title3.weight(.semibold))
                .monospacedDigit()
            // >>> CHANGE-[2026-08-20 14:00:00]-[深色模式文字色整改] 开始
            // 原因: 单位小字用 sub(dark 0xa1a1a6) 深色下偏暗; 改 reading(dark 0xd1d1d6) 清晰
            // 回退: 改回 AIATheme.sub
            Text(unit).font(AIATheme.Font.micro).foregroundStyle(AIATheme.reading)
            // <<< CHANGE-[2026-08-20 14:00:00]-[深色模式文字色整改] 结束
        }
        .padding(12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}