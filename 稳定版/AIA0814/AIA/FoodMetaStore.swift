// FoodMetaStore.swift
// 食物营养本地缓存经验库：NutritionLibrary（硬编码）未命中时，用云端结果沉淀到此。
// 纯本地、不上云，支持按归一化名称 lookup 与 upsert。
import SwiftData
import Foundation

enum FoodMetaStore {
    /// 按食物名查询本地缓存。命中时 hitCount+1、lastSeen 刷新。
    static func lookup(_ name: String, in context: ModelContext) -> FoodMeta? {
        let key = FoodMeta.normalize(name)
        guard !key.isEmpty else { return nil }

        let descriptor = FetchDescriptor<FoodMeta>(
            predicate: #Predicate { $0.name == key }
        )
        guard let meta = (try? context.fetch(descriptor))?.first else { return nil }

        // 命中即刷新统计，靠 autosave 自动持久化
        meta.hitCount += 1
        meta.lastSeen = .now
        return meta
    }

    /// 将云端/用户修正的营养数据写入本地缓存。已存在则覆盖更新。
    /// 写入的是「每100g」基准，便于下次按不同重量自动换算。
    /// fiber/sugar/sodium 传 nil 表示「调用方没有该数据」：更新时保留既有值（不清零），新建时按 0 落库。
    static func upsert(name: String,
                       displayName: String? = nil,
                       kcal: Double,
                       protein: Double,
                       carbs: Double,
                       fat: Double,
                       fiber: Double? = nil,
                       sugar: Double? = nil,
                       sodium: Double? = nil,
                       source: String = "cloud",
                       in context: ModelContext) {
        let key = FoodMeta.normalize(name)
        guard !key.isEmpty else { return }

        if let existing = lookup(name, in: context) {
            existing.displayName = (displayName ?? name).trimmingCharacters(in: .whitespaces)
            existing.kcal = kcal
            existing.protein = protein
            existing.carbs = carbs
            existing.fat = fat
            // nil = 调用方无此数据 → 保留既有值，避免把云端之前补齐的微营养素清零
            if let fiber { existing.fiber = fiber }
            if let sugar { existing.sugar = sugar }
            if let sodium { existing.sodium = sodium }
            existing.source = source
            existing.lastSeen = .now
            // hitCount 已在 lookup 中 +1
        } else {
            let meta = FoodMeta(
                name: name,
                displayName: displayName,
                kcal: kcal,
                protein: protein,
                carbs: carbs,
                fat: fat,
                fiber: fiber ?? 0,
                sugar: sugar ?? 0,
                sodium: sodium ?? 0,
                source: source,
                hitCount: 1,
                lastSeen: .now
            )
            context.insert(meta)
        }
    }

    /// 把「某重量下的总营养」反推成每100g基准后写入缓存。
    static func upsertFromTotal(name: String,
                                displayName: String? = nil,
                                totalKcal: Double,
                                totalProtein: Double,
                                totalCarbs: Double,
                                totalFat: Double,
                                totalFiber: Double? = nil,
                                totalSugar: Double? = nil,
                                totalSodium: Double? = nil,
                                weightGram: Double,
                                source: String = "cloud",
                                in context: ModelContext) {
        let weight = max(weightGram, 1)
        upsert(
            name: name,
            displayName: displayName,
            kcal: totalKcal / weight * 100,
            protein: totalProtein / weight * 100,
            carbs: totalCarbs / weight * 100,
            fat: totalFat / weight * 100,
            fiber: totalFiber.map { $0 / weight * 100 },
            sugar: totalSugar.map { $0 / weight * 100 },
            sodium: totalSodium.map { $0 / weight * 100 },
            source: source,
            in: context
        )
    }

