// DataDeduplicator.swift
// 数据去重工具：启动时一次性清理重复记录 + 新建前内容级去重。
// 设计原则：不依赖 syncId，按业务键（内容+时间）匹配。
import SwiftData
import Foundation

enum DataDeduplicator {
    /// 清理本地所有 SwiftData 模型中的重复记录。
    /// 按业务键分组：每组保留 syncUpdatedAt 最早的一条（兼顾已有同步数据），
    /// 其余标记 syncDeleted=true（墓碑会通过同步传播到其他设备）。
    /// 用 UserDefaults 标记「已清理过」，避免每次启动都跑；版本号 bump 可强制重新清理一次。
    ///  bumped to v2 (2026-07-29)：修复小程序与 App 跨端同步时因 syncId 不一致导致的重复记录。
    @MainActor
    static func runOnce(context: ModelContext) {
        let key = "aia_dedup_done_v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        var totalDuped = 0

        // 1) Bill：按 merchant + amount(两位小数归并) + time(按分钟) 分组
        if let bills = try? context.fetch(FetchDescriptor<Bill>()) {
            let grouped = Dictionary(grouping: bills) {
                GroupKey.bill(
                    merchant: $0.merchant.lowercased().trimmingCharacters(in: .whitespaces),
                    amount: round($0.amount * 100) / 100,  // 两位小数归并，避免浮点精度问题
                    time: floor($0.time.timeIntervalSince1970 / 60)
                )
            }
            for (_, group) in grouped where group.count > 1 {
                totalDuped += dedupe(group)
            }
        }

        // 2) FoodEntry：按 name + date（天）+ portion 分组
        if let foods = try? context.fetch(FetchDescriptor<FoodEntry>()) {
            let cal = Calendar.current
            let grouped = Dictionary(grouping: foods) {
                let day = cal.startOfDay(for: $0.date)
                return GroupKey.food(
                    name: $0.name.lowercased().trimmingCharacters(in: .whitespaces),
                    day: day,
                    portion: $0.portion.trimmingCharacters(in: .whitespaces)
                )
            }
            for (_, group) in grouped where group.count > 1 {
                totalDuped += dedupe(group)
            }
        }

        // 3) Reminder：按 title + due(按小时) 分组
        if let reminders = try? context.fetch(FetchDescriptor<Reminder>()) {
            let grouped = Dictionary(grouping: reminders) {
                let dueKey = $0.due.map { floor($0.timeIntervalSince1970 / 3600) } ?? 0
                return GroupKey.reminder(
                    title: $0.title.lowercased().trimmingCharacters(in: .whitespaces),
                    dueKey: dueKey
                )
            }
            for (_, group) in grouped where group.count > 1 {
                totalDuped += dedupe(group)
            }
        }

        // 4) HealthMetric：按 metric + value + unit + date(天) 分组
        if let metrics = try? context.fetch(FetchDescriptor<HealthMetric>()) {
            let cal = Calendar.current
            let grouped = Dictionary(grouping: metrics) {
                GroupKey.health(
                    metric: $0.metric.lowercased().trimmingCharacters(in: .whitespaces),
                    value: $0.value.trimmingCharacters(in: .whitespaces),
                    unit: $0.unit.lowercased().trimmingCharacters(in: .whitespaces),
                    day: cal.startOfDay(for: $0.date)
                )
            }
            for (_, group) in grouped where group.count > 1 {
                totalDuped += dedupe(group)
            }
        }

        // 5) RecognitionRecord：按 rawText + 按小时归并
        if let records = try? context.fetch(FetchDescriptor<RecognitionRecord>()) {
            let grouped = Dictionary(grouping: records) {
                GroupKey.recognition(
                    rawText: $0.rawText.trimmingCharacters(in: .whitespaces),
                    hour: floor($0.recognizedAt.timeIntervalSince1970 / 3600)
                )
            }
            for (_, group) in grouped where group.count > 1 {
                totalDuped += dedupe(group)
            }
        }

        if totalDuped > 0 {
            try? context.save()
            print("[DataDeduplicator] 已清理 \(totalDuped) 条重复记录")
        }
    }

