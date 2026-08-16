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
//           同步地，外层 RecurringRule 在 v9 新增 syncId/syncUpdatedAt/syncDeleted，
//           v4 必须内嵌一个「v4 时刻的旧 shape」RecurringRule（含周期字段，无 sync 字段），
//           而非引用外层已变异的 RecurringRule。
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

    // v4 时刻的 RecurringRule：含周期字段（cycleRaw/customValue/customUnitRaw），
    // 但尚无 syncId/syncUpdatedAt/syncDeleted（这些是 v9 新增的）。
    // 与 v1/v3 内嵌版类身份不同，确保唯一的 schema checksum。
    @Model final class RecurringRule {
        var merchant: String
        var amount: Double
        var category: String
        var note: String
        var isIncome: Bool
        var dayOfMonth: Int
        var startDate: Date
        var lastGeneratedAt: Date?
        var cycleRaw: String?
        var customValue: Int?
        var customUnitRaw: String?

        init(merchant: String = "", amount: Double = 0, category: String = "",
             note: String = "", isIncome: Bool = false, dayOfMonth: Int = 1,
             startDate: Date = .now, lastGeneratedAt: Date? = nil,
             cycleRaw: String = "monthly", customValue: Int = 1, customUnitRaw: String = "month") {
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
            RecurringRule.self, // SchemaVersion4 内嵌旧版（含周期字段，无 sync）
            MerchantMeta.self
        ]
    }
}

// MARK: - v5.0.0：FoodEntry 新增 weightGram / baseCalories / baseProtein / baseCarbs / baseFat，
//           支持编辑页改重量时自动联动热量与三大营养素。
//           注意：v8 已新增 fiber/sugar/sodium/waterIntake/baseFiber/baseSugar/baseSodium。
//           为保持 v5 checksum 不被新外层 FoodEntry 污染、且不与 v8 重复 checksum，
//           v5 必须内嵌一个「v5 时刻的旧 shape」FoodEntry（仅含 weightGram/base*，无新字段），
//           而不是直接引用外层已变异的 FoodEntry。
enum SchemaVersion5: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(5, 0, 0)

    @Model final class FoodEntry {
        var name: String
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var portion: String
        var meal: String
        var date: Date
        var weightGram: Double?
        var baseCalories: Double?
        var baseProtein: Double?
        var baseCarbs: Double?
        var baseFat: Double?
        var imageName: String?
        var syncId: UUID
        var syncUpdatedAt: Date
        var syncDeleted: Bool

        init(name: String = "", calories: Double = 0, protein: Double = 0, carbs: Double = 0,
             fat: Double = 0, portion: String = "", meal: String = "午餐", date: Date = .now,
             weightGram: Double? = nil,
             baseCalories: Double? = nil, baseProtein: Double? = nil,
             baseCarbs: Double? = nil, baseFat: Double? = nil,
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
            self.weightGram = weightGram
            self.baseCalories = baseCalories
            self.baseProtein = baseProtein
            self.baseCarbs = baseCarbs
            self.baseFat = baseFat
            self.imageName = imageName
            self.syncId = syncId
            self.syncUpdatedAt = syncUpdatedAt
            self.syncDeleted = syncDeleted
        }
    }

    // v5 时刻的 RecurringRule（含周期字段，无 sync 字段），同类嵌入规则参见 v4。
    @Model final class RecurringRule {
        var merchant: String
        var amount: Double
        var category: String
        var note: String
        var isIncome: Bool
        var dayOfMonth: Int
        var startDate: Date
        var lastGeneratedAt: Date?
        var cycleRaw: String?
        var customValue: Int?
        var customUnitRaw: String?
        init(merchant: String = "", amount: Double = 0, category: String = "", note: String = "", isIncome: Bool = false, dayOfMonth: Int = 1, startDate: Date = .now, lastGeneratedAt: Date? = nil, cycleRaw: String = "monthly", customValue: Int = 1, customUnitRaw: String = "month") {
            self.merchant = merchant; self.amount = amount; self.category = category; self.note = note; self.isIncome = isIncome; self.dayOfMonth = min(max(dayOfMonth, 1), 28); self.startDate = startDate; self.lastGeneratedAt = lastGeneratedAt; self.cycleRaw = cycleRaw; self.customValue = max(customValue, 1); self.customUnitRaw = customUnitRaw
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,     // SchemaVersion5 内嵌旧 shape（仅 weightGram/base*，无新字段）
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self, // SchemaVersion5 内嵌旧版（含周期字段，无 sync）
            MerchantMeta.self
        ]
    }
}

