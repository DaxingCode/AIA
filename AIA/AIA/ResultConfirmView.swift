// ResultConfirmView.swift
// 识别结果确认页。两种来源：
//  - 正常流程（2026-07-22 起）：识别完成**不入库**，用户点右上角「保存」才调 autoSave 写入。
//    本页只做「查看 / 覆盖修改」，点「保存」更新已存记录，点「返回」已存结果不变。
//  - 重复流程：识别结果图片命中历史指纹时**仍自动入库**，本页顶部显示「似乎已记录过」警告，
//    告知用户可能与已有记录重复；记录已入库，用户可直接编辑/保留，或在对应列表里删除。
// UI 采用卡片化布局，与首页/设置页设计系统一致。
import SwiftUI
import SwiftData
import Combine

/// 识别来源类型别名（与 RecognizeService.RecognitionSource 一致）。模块级可见，供 ResultConfirmView 与 makeResultConfirmView 共用。
typealias RecognitionSource = RecognizeService.RecognitionSource

/// 确认页里单条账单的可编辑副本。originalIndex 记录它在识别结果 billList 中的位置，
/// 用于保存时精准映射回 session.bills（即使中间删掉某条也不乱）。
private struct EditableBill: Identifiable {
    let id = UUID()
    let originalIndex: Int
    var merchant: String
    var amount: String
    var category: String
    var date: Date
}

/// 确认页里单条食物的可编辑副本。
private struct EditableFood: Identifiable {
    let id = UUID()
    var name: String
    var meal: String
    var weightGram: String       // 克，用户可编辑
    var caloriesPer100g: Double
    var proteinPer100g: Double
    var carbsPer100g: Double
    var fatPer100g: Double
    var fiberPer100g: Double     // 膳食纤维（克/100g）
    var sugarPer100g: Double     // 糖（克/100g）
    var sodiumPer100g: Double    // 钠（毫克/100g）
}

struct ResultConfirmView: View {
    let result: RecognitionResult
    let rawText: String
    let sourceImage: UIImage?
    /// 识别来源（本地 / 云端），顶部展示「本地AI识别 / 云端AI识别」标签。
    var source: RecognitionSource = .cloud
    /// 非 nil = 已经自动入库（正常流程），applyAndSave 直接覆盖。
    var existingSession: SavedSession? = nil
    /// 非 nil = 命中重复尚未入库（重复流程），applyAndSave 时才真正入库。
    var duplicate: DuplicatePayload? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    // 查询库中已有账单，用于「相似账单去重提示」（同商户+金额相近+近7天）。
    @Query private var allBills: [Bill]


