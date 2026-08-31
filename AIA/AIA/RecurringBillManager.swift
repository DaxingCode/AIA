// RecurringBillManager.swift
// 周期性 / 订阅账单：房租、会员费、房贷等按周期自动入账。
// - RecurringRule：一条周期规则（已带 syncId/syncUpdatedAt/syncDeleted 字段，v9 预留云同步；
//   目前 CloudSyncManager 未列举本模型，故暂不上云）。
// - RecurringBillManager：在 App 打开 / 回到前台时调用 generateDue，
//   把「已到期但尚未生成」的账期自动写成 Bill；长期未打开也会补齐中间周期（去重靠 lastGeneratedAt）。
import Foundation
import SwiftData
import AIAKit

// MARK: - 生成管理器
// RecurringRule / RecurrenceCycle / RecurrenceUnit 已抽入 AIAKit，本文件仅保留生成逻辑。
enum RecurringBillManager {
    /// 生成所有「已到期但尚未生成」的周期账单。App 打开 / 回到前台时调用。
    /// 自动补齐中间漏掉的周期（如长期未打开 App）：每个未生成的账期各写一笔，并把备注标「自动」。
    @MainActor
    static func generateDue(context: ModelContext) {
        // 用「今天结束时刻」作为到期基准：这样「今天」这一期（无论时分秒）都算已到期，
        // 解决 daily 规则在创建当天因时间戳几乎相等而被判为「未到」、不生成首笔的问题。
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_399)
        let rules = (try? context.fetch(FetchDescriptor<RecurringRule>())) ?? []
        guard !rules.isEmpty else { return }
        var dirtied = false
        for rule in rules {
            // ① 首次生成：从未生成过，且首次生成日期已到（今天或过去）
            //    → 先把 startDate 当天这一笔强制生成出来，它就是序列的第一笔。
            //    账单时间 = startDate 的时分秒（用户选日期时保存的时刻）。
            if rule.lastGeneratedAt == nil && rule.startDate <= now {
                createBill(from: rule, time: rule.startDate, context: context)
                rule.lastGeneratedAt = rule.startDate
                dirtied = true
            }

            // ② 以 lastGeneratedAt 为起点，按周期补齐从 startDate 到今天的所有账期。
            var cursor = rule.lastGeneratedAt ?? rule.startDate.addingTimeInterval(-1)
            while let d = nextOccurrence(after: cursor, rule: rule),
                  d <= now {
                guard d >= rule.startDate else { cursor = d; continue }
                createBill(from: rule, time: d, context: context)
                rule.lastGeneratedAt = d
                cursor = d
                dirtied = true
            }
        }
        if dirtied { try? context.save() }
    }

    // MARK: - 生成一条账单
    private static func createBill(from rule: RecurringRule, time: Date, context: ModelContext) {
        // 备注：未填则显示「周期账单」，已填则保留用户备注 + 「· 周期账单」后缀
        let billNote = rule.note.isEmpty ? "周期账单" : rule.note + " · 周期账单"
        let bill = Bill(merchant: rule.merchant,
                        amount: rule.amount,
                        category: rule.category,
                        time: time,
                        note: billNote,
                        confirmed: false,
                        isIncome: rule.isIncome,
                        imageName: nil)
        // >>> CHANGE-[2026-08-31 23:30:00]-[周期账单来源关联] 开始
        // 记录来源规则 syncId：账单编辑页靠它回填「设为周期账单」开关为打开状态。
        bill.sourceRecurringRuleSyncId = rule.syncId
        // <<< CHANGE-[2026-08-31 23:30:00]-[周期账单来源关联] 结束
        context.insert(bill)
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
        @unknown default: return nil
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

    // >>> CHANGE-[2026-08-30 13:43:27]-[生成日1到31] 开始
    /// 取某年某月的"目标日"；若那个月没有这一天（如 2 月 30 日），返回该月最后一天。
    private static func safeDay(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        let clamped = min(max(day, 1), 31)
        let comps = DateComponents(year: year, month: month, day: clamped)
        if let d = calendar.date(from: comps) { return d }
        // 该月不存在这一天 → 取下个月 0 日 = 当月最后一天
        return calendar.date(from: DateComponents(year: year, month: month + 1, day: 0))
    }
    // <<< CHANGE-[2026-08-30 13:43:27]-[生成日1到31] 结束

    private static func nextMonthly(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let day = min(max(rule.dayOfMonth, 1), 31)
        var comps = cal.dateComponents([.year, .month, .day], from: after)
        if let candidate = Self.safeDay(year: comps.year ?? 0, month: comps.month ?? 1, day: day, calendar: cal),
           candidate > after {
            return candidate
        }
        guard let monthStart = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
        let nextComps = cal.dateComponents([.year, .month], from: nextMonth)
        return Self.safeDay(year: nextComps.year ?? 0, month: nextComps.month ?? 1, day: day, calendar: cal)
    }

    private static func nextQuarterly(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let startMonth = cal.component(.month, from: rule.startDate)
        let day = min(max(rule.dayOfMonth, 1), 31)

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
                if let d = Self.safeDay(year: year, month: qm, day: day, calendar: cal) {
                    return d
                }
            }
        }

        // 跨年：用下一个年度的第一个季度月
        return Self.safeDay(year: year + 1, month: quarterMonths[0], day: day, calendar: cal)
    }

    private static func nextYearly(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let month = cal.component(.month, from: rule.startDate)
        let day = min(max(rule.dayOfMonth, 1), 31)
        let comps = cal.dateComponents([.year, .month, .day], from: after)
        let year = comps.year ?? 0
        let currentMonth = comps.month ?? 1
        let currentDay = comps.day ?? 0

        if currentMonth < month || (currentMonth == month && currentDay < day) {
            return Self.safeDay(year: year, month: month, day: day, calendar: cal)
        }
        return Self.safeDay(year: year + 1, month: month, day: day, calendar: cal)
    }

    private static func nextCustom(after: Date, rule: RecurringRule) -> Date? {
        let cal = Calendar.current
        let unit: Calendar.Component
        switch rule.customUnit {
        case .day:   unit = .day
        case .week:  unit = .weekOfYear
        case .month: unit = .month
        case .year:  unit = .year
        @unknown default: unit = .day
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
            let day = min(max(rule.dayOfMonth, 1), 31)
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month], from: base)
            return Self.safeDay(year: comps.year ?? 0, month: comps.month ?? 1, day: day, calendar: cal) ?? base
        case .custom:
            return rule.startDate
        @unknown default:
            return base
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
            // >>> CHANGE-[2026-08-31 23:29:43]-[周期规则日期显示补齐] 开始
            // 年周期不能丢月份：从 startDate 取月份，如「每年 8 月 31 日」
            let yearMonth = Calendar.current.component(.month, from: rule.startDate)
            return "每年 \(yearMonth) 月 \(rule.dayOfMonth) 日"
            // <<< CHANGE-[2026-08-31 23:29:43]-[周期规则日期显示补齐] 结束
        case .custom:
            return "每 \(rule.customValue ?? 1) \(rule.customUnit.title)"
        @unknown default:
            return "自定义"
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
