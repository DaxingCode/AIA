// RecurringRule.swift
// 从 RecurringBillManager.swift 抽出周期账单模型与枚举，供 AIAKit 共享（迁移计划引用 RecurringRule.self）。
import Foundation
import SwiftData

// MARK: - 周期类型
/// 周期账单的循环周期。
public enum RecurrenceCycle: String, Codable, CaseIterable, Identifiable {
    case daily     = "daily"
    case weekly    = "weekly"
    case monthly   = "monthly"
    case quarterly = "quarterly"
    case yearly    = "yearly"
    case custom    = "custom"

    public var id: String { rawValue }

    public var title: String {
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
public enum RecurrenceUnit: String, Codable, CaseIterable, Identifiable {
    case day     = "day"
    case week    = "week"
    case month   = "month"
    case quarter = "quarter"
    case year    = "year"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day:     return "天"
        case .week:    return "周"
        case .month:   return "月"
        case .quarter: return "季"
        case .year:    return "年"
        }
    }
}

/// 周期账单规则（本地模型：持有 syncId/syncUpdatedAt/syncDeleted 元数据字段，
/// 但 CloudSyncManager.buildPushItems 未列举本模型，故不会上云；字段仅本地预留）。
@Model public final class RecurringRule {
    public var merchant: String        // 商户，如「链家房租」
    public var amount: Double          // 金额
    public var category: String        // 分类，如 住房/娱乐
    public var note: String            // 备注（生成到账单后带「·自动」后缀）
    public var isIncome: Bool          // 是否收入（如理财利息；默认 false 为支出）
    /// 每月/季/年中的生成日（1...31；若目标月份没有这一天，生成时自动取该月最后一天，避免永不触发）。
    public var dayOfMonth: Int
    /// 规则生效起始日期：首次生成不早于此日。
    public var startDate: Date
    /// 上次已自动生成的账期日期（nil=从未生成）。生成后更新为最近一次生成的账期，用于去重与补生成。
    public var lastGeneratedAt: Date?

    // MARK: 云同步字段（v9 新增；本模型不进 push 列表，仅本地预留，不会上云）
    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    // MARK: 周期相关（v4 新增）
    /// 周期类型：daily/weekly/monthly/quarterly/yearly/custom
    public var cycleRaw: String?
    /// 自定义周期数值（仅 custom 有效，>=1）
    public var customValue: Int?
    /// 自定义周期单位：day/week/month/quarter/year（仅 custom 有效）
    public var customUnitRaw: String?

    /// 周期类型（计算属性，不存盘）。
    public var cycle: RecurrenceCycle {
        get { RecurrenceCycle(rawValue: cycleRaw ?? RecurrenceCycle.monthly.rawValue) ?? .monthly }
        set { cycleRaw = newValue.rawValue }
    }

    /// 自定义周期单位（计算属性，不存盘）。
    public var customUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: customUnitRaw ?? RecurrenceUnit.month.rawValue) ?? .month }
        set { customUnitRaw = newValue.rawValue }
    }

    public init(merchant: String = "", amount: Double = 0, category: String = "",
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
        self.dayOfMonth = min(max(dayOfMonth, 1), 31)
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
