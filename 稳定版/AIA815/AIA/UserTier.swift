// UserTier.swift
// 识别成本的商业分层：免费版只走本地 + 云端文本模型（不发的图），
// 付费版额外允许视觉模型兜底（发的图，最贵一档）。
//
// ⚠️ 注意：此处的「免费/付费」是 App 的商业订阅档位，与
// 「Apple Developer 付费账号才能用 HealthKit/CloudKit」的 OS 能力限制是两回事——
// 后者决定能否调用系统 API，本档位只决定云端 LLM 怎么花钱。
import Foundation

enum UserTier: String, CaseIterable, Hashable, Identifiable {
    case free
    case paid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "免费版"
        case .paid: return "付费版"
        }
    }

    /// 付费：允许视觉模型兜底（发的图，最贵一档）。免费：禁用，避免图片 token 成本。
    var allowVision: Bool { self == .paid }

    /// 免费用户本地胜出门槛更严：必须「金额 + 已知商户（MerchantMeta 命中）」才算高置信本地赢；
    /// 付费用户宽松：金额存在即本地赢（反正错了还有视觉兜底救）。
    var localWinRequiresKnownMerchant: Bool { self == .free }
}

/// 当前档位的全局读写（持久化到 UserDefaults）。
enum AppUserTier {
    private static let tierKey = "aia.userTier"
    private static let usageMonthKey = "aia.freeUsageMonth"
    private static let usageCountKey = "aia.freeUsageCount"

    /// 免费用户每月云端文本模型（不发的图）调用上限，超额降级本地-only。
    static let freeMonthlyQuota = 50

    static var current: UserTier {
        get { UserDefaults.standard.bool(forKey: tierKey) ? .paid : .free }
        set { UserDefaults.standard.set(newValue == .paid, forKey: tierKey) }
    }

    /// 免费用户消耗一次云端文本额度；付费用户恒返回 true（不限）。
    /// 返回 false 表示已超额，调用方应降级到本地-only，禁止再调云端。
    @discardableResult
    static func consumeCloudTextQuota() -> Bool {
        if current == .paid { return true }
        let month = monthKey()
        let saved = UserDefaults.standard.string(forKey: usageMonthKey) ?? ""
        var count = (saved == month) ? UserDefaults.standard.integer(forKey: usageCountKey) : 0
        guard count < freeMonthlyQuota else { return false }
        count += 1
        UserDefaults.standard.set(month, forKey: usageMonthKey)
        UserDefaults.standard.set(count, forKey: usageCountKey)
        return true
    }

    /// 免费用户本月剩余云端文本额度（付费恒返回 nil，表示不限）。
    static var freeUsageRemaining: Int? {
        if current == .paid { return nil }
        let month = monthKey()
        let saved = UserDefaults.standard.string(forKey: usageMonthKey) ?? ""
        let count = (saved == month) ? UserDefaults.standard.integer(forKey: usageCountKey) : 0
        return max(0, freeMonthlyQuota - count)
    }

    private static func monthKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }
}