// MARK: - v6.0.0：新增 FoodMeta（食物营养本地缓存，纯本地不上云）。
//           本地硬编码 NutritionLibrary 未命中时，走云端查询并沉淀到此表。
//           注意：外层 MerchantMeta 已在 v7 新增 syncId/syncUpdatedAt/syncDeleted，
//           为保持 v6 schema checksum 不变，此处内嵌旧版 MerchantMeta（无 sync 字段）。
//           同样：外层 FoodEntry 在 v8 新增 fiber/sugar/sodium/waterIntake，
//           为防止 v6 引用外层 FoodEntry 造成 checksum 漂移、与 v8 重复，
//           v6 也内嵌 v5 时刻的旧 shape FoodEntry（仅含 weightGram/base*）。
enum SchemaVersion6: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(6, 0, 0)

    @Model final class FoodEntry {
        var name: String
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var portion: String
        var meal: String
        var date: Date
        var weightGram: Double?
        var baseCalories: Double?
        var baseProtein: Double?
        var baseCarbs: Double?
        var baseFat: Double?
        var imageName: String?
        var syncId: UUID
        var syncUpdatedAt: Date
        var syncDeleted: Bool

        init(name: String = "", calories: Double = 0, protein: Double = 0, carbs: Double = 0,
             fat: Double = 0, portion: String = "", meal: String = "午餐", date: Date = .now,
             weightGram: Double? = nil,
             baseCalories: Double? = nil, baseProtein: Double? = nil,
             baseCarbs: Double? = nil, baseFat: Double? = nil,
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
            self.weightGram = weightGram
            self.baseCalories = baseCalories
            self.baseProtein = baseProtein
            self.baseCarbs = baseCarbs
            self.baseFat = baseFat
            self.imageName = imageName
            self.syncId = syncId
            self.syncUpdatedAt = syncUpdatedAt
            self.syncDeleted = syncDeleted
        }
    }

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

    // v6 时刻的 FoodMeta：仅含 kcal/protein/carbs/fat 共 4 营养字段，无 fiber/sugar/sodium。
    // 同样按 v4 嵌入 RecurringRule / v6 嵌入 MerchantMeta 的模式，把当前已变异的
    // 外层 FoodMeta 锁在 v6 checksum 内，避免 v8 升级时 checksum 漂移/重复。
    @Model final class FoodMeta {
        @Attribute(.unique) var name: String
        var displayName: String
        var kcal: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var source: String
        var hitCount: Int
        var lastSeen: Date

        init(name: String, displayName: String? = nil,
             kcal: Double, protein: Double, carbs: Double, fat: Double,
             source: String = "cloud", hitCount: Int = 1, lastSeen: Date = .now) {
            self.name = FoodMeta.normalize(name)
            self.displayName = (displayName ?? name).trimmingCharacters(in: .whitespaces)
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
            self.source = source
            self.hitCount = hitCount
            self.lastSeen = lastSeen
        }

        static func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
        }
    }

    // v6 时刻的 RecurringRule（含周期字段，无 sync 字段）
    @Model final class RecurringRule {
        var merchant: String; var amount: Double; var category: String; var note: String; var isIncome: Bool; var dayOfMonth: Int; var startDate: Date; var lastGeneratedAt: Date?; var cycleRaw: String?; var customValue: Int?; var customUnitRaw: String?
        init(merchant: String = "", amount: Double = 0, category: String = "", note: String = "", isIncome: Bool = false, dayOfMonth: Int = 1, startDate: Date = .now, lastGeneratedAt: Date? = nil, cycleRaw: String = "monthly", customValue: Int = 1, customUnitRaw: String = "month") {
            self.merchant = merchant; self.amount = amount; self.category = category; self.note = note; self.isIncome = isIncome; self.dayOfMonth = min(max(dayOfMonth, 1), 28); self.startDate = startDate; self.lastGeneratedAt = lastGeneratedAt; self.cycleRaw = cycleRaw; self.customValue = max(customValue, 1); self.customUnitRaw = customUnitRaw
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,     // SchemaVersion6 内嵌旧 shape FoodEntry
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self, // SchemaVersion6 内嵌旧版（含周期字段，无 sync）
            MerchantMeta.self,  // 内嵌旧版
            FoodMeta.self       // SchemaVersion6 内嵌旧 shape FoodMeta
        ]
    }
}

