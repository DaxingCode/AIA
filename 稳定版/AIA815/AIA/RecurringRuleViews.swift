// RecurringRuleViews.swift
// 周期 / 订阅账单管理界面：规则列表 + 新增/编辑表单。
// 入口：账单列表页（BillListView）顶部「周期/订阅账单」按钮跳转至此。
import SwiftUI
import SwiftData

// 常用分类（与确认页一致），供一键选择
private let recurringCategories = ["住房", "娱乐", "餐饮", "交通", "购物", "通讯",
                                   "教育", "医疗", "服饰", "美妆", "旅行", "红包",
                                   "工资", "其他"]

struct RecurringRuleListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringRule.merchant) private var rules: [RecurringRule]

    // 包装一层，给每次弹窗一个独立身份，避免 SwiftUI 复用旧弹窗导致编辑时不显示已有内容
    private struct EditSheet: Identifiable {
        let id = UUID()
        let rule: RecurringRule?   // nil = 新增
    }

    @State private var editSheet: EditSheet? = nil

    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日"; return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if rules.isEmpty {
                    emptyState
                } else {
                    ForEach(rules) { rule in
                        ruleCard(rule)
                            .onLongPressGesture(minimumDuration: 0.5) {
                                editSheet = EditSheet(rule: rule)
                            }
                    }
                }
            }
            .padding()
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle("周期 / 订阅账单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editSheet = EditSheet(rule: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(AIATheme.Font.body.weight(.medium))
                }
            }
        }
        .sheet(item: $editSheet) { wrapper in
            RecurringRuleEditView(rule: wrapper.rule)
                .environment(\.modelContext, context)
        }
    }

    private var emptyState: some View {
        // 垂直居中：上下 Spacer 让空态落在模块可视区域中央。
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Image(systemName: "repeat.circle")
                    .font(AIATheme.Font.ultra)
                    .foregroundStyle(AIATheme.muted)
                Text("还没有周期账单")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text("把房租、会员费、房贷等设为每月自动入账")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
                    .multilineTextAlignment(.center)
                Button {
                    editSheet = EditSheet(rule: nil)
                } label: {
                    Text("添加一条")
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(AIATheme.blue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                // 自动记账模块：引导用户配置快捷指令自动记账
                autoRecordPrompt
                    .padding(.top, 24)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空态下方的「自动记账」引导模块：图标 + 标题 + 副标题 + 跳转按钮
    private var autoRecordPrompt: some View {
        VStack(spacing: 12) {
            IllustrationView(kind: .bill, size: 80)
            Text("自动记账")
                .font(AIATheme.Font.body.weight(.semibold))
                .foregroundStyle(.primary)
            Text("设置快捷指令，自动记账")
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.sub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
            Button {
                NavigationRouter.shared.navigate(.autoSetup)
            } label: {
                Text("查看教程")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(AIATheme.blue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func ruleCard(_ rule: RecurringRule) -> some View {
        SwipeToDeleteCard(onDelete: { deleteRule(rule) }) {
            ruleCardContent(rule)
        }
    }

    private func ruleCardContent(_ rule: RecurringRule) -> some View {
        let next = RecurringBillManager.nextDueDate(for: rule)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(BillCategoryHelpers.icon(for: rule.category))
                    .font(AIATheme.Font.title1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.merchant.isEmpty ? "未命名" : rule.merchant)
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(RecurringBillManager.cycleDescription(for: rule)) · \(rule.category)")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.sub)
                }
                Spacer(minLength: 0)
                Text("¥\(Int(rule.amount))")
                    .font(AIATheme.Font.headline.weight(.semibold))
                    .foregroundStyle(rule.isIncome ? AIATheme.income : AIATheme.expense)
            }
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("下次生成：\(dateFmt.string(from: next))")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.sub)
                if rule.isIncome {
                    Text("收入")
                        .font(AIATheme.Font.micro.weight(.medium))
                        .foregroundStyle(AIATheme.income)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AIATheme.income.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .card()
        .contentShape(Rectangle())
        .onTapGesture {
            editSheet = EditSheet(rule: rule)
        }
    }

    private func deleteRule(_ rule: RecurringRule) {
        // 规则删除只停止未来自动生成；已生成的历史账单保留在账单列表中。
        // RecurringRule 不参与 CloudSync，无需 SafeDelete 软删，直接硬删即可。
        withAnimation {
            context.delete(rule)
        }
    }
}

struct RecurringRuleEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    // nil = 新增；非 nil = 编辑已有规则（直接改其字段）
    private let existing: RecurringRule?

    @State private var merchant: String
    @State private var amountText: String
    @State private var category: String
    @State private var dayOfMonth: Int
    @State private var isIncome: Bool
    @State private var note: String
    @State private var startDate: Date
    @State private var cycleRaw: String
    @State private var customValue: Int
    @State private var customUnitRaw: String
    @State private var showDeleteConfirm = false

    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日"; return f
    }()

    init(rule: RecurringRule?) {
        self.existing = rule
        _merchant = State(initialValue: rule?.merchant ?? "")
        _amountText = State(initialValue: rule?.amount ?? 0 > 0 ? String(format: "%g", rule?.amount ?? 0) : "")
        _category = State(initialValue: rule?.category ?? "住房")
        _dayOfMonth = State(initialValue: rule?.dayOfMonth ?? 1)
        _isIncome = State(initialValue: rule?.isIncome ?? false)
        _note = State(initialValue: rule?.note ?? "")
        _cycleRaw = State(initialValue: rule?.cycleRaw ?? RecurrenceCycle.monthly.rawValue)
        _customValue = State(initialValue: rule?.customValue ?? 1)
        _customUnitRaw = State(initialValue: rule?.customUnitRaw ?? RecurrenceUnit.month.rawValue)
        if let r = rule {
            _startDate = State(initialValue: r.startDate)
        } else {
            _startDate = State(initialValue: .now)
        }
    }

    private var amountValue: Double { Double(amountText) ?? 0 }
    private var canSave: Bool { !merchant.isEmpty && amountValue > 0 }
    private var cycle: RecurrenceCycle { RecurrenceCycle(rawValue: cycleRaw) ?? .monthly }
    private var customUnit: RecurrenceUnit { RecurrenceUnit(rawValue: customUnitRaw) ?? .month }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // MARK: 基本信息
                    SectionTitle(text: "基本信息")
                    VStack(spacing: 10) {
                        fieldRow(icon: "building.2", label: "商户 / 名称") {
                            TextField("如 链家房租 / 视频会员", text: $merchant)
                                .font(AIATheme.Font.body.weight(.medium))
                                .foregroundStyle(.primary)
                        }

                        fieldRow(icon: "yensign.circle", label: "金额") {
                            HStack(spacing: 6) {
                                Text("¥")
                                    .font(AIATheme.Font.title1.weight(.bold))
                                    .foregroundStyle(AIATheme.bill)
                                TextField("0.00", text: $amountText)
                                    .keyboardType(.decimalPad)
                                    .font(AIATheme.Font.display.weight(.bold))
                                    .foregroundStyle(AIATheme.bill)
                            }
                        }

                        HStack(spacing: 10) {
                            Image(systemName: isIncome ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .font(AIATheme.Font.title3)
                                .foregroundStyle(isIncome ? AIATheme.income : AIATheme.expense)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("这是一笔收入")
                                    .font(AIATheme.Font.subhead.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(isIncome ? "如理财利息、工资入账" : "如房租、会员费等固定支出")
                                    .font(AIATheme.Font.micro)
                                    .foregroundStyle(AIATheme.muted)
                            }
                            Spacer(minLength: 0)
                            Toggle("", isOn: $isIncome)
                                .tint(AIATheme.income)
                                .labelsHidden()
                        }
                        .padding(12)
                        .background(AIATheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                    }
                    .card()

                    // MARK: 分类
                    SectionTitle(text: "分类")
                    categoryGrid

                    // MARK: 生成规则
                    SectionTitle(text: "生成规则")
                    VStack(spacing: 0) {
                        // 周期选择
                        ruleRow(title: "周期", icon: "repeat") {
                            Picker("", selection: $cycleRaw) {
                                ForEach(RecurrenceCycle.allCases) { c in
                                    Text(c.title).tag(c.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .frame(maxWidth: 120, alignment: .trailing)
                        }

                        // 根据周期类型显示对应的参数行
                        if cycle == .monthly || cycle == .quarterly || cycle == .yearly {
                            Divider()
                                .padding(.leading, 42)
                                .background(AIATheme.hairline)

                            ruleRow(title: "生成日", icon: "calendar") {
                                Picker("", selection: $dayOfMonth) {
                                    ForEach(1...28, id: \.self) { Text("\($0) 日").tag($0) }
                                }
                                .pickerStyle(.menu)
                                .font(AIATheme.Font.subhead.weight(.medium))
                                .frame(maxWidth: 100, alignment: .trailing)
                            }
                        } else if cycle == .weekly {
                            Divider()
                                .padding(.leading, 42)
                                .background(AIATheme.hairline)

                            ruleRow(title: "每周", icon: "calendar.week") {
                                Text("星期 \(weekdayText(from: startDate))")
                                    .font(AIATheme.Font.subhead.weight(.medium))
                                    .foregroundStyle(AIATheme.sub)
                            }
                        } else if cycle == .custom {
                            Divider()
                                .padding(.leading, 42)
                                .background(AIATheme.hairline)

                            ruleRow(title: "间隔", icon: "gearshape") {
                                HStack(spacing: 4) {
                                    Text("每")
                                        .font(AIATheme.Font.subhead)
                                        .foregroundStyle(AIATheme.sub)
                                    TextField("", value: $customValue, format: .number)
                                        .keyboardType(.numberPad)
                                        .font(AIATheme.Font.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 44)
                                    Picker("", selection: $customUnitRaw) {
                                        ForEach(RecurrenceUnit.allCases) { u in
                                            Text(u.title).tag(u.rawValue)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .font(AIATheme.Font.subhead.weight(.medium))
                                    .frame(maxWidth: 70, alignment: .trailing)
                                }
                            }
                        }

                        Divider()
                            .padding(.leading, 42)
                            .background(AIATheme.hairline)

                        ruleRow(title: "首次生成", icon: "calendar.badge.clock") {
                            DatePicker("", selection: $startDate, displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                                .frame(maxWidth: 110, alignment: .trailing)
                        }
                    }
                    .card()

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                        Text("首次生成：\(dateFmt.string(from: startDate))，之后\(cycleHint)自动入账")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)

                    // MARK: 备注
                    SectionTitle(text: "备注（可选）")
                    fieldRow(icon: "note.text", label: "备注") {
                        TextField("如：房东微信收款", text: $note)
                            .font(AIATheme.Font.callout)
                            .foregroundStyle(.primary)
                    }
                    .card()

                    // MARK: 删除（仅编辑模式显示）
                    if existing != nil {
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text("删除这条周期账单")
                            }
                            .font(AIATheme.Font.callout.weight(.medium))
                            .foregroundStyle(AIATheme.warn)
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .background(AIATheme.warn.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
            .background(AIATheme.fillSoft.ignoresSafeArea())
            .navigationTitle(existing == nil ? "新增周期账单" : "编辑周期账单")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("确定删除这条周期账单？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let rule = existing {
                        deleteRuleAndDismiss(rule)
                    }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("删除后不再自动生成，已生成的历史账单仍会保留。")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.sub)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        save()
                        dismiss()
                    } label: {
                        Text("保存")
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(canSave ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(canSave ? AIATheme.blue : AIATheme.blue.opacity(0.4))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
            }
        }
    }

    private var cycleHint: String {
        switch cycle {
        case .daily:     return "每天"
        case .weekly:    return "每周"
        case .monthly:   return "每月"
        case .quarterly: return "每季"
        case .yearly:    return "每年"
        case .custom:    return "每 \(customValue) \(customUnit.title)"
        @unknown default: return "自定义"
        }
    }

    private func weekdayText(from date: Date) -> String {
        switch Calendar.current.component(.weekday, from: date) {
        case 1: return "日"
        case 2: return "一"
        case 3: return "二"
        case 4: return "三"
        case 5: return "四"
        case 6: return "五"
        case 7: return "六"
        default: return ""
        }
    }

    // MARK: - 分类网格
    private var categoryGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 68), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(recurringCategories, id: \.self) { cat in
                let selected = category == cat
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        category = cat
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(BillCategoryHelpers.icon(for: cat))
                            .font(AIATheme.Font.title1)
                        Text(cat)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? .white : AIATheme.sub)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selected ? AIATheme.bill : AIATheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                    .overlay(RoundedRectangle(cornerRadius: AIATheme.rSM).stroke(selected ? Color.clear : AIATheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    // MARK: - 规则行
    private func ruleRow<Content: View>(title: String, icon: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AIATheme.bill.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(AIATheme.bill)
            }
            Text(title)
                .font(AIATheme.Font.callout.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            content()
        }
        .padding(12)
    }

    // MARK: - 输入行
    private func fieldRow<Content: View>(icon: String, label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
                Text(label).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
            }
            content()
        }
        .padding(12)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    private func save() {
        let rule: RecurringRule
        if let e = existing {
            rule = e
        } else {
            rule = RecurringRule()
            context.insert(rule)
        }
        rule.merchant = merchant
        rule.amount = amountValue
        rule.category = category
        rule.note = note
        rule.isIncome = isIncome
        rule.dayOfMonth = dayOfMonth
        rule.startDate = startDate
        rule.cycleRaw = cycleRaw
        rule.customValue = max(customValue, 1)
        rule.customUnitRaw = customUnitRaw
        // 新增规则时若首次生成日已≤今天，立即生成当前周期这笔；编辑时保持一致。
        try? context.save()
        RecurringBillManager.generateDue(context: context)
    }

    private func deleteRuleAndDismiss(_ rule: RecurringRule) {
        withAnimation {
            context.delete(rule)
        }
        dismiss()
    }
}
