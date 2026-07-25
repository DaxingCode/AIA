// RecurringBillManager.swift
// 周期性 / 订阅账单：房租、会员费、房贷等按周期自动入账。
// - RecurringRule：一条周期规则（纯本地模型，不参与云同步）。
// - RecurringBillManager：在 App 打开 / 回到前台时调用 generateDue，
//   把「已到期但尚未生成」的账期自动写成 Bill；长期未打开也会补齐中间周期（去重靠 lastGeneratedAt）。
import Foundation
import SwiftData

// MARK: - 周期类型
/// 周期账单的循环周期。
enum RecurrenceCycle: String, Codable, CaseIterable, Identifiable {
    case daily     = "daily"
    case weekly    = "weekly"
    case monthly   = "monthly"
    case quarterly = "quarterly"
    case yearly    = "yearly"
    case custom    = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily:     return "每天"
        case .weekly:    return "每周"
        case .monthly:   return "每月"
        case .quarterly: return "每季"
        case .yearly:    return "每年"
        case .custom:    return "自定义"
        }
    }
}

/// 自定义周期的单位。
enum RecurrenceUnit: String, Codable, CaseIterable, Identifiable {
    case day   = "day"
    case week  = "week"
    case month = "month"
    case year  = "year"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:   return "天"
        case .week:  return "周"
        case .month: return "月"
        case .year:  return "年"
        }
    }
}

/// 周期账单规则（本地模型：持有 syncId/syncUpdatedAt/syncDeleted 元数据字段，
/// 但 CloudSyncManager.buildPushItems 未列举本模型，故不会上云；字段仅本地预留）。
@Model final class RecurringRule {
    var merchant: String        // 商户，如「链家房租」
    var amount: Double          // 金额
    var category: String        // 分类，如 住房/娱乐
    var note: String            // 备注（生成到账单后带「·自动」后缀）
    var isIncome: Bool          // 是否收入（如理财利息；默认 false 为支出）
    /// 每月/季/年中的生成日（1...28，避免 2 月没有 29-31 日导致永不触发）。
    var dayOfMonth: Int
    /// 规则生效起始日期：首次生成不早于此日。
    var startDate: Date
    /// 上次已自动生成的账期日期（nil=从未生成）。生成后更新为最近一次生成的账期，用于去重与补生成。
    var lastGeneratedAt: Date?

    // MARK: 云同步字段（v9 新增；本模型不进 push 列表，仅本地预留，不会上云）
    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    // MARK: 周期相关（v4 新增）
    /// 周期类型：daily/weekly/monthly/quarterly/yearly/custom
    var cycleRaw: String?
    /// 自定义周期数值（仅 custom 有效，>=1）
    var customValue: Int?
    /// 自定义周期单位：day/week/month/year（仅 custom 有效）
    var customUnitRaw: String?

    /// 周期类型（计算属性，不存盘）。
    var cycle: RecurrenceCycle {
        get { RecurrenceCycle(rawValue: cycleRaw ?? RecurrenceCycle.monthly.rawValue) ?? .monthly }
        set { cycleRaw = newValue.rawValue }
    }