// MARK: - v7.0.0：MerchantMeta 新增 syncId / syncUpdatedAt / syncDeleted，支持云端同步。
//           同 v5/v6：内嵌 v5 时刻的旧 shape FoodEntry（仅含 weightGram/base*），
//           避免 v8 升级时外层 FoodEntry 已新增字段导致 checksum 漂移/重复。
enum SchemaVersion7: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(7, 0, 0)

    @Model final class FoodEntry {
        var name: String
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var portion: String
        var meal: String
        var date: Date
        var weightGram: Double?
        var baseCalories: Double?
        var baseProtein: Double?
        var baseCarbs: Double?
        var baseFat: Double?
        var imageName: String?
        var syncId: UUID
        var syncUpdatedAt: Date
        var syncDeleted: Bool

        init(name: String = "", calories: Double = 0, protein: Double = 0, carbs: Double = 0,
             fat: Double = 0, portion: String = "", meal: String = "午餐", date: Date = .now,
             weightGram: Double? = nil,
             baseCalories: Double? = nil, baseProtein: Double? = nil,
             baseCarbs: Double? = nil, baseFat: Double? = nil,
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
            self.weightGram = weightGram
            self.baseCalories = baseCalories
            self.baseProtein = baseProtein
            self.baseCarbs = baseCarbs
            self.baseFat = baseFat
            self.imageName = imageName
            self.syncId = syncId
            self.syncUpdatedAt = syncUpdatedAt
            self.syncDeleted = syncDeleted
        }
    }

    // v7 时刻的 FoodMeta：与 v6 嵌入版同构（仅 4 营养字段），
    // 但用 v7 自己的类身份，区别于 v6 的内嵌类（与 v1/v3 嵌入 RecurringRule 同款技巧）。
    @Model final class FoodMeta {
        @Attribute(.unique) var name: String
        var displayName: String
        var kcal: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var source: String
        var hitCount: Int
        var lastSeen: Date

        init(name: String, displayName: String? = nil,
             kcal: Double, protein: Double, carbs: Double, fat: Double,
             source: String = "cloud", hitCount: Int = 1, lastSeen: Date = .now) {
            self.name = FoodMeta.normalize(name)
            self.displayName = (displayName ?? name).trimmingCharacters(in: .whitespaces)
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
            self.source = source
            self.hitCount = hitCount
            self.lastSeen = lastSeen
        }

        static func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
        }
    }

    // v7 时刻的 RecurringRule（含周期字段，无 sync 字段）
    @Model final class RecurringRule {
        var merchant: String; var amount: Double; var category: String; var note: String; var isIncome: Bool; var dayOfMonth: Int; var startDate: Date; var lastGeneratedAt: Date?; var cycleRaw: String?; var customValue: Int?; var customUnitRaw: String?
        init(merchant: String = "", amount: Double = 0, category: String = "", note: String = "", isIncome: Bool = false, dayOfMonth: Int = 1, startDate: Date = .now, lastGeneratedAt: Date? = nil, cycleRaw: String = "monthly", customValue: Int = 1, customUnitRaw: String = "month") {
            self.merchant = merchant; self.amount = amount; self.category = category; self.note = note; self.isIncome = isIncome; self.dayOfMonth = min(max(dayOfMonth, 1), 28); self.startDate = startDate; self.lastGeneratedAt = lastGeneratedAt; self.cycleRaw = cycleRaw; self.customValue = max(customValue, 1); self.customUnitRaw = customUnitRaw
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,     // SchemaVersion7 内嵌旧 shape FoodEntry
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self, // SchemaVersion7 内嵌旧版（含周期字段，无 sync）
            MerchantMeta.self,  // 外层新版（含 sync 字段）
            FoodMeta.self       // SchemaVersion7 内嵌旧 shape FoodMeta
        ]
    }
}

