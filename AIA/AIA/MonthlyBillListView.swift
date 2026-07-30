// MonthlyBillListView.swift
// 按月查看：点击某个月份卡片后进入的该月账单明细列表，支持点进详情删除单笔账单。
import SwiftUI
import SwiftData

struct MonthlyBillListView: View {
    let year: Int
    let month: Int
    @Environment(\.modelContext) private var context
    /// 2026-07-29：改为 @Query 自动按 year/month 过滤 + 过滤 syncDeleted，
    /// 让 NavigationRouter 路由推送（不带 bills 参数）也能拿到本月账单；以前靠外部传 bills，路由化后无法附带。
    @Query private var monthBills: [Bill]
    /// 点击账单行 → 直接弹出「编辑账单」sheet（与主账单页 / 食物 / 待办 列表点击行为统一）
    @State private var editBill: Bill? = nil

    // MARK: 多选删除
    @State private var multiSelectMode = false
    @State private var selectedIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm = false

    init(year: Int, month: Int, bills: [Bill] = []) {
        self.year = year
        self.month = month
        // 计算本月时间窗，注入 @Query filter
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        let start = cal.date(from: comps) ?? .distantPast
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? .distantFuture
        _monthBills = Query(
            filter: #Predicate<Bill> { $0.time >= start && $0.time < end && !$0.syncDeleted },
            sort: \Bill.time,
            order: .reverse
        )
        // bills 入参保留以兼容旧调用，但实际数据走 @Query（自动响应 syncDeleted 等变更）
    }

    private var monthTitle: String {
        "\(String(year))年\(month)月"
    }

    private var sortedBills: [Bill] {
        monthBills
    }

    private var totalIncome: Double {
        sortedBills.filter(\.isIncome).reduce(0) { $0 + $1.amount }
    }

    private var totalExpense: Double {
        sortedBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
    }

    private var balance: Double {
        totalIncome - totalExpense
    }

    private var groupedBills: [(date: Date, bills: [Bill])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: sortedBills) { cal.startOfDay(for: $0.time) }
        return grouped.sorted { $0.key > $1.key }.map { (date: $0.key, bills: $0.value) }
    }

    private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sortedBills.isEmpty {
                    EmptyStateView(
                        kind: .bill,
                        title: "本月暂无账单",
                        message: "去「全部」页添加或识别一笔账单吧。",
                        actionTitle: nil,
                        action: nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    summaryCard

                    ForEach(groupedBills, id: \.date) { group in
                        daySection(group.date, bills: group.bills)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(monthTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if multiSelectMode {
                MultiSelectBottomBar(
                    count: selectedIDs.count,
                    totalCount: sortedBills.count,
                    onCancel: {
                        multiSelectMode = false
                        selectedIDs.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allIDs = Set(sortedBills.map(\.persistentModelID))
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
                batchDeleteMonthly()
            }
        } message: {
            Text(String(format: NSLocalizedString("common.deleteCount", comment: ""), selectedIDs.count))
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        // 账单行点击 → 直接弹「编辑账单」sheet（与主账单页/食物/待办统一体验）
        .sheet(item: $editBill) { b in
            EditBillView(bill: b)
        }
    }

    // MARK: 多选删除

    private func enterMonthlyMultiSelect(_ id: PersistentIdentifier) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        multiSelectMode = true
        selectedIDs.insert(id)
    }

    private func toggleMonthlySelection(_ id: PersistentIdentifier) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedIDs.isEmpty { multiSelectMode = false }
        } else {
            selectedIDs.insert(id)
        }
    }

    private func batchDeleteMonthly() {
        for id in selectedIDs {
            SafeDelete.billByID(id, in: context)
        }
        multiSelectMode = false
        selectedIDs.removeAll()
    }

    // MARK: - 本月收支概览
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本月收支概览")
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("共 \(sortedBills.count) 笔")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }

            HStack(spacing: 10) {
                statTile("收入", totalIncome, AIATheme.income)
                statTile("支出", totalExpense, AIATheme.expense)
                statTile("结余", balance, balance >= 0 ? AIATheme.income : AIATheme.expense)
            }
        }
        .padding(16)
        .card(radius: AIATheme.rLG, shadow: false)
    }

    private func statTile(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.sub)
            Text("¥\(Int(value))")
                .font(AIATheme.Font.headline.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    // MARK: - 按天分组的账单卡片
    private func daySection(_ date: Date, bills: [Bill]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(dayHeader(date))
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(dayTotal(bills))
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ForEach(Array(bills.enumerated()), id: \.element.persistentModelID) { idx, b in
                if idx > 0 {
                    Divider()
                        .padding(.leading, 62)
                        .background(AIATheme.hairline)
                }

                SelectableRow(
                    isSelecting: multiSelectMode,
                    isSelected: selectedIDs.contains(b.persistentModelID),
                    onTap: { editBill = b },
                    onLongPress: { enterMonthlyMultiSelect(b.persistentModelID) },
                    onToggle: { toggleMonthlySelection(b.persistentModelID) },
                    onDelete: { SafeDelete.bill(b, in: context) }
                ) {
                    billRow(b)
                }
            }
        }
        .padding(.bottom, 10)
        .card(radius: AIATheme.rLG, shadow: false)
    }

    private func billRow(_ b: Bill) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(BillCategoryHelpers.color(for: b.category).opacity(0.12))
                    .frame(width: 40, height: 40)
                Text(BillCategoryHelpers.icon(for: b.category))
                    .font(AIATheme.Font.title2)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(b.category.isEmpty ? NSLocalizedString("common.other", comment: "") : b.category)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                    if b.isIncome {
                        Text("收入")
                            .font(AIATheme.Font.micro.weight(.medium))
                            .foregroundStyle(AIATheme.income)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(AIATheme.income.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
                Text("\(AppFormat.time.string(from: b.time)) · \(b.merchant)")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text((b.isIncome ? "+" : "-") + String(format: "%.2f", b.amount))
                .font(AIATheme.Font.callout.weight(.semibold))
                .foregroundStyle(b.isIncome ? AIATheme.income : AIATheme.expense)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AIATheme.surface)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers
    private func dayHeader(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let weekday = cal.component(.weekday, from: date) - 1
        let w = weekdayNames[safe: weekday] ?? ""
        return "\(cal.component(.month, from: date))月\(cal.component(.day, from: date))日 星期\(w)"
    }

    private func dayTotal(_ bills: [Bill]) -> String {
        let inc = bills.filter(\.isIncome).reduce(0) { $0 + $1.amount }
        let exp = bills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
        if inc > 0 && exp > 0 {
            return "收 ¥\(Int(inc)) / 支 ¥\(Int(exp))"
        } else if inc > 0 {
            return "+¥\(Int(inc))"
        } else {
            return "-¥\(Int(exp))"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