    /// 内容级去重：新建前检查是否已存在同内容的记录（24 小时内）。
    /// FoodEntry：同 name + date（天）+ portion → 重复。过滤 syncDeleted：被软删的记录不应再被当作重复。
    @MainActor
    static func isDuplicateFood(name: String, date: Date, portion: String, context: ModelContext) -> Bool {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let normName = name.lowercased().trimmingCharacters(in: .whitespaces)
        let normPortion = portion.trimmingCharacters(in: .whitespaces)
        let existing = (try? context.fetch(FetchDescriptor<FoodEntry>(
            predicate: #Predicate { !$0.syncDeleted && $0.date >= dayStart && $0.date < dayEnd }
        ))) ?? []
        return existing.contains { f in
            f.name.lowercased().trimmingCharacters(in: .whitespaces) == normName &&
            f.portion.trimmingCharacters(in: .whitespaces) == normPortion
        }
    }

    /// Bill：同 merchant + amount → 重复（24 小时内）。过滤 syncDeleted：被软删的记录不应再被当作重复。
    @MainActor
    static func isDuplicateBill(merchant: String, amount: Double, time: Date, context: ModelContext) -> Bool {
        let window = time.addingTimeInterval(-86400) // 以传入时间为准的过去 24 小时
        let normMerchant = merchant.lowercased().trimmingCharacters(in: .whitespaces)
        let roundedAmount = round(amount * 100) / 100
        return ((try? context.fetch(FetchDescriptor<Bill>(
            predicate: #Predicate { !$0.syncDeleted && $0.time >= window && $0.amount >= (roundedAmount - 0.005) && $0.amount <= (roundedAmount + 0.005) }
        ))) ?? []).contains { b in
            b.merchant.lowercased().trimmingCharacters(in: .whitespaces) == normMerchant
        }
    }

    /// Reminder：同 title → 重复（24 小时内）。过滤 syncDeleted：被软删的记录不应再被当作重复。
    @MainActor
    static func isDuplicateReminder(title: String, context: ModelContext) -> Bool {
        let window = Date().addingTimeInterval(-86400)
        let normTitle = title.lowercased().trimmingCharacters(in: .whitespaces)
        let all = (try? context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { !$0.syncDeleted }))) ?? []
        return all.contains { r in
            guard let due = r.due else { return false }
            return due >= window &&
                r.title.lowercased().trimmingCharacters(in: .whitespaces) == normTitle
        }
    }

    // MARK: - Internal

    /// 去重一组相同业务键的记录：syncUpdatedAt 最早 = 主记录，其余标记删除。
    /// 返回清理掉的条数。
    private static func dedupe<T: AnyObject>(_ items: [T]) -> Int where T: AnyObject {
        guard items.count > 1 else { return 0 }
        var sorted = items
        // 按 syncUpdatedAt 排序（nil 的排最后 = 最先删）
        sorted.sort { a, b in
            let t1 = (a as? SyncDeletable)?.syncUpdatedAt ?? .distantPast
            let t2 = (b as? SyncDeletable)?.syncUpdatedAt ?? .distantPast
            return t1 < t2
        }
        // 保留 index=0（最早同步的），清理 index>=1
        var cleaned = 0
        for item in sorted.dropFirst() {
            if var deletable = item as? SyncDeletable {
                deletable.syncDeleted = true
                cleaned += 1
            }
        }
        return cleaned
    }

    // MARK: - GroupKey（分组的不可变键）

    private enum GroupKey: Hashable {
        case bill(merchant: String, amount: Double, time: Double)
        case food(name: String, day: Date, portion: String)
        case reminder(title: String, dueKey: Double)
        case health(metric: String, value: String, unit: String, day: Date)
        case recognition(rawText: String, hour: Double)
    }
}
