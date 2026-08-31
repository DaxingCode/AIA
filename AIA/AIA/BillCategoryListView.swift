// >>> CHANGE-[2026-08-24 17:59:13]-[账单分类点击跳分类明细] 开始
// 功能：从账单仪表盘「支出分类构成」点击某分类，跳转到仅显示该分类 + 当前周期 + 收支类型的账单明细列表。
// 路由：HomeRoute.billCategory(category:periodStart:periodEnd:onlyIncome:)，由 ContentView.routeDestination 分发。
// 设计：轻量"看明细"页，复用 groupedBillRow 视觉但不带多选/长按/工具按钮；支持单条点进详情 + 左滑软删。
// 回退：删本文件 + ContentView 内路由 case/分支 + BillDashboardView 的 Button 包装即可整体移除。
import SwiftUI
import SwiftData

struct BillCategoryListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Bill> { !$0.syncDeleted }, sort: \Bill.time, order: .reverse) private var allBills: [Bill]

    let category: String
    let periodStart: Date
    let periodEnd: Date
    let onlyIncome: Bool

    // 与 BillDashboardView.categoryBreakdown 一致的归一化：空分类按"其他"显示
    private var targetCategory: String { category.isEmpty ? NSLocalizedString("common.other", comment: "") : category }

    private var filtered: [Bill] {
        allBills.filter {
            $0.time >= periodStart &&
            $0.time <= periodEnd &&
            $0.isIncome == onlyIncome &&
            ($0.category.isEmpty ? NSLocalizedString("common.other", comment: "") : $0.category) == targetCategory
        }
    }

    private var total: Double { filtered.reduce(0) { $0 + $1.amount } }

    var body: some View {
        VStack(spacing: 0) {
            // 小汇总头：分类名 + 图标 + 总额 + 笔数（与仪表盘 categoryRow 风格对齐）
            HStack(spacing: 12) {
                Text(BillCategoryHelpers.icon(for: targetCategory))
                    .font(AIATheme.Font.title1)
                    .frame(width: 42, height: 42)
                    .background(AIATheme.bill.opacity(0.12))
                    .foregroundStyle(AIATheme.bill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(targetCategory)
                        .font(AIATheme.Font.headline)
                        .foregroundStyle(.primary)
                    Text(String(format: NSLocalizedString("bill.categoryCount", comment: ""), filtered.count))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer()
                Text(String(format: "%.2f", total))
                    .font(AIATheme.Font.headline.weight(.semibold))
                    .foregroundStyle(onlyIncome ? AIATheme.income : AIATheme.expense)
            }
            .padding(14)
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))

            if filtered.isEmpty {
                Spacer(minLength: 40)
                ContentUnavailableView(
                    String(format: NSLocalizedString("bill.categoryEmpty", comment: ""), targetCategory),
                    systemImage: "tray"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered, id: \.persistentModelID) { b in
                        Button {
                            NavigationRouter.shared.navigate(.billDetail(b))
                        } label: {
                            billRow(b)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowBackground(AIATheme.fillSoft)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                    .onDelete { idx in
                        for i in idx {
                            SafeDelete.billByID(filtered[i].persistentModelID, in: context)
                        }
                        CloudSyncManager.shared.syncAfterLocalChange(context: context)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle(targetCategory)
        .navigationBarTitleDisplayMode(.inline)
    }

    // 复用 BillListView.groupedBillRow 的视觉（内联拷贝，避免跨文件调用 private 函数）
    private func billRow(_ b: Bill) -> some View {
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
                // >>> CHANGE-[2026-08-24 17:59:13]-[分类明细行加日期] 开始
                // 原因：原 billRow 只显示 hourMinute（如 "13:35"），分类明细跨多天时看不出是哪天；补 monthDay。
                // 回退：删本行并恢复原 "AppFormat.hourMinute | merchant" 拼接即可。
                Text("\(AppFormat.monthDay.string(from: b.time)) \(AppFormat.hourMinute.string(from: b.time)) | \(b.merchant)")
                // <<< CHANGE-[2026-08-24 17:59:13]-[分类明细行加日期] 结束
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
}
// <<< CHANGE-[2026-08-24 17:59:13]-[账单分类点击跳分类明细] 结束
