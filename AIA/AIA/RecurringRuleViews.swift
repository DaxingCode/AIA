// RecurringRuleViews.swift
// 周期 / 订阅账单管理界面：规则列表 + 新增/编辑表单。
// 入口：账单列表页（BillListView）顶部「周期/订阅账单」按钮跳转至此。
import SwiftUI
import SwiftData

struct RecurringRuleListView: View {
    @Environment(\.modelContext) private var context
    // >>> CHANGE-[2026-08-31 23:34:46]-[周期规则按下次生成日期排序] 开始
    // 排序不能在 @Query 里做（下次生成日期是动态计算的），改为查询后按 nextDueDate 升序：
    // 越快到期的越靠前（方案 A，用户拍板）。不再按商户名排。
    @Query private var rules: [RecurringRule]

    private var sortedRules: [RecurringRule] {
        rules.sorted {
            RecurringBillManager.nextDueDate(for: $0) < RecurringBillManager.nextDueDate(for: $1)
        }
    }
    // <<< CHANGE-[2026-08-31 23:34:46]-[周期规则按下次生成日期排序] 结束

    // 包装一层，给每次弹窗一个独立身份，避免 SwiftUI 复用旧弹窗导致编辑时不显示已有内容
    private struct EditSheet: Identifiable {
        let id = UUID()
        let rule: RecurringRule?   // nil = 新增
    }

    @State private var editSheet: EditSheet? = nil

