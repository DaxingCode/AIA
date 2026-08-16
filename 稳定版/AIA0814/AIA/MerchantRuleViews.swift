// MerchantRuleViews.swift
// 「商户分类规则」管理页：用户手动维护「商户名 → 账单分类」映射，
// 识别账单/文字记账时优先命中本地规则，减少 AI 调用。规则随 CloudSync 同步到云端。
import SwiftUI
import SwiftData

struct MerchantRuleListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<MerchantMeta> { !$0.syncDeleted }, sort: \MerchantMeta.lastSeen, order: .reverse)
    private var rules: [MerchantMeta]

    init() {}

    @State private var editingRule: MerchantMeta?
    @State private var showAddSheet = false
    // 多选删除
    @State private var multiSelectMode = false
    @State private var selectedRuleIDs = Set<PersistentIdentifier>()
    @State private var showMultiDeleteConfirm = false

    private var visibleRules: [MerchantMeta] { rules }

    private func toggleSelection(_ id: PersistentIdentifier) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedRuleIDs.contains(id) {
            selectedRuleIDs.remove(id)
            if selectedRuleIDs.isEmpty { multiSelectMode = false }
        } else {
            selectedRuleIDs.insert(id)
        }
    }

    private func enterMultiSelect(_ id: PersistentIdentifier) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        multiSelectMode = true
        selectedRuleIDs.insert(id)
    }

    private func deleteSelectedRules() {
        for id in selectedRuleIDs {
            SafeDelete.merchantMetaByID(id, in: context)
        }
        multiSelectMode = false
        selectedRuleIDs.removeAll()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if visibleRules.isEmpty {
                    EmptyStateView(
                        kind: .bill,
                        title: "暂无商户规则",
                        message: "添加常用商户名和分类\n后续识别到该商户会自动归类"
                    )
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleRules) { rule in
                            SelectableRow(
                                isSelecting: multiSelectMode,
                                isSelected: selectedRuleIDs.contains(rule.persistentModelID),
                                onTap: { editingRule = rule },
                                onLongPress: { enterMultiSelect(rule.persistentModelID) },
                                onToggle: { toggleSelection(rule.persistentModelID) },
                                onDelete: {
                                    SafeDelete.merchantMeta(rule, in: context)
                                    CloudSyncManager.shared.syncAfterLocalChange(context: context)
                                }
                            ) {
                                ruleRowContent(rule)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                }
            }
        }
        .navigationTitle("商户分类规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !multiSelectMode {
                    Button {
                        editingRule = nil
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(AIATheme.Font.headline.weight(.semibold))
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            MerchantRuleEditSheet(rule: nil)
                .environment(\.modelContext, context)
        }
        .sheet(item: $editingRule) { rule in
            MerchantRuleEditSheet(rule: rule)
                .environment(\.modelContext, context)
        }
        .overlay(alignment: .bottom) {
            if multiSelectMode {
                MultiSelectBottomBar(
                    count: selectedRuleIDs.count,
                    totalCount: visibleRules.count,
                    onCancel: {
                        multiSelectMode = false
                        selectedRuleIDs.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allIDs = Set(visibleRules.map(\.persistentModelID))
                        if selectedRuleIDs.isSuperset(of: allIDs) {
                            selectedRuleIDs.subtract(allIDs)
                        } else {
                            selectedRuleIDs.formUnion(allIDs)
                        }
                    },
                    onDelete: {
                        guard !selectedRuleIDs.isEmpty else { return }
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
                deleteSelectedRules()
            }
        } message: {
            Text(String(format: NSLocalizedString("common.deleteCount", comment: ""), selectedRuleIDs.count))
        }
    }

    private func ruleRowContent(_ rule: MerchantMeta) -> some View {
        HStack(spacing: 12) {
            Text(BillCategoryHelpers.icon(for: rule.category))
                .font(AIATheme.Font.title1)
                .frame(width: 36, height: 36)
                .background(BillCategoryHelpers.color(for: rule.category).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))

            VStack(alignment: .leading, spacing: 4) {
                Text(rule.merchant)
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(rule.category)
                        .font(AIATheme.Font.caption.weight(.medium))
                        .foregroundStyle(BillCategoryHelpers.color(for: rule.category))
                    Text("·")
                        .foregroundStyle(AIATheme.muted)
                    Text(rule.isIncome ? "收入" : "支出")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(rule.isIncome ? AIATheme.income : AIATheme.expense)
                }
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(AIATheme.muted)
        }
        .padding(12)
        .card()
        .contentShape(Rectangle())
    }
}

