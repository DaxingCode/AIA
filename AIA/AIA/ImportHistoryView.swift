// ImportHistoryView.swift
// 导入记录：按批次列出每次导入的来源/文件/时间/条数，点批次可看该批次的账单明细。
// 入口：账单导入页右上角「导入记录」→ NavigationRouter.navigate(.importHistory)。
import SwiftUI
import SwiftData

struct ImportHistoryView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<ImportBatch> { !$0.syncDeleted },
           sort: \ImportBatch.importedAt, order: .reverse)
    private var batches: [ImportBatch]

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        Group {
            if batches.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle("导入记录")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(AIATheme.Font.largeTitle)
                .foregroundStyle(AIATheme.muted)
            Text("还没有导入记录")
                .font(AIATheme.Font.callout)
                .foregroundStyle(AIATheme.sub)
            Text("在「账单导入」导入账单后，会在这里留下记录")
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(batches) { batch in
                    NavigationLink {
                        ImportBatchDetailView(batch: batch)
                            .environment(\.modelContext, context)
                    } label: {
                        batchRow(batch)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func batchRow(_ batch: ImportBatch) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(sourceColor(batch.source).opacity(0.12))
                    .frame(width: 40, height: 40)
                sourceImage(batch.source)
                    .font(AIATheme.Font.body.weight(.medium))
                    .foregroundStyle(sourceColor(batch.source))
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(sourceTitle(batch.source))
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let name = batch.fileName {
                        Text(name)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.sub)
                            .lineLimit(1)
                    }
                }
                Text(dateFormatter.string(from: batch.importedAt))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text("导入 \(batch.totalCount) 条")
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(AIATheme.bill)
                if batch.skippedCount > 0 {
                    Text("跳过 \(batch.skippedCount) 条")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }
        }
        .padding(14)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    // MARK: - 来源展示
    private func sourceTitle(_ source: String) -> String {
        switch source {
        case "wechat": return "微信"
        case "alipay": return "支付宝"
        case "paste":  return "粘贴"
        default:       return "其他来源"
        }
    }

    @ViewBuilder
    private func sourceImage(_ source: String) -> some View {
        switch source {
        case "wechat": Image("wechat").resizable().scaledToFit()
        case "alipay": Image(systemName: "creditcard.fill")
        case "paste":  Image(systemName: "doc.on.clipboard")
        default:       Image(systemName: "doc.on.doc")
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "wechat": return Color(hex: 0x07c160)
        case "alipay": return Color(hex: 0x1677ff)
        case "paste":  return AIATheme.purple
        default:       return AIATheme.blue
        }
    }
}

// MARK: - 批次明细
struct ImportBatchDetailView: View {
    let batch: ImportBatch

    @Query private var allBills: [Bill]

    init(batch: ImportBatch) {
        self.batch = batch
        let id = batch.syncId
        _allBills = Query(filter: #Predicate<Bill> { !$0.syncDeleted && $0.importBatchId == id },
                          sort: \Bill.time, order: .reverse)
    }

    private let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencySymbol = "¥"
        return f
    }()

    var body: some View {
        Group {
            if allBills.isEmpty {
                Text("该批次没有可导出的账单")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listView
            }
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle("导入明细")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("共 \(allBills.count) 条")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                    Spacer()
                }
                ForEach(allBills) { bill in
                    row(bill)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func row(_ bill: Bill) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(bill.isIncome ? "收入" : "支出")
                        .font(AIATheme.Font.micro.weight(.medium))
                        .foregroundStyle(bill.isIncome ? AIATheme.income : AIATheme.expense)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((bill.isIncome ? AIATheme.income : AIATheme.expense).opacity(0.12))
                        .clipShape(Capsule())
                    Text(bill.merchant.isEmpty ? "未命名" : bill.merchant)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(dateString(bill.time))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                    if !bill.category.isEmpty {
                        Text("·").font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
                        Text(bill.category).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                    }
                    Spacer(minLength: 0)
                }
            }
            Text(moneyFormatter.string(from: NSNumber(value: bill.amount)) ?? String(format: "%.2f", bill.amount))
                .font(AIATheme.Font.callout.weight(.semibold))
                .foregroundStyle(bill.isIncome ? AIATheme.income : AIATheme.expense)
        }
        .padding(10)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