// MARK: - v8.0.0：FoodEntry 新增 fiber/sugar/sodium/waterIntake 及 baseFiber/baseSugar/baseSodium，
//           支持膳食纤维、糖、钠、饮水量的记录与展示。
//           v5/v6/v7 已各自内嵌旧 shape FoodEntry（仅 weightGram/base*，无新字段），
//           所以 v8 引用外层 FoodEntry 即可——外层已含新字段，与 v5/v6/v7 字段结构不同，
//           不会触发 Duplicate version checksums。
//           同 v4/v5/v6/v7：内嵌旧版 RecurringRule（含周期字段，无 sync），
//           避免 v9 升级时外层 RecurringRule 已新增 sync 字段导致 checksum 漂移。
enum SchemaVersion8: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(8, 0, 0)

    // v8 时刻的 RecurringRule（含周期字段，无 sync 字段）
    @Model final class RecurringRule {
        var merchant: String; var amount: Double; var category: String; var note: String; var isIncome: Bool; var dayOfMonth: Int; var startDate: Date; var lastGeneratedAt: Date?; var cycleRaw: String?; var customValue: Int?; var customUnitRaw: String?
        init(merchant: String = "", amount: Double = 0, category: String = "", note: String = "", isIncome: Bool = false, dayOfMonth: Int = 1, startDate: Date = .now, lastGeneratedAt: Date? = nil, cycleRaw: String = "monthly", customValue: Int = 1, customUnitRaw: String = "month") {
            self.merchant = merchant; self.amount = amount; self.category = category; self.note = note; self.isIncome = isIncome; self.dayOfMonth = min(max(dayOfMonth, 1), 28); self.startDate = startDate; self.lastGeneratedAt = lastGeneratedAt; self.cycleRaw = cycleRaw; self.customValue = max(customValue, 1); self.customUnitRaw = customUnitRaw
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,     // 外层新版 FoodEntry，含 fiber/sugar/sodium/waterIntake/baseFiber/baseSugar/baseSodium
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self, // SchemaVersion8 内嵌旧版（含周期字段，无 sync）
            MerchantMeta.self,
            FoodMeta.self
        ]
    }
}

// MARK: - v9.0.0：RecurringRule 新增 syncId / syncUpdatedAt / syncDeleted，支持云端同步。
//           v4/v5/v6/v7/v8 已各自内嵌旧版 RecurringRule（含周期字段，无 sync），
//           v9 引用外层新版 RecurringRule（含 sync 字段）。
// ⚠️ 注意：之前 v9 引用外层 RecurringRule，v8→v9 lightweight 迁移静默失败，
//    原因可能是 SwiftData 无法匹配 v8 内嵌类(不同 class identity)与 v9 外层类。
//    当前用户已删 App 重装（fresh v9 store），无迁移需要，此问题暂不修复。
//    用户在 2026-07-23 12:00 已删除重装后正常使用。如有老用户升级遇到同样问题，
//    建议方案：删除 App 重新安装（数据在云端，登录后 0.3s 同步即可恢复）。
enum SchemaVersion9: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self, // 外层新版 RecurringRule，含 syncId/syncUpdatedAt/syncDeleted
            MerchantMeta.self,
            FoodMeta.self
        ]
    }
}

// MARK: - v10.0.0：新增 WaterLog 模型（手动饮水记录）。
//            每点 +100ml = 一条 WaterLog，与 FoodEntry.waterIntake 并存：
//            聊天/拍照识别走 FoodEntry.waterIntake，饮食页 tap 加的水走本表。
//            本次仅新增模型、不修改已有 @Model 字段，v9→v10 走 lightweight 即可。
enum SchemaVersion10: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self, // 外层新版
            MerchantMeta.self,
            FoodMeta.self,
            WaterLog.self       // v10 新增
        ]
    }
}

// MARK: - v11.0.0：新增 FoodNote 模型（食物备注/图片附件）。
//            关联 FoodEntry.syncId（1:1），用于编辑食物页的备注栏（文字 + 图片）。
//            本次仅新增模型、不修改已有 @Model 字段，v10→v11 走 lightweight 即可。
//            注意：FoodNote 仅本地存储，不参与云同步；旧库升 v11 后老食物记录
//            没有对应 FoodNote（首次进入编辑页时会懒创建）。
enum SchemaVersion11: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,
            FoodMeta.self,
            WaterLog.self,
            FoodNote.self       // v11 新增
        ]
    }
}