struct MerchantRuleEditSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let rule: MerchantMeta?

    @Query(sort: \Bill.time, order: .reverse)
    private var bills: [Bill]
    @Query(sort: \MerchantMeta.lastSeen, order: .reverse)
    private var allRules: [MerchantMeta]

    @State private var merchant: String = ""
    @State private var category: String = ""
    @State private var isIncome: Bool = false
    @State private var showCategoryPicker = false
    @State private var showDeleteConfirm = false
    @FocusState private var merchantFocused: Bool

    private var isEditing: Bool { rule != nil }
    private var canSave: Bool {
        !merchant.trimmingCharacters(in: .whitespaces).isEmpty
        && !category.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        merchantInputCard
                        categoryPickerCard
                        incomeToggleCard
                        if isEditing {
                            deleteCard
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(isEditing ? "编辑规则" : "新增规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(AIATheme.Font.body.weight(.semibold))
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showCategoryPicker) {
                BillCategoryPickerSheet(selection: $category)
            }
            .confirmationDialog(
                "确定要删除「\(merchant)」的规则吗？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除规则", role: .destructive) {
                    deleteRule()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后此商户将恢复默认分类。")
            }
        }
    }

    /// 所有已记录商户候选：账单原始商户名 + 已有规则归一化商户名，去空去重。
    /// 排序：按该商户最近一次支付时间倒序（最近支付的排最上面），无账单记录的排最后。
    private var candidateMerchants: [String] {
        let fromBills = bills
            .map { $0.merchant }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let fromRules = allRules
            .filter { !$0.syncDeleted }
            .map { $0.merchant }
        let all = Array(Set(fromBills + fromRules))

        // 构建每个商户的最近支付时间
        var latestTime: [String: Date] = [:]
        for b in bills {
            let m = b.merchant.trimmingCharacters(in: .whitespaces)
            guard !m.isEmpty else { continue }
            if let existing = latestTime[m] {
                if b.time > existing { latestTime[m] = b.time }
            } else {
                latestTime[m] = b.time
            }
        }

        // 按最近支付时间倒序排列，无账单记录的排最后
        return all.sorted { (a: String, b: String) -> Bool in
            let ta = latestTime[a]
            let tb = latestTime[b]
            switch (ta, tb) {
            case (nil, nil): return a < b          // 都无账单 → 字典序
            case (nil, _): return false             // a 无账单，排后面
            case (_, nil): return true              // b 无账单，a 排前面
            case let (.some(la), .some(lb)): return la > lb       // 都有 → 最近支付的排前面
            }
        }
    }

    /// 按当前输入搜索过滤后的候选；空输入时展示全部。
    private var filteredMerchants: [String] {
        let q = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return candidateMerchants }
        return candidateMerchants.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var isNewMerchant: Bool {
        let q = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return !candidateMerchants.contains { MerchantMetaStore.normalize($0) == MerchantMetaStore.normalize(q) }
    }

    private var merchantInputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("商户名")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(AIATheme.muted)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(AIATheme.muted)

                    TextField("例如：星巴克、滴滴出行", text: $merchant)
                        .font(AIATheme.Font.body)
                        .focused($merchantFocused)
                        .textInputAutocapitalization(.never)

                    if !merchant.isEmpty {
                        Button {
                            merchant = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(AIATheme.Font.title3)
                                .foregroundStyle(AIATheme.muted)
                        }
                    }
                }
                .padding(12)
                .background(AIATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))

                if merchantFocused && (!filteredMerchants.isEmpty || isNewMerchant) {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(filteredMerchants.enumerated()), id: \.offset) { _, name in
                                    Button {
                                        merchant = name
                                        merchantFocused = false
                                    } label: {
                                        HStack(spacing: 10) {
                                            highlightedMerchant(name)
                                                .font(AIATheme.Font.callout)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                            if MerchantMetaStore.normalize(name) == MerchantMetaStore.normalize(merchant) {
                                                Image(systemName: "checkmark")
                                                    .font(AIATheme.Font.footnote.weight(.semibold))
                                                    .foregroundStyle(AIATheme.blue)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if name != filteredMerchants.last {
                                        Divider()
                                            .padding(.leading, 12)
                                    }
                                }

                                if isNewMerchant {
                                    if !filteredMerchants.isEmpty {
                                        Divider()
                                            .padding(.leading, 12)
                                    }
                                    Button {
                                        merchantFocused = false
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(AIATheme.Font.title3)
                                                .foregroundStyle(AIATheme.blue)
                                            Text("新建商户「\(merchant.trimmingCharacters(in: .whitespacesAndNewlines))」")
                                                .font(AIATheme.Font.callout)
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                    }
                    .background(AIATheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                    .padding(.top, 6)
                    .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 4)
                }
            }
        }
        .padding(12)
        .card()
    }

    /// 高亮匹配到的搜索关键字。
    private func highlightedMerchant(_ name: String) -> Text {
        let q = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let range = name.range(of: q, options: .caseInsensitive) else {
            return Text(name).foregroundStyle(.primary)
        }
        let before = String(name[..<range.lowerBound])
        let match = String(name[range])
        let after = String(name[range.upperBound...])
        var result = AttributedString(before)
        result.swiftUI.foregroundColor = .primary
        var matched = AttributedString(match)
        matched.swiftUI.foregroundColor = AIATheme.blue
        matched.swiftUI.font = .body.weight(.semibold)
        var tail = AttributedString(after)
        tail.swiftUI.foregroundColor = .primary
        result.append(matched)
        result.append(tail)
        return Text(result)
    }

    private var categoryPickerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(AIATheme.muted)
            Button {
                showCategoryPicker = true
            } label: {
                HStack(spacing: 10) {
                    Text(category.isEmpty ? "选择分类" : BillCategoryHelpers.icon(for: category))
                        .font(AIATheme.Font.title2)
                    Text(category.isEmpty ? "选择分类" : category)
                        .font(AIATheme.Font.body)
                        .foregroundStyle(category.isEmpty ? AIATheme.muted : .primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.footnote.weight(.medium))
                        .foregroundStyle(AIATheme.muted)
                }
                .padding(12)
                .background(AIATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .card()
    }

    private var incomeToggleCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(AIATheme.Font.title1)
                .foregroundStyle(isIncome ? AIATheme.income : AIATheme.expense)
            VStack(alignment: .leading, spacing: 2) {
                Text("收支类型")
                    .font(AIATheme.Font.callout.weight(.semibold))
                Text(isIncome ? "该商户通常为收入" : "该商户通常为支出")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }
            Spacer(minLength: 0)
            Picker("", selection: $isIncome) {
                Text("支出").tag(false)
                Text("收入").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
        }
        .padding(12)
        .card()
    }

    /// 危险操作卡片：仅编辑模式展示，与其他 card 同宽 + 圆角 + 卡片背景。
    /// 整行可点 → 弹确认 dialog → 二次确认后才执行删除（防误触）。
    private var deleteCard: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(AIATheme.over)
                    .frame(width: 32, height: 32)
                    .background(AIATheme.over.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("删除此规则")
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AIATheme.over)
                    Text("删除后此商户将恢复默认分类")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    init(rule: MerchantMeta?) {
        self.rule = rule
        if let rule {
            _merchant = State(initialValue: rule.merchant)
            _category = State(initialValue: rule.category)
            _isIncome = State(initialValue: rule.isIncome)
        } else {
            _merchant = State(initialValue: "")
            _category = State(initialValue: "")
            _isIncome = State(initialValue: false)
        }
    }

    private func save() {
        let raw = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKey = MerchantMetaStore.normalize(raw)

        // 如果编辑时修改了商户名，把旧规则标记为删除，避免同一商户出现两条规则。
        if let rule, rule.merchant != newKey {
            MerchantMetaStore.markDeleted(rule)
        }

        MerchantMetaStore.saveRule(merchant: raw, category: category, isIncome: isIncome, in: context)
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        dismiss()
    }

    /// 软删当前规则：syncDeleted=true → @Query 谓词过滤掉 → 列表自动消失。
    /// 与 markDeleted 行为一致（不硬删，保留云同步追溯能力）。
    private func deleteRule() {
        guard let rule else { return }
        MerchantMetaStore.markDeleted(rule)
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        MerchantRuleListView()
    }
    .modelContainer(for: MerchantMeta.self, inMemory: true)
}
