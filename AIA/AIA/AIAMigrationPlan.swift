// AIAMigrationPlan.swift
// SwiftData 轻量迁移计划。
//
// 历史背景：早期开发用 `AIA.store.vN` 文件名 + schemaVersion 手动闸门，模型一变就弃用旧文件，
// 导致数据丢失。现在切换到固定文件名 `AIA.store` + 正式迁移计划。
//
// 版本约定：
//   - v1.0.0：对应旧 `AIA.store.v2` 文件创建时的无版本化 schema（SwiftData 默认 tag 为 1.0.0）。
//            模型集合与 v3 的基础 7 模型一致（已含 RecurringRule），旧库即从这里直接升级。
//   - v3.0.0：当前正式版本化 schema，比 v1 多一个 MerchantMeta（商户经验库，本地缓存，不上云）。
//
// 以后改 @Model 字段或新增模型：+1 版本号、加 SchemaVersion、加 Stage，不要改 store 文件名。
// 注意：禁止插入「模型集合与已有版本完全相同」的中间版本——SwiftData 按 schema checksum 匹配，
// 同构版本的 checksum 会重复，导致启动崩溃 "Duplicate version checksums across stages detected"。
// 新版本必须相对上一版有真实模型差异，才能直接连到迁移链。
import SwiftData
import Foundation

// MARK: - v1.0.0：旧无版本化 store 的基线（模型集合与 v2 相同）
enum SchemaVersion1: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(1, 0, 0)

    // v1 时期的 RecurringRule（不含 v4 新增的周期字段），用于生成独立的 schema checksum。
    // 外层 RecurringRule 已包含 v4 字段；若各 VersionedSchema 都引用同一个类，
    // SwiftData 会算出相同 checksum，导致 "Duplicate version checksums detected"。
    @Model final class RecurringRule {
        var merchant: String
        var amount: Double
        var category: String
        var note: String
        var isIncome: Bool
        var dayOfMonth: Int
        var startDate: Date
        var lastGeneratedAt: Date?

        init(merchant: String = "", amount: Double = 0, category: String = "",
             note: String = "", isIncome: Bool = false, dayOfMonth: Int = 1,
             startDate: Date = .now, lastGeneratedAt: Date? = nil) {
            self.merchant = merchant
            self.amount = amount
            self.category = category
            self.note = note
            self.isIncome = isIncome
            self.dayOfMonth = min(max(dayOfMonth, 1), 28)
            self.startDate = startDate
            self.lastGeneratedAt = lastGeneratedAt
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self
        ]
    }
}

// MARK: - v3.0.0：新增 MerchantMeta（商户经验库，本地缓存，不上云）
enum SchemaVersion3: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(3, 0, 0)

    // v3 时期的 RecurringRule（仍不含 v4 周期字段），与 v1 同构但处于不同 schema 版本。
    @Model final class RecurringRule {
        var merchant: String
        var amount: Double
        var category: String
        var note: String
        var isIncome: Bool
        var dayOfMonth: Int
        var startDate: Date
        var lastGeneratedAt: Date?

        init(merchant: String = "", amount: Double = 0, category: String = "",
             note: String = "", isIncome: Bool = false, dayOfMonth: Int = 1,
             startDate: Date = .now, lastGeneratedAt: Date? = nil) {
            self.merchant = merchant
            self.amount = amount
            self.category = category
            self.note = note
            self.isIncome = isIncome
            self.dayOfMonth = min(max(dayOfMonth, 1), 28)
            self.startDate = startDate
            self.lastGeneratedAt = lastGeneratedAt
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self
        ]
    }
}

