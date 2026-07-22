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
    static func upsert(name: String,
                       displayName: String? = nil,
                       kcal: Double,
                       protein: Double,
                       carbs: Double,
                       fat: Double,
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
            source: source,
            in: context
        )
    }
}
