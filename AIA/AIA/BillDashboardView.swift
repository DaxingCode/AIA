// BillDashboardView.swift
// 账单详情仪表盘：点击账单管理页「今日账单/本月账单」进入。
// 参照咔皮记账风格，支持周/月/年/自定义四种查看方式，含支出/收入/结余、分类 donut 图、分类列表。
import SwiftUI
import SwiftData

enum BillDashboardMode: String, CaseIterable {
    case week, month, year, custom
    var label: String {
        switch self {
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        case .custom: return "自定义"
        }
    }
}

struct BillDashboardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bill.time, order: .reverse) private var allBills: [Bill]

    @State var mode: BillDashboardMode
    @State private var anchorDate: Date = Date()
    @State private var customStart: Date = Date()
    @State private var customEnd: Date = Date()
    @State private var showIncome: Bool = false
    @State private var showCustomPicker: Bool = false

    private let cal = Calendar.current
    private var mondayCalendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2 // 周一为每周起始
        c.minimumDaysInFirstWeek = 4
        return c
    }

    // MARK: - 周期计算
    private var periodStart: Date {
        switch mode {
        case .week:
            let comp = mondayCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchorDate)
            return mondayCalendar.date(from: comp) ?? anchorDate
        case .month:
            let comp = cal.dateComponents([.year, .month], from: anchorDate)
            return cal.date(from: comp) ?? anchorDate
        case .year:
            let comp = cal.dateComponents([.year], from: anchorDate)
            return cal.date(from: comp) ?? anchorDate
        case .custom:
            return customStart
        }
    }

    private var periodEnd: Date {
        switch mode {
        case .week:
            return mondayCalendar.date(byAdding: .day, value: 6, to: periodStart) ?? anchorDate
        case .month:
            return cal.date(byAdding: DateComponents(month: 1, day: -1), to: periodStart) ?? anchorDate
        case .year:
            return cal.date(byAdding: DateComponents(year: 1, day: -1), to: periodStart) ?? anchorDate
        case .custom:
            return customEnd
        }
    }

    private var periodTitle: String {
        switch mode {
        case .week:
            let start = cal.dateComponents([.year, .month, .day], from: periodStart)
            let end = cal.dateComponents([.month, .day], from: periodEnd)
            if start.month == end.month {
                return "\(String(start.year!)).\(start.month!).\(start.day!) - \(end.day!)"
            } else {
                return "\(String(start.year!)).\(start.month!).\(start.day!) - \(end.month!).\(end.day!)"
            }
        case .month:
            let comp = cal.dateComponents([.year, .month], from: periodStart)
            return "\(String(comp.year!))年\(comp.month!)月"
        case .year:
            let comp = cal.dateComponents([.year], from: periodStart)
            return "\(String(comp.year!))年"
        case .custom:
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy.M.d"
            return "\(fmt.string(from: periodStart)) - \(fmt.string(from: periodEnd))"
        }
    }

    // MARK: - 数据过滤
    private var billsInPeriod: [Bill] {
        allBills.filter { $0.time >= periodStart && $0.time <= periodEnd }
    }

    private var totalExpense: Double { billsInPeriod.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount } }
    private var totalIncome: Double { billsInPeriod.filter { $0.isIncome }.reduce(0) { $0 + $1.amount } }
    private var balance: Double { totalIncome - totalExpense }

    private var categoryBreakdown: [(cat: String, sum: Double, count: Int)] {
        let filtered = showIncome ? billsInPeriod.filter { $0.isIncome } : billsInPeriod.filter { !$0.isIncome }
        var dict: [String: (sum: Double, count: Int)] = [:]
        for b in filtered {
            let cat = b.category.isEmpty ? NSLocalizedString("common.other", comment: "") : b.category
            dict[cat, default: (0, 0)].sum += b.amount
            dict[cat, default: (0, 0)].count += 1
        }
        return dict.map { (cat: $0.key, sum: $0.value.sum, count: $0.value.count) }
            .sorted { $0.sum > $1.sum }
    }

    private var donutSegments: [(color: Color, fraction: Double)] {
        let total = categoryBreakdown.reduce(0) { $0 + $1.sum }
        guard total > 0 else { return [] }
        return categoryBreakdown.map { (color: BillCategoryHelpers.color(for: $0.cat), fraction: $0.sum / total) }
    }

    private var totalAmountForCurrentType: Double {
        showIncome ? totalIncome : totalExpense
    }

    private func money(_ value: Double) -> String {
        if value >= 10000 {
            return String(format: "¥%.2f万", value / 10000)
        } else if value == 0 {
            return "¥0"
        } else {
            return String(format: "¥%.2f", value)
        }
    }

    private func moneyNoDecimal(_ value: Double) -> String {
        "¥\(Int(value))"
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modePicker
                    periodNavigator
                    summaryCard
                    categoryCard
                }
                .padding()
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle(LocalizedStringKey("tab.bill"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: mode) { _, new in
            // 切换模式时重置锚点到当前日期，避免跨模式日期错位
            anchorDate = Date()
            if new == .custom {
                customStart = Date()
                customEnd = Date()
            }
        }
        .sheet(isPresented: $showCustomPicker) {
            customDatePickerSheet
        }
    }

    // MARK: - 周期选择器
    private var modePicker: some View {
        SegmentedPicker(options: BillDashboardMode.allCases.map { (value: $0, label: $0.label) }, selection: $mode)
    }

    // MARK: - 周期导航
    private var periodNavigator: some View {
        HStack(spacing: 12) {
            Button {
                shiftPeriod(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(AIATheme.sub)
                    .frame(width: 32, height: 32)
                    .background(AIATheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            if mode == .custom {
                Button {
                    showCustomPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(periodTitle)
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(AIATheme.Font.micro.weight(.semibold))
                            .foregroundStyle(AIATheme.sub)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AIATheme.surface)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text(periodTitle)
                    .font(AIATheme.Font.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                shiftPeriod(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(AIATheme.sub)
                    .frame(width: 32, height: 32)
                    .background(AIATheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func shiftPeriod(by direction: Int) {
        if mode == .custom {
            showCustomPicker = true
            return
        }
        let calendar: Calendar = mode == .week ? mondayCalendar : cal
        let component: Calendar.Component = {
            switch mode {
            case .week: return .weekOfYear
            case .month: return .month
            case .year: return .year
            case .custom: return .day
            }
        }()
        if let newDate = calendar.date(byAdding: component, value: direction, to: anchorDate) {
            anchorDate = newDate
        }
    }

    // MARK: - 汇总卡片
    private var summaryCard: some View {
        HStack(spacing: 0) {
            summaryColumn(title: "支出", value: totalExpense, color: AIATheme.expense)
            Divider().frame(height: 50)
            summaryColumn(title: "收入", value: totalIncome, color: AIATheme.income)
            Divider().frame(height: 50)
            summaryColumn(title: "结余", value: balance, color: balance >= 0 ? AIATheme.income : AIATheme.expense)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private func summaryColumn(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.sub)
            Text(money(value))
                .font(AIATheme.Font.headline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 分类卡片
    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("支出分类构成")
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                typeToggle
            }

            if categoryBreakdown.isEmpty {
                ContentUnavailableView("暂无\(showIncome ? "收入" : "支出")记录",
                    systemImage: "yensign.circle",
                    description: Text("该周期内没有记录"))
                    .frame(height: 180)
            } else {
                HStack(spacing: 20) {
                    DonutView(segments: donutSegments, size: 130, lineWidth: 18)
                        .overlay(
                            VStack(spacing: 2) {
                                Text(showIncome ? "收入" : "支出")
                                    .font(AIATheme.Font.micro)
                                    .foregroundStyle(AIATheme.muted)
                                Text(moneyNoDecimal(totalAmountForCurrentType))
                                    .font(AIATheme.Font.subhead.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        )
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    // 先物化一次，避免 categoryBreakdown（派生自 @Query）在 ForEach 求值期间变化导致下标越界。
                    // 用 enumerated() 取 offset 作 id，不依赖 category 唯一性，保证单次 render 内稳定。
                    let items = categoryBreakdown
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        let pct = totalAmountForCurrentType > 0 ? item.sum / totalAmountForCurrentType : 0
                        categoryRow(item: item, percent: pct)
                        if index < items.count - 1 {
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private var typeToggle: some View {
        HStack(spacing: 0) {
            Button { showIncome = false } label: {
                Text("支出")
                    .font(AIATheme.Font.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(showIncome ? Color.clear : AIATheme.blue)
                    .foregroundStyle(showIncome ? AIATheme.sub : .white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Button { showIncome = true } label: {
                Text("收入")
                    .font(AIATheme.Font.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(showIncome ? AIATheme.amber : Color.clear)
                    .foregroundStyle(showIncome ? .white : AIATheme.sub)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(2)
        .background(AIATheme.fillSoft)
        .clipShape(Capsule())
    }

    private func categoryRow(item: (cat: String, sum: Double, count: Int), percent: Double) -> some View {
        HStack(spacing: 12) {
            Text(BillCategoryHelpers.icon(for: item.cat))
                .font(AIATheme.Font.title1)
                .frame(width: 30, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(item.cat)
                        .font(AIATheme.Font.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(String(format: "%.2f%%", percent * 100))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                    Spacer()
                    Text(money(item.sum))
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 4) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(AIATheme.track)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(BillCategoryHelpers.color(for: item.cat))
                                    .frame(width: geo.size.width * CGFloat(percent), height: 6)
                            }
                    }
                    .frame(height: 6)
                    Text("\(item.count)笔")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - 自定义日期选择器（红框标题：开始日期 / 结束日期）
    private struct CustomCalendarPicker: View {
        @Binding var selectedDate: Date
        let title: String
        @State private var visibleMonth: Date

        private let cal = Calendar.current

        init(selectedDate: Binding<Date>, title: String) {
            self._selectedDate = selectedDate
            self.title = title
            self._visibleMonth = State(initialValue: selectedDate.wrappedValue)
        }

        private var monthTitle: String {
            let f = DateFormatter()
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: "yyyyMMMM", options: 0, locale: Locale.current)
            return f.string(from: visibleMonth)
        }

        private var weekdays: [String] {
            [
                NSLocalizedString("todo.calendar.weekday.sun", comment: ""),
                NSLocalizedString("todo.calendar.weekday.mon", comment: ""),
                NSLocalizedString("todo.calendar.weekday.tue", comment: ""),
                NSLocalizedString("todo.calendar.weekday.wed", comment: ""),
                NSLocalizedString("todo.calendar.weekday.thu", comment: ""),
                NSLocalizedString("todo.calendar.weekday.fri", comment: ""),
                NSLocalizedString("todo.calendar.weekday.sat", comment: "")
            ]
        }

        private var daysInMonth: [Date?] {
            guard let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: visibleMonth)) else { return [] }
            let weekday = cal.component(.weekday, from: firstDay)
            let daysInMonth = cal.range(of: .day, in: .month, for: visibleMonth)?.count ?? 0
            var days: [Date?] = Array(repeating: nil, count: weekday - 1)
            for d in 0..<daysInMonth {
                if let date = cal.date(byAdding: .day, value: d, to: firstDay) {
                    days.append(cal.startOfDay(for: date))
                }
            }
            while days.count % 7 != 0 { days.append(nil) }
            return days
        }

        private var prevMonth: Date {
            cal.date(byAdding: .month, value: -1, to: visibleMonth) ?? visibleMonth
        }

        private var nextMonth: Date {
            cal.date(byAdding: .month, value: 1, to: visibleMonth) ?? visibleMonth
        }

        var body: some View {
            VStack(spacing: 12) {
                // 标题区（红框位置）
                HStack {
                    Button {
                        visibleMonth = prevMonth
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(AIATheme.blue)
                            .frame(width: 36, height: 36)
                            .background(AIATheme.blue.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    VStack(spacing: 2) {
                        Text(title)
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(monthTitle)
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(AIATheme.sub)
                    }

                    Spacer()

                    Button {
                        visibleMonth = nextMonth
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(AIATheme.blue)
                            .frame(width: 36, height: 36)
                            .background(AIATheme.blue.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                // 星期头
                HStack(spacing: 0) {
                    ForEach(weekdays, id: \.self) { d in
                        Text(d)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.sub)
                            .frame(maxWidth: .infinity)
                    }
                }

                // 日期网格
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                    ForEach(daysInMonth.indices, id: \.self) { i in
                        if let date = daysInMonth[i] {
                            dayCell(date)
                        } else {
                            Color.clear.frame(height: 40)
                        }
                    }
                }
            }
            .padding(12)
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }

        private func dayCell(_ date: Date) -> some View {
            let isSelected = cal.isDate(date, inSameDayAs: selectedDate)
            let isToday = cal.isDateInToday(date)
            return Button {
                selectedDate = date
            } label: {
                Text("\(cal.component(.day, from: date))")
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : (isToday ? AIATheme.blue : .primary))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(isSelected ? AIATheme.blue : Color.clear)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 自定义日期选择
    private var customDatePickerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CustomCalendarPicker(
                        selectedDate: $customStart,
                        title: NSLocalizedString("bill.custom.startDate", comment: "")
                    )
                    CustomCalendarPicker(
                        selectedDate: $customEnd,
                        title: NSLocalizedString("bill.custom.endDate", comment: "")
                    )
                }
                .padding()
            }
            .navigationTitle("选择日期范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showCustomPicker = false }
                        .font(AIATheme.Font.callout.weight(.medium))
                }
            }
            .background(AIATheme.fillSoft.ignoresSafeArea())
        }
    }
}

#Preview {
    NavigationStack {
        BillDashboardView(mode: .week)
    }
}