// MARK: - v4.0.0：RecurringRule 新增 cycleRaw / customValue / customUnitRaw 字段，支持多周期。
//           为了与 v5 的 FoodEntry（新增 weightGram/base* 字段）schema checksum 不同，
//           v4 必须内嵌一个同构旧版 FoodEntry，而不是直接引用外层已变异的 FoodEntry。
enum SchemaVersion4: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(4, 0, 0)

    @Model final class FoodEntry {
        var name: String
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var portion: String
        var meal: String
        var date: Date
        var imageName: String?
        var syncId: UUID
        var syncUpdatedAt: Date
        var syncDeleted: Bool

        init(name: String = "", calories: Double = 0, protein: Double = 0, carbs: Double = 0,
             fat: Double = 0, portion: String = "", meal: String = "午餐", date: Date = .now,
             imageName: String? = nil,
             syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
            self.name = name
            self.calories = calories
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
            self.portion = portion
            self.meal = meal
            self.date = date
            self.imageName = imageName
            self.syncId = syncId
            self.syncUpdatedAt = syncUpdatedAt
            self.syncDeleted = syncDeleted
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,     // SchemaVersion4 内部旧版（不含 weightGram/base*）
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self, // 外层 RecurringRule，含 v4 周期字段
            MerchantMeta.self
        ]
    }
}

// MARK: - v5.0.0：FoodEntry 新增 weightGram / baseCalories / baseProtein / baseCarbs / baseFat，
//           支持编辑页改重量时自动联动热量与三大营养素。
enum SchemaVersion5: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,     // 外层新版 FoodEntry，含 weightGram/base*
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self
        ]
    }
}

// MARK: - v6.0.0：新增 FoodMeta（食物营养本地缓存，纯本地不上云）。
//           本地硬编码 NutritionLibrary 未命中时，走云端查询并沉淀到此表。
//           注意：外层 MerchantMeta 已在 v7 新增 syncId/syncUpdatedAt/syncDeleted，
//           为保持 v6 schema checksum 不变，此处内嵌旧版 MerchantMeta（无 sync 字段）。
enum SchemaVersion6: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(6, 0, 0)

    @Model final class MerchantMeta {
        @Attribute(.unique) var merchant: String
        var category: String
        var isIncome: Bool
        var hitCount: Int
        var lastSeen: Date

        init(merchant: String, category: String, isIncome: Bool = false,
             hitCount: Int = 1, lastSeen: Date = .now) {
            self.merchant = merchant
            self.category = category
            self.isIncome = isIncome
            self.hitCount = hitCount
            self.lastSeen = lastSeen
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,  // 内嵌旧版
            FoodMeta.self
        ]
    }
}

// MARK: - v7.0.0：MerchantMeta 新增 syncId / syncUpdatedAt / syncDeleted，支持云端同步。
enum SchemaVersion7: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,  // 外层新版（含 sync 字段）
            FoodMeta.self
        ]
    }
}

// MARK: - 迁移计划：v1 → v3 仅新增 MerchantMeta 表；v3 → v4 为 RecurringRule 新增 3 个字段；
//           v4 → v5 为 FoodEntry 新增 5 个可选字段；v5 → v6 新增 FoodMeta 表；
//           v6 → v7 为 MerchantMeta 新增 3 个 sync 字段，均为 lightweight。
//           注意：v1 与 v3 之间的中间版本（如 v2）若模型集合与 v1 完全相同，
//           其 schema checksum 会与 v1 重复，导致 SwiftData 报
//           "Duplicate version checksums across stages detected"，故不保留同构中间版本。
enum AIAMigrationPlan: SchemaMigrationPlan {
    static var schemas: [VersionedSchema.Type] { [SchemaVersion1.self, SchemaVersion3.self, SchemaVersion4.self, SchemaVersion5.self, SchemaVersion6.self, SchemaVersion7.self] }
    static var stages: [MigrationStage] { [migrateV1toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7] }

    static let migrateV1toV3 = MigrationStage.lightweight(
        fromVersion: SchemaVersion1.self,
        toVersion: SchemaVersion3.self
    )

    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: SchemaVersion3.self,
        toVersion: SchemaVersion4.self
    )

    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: SchemaVersion4.self,
        toVersion: SchemaVersion5.self
    )

    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: SchemaVersion5.self,
        toVersion: SchemaVersion6.self
    )

    static let migrateV6toV7 = MigrationStage.lightweight(
        fromVersion: SchemaVersion6.self,
        toVersion: SchemaVersion7.self
    )
}
