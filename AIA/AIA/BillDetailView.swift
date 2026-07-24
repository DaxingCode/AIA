// BillDetailView.swift
// 账单详情：点击账单列表行进入。展示账单信息，支持确认、编辑与删除。
import SwiftUI
import SwiftData

struct BillDetailView: View {
    let bill: Bill
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    private var amountLabel: String {
        let sign = bill.isIncome ? "+" : "-"
        return "\(sign)¥\(String(format: "%.2f", bill.amount))"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerCard
                    infoGrid
                    if bill.imageName != nil { imageCard }
                    actionCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            AIBottomBar()
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle("账单详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEdit) { EditBillView(bill: bill) }
        .onDisappear {
            // 2026-07-20 实测：onDisappear 仍可能在父页面刚刚显示、pop 动画尚未完全收尾时调用。
            // 同步改模型触发 @Query 重 fetch，会与父页面初始渲染竞争，导致返回列表后卡死。
            // 延迟 600ms 等父页面彻底稳定后再真正执行 SafeDelete。
            // 关键：不直接捕获 bill 对象，只保存 persistentModelID；返回列表后若对象被 fault 化，
            // 直接访问属性会触发 fault 异常。通过 context.model(for:) 重新取活对象可避免此问题。
            if let id = pendingDeleteID {
                pendingDeleteID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    SafeDelete.billByID(id, in: context)
                }
            }
        }
    }

    // MARK: - 头部信息卡片
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text(BillCategoryHelpers.icon(for: bill.category))
                    .font(AIATheme.Font.display)
                    .frame(width: 56, height: 56)
                    .background(BillCategoryHelpers.color(for: bill.category).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text(bill.merchant.isEmpty ? "其他消费" : bill.merchant)
                        .font(AIATheme.Font.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(bill.category.isEmpty ? "其他" : bill.category)
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(amountLabel)
                    .font(AIATheme.Font.hero.weight(.bold))
                    .foregroundStyle(bill.isIncome ? AIATheme.ok : AIATheme.warn)
                Text(AppFormat.dateTime.string(from: bill.time))
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AIATheme.billBG)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
        .padding(14)
        .card()
    }

    // MARK: - 账单信息（4 格：类型 / 分类 / 时间 / 商户，避免与头部金额重复）
    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("账单信息")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(.primary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                infoBox(icon: "arrow.2.circlepath", label: "类型", value: bill.isIncome ? "收入" : "支出")
                infoBox(icon: "tag", label: "分类", value: bill.category.isEmpty ? "其他" : bill.category)
                infoBox(icon: "clock", label: "时间", value: AppFormat.time.string(from: bill.time))
                infoBox(icon: "building.2", label: "商户", value: bill.merchant.isEmpty ? "—" : bill.merchant)
            }
        }
        .padding(14)
        .card()
    }

    private func infoBox(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text(label)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            Text(value)
                .font(AIATheme.Font.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    // MARK: - 账单图片（标题统一在卡片层，AttachmentSection 不再重复显示）
    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账单图片")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(.primary)
            AttachmentSection(imageName: bill.imageName, title: nil)
        }
        .padding(14)
        .card()
    }

    // MARK: - 操作卡片（编辑主按钮 + 删除次按钮，逻辑更直观）
    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("操作")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(.primary)

            Button {
                showEdit = true
            } label: {
                Text("编辑账单")
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AIATheme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)

            Button {
                // 先标记删除意图并 pop 回列表，等 onDisappear（pop 动画完全结束）
                // 再真正执行 SafeDelete。避免 syncDeleted=true 触发 @Query 重 fetch
                // 与 NavigationStack pop 动画叠加，导致最后一条删除时卡死。
                // 只保存 ID，不捕获 bill 对象，防止返回列表后对象被 fault 化，
                // 600ms 后访问属性触发 fault 异常闪退。
                pendingDeleteID = bill.persistentModelID
                dismiss()
            } label: {
                Text("删除该账单")
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(AIATheme.warn)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AIATheme.warn.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: AIATheme.rMD).stroke(AIATheme.warn.opacity(0.25), lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .card()
    }
}