// MARK: - v12.0.0：新增 ReminderNote 模型（待办备注，1:1 关联 Reminder.syncId）。
//            用于编辑待办页的备注栏（文字，不带图片附件，参照 Bill.note 简洁模式）。
//            本次仅新增模型、不修改已有 @Model 字段，v11→v12 走 lightweight（参照 v9→v10
//            加 WaterLog 表已验证可行）。ReminderNote 仅本地存储，不参与云同步。
//            旧库升 v12 后老待办记录没有对应 ReminderNote，首次进入编辑页时懒创建。
enum SchemaVersion12: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(12, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,
            FoodMeta.self,
            WaterLog.self,
            FoodNote.self,
            ReminderNote.self    // v12 新增
        ]
    }
}

// MARK: - v13.0.0：新增 FoodSource 表（饮食记录来源标记，仅本地，不上云）。
//           本次仅新增模型、不修改已有 @Model 字段，v12→v13 走 lightweight（参照 v9→v10 加 WaterLog 表已验证可行）。
//           FoodSource 仅本地存储，不参与云同步；旧库升 v13 后已同步的小程序饮食记录
//           会在下次 pull 新建时自动补建 FoodSource（已存在的本地记录不回溯）。
enum SchemaVersion13: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(13, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,
            FoodMeta.self,
            WaterLog.self,
            FoodNote.self,
            ReminderNote.self,
            FoodSource.self      // v13 新增
        ]
    }
}

// MARK: - v14.0.0：新增 HealthNote 表（健康指标备注，仅本地，不上云）。
//           本次仅新增模型、不修改已有 @Model 字段，v13→v14 走 lightweight。
//           HealthNote 关联 HealthMetric.syncId（1:1），仅本地存储，不参与云同步；
//           原图缩略图直接读取 HealthMetric.imageName。旧库升 v14 后老健康记录没有
//           对应 HealthNote，首次进入编辑页时懒创建。
enum SchemaVersion14: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(14, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,
            FoodMeta.self,
            WaterLog.self,
            FoodNote.self,
            ReminderNote.self,
            FoodSource.self,
            HealthNote.self      // v14 新增
        ]
    }
}

// MARK: - v15.0.0：新增 ImportBatch 表（账单导入批次记录，仅本地，不上云）；
//           Bill 新增可选字段 importBatchId（默认 nil，lightweight 迁移安全）。
//           均为纯新增，v14→v15 走 lightweight（参照 v9→v10 加 WaterLog 表已验证可行）。
enum SchemaVersion15: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(15, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,
            FoodMeta.self,
            WaterLog.self,
            FoodNote.self,
            ReminderNote.self,
            FoodSource.self,
            HealthNote.self,
            ImportBatch.self     // v15 新增
        ]
    }
}

// MARK: - v16.0.0：新增 SleepSession 表（手动睡眠记录，仅本地，不上云）。
//           v15→v16 纯新增表，走 lightweight 迁移自动建表（参照 v9→v10 加 WaterLog 表已验证可行）。
//           此前 SleepSession 漏注册到 v15 的 models，导致 insert 不报错但数据不持久化、
//           杀 App 重开即丢、遮罩时间随系统时间漂（根因）。补注册即可修复。
enum SchemaVersion16: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(16, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,
            FoodMeta.self,
            WaterLog.self,
            FoodNote.self,
            ReminderNote.self,
            FoodSource.self,
            HealthNote.self,
            ImportBatch.self,
            SleepSession.self     // v16 新增
        ]
    }
}

// 版本 17：新增 DailyHealthMetric（每日健康指标快照，替代旧 ManualHealthStore 的 UserDefaults 方案）
enum SchemaVersion17: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(17, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Bill.self,
            Reminder.self,
            FoodEntry.self,
            HealthMetric.self,
            RecognitionRecord.self,
            ChatMessage.self,
            RecurringRule.self,
            MerchantMeta.self,
            FoodMeta.self,
            WaterLog.self,
            FoodNote.self,
            ReminderNote.self,
            FoodSource.self,
            HealthNote.self,
            ImportBatch.self,
            SleepSession.self,
            DailyHealthMetric.self     // v17 新增
        ]
    }
}

