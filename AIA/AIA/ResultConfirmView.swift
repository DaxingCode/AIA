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

    // 常用账单分类，供确认页一键 chip 选择（顺手编辑）。
    private let commonCategories = ["餐饮", "交通", "购物", "住房", "娱乐", "医疗",
                                    "教育", "通讯", "服饰", "美妆", "旅行", "红包",
                                    "工资", "其他"]

    // 可编辑的本地副本（确认前给用户改）。一图/一消息可能有多条账单，故用数组逐条展示。
    @State private var editableBills: [EditableBill] = []
    @State private var showImageFull = false
    @State private var todoTitle: String = ""
    @State private var todoDueDate: Date = .now
    @State private var foodName: String = ""
    @State private var foodMeal: String = "午餐"     // 餐次：早餐/午餐/晚餐/其他，按识别时间自动判定，用户可改
    @State private var foodWeight: String = "100"   // 克，用户可改
    @State private var foodCaloriesPer100g: Double = 0
    @State private var foodProteinPer100g: Double = 0
    @State private var foodCarbsPer100g: Double = 0
    @State private var foodFatPer100g: Double = 0
    @State private var healthMetric: String = ""
    @State private var healthValue: String = ""
    @State private var nutritionSource: String = ""   // 营养库校正来源提示

    // 根据重量自动计算总热量
    private var foodCalories: Double {
        let weight = Double(foodWeight) ?? 100
        return foodCaloriesPer100g * weight / 100
    }

    // 根据重量自动计算总蛋白质、碳水、脂肪
    private var foodProtein: Double {
        let weight = Double(foodWeight) ?? 100
        return foodProteinPer100g * weight / 100
    }

    private var foodCarbs: Double {
        let weight = Double(foodWeight) ?? 100
        return foodCarbsPer100g * weight / 100
    }

    private var foodFat: Double {
        let weight = Double(foodWeight) ?? 100
        return foodFatPer100g * weight / 100
    }

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
        if types.contains("food"), !foodName.isEmpty { parts.append("1 条饮食") }
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
                        }
                    }
                }
            }
        }
    }

    // MARK: - 分类快捷选择 chips（一键选常用分类，减少手输）
    private func categoryChips(_ selection: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commonCategories, id: \.self) { cat in
                    let selected = selection.wrappedValue.trimmingCharacters(in: .whitespaces) == cat
                    Button {
                        selection.wrappedValue = cat
                        hideKeyboard()
                    } label: {
                        HStack(spacing: 4) {
                            Text(BillCategoryHelpers.icon(for: cat))
                                .font(AIATheme.Font.caption)
                            Text(cat)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
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

    // MARK: - 食物卡片
    private var foodCard: some View {
        sectionCard(title: "食物", icon: "fork.knife", color: AIATheme.food) {
            VStack(spacing: 12) {
                fieldRow(icon: "sun.horizon", label: "餐次") {
                    Picker("", selection: $foodMeal) {
                        ForEach(["早餐", "午餐", "晚餐", "加餐"], id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                }
                fieldRow(icon: "fork.knife", label: "名称") {
                    textField($foodName, placeholder: "输入食物名称")
                }
                HStack(spacing: 12) {
                    fieldRow(icon: "scalemass", label: "重量") {
                        HStack(spacing: 4) {
                            Spacer()
                            TextField("100", text: $foodWeight)
                                .keyboardType(.decimalPad)
                                .font(AIATheme.Font.title3.weight(.semibold))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("g")
                                .font(AIATheme.Font.callout)
                                .foregroundStyle(AIATheme.muted)
                        }
                    }
                    fieldRow(icon: "flame", label: "热量") {
                        HStack(spacing: 4) {
                            Spacer()
                            Text("\(foodCalories, specifier: "%.1f")")
                                .font(AIATheme.Font.title3.weight(.semibold))
                                .foregroundStyle(AIATheme.food)
                            Text("kcal")
                                .font(AIATheme.Font.caption)
                                .foregroundStyle(AIATheme.muted)
                        }
                    }
                }
                VStack(spacing: 8) {
                    macroRow("蛋白质", foodProtein, foodProteinPer100g, "g", AIATheme.blue)
                    macroRow("碳水", foodCarbs, foodCarbsPer100g, "g", AIATheme.amber)
                    macroRow("脂肪", foodFat, foodFatPer100g, "g", AIATheme.green)
                }
                if !nutritionSource.isEmpty {
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
            EditableBill(
                originalIndex: i,
                merchant: b.merchant ?? "",
                amount: b.amount.map { "\($0)" } ?? "",
                category: b.category ?? "",
                date: RecognitionResult.date(from: b.time) ?? .now
            )
        }

        todoTitle = result.todo?.title ?? ""
        todoDueDate = defaultTodoDueDate()

        foodName = result.food?.name ?? ""
        foodMeal = RecognitionSaver.defaultMeal(for: .now)
        foodCaloriesPer100g = result.food?.calories ?? 0
        foodProteinPer100g = result.food?.protein ?? 0
        foodCarbsPer100g = result.food?.carbs ?? 0
        foodFatPer100g = result.food?.fat ?? 0

        // 营养成分表本地 OCR 的标签值是权威，绝不被通用营养库覆盖。
        // 只有云端/文本模型估算（无真实标签）时，才用营养库做校正。
        if source == .local {
            nutritionSource = result.food?.name?.isEmpty == false
                ? "按包装标签识别"
                : ""
        } else if let ref = NutritionLibrary.shared.match(foodName) {
            foodCaloriesPer100g = ref.kcal
            foodProteinPer100g = ref.protein
            foodCarbsPer100g = ref.carbs
            foodFatPer100g = ref.fat
            nutritionSource = "已按营养库「\(ref.name)」校正：每100g \(Int(ref.kcal)) kcal"
        } else {
            nutritionSource = result.food?.name?.isEmpty == false
                ? "未匹配营养库，使用模型估算值（可手动改重量）"
                : ""
        }

        let portion = result.food?.portion ?? "100克"
        if let match = portion.range(of: #"\d+"#, options: .regularExpression) {
            foodWeight = String(portion[match])
        } else {
            foodWeight = "100"
        }

        healthMetric = result.health?.metric ?? ""
        healthValue = result.health?.value ?? ""
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
        if types.contains("food"), let f = session.food {
            let weight = Double(foodWeight) ?? 100
            let ratio = weight / 100
            f.name = foodName
            f.meal = foodMeal
            f.calories = foodCaloriesPer100g * ratio
            f.protein = foodProteinPer100g * ratio
            f.carbs = foodCarbsPer100g * ratio
            f.fat = foodFatPer100g * ratio
            f.portion = "\(Int(weight))克"
            f.weightGram = weight
            f.baseCalories = foodCaloriesPer100g
            f.baseProtein = foodProteinPer100g
            f.baseCarbs = foodCarbsPer100g
            f.baseFat = foodFatPer100g
            f.imageName = session.imageName
            HealthManager.shared.saveCaloriesConsumed(f.calories, date: .now)  // 确认时同步卡路里
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
                "carbs": n(f.carbs), "fat": n(f.fat), "portion": n(f.portion)
            ]
            let corrected: [String: Any] = [
                "name": foodName, "calories": foodCaloriesPer100g,
                "protein": foodProteinPer100g, "carbs": foodCarbsPer100g,
                "fat": foodFatPer100g, "portion": "\(Int(Double(foodWeight) ?? 100))克"
            ]
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