    /// 首启 seed 用：把内置营养表的一行写入本地库（source:"builtin"）。
    /// 若同归一化名已存在（含用户/云端沉淀的 cloud 条目）则跳过，不覆盖既有数据。
    /// 写全 8 字段（区别于 upsert 仅写 4 字段），避免微营养素在 seed 时丢失。
    static func seedIfAbsent(name: String, kcal: Double, protein: Double, carbs: Double,
                             fat: Double, fiber: Double, sugar: Double, sodium: Double,
                             in context: ModelContext) {
        let key = FoodMeta.normalize(name)
        guard !key.isEmpty else { return }
        let descriptor = FetchDescriptor<FoodMeta>(predicate: #Predicate { $0.name == key })
        if (try? context.fetch(descriptor))?.first != nil { return }
        let meta = FoodMeta(name: name, displayName: name, kcal: kcal, protein: protein,
                            carbs: carbs, fat: fat, fiber: fiber, sugar: sugar, sodium: sodium,
                            source: "builtin", hitCount: 0, lastSeen: .distantPast)
        context.insert(meta)
    }

    /// 版本化覆盖式 seed（C2）：扩充/修正权威表后，对内置键统一刷新为最新官方值。
    /// 若该食物已有条目 → 用权威 builtin 值覆盖（刷新被 LLM 估算污染的旧 cloud 值，也同步权威表自身的改进）；
    /// 若不存在 → 新建。只动内置键，云端沉淀的库外长尾食物（无 builtin 对应键）保持不动。
    /// AppDelegate 通过 SEED_VERSION 比较决定是否调用，老用户升级时即可拿到新表。
    static func seedBuiltin(_ entries: [(name: String, kcal: Double, protein: Double, carbs: Double, fat: Double, fiber: Double, sugar: Double, sodium: Double)], in context: ModelContext) {
        for e in entries {
            let key = FoodMeta.normalize(e.name)
            guard !key.isEmpty else { continue }
            if let existing = peek(name: e.name, in: context) {
                existing.displayName = e.name
                existing.kcal = e.kcal
                existing.protein = e.protein
                existing.carbs = e.carbs
                existing.fat = e.fat
                existing.fiber = e.fiber
                existing.sugar = e.sugar
                existing.sodium = e.sodium
                existing.source = "builtin"
                existing.lastSeen = .distantPast
            } else {
                let meta = FoodMeta(name: e.name, displayName: e.name, kcal: e.kcal, protein: e.protein,
                                    carbs: e.carbs, fat: e.fat, fiber: e.fiber, sugar: e.sugar, sodium: e.sodium,
                                    source: "builtin", hitCount: 0, lastSeen: .distantPast)
                context.insert(meta)
            }
        }
        do {
            try context.save()
        } catch {
            print("[FoodMetaStore] seedBuiltin save failed: \(error)")
        }
    }

    /// 样本键完整性检查：某内置键是否已存在于库（source 为 builtin）。
    /// 用于 AppDelegate 在版本号已写但数据缺失时强制重 seed。
    static func hasBuiltinKey(_ name: String, in context: ModelContext) -> Bool {
        peek(name: name, in: context)?.source == "builtin"
    }

    /// 匹配用：按归一化名查询，但**不递增 hitCount**（否则搜索会把内置词顶进「常吃」排序）。
    static func peek(name: String, in context: ModelContext) -> FoodMeta? {
        let key = FoodMeta.normalize(name)
        guard !key.isEmpty else { return nil }
        let descriptor = FetchDescriptor<FoodMeta>(predicate: #Predicate { $0.name == key })
        return (try? context.fetch(descriptor))?.first
    }

    /// 该食物在本地库中是否来自内置权威表。
    /// 用途：命中项的纤维/糖/钠全为 0 时，只有「非 builtin」（即云端沉淀的旧值）才值得回云端重查；
    /// builtin 的 0 是权威表本身的取值（如食用油纤维=0），重查纯属浪费调用。
    static func isBuiltin(name: String, in context: ModelContext) -> Bool {
        peek(name: name, in: context)?.source == "builtin"
    }

    /// 子串扫描用：返回全部归一化名（含 builtin seed 与 cloud 沉淀）。
    static func allNames(in context: ModelContext) -> [String] {
        (try? context.fetch(FetchDescriptor<FoodMeta>()).map { $0.name }) ?? []
    }
}
