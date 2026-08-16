// BillWidget.swift
// 小型(2x2)：账单管理宫格，复刻 ContentView.billTile。
import WidgetKit
import SwiftUI
import AIAKit

struct BillProvider: TimelineProvider {
    func placeholder(in context: Context) -> BillEntry {
        BillEntry(date: Date(), isEmpty: false, hidden: false,
                  todayExpense: 58, monthIncome: 12000, monthExpense: 3200,
                  monthlyBudget: 5000, monthBalance: 8800)
    }

    func getSnapshot(in context: Context, completion: @escaping (BillEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BillEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    func loadEntry() -> BillEntry {
        let hidden = WidgetStore.billHidden()
        let income = WidgetStore.monthIncomeDirect()
        let expense = WidgetStore.monthExpenseDirect()
        let budget = WidgetStore.monthlyBudget()
        return BillEntry(
            date: Date(),
            isEmpty: WidgetStore.billTotalCountDirect() == 0,
            hidden: hidden,
            todayExpense: WidgetStore.todayExpenseDirect(),
            monthIncome: income,
            monthExpense: expense,
            monthlyBudget: budget,
            monthBalance: income - expense
        )
    }
}

/// 指标：默认双行（标签在上、金额在下）；horizontal=true 时标签与金额同一行（仅用于「今日支出」）
private struct BillMetric: View {
    let label: String
    let value: String
    let valueColor: Color
    var alignment: HorizontalAlignment = .center
    var horizontal: Bool = false

    var body: some View {
        if horizontal {
            HStack(spacing: 6) {
                Text(label)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 17))
                    .fontWeight(.semibold)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        } else {
            VStack(alignment: alignment, spacing: 1) {
                Text(label)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(value)
                    .font(.system(size: 10))
                    .fontWeight(.regular)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        }
    }
}

struct BillWidgetEntryView: View {
    var entry: BillEntry

    private var hiddenText: String { "•••" }
    private var expenseTxt: String { entry.hidden ? hiddenText : "\(Int(entry.todayExpense))" }
    private var monthExpenseTxt: String { entry.hidden ? hiddenText : "\(Int(entry.monthExpense))" }
    private var incomeTxt: String { entry.hidden ? hiddenText : "\(Int(entry.monthIncome))" }
    private var budgetTxt: String { entry.hidden ? hiddenText : "\(Int(entry.monthlyBudget))" }
    private var balanceTxt: String { entry.hidden ? hiddenText : "\(Int(entry.monthBalance))" }
    private var balanceColor: Color {
        entry.hidden ? AIATheme.muted : (entry.monthBalance >= 0 ? AIATheme.income : AIATheme.expense)
    }

    var body: some View {
        WidgetTile(
            accent: AIATheme.bill,
            icon: "creditcard.fill",
            title: "账单管理",
            badge: "",
            number: "",
            unit: "",
            isEmpty: entry.isEmpty,
            showBigNumber: false
        ) {
            VStack(alignment: .leading, spacing: 5) {
                BillMetric(label: "今日支出", value: expenseTxt,
                           valueColor: entry.hidden ? AIATheme.muted : AIATheme.expense,
                           alignment: .leading, horizontal: true)
                HStack(spacing: 4) {
                    BillMetric(label: "本月收入", value: incomeTxt,
                               valueColor: entry.hidden ? AIATheme.muted : AIATheme.income,
                               alignment: .leading)
                    BillMetric(label: "本月支出", value: monthExpenseTxt,
                               valueColor: entry.hidden ? AIATheme.muted : AIATheme.expense,
                               alignment: .leading)
                }
                HStack(spacing: 4) {
                    BillMetric(label: "本月预算", value: budgetTxt, valueColor: AIATheme.sub,
                               alignment: .leading)
                    BillMetric(label: "本月结余", value: balanceTxt, valueColor: balanceColor,
                               alignment: .leading)
                }
            }
        }
        .widgetURL(URL(string: "aia://bill"))
    }
}

struct BillWidget: Widget {
    let kind = "aia.bill"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BillProvider()) { entry in
            BillWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("账单管理")
        .description("今日支出 / 本月收支结余")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
