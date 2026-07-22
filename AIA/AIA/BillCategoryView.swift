// BillCategoryView.swift
// ⑬ 账单分类明细：按《UI完整页面流.html》屏幕 13 重做。category 由账单页分类图例传入。
import SwiftUI
import SwiftData
import Charts

private struct BPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}
private let bFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "M/d"; return f
}()

struct BillCategoryView: View {
    let category: String
    @Query(sort: \Bill.time, order: .reverse) private var bills: [Bill]
    @Environment(\.modelContext) private var context
    @State private var toast: String?
    @State private var previewImage: UIImage?

    private var monthBills: [Bill] {
        bills.filter { Calendar.current.isDate($0.time, equalTo: Date(), toGranularity: .month) }
    }
    private var catBills: [Bill] { monthBills.filter { ($0.category.isEmpty ? "其他" : $0.category) == category } }
    private var total: Double { catBills.reduce(0) { $0 + $1.amount } }
    private var monthTotal: Double { monthBills.reduce(0) { $0 + $1.amount } }
    private var ratio: Double { monthTotal > 0 ? total / monthTotal : 0 }
    private var budget: Double { 1500 }   // 演示默认值（后续可做成可配置）

    private var weekData: [BPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: today)!
            let sum = catBills.filter { cal.isDate($0.time, inSameDayAs: d) }.reduce(0) { $0 + $1.amount }
            return BPoint(label: bFmt.string(from: d), value: sum)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(format: "¥%.0f", total)).font(AIATheme.Font.callout.weight(.semibold))
                    Spacer()
                    Text(String(format: "本月 · 占比 %.0f%%", ratio * 100))
                        .font(AIATheme.Font.micro)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(AIATheme.fillSoft).foregroundStyle(AIATheme.sub)
                        .clipShape(Capsule())
                }

                Chart(weekData) { p in
                    BarMark(x: .value("日", p.label), y: .value("¥", p.value))
                        .foregroundStyle(AIATheme.bill.opacity(0.7))
                }
                .frame(height: 56)
                .chartYAxis(.hidden).chartXAxis(.hidden)
                Text("近 7 日\(category)支出").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)

                SectionTitle(text: "明细")
                if catBills.isEmpty {
                    Text("本月暂无\(category)账单记录").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        .frame(height: 60)
                } else {
                    ForEach(catBills) { b in
                        HStack {
                            NavigationLink { BillDetailView(bill: b) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(b.merchant).font(AIATheme.Font.footnote.weight(.medium))
                                        Text(AppFormat.dateTime.string(from: b.time))
                                            .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                                    }
                                    Spacer()
                                    Text(String(format: "¥%.2f", b.amount)).font(AIATheme.Font.footnote.weight(.medium))
                                }
                            }
                            .buttonStyle(.plain)
                            if let thumb = LocalImageStore.load(b.imageName) {
                                Button { previewImage = thumb } label: {
                                    Image(uiImage: thumb)
                                        .resizable().scaledToFill()
                                        .frame(width: 34, height: 34)
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 10)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                SafeDelete.bill(b, in: context)
                            } label: { Label("删除", systemImage: "trash") }
                        }
                        Divider()
                    }
                }

                SectionTitle(text: "预算管理")
                HStack {
                    Text(String(format: "%@预算 ¥%.0f", category, budget)).font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
                    Spacer()
                    Text(String(format: "已用 %.0f%%", min(total / budget, 1) * 100)).font(AIATheme.Font.caption.weight(.medium))
                }
                MiniBar(value: min(total / budget, 1), color: AIATheme.warning)

                Button { toast = "调整分类预算" } label: {
                    HStack {
                        Text("调整分类预算").font(AIATheme.Font.footnote.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(AIATheme.muted)
                    }.padding(.vertical, 12)
                }.buttonStyle(.plain)

                ShareLink(item: csvURL) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出该分类明细 (CSV)").font(AIATheme.Font.footnote.weight(.medium))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
            }
            .padding()
        }
        AIBottomBar()
    }
    .background(Color(.secondarySystemBackground))
    .navigationTitle("\(category)支出")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(toast ?? "") }
        .fullScreenCover(isPresented: Binding(get: { previewImage != nil }, set: { if !$0 { previewImage = nil } })) {
            if let img = previewImage { FullImageView(image: img) }
        }
    }

    private var csvURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(category)_账单.csv")
        try? csvString.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private var csvString: String {
        var s = "商户,金额,时间,分类,备注\n"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        for b in catBills {
            s += "\"\(b.merchant)\",\(String(format: "%.2f", b.amount)),\"\(f.string(from: b.time))\",\(b.category),\"\(b.note)\"\n"
        }
        return s
    }
}
