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
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    if bill.imageName != nil { imageCard }
                    actionCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            AIBottomBar(entrySource: "bill")
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
                Text("💳")
                    .font(AIATheme.Font.display)
                    .frame(width: 60, height: 60)
                    .background(AIATheme.billBG)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text(bill.merchant)
                        .font(AIATheme.Font.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(bill.category.isEmpty ? "其他" : bill.category)
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(amountLabel)
                    .font(AIATheme.Font.hero.weight(.bold))
                    .foregroundStyle(bill.isIncome ? AIATheme.ok : AIATheme.warn)
                HStack(spacing: 8) {
                    Text(AppFormat.dateTime.string(from: bill.time))
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AIATheme.billBG)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))

            infoGrid
        }
        .padding(14)
        .card()
    }

    private var infoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            infoBox(icon: "arrow.2.circlepath", label: bill.isIncome ? "类型" : "类型", value: bill.isIncome ? "收入" : "支出")
            infoBox(icon: "yensign.circle", label: "金额", value: "¥\(String(format: "%.2f", bill.amount))")
        }
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

    // MARK: - 识别原图
    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别原图")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(.primary)
            AttachmentSection(imageName: bill.imageName)
        }
        .padding(14)
        .card()
    }

    // MARK: - 操作卡片
    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("操作")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 6)

            actionButton(
                title: "编辑账单",
                sub: "商户 / 金额 / 分类",
                icon: "square.and.pencil",
                color: AIATheme.sub
            ) {
                showEdit = true
            }
            Divider().padding(.leading, 14)

            actionButton(
                title: "删除该账单",
                sub: "删除后不可恢复",
                icon: "trash",
                color: AIATheme.warn
            ) {
                // 先标记删除意图并 pop 回列表，等 onDisappear（pop 动画完全结束）
                // 再真正执行 SafeDelete。避免 syncDeleted=true 触发 @Query 重 fetch
                // 与 NavigationStack pop 动画叠加，导致最后一条删除时卡死。
                // 只保存 ID，不捕获 bill 对象，防止返回列表后对象被 fault 化，
                // 600ms 后访问属性触发 fault 异常闪退。
                pendingDeleteID = bill.persistentModelID
                dismiss()
            }
        }
        .padding(14)
        .card()
    }

    private func actionButton(title: String, sub: String, icon: String, color: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.1))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(color)
                    Text(sub)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