// MARK: - 迁移计划：v1 → v3 仅新增 MerchantMeta 表；v3 → v4 为 RecurringRule 新增 3 个字段；
//           v4 → v5 为 FoodEntry 新增 5 个可选字段；v5 → v6 新增 FoodMeta 表；
//           v6 → v7 为 MerchantMeta 新增 3 个 sync 字段；v7 → v8 为 FoodEntry 新增 7 个字段；
//           v8 → v9 为 RecurringRule 新增 3 个 sync 字段；
//           v9 → v10 新增 WaterLog 表；v10 → v11 新增 FoodNote 表；v11 → v12 新增 ReminderNote 表。
//           均为 lightweight。
//           注意：v1 与 v3 之间的中间版本（如 v2）若模型集合与 v1 完全相同，
//           其 schema checksum 会与 v1 重复，导致 SwiftData 报
//           "Duplicate version checksums across stages detected"，故不保留同构中间版本。
enum AIAMigrationPlan: SchemaMigrationPlan {
    static var schemas: [VersionedSchema.Type] { [SchemaVersion1.self, SchemaVersion3.self, SchemaVersion4.self, SchemaVersion5.self, SchemaVersion6.self, SchemaVersion7.self, SchemaVersion8.self, SchemaVersion9.self, SchemaVersion10.self, SchemaVersion11.self, SchemaVersion12.self, SchemaVersion13.self, SchemaVersion14.self, SchemaVersion15.self, SchemaVersion16.self, SchemaVersion17.self] }
    static var stages: [MigrationStage] { [migrateV1toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7, migrateV7toV8, migrateV8toV9, migrateV9toV10, migrateV10toV11, migrateV11toV12, migrateV12toV13, migrateV13toV14, migrateV14toV15, migrateV15toV16, migrateV16toV17] }

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

    static let migrateV7toV8 = MigrationStage.lightweight(
        fromVersion: SchemaVersion7.self,
        toVersion: SchemaVersion8.self
    )

    static let migrateV8toV9 = MigrationStage.lightweight(
        fromVersion: SchemaVersion8.self,
        toVersion: SchemaVersion9.self
    )

    static let migrateV9toV10 = MigrationStage.lightweight(
        fromVersion: SchemaVersion9.self,
        toVersion: SchemaVersion10.self
    )

    static let migrateV10toV11 = MigrationStage.lightweight(
        fromVersion: SchemaVersion10.self,
        toVersion: SchemaVersion11.self
    )

    static let migrateV11toV12 = MigrationStage.lightweight(
        fromVersion: SchemaVersion11.self,
        toVersion: SchemaVersion12.self
    )

    static let migrateV12toV13 = MigrationStage.lightweight(
        fromVersion: SchemaVersion12.self,
        toVersion: SchemaVersion13.self
    )

    static let migrateV13toV14 = MigrationStage.lightweight(
        fromVersion: SchemaVersion13.self,
        toVersion: SchemaVersion14.self
    )

    // v14 → v15：新增 ImportBatch 表（仅本地，不上云，参照 v9→v10 / v13→v14）；Bill 加可选字段 importBatchId（默认 nil，lightweight 安全）。
    // 均为纯新增，lightweight 迁移自动建表 + 填充可选字段默认值。
    static let migrateV14toV15 = MigrationStage.lightweight(
        fromVersion: SchemaVersion14.self,
        toVersion: SchemaVersion15.self
    )

    // v15 → v16：新增 SleepSession 表（纯新增，lightweight 自动建表）。
    static let migrateV15toV16 = MigrationStage.lightweight(
        fromVersion: SchemaVersion15.self,
        toVersion: SchemaVersion16.self
    )

    // v16 → v17：新增 DailyHealthMetric 表（纯新增，lightweight 自动建表）。
    static let migrateV16toV17 = MigrationStage.lightweight(
        fromVersion: SchemaVersion16.self,
        toVersion: SchemaVersion17.self
    )
}
