// MonthlyReportView.swift
// 按月导出 CSV + 生成月报图片分享。
// 入口：账单列表页顶部「月报 / 数据导出」卡片。
import SwiftUI
import SwiftData

/// 单月报告所需数据（屏幕展示与图片渲染共用同一份，保证一致）。
private struct MonthReportData {
    let monthLabel: String          // 如 2026年7月
    let income: Double
    let expense: Double
    let balance: Double
    let categories: [(cat: String, sum: Double, color: Color, icon: String)]  // 支出分类占比
    let topMerchants: [(name: String, amount: Double)]                        // 支出 Top3
    let billCount: Int
}

struct MonthlyReportView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Bill> { !$0.syncDeleted }, sort: \Bill.time, order: .reverse) private var bills: [Bill]
    @State private var selectedMonth: Date = startOfMonth(Date())
    @State private var sharePayload: SharePayload? = nil
    @State private var exporting = false

    private let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy年M月"; return f
    }()
    private let fileFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f
    }()

    // 有账单的月份（每月 1 号），降序
    private var availableMonths: [Date] {
        let cal = Calendar.current
        let set = Set(bills.map { cal.date(from: cal.dateComponents([.year, .month], from: $0.time))! })
        return set.sorted(by: >)
    }

    private var monthBills: [Bill] {
        bills.filter { Calendar.current.isDate($0.time, equalTo: selectedMonth, toGranularity: .month) }
    }

    private var reportData: MonthReportData {
        let expenseBills = monthBills.filter { !$0.isIncome }
        let income = monthBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
        let expense = expenseBills.reduce(0) { $0 + $1.amount }
        // 分类汇总（按支出）
        var dict: [String: Double] = [:]
        for b in expenseBills { dict[b.category.isEmpty ? "其他" : b.category, default: 0] += b.amount }
        let categories = dict.sorted { $0.value > $1.value }.map {
            (cat: $0.key, sum: $0.value,
             color: BillCategoryHelpers.color(for: $0.key),
             icon: BillCategoryHelpers.icon(for: $0.key))
        }
        let top = expenseBills.sorted { $0.amount > $1.amount }.prefix(3).map {
            (name: $0.merchant.isEmpty ? "未命名" : $0.merchant, amount: $0.amount)
        }
        return MonthReportData(
            monthLabel: monthFmt.string(from: selectedMonth),
            income: income, expense: expense, balance: income - expense,
            categories: categories, topMerchants: Array(top), billCount: monthBills.count
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 月份选择
                monthPicker
                if monthBills.isEmpty {
                    emptyState
                } else {
                    ReportCardView(data: reportData)
                        .padding(.horizontal, 2)
                    actionButtons
                }
            }
            .padding()
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle("月报 / 数据导出")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharePayload) { ShareSheet(items: $0.items) }
    }

    private var monthPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableMonths, id: \.self) { m in
                    let sel = Calendar.current.isDate(m, equalTo: selectedMonth, toGranularity: .month)
                    Button {
                        selectedMonth = m
                    } label: {
                        Text(monthFmt.string(from: m))
                            .font(.system(size: 13, weight: sel ? .semibold : .regular))
                            .foregroundStyle(sel ? .white : AIATheme.sub)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(sel ? AIATheme.blue : AIATheme.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(AIATheme.hairline, lineWidth: sel ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyState: some View {
        // 垂直居中：上下 Spacer 让空态落在模块可视区域中央。
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(AIATheme.Font.ultra)
                    .foregroundStyle(AIATheme.muted)
                Text("\(monthFmt.string(from: selectedMonth)) 暂无账单")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text("记几笔账单后再来生成月报")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                exportCSV()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                    Text("导出 CSV（按月明细）")
                }
                .font(AIATheme.Font.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(AIATheme.blue)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)

            Button {
                exportImage()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up.fill")
                    Text("生成月报图片分享")
                }
                .font(AIATheme.Font.callout.weight(.semibold))
                .foregroundStyle(AIATheme.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(AIATheme.blue.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - CSV 导出
    private func exportCSV() {
        let csv = Self.buildCSV(month: selectedMonth, bills: monthBills)
        let filename = "账单_\(fileFmt.string(from: selectedMonth)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        sharePayload = SharePayload(items: [url])
    }

    static func buildCSV(month: Date, bills: [Bill]) -> String {
        var lines: [String] = []
        lines.append("\u{FEFF}日期,商户,分类,类型,金额,备注")   // BOM 让 Excel 正确识别 UTF-8 中文
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let sorted = bills.sorted { $0.time < $1.time }
        for b in sorted {
            let row = [
                f.string(from: b.time),
                csvEscape(b.merchant),
                csvEscape(b.category),
                b.isIncome ? "收入" : "支出",
                String(format: "%.2f", b.amount),
                csvEscape(b.note)
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    // MARK: - 月报图片导出
    private func exportImage() {
        let view = ReportCardView(data: reportData)
            .preferredColorScheme(.light)
            .frame(width: 390)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = .init(width: 390, height: .infinity)
        if let image = renderer.uiImage {
            sharePayload = SharePayload(items: [image])
        }
    }

    private static func startOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }
}

// MARK: - 月报卡片（屏幕与图片共用）
private struct ReportCardView: View {
    let data: MonthReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 头部
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("好记AI")
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                    Text("月度账单报告")
                        .font(AIATheme.Font.title2.weight(.bold))
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                Text(data.monthLabel)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(AIATheme.surfaceSecondary)
                    .clipShape(Capsule())
            }

            // 三数：收入 / 支出 / 结余
            HStack(spacing: 10) {
                statTile("收入", data.income, AIATheme.income)
                statTile("支出", data.expense, AIATheme.expense)
                statTile("结余", data.balance, data.balance >= 0 ? AIATheme.income : AIATheme.expense)
            }

            // 分类占比
            if !data.categories.isEmpty {
                HStack(alignment: .center, spacing: 16) {
                    DonutView(segments: data.categories.map { ($0.color, $0.sum) },
                              size: 104, lineWidth: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<min(data.categories.count, 5), id: \.self) { i in
                            let c = data.categories[i]
                            let pct = data.expense > 0 ? Int(c.sum / data.expense * 100) : 0
                            HStack(spacing: 6) {
                                Text(c.icon).font(AIATheme.Font.caption)
                                Text(c.cat).font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
                                Spacer(minLength: 0)
                                Text("¥\(Int(c.sum))").font(AIATheme.Font.caption.weight(.medium)).foregroundStyle(.primary)
                                Text("\(pct)%").font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            // Top 商户
            if !data.topMerchants.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("支出 Top")
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    ForEach(0..<data.topMerchants.count, id: \.self) { i in
                        let m = data.topMerchants[i]
                        HStack(spacing: 8) {
                            Text("\(i + 1)")
                                .font(AIATheme.Font.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(AIATheme.blue)
                                .clipShape(Circle())
                            Text(m.name)
                                .font(AIATheme.Font.footnote)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("¥\(Int(m.amount))")
                                .font(AIATheme.Font.footnote.weight(.medium))
                                .foregroundStyle(AIATheme.blue)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text("由 好记AI 生成 · 共 \(data.billCount) 笔")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
        }
        .padding(18)
        .card(radius: AIATheme.rLG, shadow: false)
    }

    private func statTile(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.sub)
            Text("¥\(Int(value))")
                .font(AIATheme.Font.title3.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }
}