    // >>> CHANGE-[2026-08-31 23:29:43]-[周期规则日期显示补齐] 开始
    // 列表「下次生成」带上年份，如「2027 年 8 月 31 日」（此前只有月日，跨年看不出哪一年）
    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy年M月d日"; return f
    }()
    // <<< CHANGE-[2026-08-31 23:29:43]-[周期规则日期显示补齐] 结束

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if rules.isEmpty {
                    emptyState
                } else {
                    // >>> CHANGE-[2026-08-31 23:34:46]-[周期规则按下次生成日期排序] 开始
                    ForEach(sortedRules) { rule in
                    // <<< CHANGE-[2026-08-31 23:34:46]-[周期规则按下次生成日期排序] 结束
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
    // >>> CHANGE-[2026-08-31 23:52:00]-[周期账单分类改下拉选择] 开始
    @State private var showCategoryPicker = false
    // <<< CHANGE-[2026-08-31 23:52:00]-[周期账单分类改下拉选择] 结束
    // >>> CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 开始
    // 默认收起「生成日」等细项：日常只填周期 + 首次生成即可，
    // 系统用「首次生成」的号数作为默认生成日；需要精确控制再展开高级选项。
    @State private var showAdvancedCycle = false
    // <<< CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 结束
    @State private var showDeleteConfirm = false

    // >>> CHANGE-[2026-08-31 23:29:43]-[周期规则日期显示补齐] 开始
    // 编辑页「首次生成」同样带年份，与列表「下次生成」格式一致
    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy年M月d日"; return f
    }()
    // <<< CHANGE-[2026-08-31 23:29:43]-[周期规则日期显示补齐] 结束

    init(rule: RecurringRule?) {
        self.existing = rule
        _merchant = State(initialValue: rule?.merchant ?? "")
        _amountText = State(initialValue: rule?.amount ?? 0 > 0 ? String(format: "%g", rule?.amount ?? 0) : "")
        _category = State(initialValue: rule?.category ?? "住房")
        // >>> CHANGE-[2026-08-31 23:18:54]-[新增周期账单生成日默认为今天] 开始
        // 新增模式下生成日默认 = 今天几号（与「首次生成」日期的当日保持一致，免去手动改），
        // 编辑已有规则仍按其原值。
        if let r = rule {
            _dayOfMonth = State(initialValue: r.dayOfMonth)
        } else {
            _dayOfMonth = State(initialValue: Calendar.current.component(.day, from: .now))
        }
        // <<< CHANGE-[2026-08-31 23:18:54]-[新增周期账单生成日默认为今天] 结束
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
        // >>> CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 开始
        // 编辑已有规则时，若「生成日」与「首次生成」的号数不一致（用户曾手动改过），
        // 自动展开高级选项以保留其设定；否则默认收起，用首次生成的号数作为生成日。
        if let r = rule {
            let startDay = Calendar.current.component(.day, from: r.startDate)
            _showAdvancedCycle = State(initialValue: r.dayOfMonth != startDay)
        } else {
            _showAdvancedCycle = State(initialValue: false)
        }
        // <<< CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 结束
    }

    // >>> CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 开始
    /// 折叠态下，「生成日」应等于「首次生成」的号数。保存前同步一次，
    /// 确保未展开高级选项时也能按首次生成日正确延续周期。
    private func syncDayFromStartIfCollapsed() {
        guard !showAdvancedCycle else { return }
        let startDay = Calendar.current.component(.day, from: startDate)
        dayOfMonth = startDay
    }
    // <<< CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 结束

    // >>> CHANGE-[2026-09-01 10:30:00]-[自定义周期强制展开间隔] 开始
    /// 高级细项（生成日 / 每周 / 间隔）是否可见。
    /// 自定义周期必须指定间隔才能确定周期长度，因此强制可见。
    private var advancedCycleVisible: Bool { showAdvancedCycle || cycle == .custom }
    // <<< CHANGE-[2026-09-01 10:30:00]-[自定义周期强制展开间隔] 结束

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
                    // >>> CHANGE-[2026-08-31 23:52:00]-[周期账单分类改下拉选择] 开始
                    // 与账单编辑页一致：一行显示当前分类，点击弹「选择分类」sheet（按使用次数排序）
                    // 视觉与「生成规则」区块对齐：ruleRow 同款圆底图标 + 外层 .card() 统一卡片底
                    SectionTitle(text: "分类")
                    categoryRow
                        .card()

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

                        // >>> CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 开始
                        // 高级选项折叠：默认隐藏「生成日 / 每周 / 间隔」，
                        // 折叠态下用 startDate 的号数(或星期/间隔)作为默认生成依据。
                        // >>> CHANGE-[2026-09-01 10:30:00]-[自定义周期强制展开间隔] 开始
                        // 自定义周期必须指定间隔才能确定周期长度，因此选中「自定义」时
                        // 视为高级展开（advancedCycleVisible），间隔框直接可见，无需手动展开。
                        // <<< CHANGE-[2026-09-01 10:30:00]-[自定义周期强制展开间隔] 结束
                        if advancedCycleVisible {
                            if cycle == .monthly || cycle == .quarterly || cycle == .yearly {
                                Divider()
                                    .padding(.leading, 42)
                                    .background(AIATheme.hairline)

                                ruleRow(title: "生成日", icon: "calendar") {
                                    Picker("", selection: $dayOfMonth) {
                                        ForEach(1...31, id: \.self) { Text("\($0) 日").tag($0) }
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
                        }
                        // <<< CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 结束

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

                        // >>> CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 开始
                        // 高级选项入口：点击展开「生成日 / 每周」手动调整。
                        // 编辑已有规则且与原默认(取自首次生成)不符时，自动展开以保留用户设定。
                        // >>> CHANGE-[2026-09-01 10:30:00]-[自定义周期强制展开间隔] 开始
                        // 自定义周期下间隔已强制可见，无需再显示该入口，直接隐藏。
                        // <<< CHANGE-[2026-09-01 10:30:00]-[自定义周期强制展开间隔] 结束
                        if cycle != .custom {
                            Divider()
                                .padding(.leading, 42)
                                .background(AIATheme.hairline)

                            Button {
                                showAdvancedCycle.toggle()
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(AIATheme.bill.opacity(0.12))
                                            .frame(width: 30, height: 30)
                                        Image(systemName: "slider.horizontal.3")
                                            .font(AIATheme.Font.footnote.weight(.medium))
                                            .foregroundStyle(AIATheme.bill)
                                    }
                                    Text("高级：自定义生成日")
                                        .font(AIATheme.Font.callout.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                    Text(showAdvancedCycle ? "收起" : "展开")
                                        .font(AIATheme.Font.micro)
                                        .foregroundStyle(AIATheme.muted)
                                    Image(systemName: "chevron.right")
                                        .font(AIATheme.Font.caption.weight(.semibold))
                                        .foregroundStyle(AIATheme.muted)
                                        .rotationEffect(.degrees(showAdvancedCycle ? 90 : 0))
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableCardStyle())
                        }
                        // <<< CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 结束
                    }
                    .card()

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                        // >>> CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 开始
                        // 折叠态提示「生成日 = 首次生成日号数」；展开态提示用户可自定义。
                        // >>> CHANGE-[2026-09-01 10:30:00]-[自定义周期强制展开间隔] 开始
                        // 自定义周期按「每 N 单位」提示，不用「每月X日」（后者仅适用月/季/年）。
                        // <<< CHANGE-[2026-09-01 10:30:00]-[自定义周期强制展开间隔] 结束
                        Text(advancedCycleVisible
                             ? "首次生成：\(dateFmt.string(from: startDate))，之后\(cycleHint)自动入账"
                             : "首次生成：\(dateFmt.string(from: startDate))，之后每月\(Calendar.current.component(.day, from: startDate))日自动入账")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        // <<< CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 结束
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
            // >>> CHANGE-[2026-08-31 23:52:00]-[周期账单分类改下拉选择] 开始
            .sheet(isPresented: $showCategoryPicker) {
                BillCategoryPickerSheet(selection: $category)
            }
            // <<< CHANGE-[2026-08-31 23:52:00]-[周期账单分类改下拉选择] 结束
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

    // >>> CHANGE-[2026-08-31 23:52:00]-[周期账单分类改下拉选择] 开始
    // >>> CHANGE-[2026-08-31 23:55:00]-[周期账单分类UI对齐准则] 开始
    // 视觉与「生成规则」区块完全对齐：ruleRow 同款圆底图标(bill.opacity 0.12 圆形底) +
    // 透明行底（卡片底由外层 .card() 统一提供）+ 右侧当前分类 + chevron。
    // 整行可点：.contentShape 撑满 + PressableCardStyle 按压反馈（项目可点卡片准则）。
    private var categoryRow: some View {
        let selected = category.trimmingCharacters(in: .whitespaces).isEmpty ? "其他" : category
        return Button {
            showCategoryPicker = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AIATheme.bill.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: "tag.fill")
                        .font(AIATheme.Font.footnote.weight(.medium))
                        .foregroundStyle(AIATheme.bill)
                }
                Text("分类")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(BillCategoryHelpers.icon(for: selected))
                        .font(AIATheme.Font.subhead)
                    Text(selected)
                        .font(AIATheme.Font.headline.weight(.medium))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardStyle())
    }
    // <<< CHANGE-[2026-08-31 23:55:00]-[周期账单分类UI对齐准则] 结束
    // <<< CHANGE-[2026-08-31 23:52:00]-[周期账单分类改下拉选择] 结束

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
        // >>> CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 开始
        // 折叠态下用「首次生成」号数覆盖 dayOfMonth，保证按首次生成日延续；
        // 展开态下保留用户手动设定的生成日。
        syncDayFromStartIfCollapsed()
        // <<< CHANGE-[2026-09-01 10:00:00]-[周期规则生成日默认收起] 结束
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

// >>> CHANGE-[2026-08-30 13:43:27]-[编辑页周期开关] 开始
extension RecurringRule {
    /// 从「账单字段 + 周期配置」构造一条周期规则并插入 context。
    /// 与 RecurringRuleEditor.save() 同源，供编辑账单页开关打开时调用。
    /// - Parameter billSyncId: 来源账单的 syncId。规则用自身 syncId 存这份关联
    ///   （RecurringRule 不上云，syncId 仅作本地关联键），编辑账单页靠它回填开关状态、
    ///   保存时做「有则更新、无则新建」去重。独立规则编辑页（RecurringRuleEditor）不传，
    ///   走默认 UUID()，不与任何账单挂钩。
    @discardableResult
    static func make(from merchant: String, amount: Double, category: String,
                     isIncome: Bool, note: String,
                     cycleRaw: String, dayOfMonth: Int,
                     customValue: Int, customUnitRaw: String,
                     startDate: Date, context: ModelContext,
                     billSyncId: UUID? = nil) -> RecurringRule {
        let rule = RecurringRule(syncId: billSyncId ?? UUID())
        rule.merchant = merchant
        rule.amount = amount
        rule.category = category
        rule.isIncome = isIncome
        rule.note = note
        rule.dayOfMonth = dayOfMonth
        rule.startDate = startDate
        rule.cycleRaw = cycleRaw
        rule.customValue = customValue
        rule.customUnitRaw = customUnitRaw
        context.insert(rule)
        return rule
    }
}
// <<< CHANGE-[2026-08-30 13:43:27]-[编辑页周期开关] 结束