    // 可编辑的本地副本（确认前给用户改）。一图/一消息可能有多条账单，故用数组逐条展示。
    @State private var editableBills: [EditableBill] = []
    @State private var showImageFull = false
    @State private var todoTitle: String = ""
    @State private var todoDueDate: Date = .now
    // 可编辑食物列表：支持图片/文字识别出多种食物时逐条编辑保存
    @State private var editableFoods: [EditableFood] = []
    @State private var healthMetric: String = ""
    @State private var healthValue: String = ""
    @State private var nutritionSource: String = ""   // 营养库校正来源提示

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(spacing: 8) {
                            typeBadge
                            sourceBadge
                        }
                        if !saveSummaryText.isEmpty { saveSummaryBanner }
                        if effectiveDuplicateHint != nil { duplicateWarning }
                        imageSection
                        let types = result.types ?? []
                        if types.contains("bill") { billCardsSection }
                        if types.contains("todo") { todoCard }
                        if types.contains("food") { foodCard }
                        if types.contains("health") { healthCard }
                        if types.contains("none") || types.isEmpty { noneCard }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { hideKeyboard() }
            }
            .navigationTitle("确认识别结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回") { dismiss() }
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.sub)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        applyAndSave(); dismiss()
                    } label: {
                        Text("保存")
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(AIATheme.blue)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .onAppear(perform: fillFromResult)
        }
    }

    // MARK: - 类型徽章
    private var typeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: typeIcon)
            Text(typeLabel)
        }
        .font(AIATheme.Font.footnote.weight(.medium))
        .foregroundStyle(typeColor)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(typeColor.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - 识别来源徽章
    private var sourceBadge: some View {
        let isLocal = source == .local
        let label = isLocal ? "本地AI识别" : "云端AI识别"
        let color = isLocal ? AIATheme.green : AIATheme.blue
        let icon = isLocal ? "cpu.fill" : "icloud.fill"
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(AIATheme.Font.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private var typeLabel: String {
        let types = result.types ?? []
        if types.contains("bill") { return "账单" }
        if types.contains("todo") { return "待办" }
        if types.contains("food") { return "食物" }
        if types.contains("health") { return "健康" }
        return "未识别"
    }

    private var typeIcon: String {
        let types = result.types ?? []
        if types.contains("bill") { return "yensign.circle" }
        if types.contains("todo") { return "checkmark.square" }
        if types.contains("health") { return "heart.text.square" }
        return "questionmark.circle"
    }

    private var typeColor: Color {
        let types = result.types ?? []
        if types.contains("bill") { return AIATheme.bill }
        if types.contains("todo") { return AIATheme.todo }
        if types.contains("food") { return AIATheme.food }
        if types.contains("health") { return AIATheme.health }
        return AIATheme.muted
    }

    // MARK: - 多意图批量确认摘要
    /// 一图/一句话可能含多类意图（如「付完款记得交报表」= 账单+待办），
    /// 顶部汇总本次将保存的条目，让用户对「一次批量确认」有明确预期。
    private var saveSummaryText: String {
        let types = result.types ?? []
        var parts: [String] = []
        if types.contains("bill"), !editableBills.isEmpty {
            parts.append("\(editableBills.count) 笔账单")
        }
        if types.contains("todo"), !todoTitle.isEmpty { parts.append("1 条待办") }
        if types.contains("food"), !editableFoods.isEmpty { parts.append("\(editableFoods.count) 条饮食") }
        if types.contains("health"), !healthMetric.isEmpty { parts.append("1 条健康") }
        // 单一意图且单条时不显示（无批量含义），多条或多类型才提示
        guard parts.count > 1 || editableBills.count > 1 else { return "" }
        return parts.joined(separator: " · ")
    }

    private var saveSummaryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(AIATheme.Font.callout)
                .foregroundStyle(AIATheme.blue)
            Text("本次将保存：\(saveSummaryText)")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AIATheme.blue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    // MARK: - 相似账单去重（基于内容，非图片指纹）
    /// 正常流程下当前 session 的账单已自动入库，需排除自身避免误判为「相似」。
    private var currentSessionBillIds: Set<UUID> {
        Set((existingSession?.bills ?? []).map { $0.syncId })
    }

    /// 查找与给定账单内容相近的历史记录：近 7 天内、同（或包含关系）商户、金额 ±5%(至少±1元)。
    /// 用于确认页提示「这笔可能和之前某笔重复」，避免同一笔消费被记两次。
    private func similarBills(merchant: String, amount: Double, date: Date) -> [Bill] {
        let m = merchant.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, amount > 0 else { return [] }
        let excluded = currentSessionBillIds
        let window: TimeInterval = 7 * 86_400
        let tol = max(1.0, amount * 0.05)
        return allBills.filter { b in
            if excluded.contains(b.syncId) || b.syncDeleted { return false }
            guard abs(b.time.timeIntervalSince(date)) <= window else { return false }
            let bm = b.merchant.trimmingCharacters(in: .whitespaces)
            guard !bm.isEmpty, bm == m || bm.contains(m) || m.contains(bm) else { return false }
            return abs(b.amount - amount) <= tol
        }.sorted { $0.time > $1.time }
    }

    private func similarBillHint(_ bills: [Bill]) -> some View {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let first = bills[0]
        let dateStr = f.string(from: first.time)
        let extra = bills.count > 1 ? " 等 \(bills.count) 笔" : ""
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("可能与已有账单重复")
                    .font(AIATheme.Font.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(dateStr) \(first.merchant) ¥\(first.amount, specifier: "%.2f")\(extra)")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(AIATheme.warn.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    // 疑似重复提示：优先取自动入库后挂上的 hint（新流程，已入库）；
    // 兼容旧的 .duplicate 流程（未入库，点「仍要记录」才入库）。
    private var effectiveDuplicateHint: DuplicateHint? {
        existingSession?.duplicateHint
            ?? duplicate.map { DuplicateHint(recognizedAt: $0.recognizedAt, summary: $0.summary, existingTypes: $0.existingTypes) }
    }

    // MARK: - 重复警告横幅
    private var duplicateWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AIATheme.Font.body)
                .foregroundStyle(AIATheme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("这张截图似乎已记录过")
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(duplicateDateText) · \(effectiveDuplicateHint?.summary ?? "")")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AIATheme.warn.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private var duplicateDateText: String {
        guard let d = effectiveDuplicateHint else { return "" }
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: d.recognizedAt)
    }

    // MARK: - 卡片容器
    private func sectionCard<Content: View>(title: String, icon: String, color: Color,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            content()
        }
        .padding(14)
        .card()
    }

    // MARK: - 字段行
    private func fieldRow<Content: View>(icon: String, label: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text(label)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            content()
        }
        .padding(12)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    /// 单行内嵌版 fieldRow：icon + 标题 在左，输入控件 + 单位 在右（用 Spacer 推开）。
    /// 适合重量/热量等需要在同一行展示「标题 + 数值」的紧凑场景；视觉上比默认 fieldRow 省一行高度。
    private func inlineFieldRow<Content: View>(icon: String, label: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text(label)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            Spacer(minLength: 8)
            content()
        }
        .padding(12)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    private func textField(_ text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .font(AIATheme.Font.callout)
            .foregroundStyle(.primary)
    }

    // MARK: - 日期+时间统一行（账单/待办复用）
    private func dateTimeRow(icon: String, label: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text(label)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
            }
            HStack(spacing: 16) {
                VStack(alignment: .center, spacing: 4) {
                    Text("日期")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                    DatePicker("", selection: selection, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .center, spacing: 4) {
                    Text("时间")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                    DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    // MARK: - 账单卡片（支持一图多账单，逐条展示）
    private var billCardsSection: some View {
        ForEach(Array(editableBills.enumerated()), id: \.element.id) { index, _ in
            let eb = $editableBills[index]
            let similar = similarBills(merchant: editableBills[index].merchant,
                                       amount: Double(editableBills[index].amount) ?? 0,
                                       date: editableBills[index].date)
            sectionCard(title: editableBills.count > 1 ? "账单 \(index + 1) / \(editableBills.count)" : "账单", icon: "yensign.circle", color: AIATheme.bill) {
                VStack(spacing: 12) {
                    if editableBills.count > 1 {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation {
                                    var arr: [EditableBill] = editableBills
                                    arr.remove(at: index)
                                    editableBills = arr
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                                    .font(AIATheme.Font.caption.weight(.medium))
                                    .foregroundStyle(AIATheme.warn)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !similar.isEmpty { similarBillHint(similar) }
                    fieldRow(icon: "building.2", label: "商户/标题") {
                        textField(eb.merchant, placeholder: "输入商户名称")
                    }
                    fieldRow(icon: "yensign.circle", label: "金额") {
                        HStack(spacing: 4) {
                            Text("¥")
                                .font(AIATheme.Font.title1.weight(.semibold))
                                .foregroundStyle(AIATheme.bill)
                            TextField("0.00", text: eb.amount)
                                .keyboardType(.decimalPad)
                                .font(AIATheme.Font.display.weight(.semibold))
                                .foregroundStyle(AIATheme.bill)
                        }
                    }
                    dateTimeRow(icon: "calendar.badge.clock", label: "日期时间", selection: eb.date)
                    fieldRow(icon: "tag", label: "分类") {
                        VStack(alignment: .leading, spacing: 8) {
                            textField(eb.category, placeholder: "输入分类")
                            categoryChips(eb.category)
                            let willBeIncome = RecognitionSaver.isIncomeCategory(eb.category.wrappedValue)
                            HStack(spacing: 4) {
                                Image(systemName: willBeIncome ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                    .font(AIATheme.Font.micro)
                                Text(willBeIncome ? "将记为收入" : "将记为支出")
                                    .font(AIATheme.Font.micro)
                            }
                            .foregroundStyle(willBeIncome ? AIATheme.income : AIATheme.expense)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 分类快捷选择 chips（使用与编辑页完全一致的 billCategoryOptions，保证名称、数量、图标统一）
    private func categoryChips(_ selection: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(billCategoryOptions, id: \.self) { cat in
                    let selected = selection.wrappedValue.trimmingCharacters(in: .whitespaces) == cat
                    Button {
                        selection.wrappedValue = cat
                        hideKeyboard()
                    } label: {
                        HStack(spacing: 4) {
                            Text(BillCategoryHelpers.icon(for: cat))
                                .font(AIATheme.Font.caption)
                            Text(cat)
                                .font(AIATheme.Font.micro.weight(selected ? .semibold : .regular))
                        }
                        .foregroundStyle(selected ? .white : AIATheme.sub)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(selected ? AIATheme.blue : AIATheme.surface)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(AIATheme.hairline, lineWidth: selected ? 0 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 待办卡片
    private var todoCard: some View {
        sectionCard(title: "待办", icon: "checkmark.square", color: AIATheme.todo) {
            VStack(spacing: 12) {
                fieldRow(icon: "text.bubble", label: "事项") {
                    textField($todoTitle, placeholder: "输入待办事项")
                }
                dateTimeRow(icon: "calendar.badge.clock", label: "日期时间", selection: $todoDueDate)
            }
        }
    }

    // MARK: - 食物卡片（支持多食物列表）
    private var foodCard: some View {
        sectionCard(title: "食物", icon: "fork.knife", color: AIATheme.food) {
            VStack(spacing: 12) {
                if editableFoods.isEmpty {
                    Text("未识别到食物")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(AIATheme.muted)
                        .padding(.vertical, 8)
                }
                ForEach(Array(editableFoods.enumerated()), id: \.element.id) { idx, _ in
                    foodItemCard(idx: idx)
                }
                // 营养校正来源提示（仅在单食物且已校正时显示，多食物时不显示以免混淆）
                if editableFoods.count == 1, !nutritionSource.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(nutritionSource.hasPrefix("已按") ? AIATheme.ok : AIATheme.muted)
                        Text(nutritionSource)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(nutritionSource.hasPrefix("已按") ? AIATheme.ok : AIATheme.muted)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background((nutritionSource.hasPrefix("已按") ? AIATheme.ok : AIATheme.muted).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                }
            }
        }
    }

    /// 单条食物编辑卡片
    private func foodItemCard(idx: Int) -> some View {
        let binding = Binding<EditableFood>(
            get: { editableFoods[idx] },
            set: { editableFoods[idx] = $0 }
        )
        let food = editableFoods[idx]
        let weight = Double(food.weightGram) ?? 100
        let ratio = weight / 100
        let totalCal = food.caloriesPer100g * ratio
        let totalPro = food.proteinPer100g * ratio
        let totalCar = food.carbsPer100g * ratio
        let totalFat = food.fatPer100g * ratio
        let totalFiber = food.fiberPer100g * ratio
        let totalSugar = food.sugarPer100g * ratio
        let totalSodium = food.sodiumPer100g * ratio

        return VStack(spacing: 10) {
            // 餐次 + 名称
            HStack(spacing: 10) {
                fieldRow(icon: "sun.horizon", label: "餐次") {
                    Picker("", selection: binding.meal) {
                        ForEach(["早餐", "午餐", "晚餐", "加餐"], id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            fieldRow(icon: "fork.knife", label: "名称") {
                textField(binding.name, placeholder: "输入食物名称")
            }
            HStack(spacing: 12) {
                // 重量：标题 + 输入框 + 单位 同一行（inlineFieldRow）
                inlineFieldRow(icon: "scalemass", label: "重量") {
                    HStack(spacing: 2) {
                        TextField("100", text: binding.weightGram)
                            .keyboardType(.decimalPad)
                            .font(AIATheme.Font.title3.weight(.semibold))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 70)
                        Text("g")
                            .font(AIATheme.Font.callout)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
                // 热量：标题 + 只读数值 + 单位 同一行（inlineFieldRow）
                inlineFieldRow(icon: "flame", label: "热量") {
                    HStack(spacing: 2) {
                        Text("\(totalCal, specifier: "%.1f")")
                            .font(AIATheme.Font.title3.weight(.semibold))
                            .foregroundStyle(AIATheme.food)
                        Text("kcal")
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
            }
            // 6 大营养素 2×3 网格：每行 3 个 cell，2 行共 6 项
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                      spacing: 8) {
                macroCell("蛋白质", totalPro, food.proteinPer100g, "g", AIATheme.blue)
                macroCell("碳水", totalCar, food.carbsPer100g, "g", AIATheme.amber)
                macroCell("脂肪", totalFat, food.fatPer100g, "g", AIATheme.green)
                macroCell("膳食纤维", totalFiber, food.fiberPer100g, "g", AIATheme.purple)
                macroCell("糖", totalSugar, food.sugarPer100g, "g", AIATheme.warn)
                macroCell("钠", totalSodium, food.sodiumPer100g, "mg", AIATheme.warning)
            }
        }
        .padding(12)
        .background(AIATheme.dietBG)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private func macroRow(_ name: String, _ total: Double, _ per100: Double, _ unit: String, _ color: Color) -> some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name)
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(AIATheme.sub)
            }
            Spacer()
            Text("\(total, specifier: "%.1f") \(unit)")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(.primary)
            Text("(\(per100, specifier: "%.1f") / 100g)")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    /// 营养网格单元（只读版）：彩色圆点 + 名称 / 数值 + 单位 / 每 100g 参考，三行内容；
    /// 适合 2×3 LazyVGrid 网格布局使用——与 EditFoodView.nutritionCell 视觉风格对齐（fillSoft 底 / rXS 圆角）。
    private func macroCell(_ name: String, _ total: Double, _ per100: Double, _ unit: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name)
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.sub)
                    .lineLimit(1)
            }
            Text("\(total, specifier: "%.1f") \(unit)")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text("(\(per100, specifier: "%.1f")/100g)")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AIATheme.fillSoft)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rXS))
    }

    // MARK: - 健康卡片
    private var healthCard: some View {
        sectionCard(title: "健康", icon: "heart.text.square", color: AIATheme.health) {
            VStack(spacing: 12) {
                fieldRow(icon: "heart.text.square", label: "指标") {
                    textField($healthMetric, placeholder: "如体重、心率")
                }
                fieldRow(icon: "number", label: "数值") {
                    textField($healthValue, placeholder: "输入数值")
                }
            }
        }
    }

    // MARK: - 未识别
    private var noneCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(AIATheme.Font.hero)
                .foregroundStyle(AIATheme.muted)
            Text("未识别到可记录的内容")
                .font(AIATheme.Font.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text("可以返回或重新截屏识别")
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .card()
    }

    // MARK: - 识别原图（与详情页 AttachmentSection 同款）
    private var imageSection: some View {
        Group {
            if let img = sourceImage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("识别原图")
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(AIATheme.sub)
                    Button {
                        showImageFull = true
                    } label: {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
                            .overlay(alignment: .bottomTrailing) {
                                Label("仅本地", systemImage: "lock.fill")
                                    .font(AIATheme.Font.micro.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.black.opacity(0.45))
                                    .clipShape(Capsule())
                                    .padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                }
                .fullScreenCover(isPresented: $showImageFull) {
                    FullImageView(image: img)
                }
            }
        }
    }

    // MARK: - 待办日期/时间默认值
    private func defaultTodoDueDate() -> Date {
        RecognitionSaver.dueDate(from: result.todo?.due)
    }

    // 用模型结果预填表单（展示已自动入库的原始识别 / 或重复待确认的原始识别）
    private func fillFromResult() {
        editableBills = result.billList.enumerated().map { (i, b) in
            let rawMerchant = b.merchant ?? ""
            // 收入类（工资/奖金/退款等）截图云端常不返商户名：默认「收入」，
            // 用户可直接保存，也可改成真实付款方（如公司名）。
            let defaultMerchant = rawMerchant.isEmpty
                ? (RecognitionSaver.isIncomeCategory(b.category ?? "") ? "收入" : "")
                : rawMerchant
            return EditableBill(
                originalIndex: i,
                merchant: defaultMerchant,
                amount: b.amount.map { "\($0)" } ?? "",
                category: b.category ?? "",
                date: RecognitionResult.date(from: b.time) ?? Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: .now) ?? .now
            )
        }

        todoTitle = result.todo?.title ?? ""
        todoDueDate = defaultTodoDueDate()

        // 逐条填充 editableFoods（识别结果中单条 food，可能为空）
        let foods: [FoodPayload] = result.food.map { [$0] } ?? []
        let defaultMeal = RecognitionSaver.defaultMeal(for: .now)
        editableFoods = foods.map { f in
            let portion = f.portion ?? "100克"
            let weight = (portion.range(of: #"\d+"#, options: .regularExpression).map { String(portion[$0]) }) ?? "100"
            return EditableFood(
                name: f.name ?? "",
                meal: f.meal ?? defaultMeal,
                weightGram: weight,
                caloriesPer100g: f.calories ?? 0,
                proteinPer100g: f.protein ?? 0,
                carbsPer100g: f.carbs ?? 0,
                fatPer100g: f.fat ?? 0,
                fiberPer100g: f.fiber ?? 0,
                sugarPer100g: f.sugar ?? 0,
                sodiumPer100g: f.sodium ?? 0
            )
        }

        // 营养成分表本地 OCR 的标签值是权威，绝不被通用营养库覆盖。
        // 其它食物走三级校正：① 硬编码营养库 → ② 本地联网缓存(FoodMetaStore) → ③ 联网查询并落库。
        // 仅对单食物做校正；多食物时不做自动校正（避免批次查询慢）
        if let firstFood = editableFoods.first, editableFoods.count == 1 {
            let name = firstFood.name
            if source == .local {
                nutritionSource = name.isEmpty ? "" : "按包装标签识别"
            } else if let ref = NutritionLibrary.shared.match(name) {
                editableFoods[0].caloriesPer100g = ref.kcal
                editableFoods[0].proteinPer100g = ref.protein
                editableFoods[0].carbsPer100g = ref.carbs
                editableFoods[0].fatPer100g = ref.fat
                editableFoods[0].fiberPer100g = ref.fiber
                editableFoods[0].sugarPer100g = ref.sugar
                editableFoods[0].sodiumPer100g = ref.sodium
                nutritionSource = "已按营养库「\(ref.name)」校正：每100g \(Int(ref.kcal)) kcal"
            } else if let meta = FoodMetaStore.lookup(name, in: context) {
                editableFoods[0].caloriesPer100g = meta.kcal
                editableFoods[0].proteinPer100g = meta.protein
                editableFoods[0].carbsPer100g = meta.carbs
                editableFoods[0].fatPer100g = meta.fat
                editableFoods[0].fiberPer100g = meta.fiber
                editableFoods[0].sugarPer100g = meta.sugar
                editableFoods[0].sodiumPer100g = meta.sodium
                let disp = meta.displayName.isEmpty ? name : meta.displayName
                nutritionSource = "已用本地营养库「\(disp)」（联网查得）：每100g \(Int(meta.kcal)) kcal"
            } else if !name.isEmpty {
                nutritionSource = "正在联网查询营养库…"
                Task { @MainActor in await resolveFoodNutrition() }
            }
        }

        healthMetric = result.health?.metric ?? ""
        healthValue = result.health?.value ?? ""
    }

    // 营养库三级校正第 ③ 步：联网查询该食物每100g营养，成功后落库 FoodMetaStore。
    @MainActor
    private func resolveFoodNutrition() async {
        guard editableFoods.count == 1, source != .local else { return }
        let name = editableFoods[0].name
        guard !name.isEmpty else { return }
        // 二次确认本地仍未命中（避免 fillFromResult 已处理或用户已改食物名）
        if NutritionLibrary.shared.match(name) != nil { return }
        if FoodMetaStore.lookup(name, in: context) != nil { return }
        do {
            if let ref = try await RecognizeService.queryFood(name: name) {
                FoodMetaStore.upsert(name: name, displayName: ref.name,
                                     kcal: ref.kcal, protein: ref.protein,
                                     carbs: ref.carbs, fat: ref.fat,
                                     source: "cloud", in: context)
                editableFoods[0].caloriesPer100g = ref.kcal
                editableFoods[0].proteinPer100g = ref.protein
                editableFoods[0].carbsPer100g = ref.carbs
                editableFoods[0].fatPer100g = ref.fat
                editableFoods[0].fiberPer100g = ref.fiber
                editableFoods[0].sugarPer100g = ref.sugar
                editableFoods[0].sodiumPer100g = ref.sodium
                nutritionSource = "已联网查询营养库「\(ref.name)」并保存"
            } else {
                nutritionSource = "未查到营养，使用模型估算值（可手动改）"
            }
        } catch {
            nutritionSource = "联网查询失败，使用模型估算值（可手动改）"
        }
    }

    // 把用户表单同步回记录（覆盖），并触发确认后副作用（卡路里/健康同步）。
    // - 正常流程：existingSession 已存在，直接覆盖。
    // - 命中重复指纹流程：同样已自动入库（existingSession 非空），直接覆盖，仅顶部带「似乎已记录过」警告。
    // 点「返回 / 跳过」不调用此方法，已入库的结果保持不变（含疑似重复记录），由用户事后在列表决定去留。
    private func applyAndSave() {
        let ctx = context
        let types = result.types ?? []

        let session: SavedSession
        if let existing = existingSession {
            session = existing
        } else {
            // 新鲜识别 / 重复流程：此刻才真正入库并登记指纹（UI 点击在主线，安全调用 @MainActor）
            session = MainActor.assumeIsolated {
                let s = RecognitionSaver.autoSave(result: result, rawText: rawText, image: sourceImage, context: ctx)
                // 如果用户通过新鲜识别点保存，登记指纹供后续去重
                if let img = sourceImage, let hash = ImageHasher.aHash(img) {
                    // 命中重复（duplicate 非空）时不上报新指纹 —— 原指纹已在初次保存时登记
                    if duplicate == nil {
                        DuplicateStore.add(DuplicateEntry(hash: hash, recognizedAt: .now,
                                                          types: (result.types ?? []).joined(separator: ","),
                                                          summary: RecognitionSaver.summary(of: result)))
                    }
                }
                if let d = duplicate {
                    DuplicateStore.add(DuplicateEntry(hash: d.hash, recognizedAt: .now,
                                                      types: types.joined(separator: ","),
                                                      summary: RecognitionSaver.summary(of: result)))
                }
                return s
            }
        }

        if types.contains("bill") {
            let keptOrig = Set(editableBills.map { $0.originalIndex })
            for eb in editableBills {
                if eb.originalIndex < session.bills.count {
                    let b = session.bills[eb.originalIndex]
                    b.merchant = eb.merchant
                    if let amt = Double(eb.amount) { b.amount = amt }
                    b.category = eb.category
                    b.time = eb.date
                    b.isIncome = RecognitionSaver.isIncomeCategory(eb.category)
                    b.imageName = session.imageName
                }
            }
            // 用户删掉的错认账单：从库里一并删除
            for i in (0..<session.bills.count).reversed() where !keptOrig.contains(i) {
                SafeDelete.bill(session.bills[i], in: context)
            }
            session.bills = session.bills.enumerated().filter { keptOrig.contains($0.offset) }.map { $0.element }
        }
        if types.contains("todo"), let r = session.todo {
            r.title = todoTitle
            r.due = todoDueDate
            DefaultReminderSettings.shared.apply(to: r)   // 重算提醒时间点
            ReminderNotificationManager.schedule(r)        // 覆盖旧通知（按 syncId）
        }
        if types.contains("food") {
            if editableFoods.count == 1, let f = session.food {
                // 单食物：沿用原有路径，更新已有的 session.food
                let weight = Double(editableFoods[0].weightGram) ?? 100
                let ratio = weight / 100
                f.name = editableFoods[0].name
                f.meal = editableFoods[0].meal
                f.calories = editableFoods[0].caloriesPer100g * ratio
                f.protein = editableFoods[0].proteinPer100g * ratio
                f.carbs = editableFoods[0].carbsPer100g * ratio
                f.fat = editableFoods[0].fatPer100g * ratio
                f.fiber = editableFoods[0].fiberPer100g * ratio
                f.sugar = editableFoods[0].sugarPer100g * ratio
                f.sodium = editableFoods[0].sodiumPer100g * ratio
                f.portion = "\(Int(weight))克"
                f.weightGram = weight
                f.baseCalories = editableFoods[0].caloriesPer100g
                f.baseProtein = editableFoods[0].proteinPer100g
                f.baseCarbs = editableFoods[0].carbsPer100g
                f.baseFat = editableFoods[0].fatPer100g
                f.baseFiber = editableFoods[0].fiberPer100g
                f.baseSugar = editableFoods[0].sugarPer100g
                f.baseSodium = editableFoods[0].sodiumPer100g
                f.imageName = session.imageName
                HealthManager.shared.saveCaloriesConsumed(f.calories, date: .now)
            } else if editableFoods.count > 1 {
                // 多食物：每食物独立建 FoodEntry（session.food 保留最后一条，不做编辑）
                for f in editableFoods {
                    let weight = Double(f.weightGram) ?? 100
                    let ratio = weight / 100
                    let cal = f.caloriesPer100g * ratio
                    let pro = f.proteinPer100g * ratio
                    let car = f.carbsPer100g * ratio
                    let fat = f.fatPer100g * ratio
                    let fiber = f.fiberPer100g * ratio
                    let sugar = f.sugarPer100g * ratio
                    let sodium = f.sodiumPer100g * ratio
                    let entry = FoodEntry(name: f.name, calories: cal, protein: pro, carbs: car, fat: fat,
                                          fiber: fiber, sugar: sugar, sodium: sodium,
                                          portion: "\(Int(weight))克", meal: f.meal,
                                          weightGram: weight,
                                          baseCalories: f.caloriesPer100g,
                                          baseProtein: f.proteinPer100g,
                                          baseCarbs: f.carbsPer100g,
                                          baseFat: f.fatPer100g,
                                          baseFiber: f.fiberPer100g,
                                          baseSugar: f.sugarPer100g,
                                          baseSodium: f.sodiumPer100g,
                                          imageName: session.imageName)
                    context.insert(entry)
                }
            }
        }
        if types.contains("health"), let h = session.health {
            h.metric = healthMetric
            h.value = healthValue
            h.unit = result.health?.unit ?? ""
            let v = Double(healthValue) ?? 0
            if healthMetric.contains("体重") || healthMetric.lowercased().contains("weight") {
                HealthManager.shared.saveWeight(v)
            } else if healthMetric.contains("身高") || healthMetric.lowercased().contains("height") {
                HealthManager.shared.saveHeight(v)
            } else if healthMetric.contains("心率") || healthMetric.lowercased().contains("heart") {
                HealthManager.shared.saveHeartRate(v)
            }
        }

        try? ctx.save()

        // 纠错回流：仅当用户改动过识别结果才上报（相同则不报），让识别越用越懂用户习惯
        if let payload = correctionPayloads(),
           let o = try? JSONSerialization.data(withJSONObject: payload.original),
           let c = try? JSONSerialization.data(withJSONObject: payload.corrected),
           String(data: o, encoding: .utf8) != String(data: c, encoding: .utf8) {
            RecognizeService.reportCorrection(type: payload.type, original: payload.original, corrected: payload.corrected)
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - 纠错样本构建（供云端 few-shot 学习）
    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: date)
    }

    /// 构建「原始识别 vs 用户最终填写」的精简字典，仅取主类型（types 中第一个非 none）。
    /// 用于云端纠错回流：模型从中学习用户习惯（如「淘宝闪购→购物类」）。无损则返回 nil。
    private func correctionPayloads() -> (type: String, original: [String: Any], corrected: [String: Any])? {
        let types = result.types ?? []
        guard let type = types.first(where: { $0 != "none" }) else { return nil }
        let n: (Any?) -> Any = { $0 ?? NSNull() }

        switch type {
        case "bill":
            let originals: [[String: Any]] = result.billList.map { b in
                ["merchant": n(b.merchant), "amount": n(b.amount), "category": n(b.category), "time": n(b.time)]
            }
            let correctedList: [[String: Any]] = editableBills.map { eb in
                ["merchant": eb.merchant, "amount": Double(eb.amount) ?? 0, "category": eb.category, "time": isoString(eb.date)]
            }
            return (type, ["bills": originals], ["bills": correctedList])
        case "todo":
            guard let t = result.todo else { return nil }
            let original: [String: Any] = ["title": n(t.title), "due": n(t.due)]
            let corrected: [String: Any] = ["title": todoTitle, "due": isoString(todoDueDate)]
            return (type, original, corrected)
        case "food":
            guard let f = result.food else { return nil }
            let original: [String: Any] = [
                "name": n(f.name), "calories": n(f.calories), "protein": n(f.protein),
                "carbs": n(f.carbs), "fat": n(f.fat),
                "portion": n(f.portion)
            ]
            let corrected: [String: Any] = {
                guard let first = editableFoods.first else { return original }
                let weight = Double(first.weightGram) ?? 100
                return ["name": first.name, "calories": first.caloriesPer100g,
                        "protein": first.proteinPer100g, "carbs": first.carbsPer100g,
                        "fat": first.fatPer100g,
                        "fiber": first.fiberPer100g, "sugar": first.sugarPer100g, "sodium": first.sodiumPer100g,
                        "portion": "\(Int(weight))克"]
            }()
            return (type, original, corrected)
        case "health":
            guard let h = result.health else { return nil }
            let original: [String: Any] = ["metric": n(h.metric), "value": n(h.value)]
            let corrected: [String: Any] = ["metric": healthMetric, "value": healthValue]
            return (type, original, corrected)
        default:
            return nil
        }
    }
}

/// 工厂：把统一的 RecognitionPresent 转成 ResultConfirmView（含正常/重复/新鲜三种分支）。
func makeResultConfirmView(_ present: RecognitionPresent) -> ResultConfirmView {
    switch present {
    case .saved(let s):
        return ResultConfirmView(result: s.result, rawText: s.rawText, sourceImage: s.sourceImage,
                                 source: s.source, existingSession: s)
    case .duplicate(let d):
        return ResultConfirmView(result: d.result, rawText: d.rawText, sourceImage: d.sourceImage,
                                 source: d.source, duplicate: d)
    case .pending(let result, let rawText, let image, let source):
        return ResultConfirmView(result: result, rawText: rawText, sourceImage: image,
                                 source: source, existingSession: nil, duplicate: nil)
    }
}