    /// 自定义周期单位（计算属性，不存盘）。
    var customUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: customUnitRaw ?? RecurrenceUnit.month.rawValue) ?? .month }
        set { customUnitRaw = newValue.rawValue }
    }

    init(merchant: String = "", amount: Double = 0, category: String = "",
         note: String = "", isIncome: Bool = false, dayOfMonth: Int = 1,
         startDate: Date = .now, lastGeneratedAt: Date? = nil,
         cycleRaw: String = RecurrenceCycle.monthly.rawValue,
         customValue: Int = 1, customUnitRaw: String = RecurrenceUnit.month.rawValue,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.merchant = merchant
        self.amount = amount
        self.category = category
        self.note = note
        self.isIncome = isIncome
        self.dayOfMonth = min(max(dayOfMonth, 1), 28)
        self.startDate = startDate
        self.lastGeneratedAt = lastGeneratedAt
        self.cycleRaw = cycleRaw
        self.customValue = max(customValue, 1)
        self.customUnitRaw = customUnitRaw
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// MARK: - 生成管理器
enum RecurringBillManager {
    /// 生成所有「已到期但尚未生成」的周期账单。App 打开 / 回到前台时调用。
    /// 自动补齐中间漏掉的周期（如长期未打开 App）：每个未生成的账期各写一笔，并把备注标「自动」。
    @MainActor
    static func generateDue(context: ModelContext) {
        let now = Date()
        let rules = (try? context.fetch(FetchDescriptor<RecurringRule>())) ?? []
        guard !rules.isEmpty else { return }
        var dirtied = false
        for rule in rules {
            var cursor = rule.lastGeneratedAt ?? rule.startDate.addingTimeInterval(-1)
            while let d = nextOccurrence(after: cursor, rule: rule),
                  d <= now {
                guard d >= rule.startDate else { cursor = d; continue }
                let billNote = rule.note.isEmpty ? "周期自动生成" : rule.note + " · 自动"
                let bill = Bill(merchant: rule.merchant,
                                amount: rule.amount,
                                category: rule.category,
                                time: d,
                                note: billNote,
                                confirmed: false,
                                isIncome: rule.isIncome,
                                imageName: nil)
                context.insert(bill)
                rule.lastGeneratedAt = d
                cursor = d
                dirtied = true
            }
        }
        if dirtied { try? context.save() }
    }

    // MARK: - 下一周期计算
    private static func nextOccurrence(after: Date, rule: RecurringRule) -> Date? {
        switch rule.cycle {
        case .daily:     return nextDaily(after: after)
        case .weekly:    return nextWeekly(after: after, rule: rule)
        case .monthly:   return nextMonthly(after: after, rule: rule)
        case .quarterly: return nextQuarterly(after: after, rule: rule)
        case .yearly:    return nextYearly(after: after, rule: rule)
        case .custom:    return nextCustom(after: after, rule: rule)
        }
    }

    private static func nextDaily(after: Date) -> Date? {
        Calendar.current.date(byAdding: .day, value: 1, to: after)
    }

    private static func nextWeekly(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: rule.startDate)
        var date = cal.date(byAdding: .day, value: 1, to: after) ?? after
        // 安全兜底：最多找 14 天，防止死循环
        for _ in 0..<14 {
            if cal.component(.weekday, from: date) == weekday {
                return date
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: date) else { return nil }
            date = next
        }
        return nil
    }

    private static func nextMonthly(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let day = min(max(rule.dayOfMonth, 1), 28)
        var comps = cal.dateComponents([.year, .month, .day], from: after)
        comps.day = day
        if let candidate = cal.date(from: comps), candidate > after {
            return candidate
        }
        guard let monthStart = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
        var nextComps = cal.dateComponents([.year, .month], from: nextMonth)
        nextComps.day = day
        return cal.date(from: nextComps)
    }

    private static func nextQuarterly(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let startMonth = cal.component(.month, from: rule.startDate)
        let day = min(max(rule.dayOfMonth, 1), 28)

        // 季度月份：startMonth, startMonth+3, startMonth+6, startMonth+9（均归一化到 1...12）
        var quarterMonths = (0...3).map { i in
            ((startMonth - 1 + 3 * i) % 12) + 1
        }
        quarterMonths.sort()

        let comps = cal.dateComponents([.year, .month, .day], from: after)
        let year = comps.year ?? 0
        let month = comps.month ?? 1
        let dayAfter = comps.day ?? 0

        for qm in quarterMonths {
            if qm > month || (qm == month && dayAfter < day) {
                if let d = cal.date(from: DateComponents(year: year, month: qm, day: day)) {
                    return d
                }
            }
        }

        // 跨年：用下一个年度的第一个季度月
        return cal.date(from: DateComponents(year: year + 1, month: quarterMonths[0], day: day))
    }

    private static func nextYearly(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let month = cal.component(.month, from: rule.startDate)
        let day = min(max(rule.dayOfMonth, 1), 28)
        let comps = cal.dateComponents([.year, .month, .day], from: after)
        let year = comps.year ?? 0
        let currentMonth = comps.month ?? 1
        let currentDay = comps.day ?? 0

        if currentMonth < month || (currentMonth == month && currentDay < day) {
            return cal.date(from: DateComponents(year: year, month: month, day: day))
        }
        return cal.date(from: DateComponents(year: year + 1, month: month, day: day))
    }

    private static func nextCustom(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let unit: Calendar.Component
        switch rule.customUnit {
        case .day:   unit = .day
        case .week:  unit = .weekOfYear
        case .month: unit = .month
        case .year:  unit = .year
        }
        let value = max(rule.customValue ?? 1, 1)

        // 从 startDate 开始，按固定间隔生成，找到第一个严格大于 after 的日期
        var current = rule.startDate
        // 安全兜底：最多 1000 次迭代，防止异常死循环
        for _ in 0..<1000 {
            if current > after { return current }
            guard let next = cal.date(byAdding: unit, value: value, to: current) else { return nil }
            current = next
        }
        return nil
    }

    // MARK: - 首次生成日期（新增规则时给个合理默认值）
    /// 计算「创建时该周期最近一期」作为首次生成默认值：若当日已过去，仍用最近一期以补生成当前周期这笔；未来日则等到那天。
    static func firstOccurrenceDefault(for rule: RecurringRule, from base: Date = .now) -> Date {
        switch rule.cycle {
        case .daily:
            return base
        case .weekly:
            // 找到 base 当周或下周的同一个 weekday
            return rule.startDate
        case .monthly, .quarterly, .yearly:
            let day = min(max(rule.dayOfMonth, 1), 28)
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month], from: base)
            comps.day = day
            return cal.date(from: comps) ?? base
        case .custom:
            return rule.startDate
        }
    }

    // MARK: - 下一笔将要生成的账期（列表展示「下次生成：X月X日」）
    static func nextDueDate(for rule: RecurringRule, now: Date = .now) -> Date {
        let start = rule.lastGeneratedAt ?? rule.startDate.addingTimeInterval(-1)
        if let d = nextOccurrence(after: start, rule: rule), d >= rule.startDate {
            return d
        }
        return rule.startDate
    }

    // MARK: - 描述文本
    /// 返回规则的周期描述，如「每月 10 日」「每 3 天」等。
    static func cycleDescription(for rule: RecurringRule) -> String {
        switch rule.cycle {
        case .daily:
            return "每天"
        case .weekly:
            let weekday = Calendar.current.component(.weekday, from: rule.startDate)
            return "每周 \(weekdayText(weekday))"
        case .monthly:
            return "每月 \(rule.dayOfMonth) 日"
        case .quarterly:
            return "每季 \(rule.dayOfMonth) 日"
        case .yearly:
            return "每年 \(rule.dayOfMonth) 日"
        case .custom:
            return "每 \(rule.customValue ?? 1) \(rule.customUnit.title)"
        }
    }

    private static func weekdayText(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "日"
        case 2: return "一"
        case 3: return "二"
        case 4: return "三"
        case 5: return "四"
        case 6: return "五"
        case 7: return "六"
        default: return ""
        }
    }
}
