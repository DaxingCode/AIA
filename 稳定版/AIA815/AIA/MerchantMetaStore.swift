// MerchantMetaStore.swift
// 商户经验库（本地缓存）的读写封装：识别账单时沉淀「商户→分类」，
// 后续同类账单/文字记账先查这里，命中即复用分类，减少 AI 调用（DB 优先、AI 兜底）。
import Foundation
import SwiftData

enum MerchantMetaStore {
    /// 归一化商户名：小写、去首尾空格、合并中间空白、去掉常见无意义后缀，
    /// 让「星 巴克」「星巴克(国金店)」等近似写法命中同一缓存。
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let lower = collapsed.lowercased()
        // 去掉常见后缀：括号内容、门店号等
        let cleaned = lower.replacingOccurrences(of: #"\(.*?\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? lower : cleaned
    }

    /// 判断归一化 key 是否像时间/日期串（如 "19:09"、"2026-07-21"、"2026-07-21 19:09:35"）。
    /// 这些不是合法商户名，经验库读写时需拒绝，避免把支付时间污染成商户（v4 防御）。
    private static func isTimeLikeKey(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// 写入/更新一条商户经验（识别账单后自动沉淀）。命中已存在则累加 hitCount 并刷新分类与时间（新识别更可信）。
    static func upsert(merchant raw: String, category: String, isIncome: Bool, in context: ModelContext) {
        let key = normalize(raw)
        guard !key.isEmpty, !category.isEmpty else { return }
        // 防御（v4）：时间串（如"19:09""2026-07-21"）不是合法商户名，绝不写入经验库，
        // 避免用户曾保存错误记录后，后续识别把支付时间误当商户并锁死分类。
        guard !isTimeLikeKey(key) else { return }

        let predicate = #Predicate<MerchantMeta> { $0.merchant == key }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            existing.category = category
            existing.isIncome = isIncome
            existing.hitCount += 1
            existing.lastSeen = .now
            existing.syncUpdatedAt = .now
        } else {
            let meta = MerchantMeta(merchant: key, category: category, isIncome: isIncome)
            context.insert(meta)
        }
        // 交给 SwiftData 自动保存（autosaveEnabled），不显式 save 避免主线程阻塞。
    }

    /// 手动保存/更新一条商户分类规则（来自「记账工具-商户分类规则」页面）。
    /// 与自动 upsert 区别：不修改 hitCount，强制刷新 syncUpdatedAt 以触发云同步。
    static func saveRule(merchant raw: String, category: String, isIncome: Bool, in context: ModelContext) {
        let key = normalize(raw)
        guard !key.isEmpty, !category.isEmpty else { return }
        guard !isTimeLikeKey(key) else { return }

        let predicate = #Predicate<MerchantMeta> { $0.merchant == key }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            existing.category = category
            existing.isIncome = isIncome
            existing.lastSeen = .now
            existing.syncUpdatedAt = .now
        } else {
            let meta = MerchantMeta(merchant: key, category: category, isIncome: isIncome)
            context.insert(meta)
        }
    }

    /// 标记一条规则为待删除（下次云同步时把 deleted=true 传上去，同步完成后再清理本地）。
    static func markDeleted(_ meta: MerchantMeta) {
        meta.syncDeleted = true
        meta.syncUpdatedAt = .now
    }

    /// 查询商户分类。返回 (category, isIncome)。仅在 hitCount 达到一定置信度时对外返回，
    /// 否则调用方应回退 AI。
    static func lookup(_ raw: String, in context: ModelContext) -> (category: String, isIncome: Bool)? {
        let key = normalize(raw)
        guard !key.isEmpty else { return nil }
        // 防御（v4）：时间串 key 不应被查询（理论上调用方已拦截，双保险）。
        guard !isTimeLikeKey(key) else { return nil }
        let predicate = #Predicate<MerchantMeta> { $0.merchant == key && $0.hitCount >= 1 && $0.syncDeleted == false }
        guard let m = try? context.fetch(FetchDescriptor(predicate: predicate)).first else { return nil }
        return (m.category, m.isIncome)
    }
}
