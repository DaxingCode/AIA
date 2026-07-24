// Models.swift
// 本地数据库模型（SwiftData）。识别结果确认后，存入对应模型。
import Foundation
import SwiftData

// 识别记录（历史流水）
// 保存每次识别的时间、识别文字、命中类型、本地原图文件名；文字同步云端，图片仅本地。
@Model final class RecognitionRecord {
    var recognizedAt: Date      // 识别时间
    var rawText: String         // 识别出的文字/结构化 JSON（本地+云端同步）
    var types: String           // 逗号分隔的类型，如 "bill,todo"
    var imageName: String?      // 本地原图文件名（仅本地，不上云）

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(recognizedAt: Date = .now, rawText: String, types: [String] = [], imageName: String? = nil,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.recognizedAt = recognizedAt
        self.rawText = rawText
        self.types = types.joined(separator: ",")
        self.imageName = imageName
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }

    var typesArray: [String] {
        types.split(separator: ",").map { String($0) }
    }
}

// 聊天记录（本地 + 云端同步）
@Model final class ChatMessage {
    enum Role: String, Codable { case ai, user }

    var roleRaw: String         // "ai" / "user"，存字符串避免 SwiftData enum 兼容问题
    var text: String            // 消息内容
    var createdAt: Date         // 消息时间，用于排序

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(role: Role, text: String, createdAt: Date = .now,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }

    var role: Role { Role(rawValue: roleRaw) ?? .ai }
}

// 账单
@Model final class Bill {
    var merchant: String        // 商户，如「滴滴出行」
    var amount: Double          // 金额
    var currency: String        // 货币，默认 CNY
    var category: String        // 分类，如 餐饮/交通/购物
    var time: Date              // 消费时间
    var note: String            // 备注
    var confirmed: Bool         // 是否用户已确认
    var isIncome: Bool          // 是否收入（如工资/退款/报销等）

    // 本地识别原图文件名（仅本地存储，不参与云同步）
    var imageName: String?

    // 云同步字段（新增，带默认值：轻量迁移，不会破坏旧库）
    var syncId: UUID            // 全局唯一 id，用于跨设备 upsert
    var syncUpdatedAt: Date     // 最后修改时间，冲突时后写胜出
    var syncDeleted: Bool       // 软删除标记（后续可传播删除）

    init(merchant: String, amount: Double, currency: String = "CNY",
         category: String, time: Date, note: String = "", confirmed: Bool = false,
         isIncome: Bool = false,
         imageName: String? = nil,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.merchant = merchant
        self.amount = amount
        self.currency = currency
        self.category = category
        self.time = time
        self.note = note
        self.confirmed = confirmed
        self.isIncome = isIncome
        self.imageName = imageName
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// 待办提醒
@Model final class Reminder {
    var title: String
    var due: Date?              // 截止时间
    var remindAt: Date?         // 本地通知提醒时间（保留兼容旧数据；新数据优先使用 remindTimes）
    var repeatRule: String      // none / daily / weekly / monthly
    var priority: String        // high / medium / low
    var done: Bool

    // 本地识别原图文件名（仅本地存储，不参与云同步）
    var imageName: String?

    // 新增：最多 3 个通知时间点（绝对时间）。空数组表示不提醒。
    var remindTimes: [Date]

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(title: String, due: Date? = nil, remindAt: Date? = nil, repeatRule: String = "none",
         priority: String = "medium", done: Bool = false,
         imageName: String? = nil,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.title = title
        self.due = due
        self.remindAt = remindAt
        self.repeatRule = repeatRule
        self.priority = priority
        self.done = done
        self.imageName = imageName
        self.remindTimes = remindAt.map { [$0] } ?? []
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// 饮食记录
@Model final class FoodEntry {
    var name: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double            // 膳食纤维（克）
    var sugar: Double            // 糖（克）
    var sodium: Double           // 钠（毫克）
    var waterIntake: Double      // 饮水量（毫升），0 表示未记录
    var portion: String         // 份量显示文本，如「50克」「1碗」
    var meal: String            // 早餐/午餐/晚餐/加餐
    var date: Date

    // 重量与营养基准：用于编辑时按重量自动反算热量/三大营养素。
    // base* 为每100g的含量；weightGram 为实际食用克数。
    // 旧数据或未解析重量时可能为 nil，编辑页会按当前营养做兜底反推。
    var weightGram: Double?
    var baseCalories: Double?
    var baseProtein: Double?
    var baseCarbs: Double?
    var baseFat: Double?
    var baseFiber: Double?       // 每100g膳食纤维
    var baseSugar: Double?       // 每100g糖
    var baseSodium: Double?      // 每100g钠（毫克）

    // 本地识别原图文件名（仅本地存储，不参与云同步）
    var imageName: String?

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(name: String, calories: Double, protein: Double = 0, carbs: Double = 0,
         fat: Double = 0, fiber: Double = 0, sugar: Double = 0, sodium: Double = 0,
         waterIntake: Double = 0,
         portion: String = "", meal: String = "午餐", date: Date = .now,
         weightGram: Double? = nil,
         baseCalories: Double? = nil, baseProtein: Double? = nil,
         baseCarbs: Double? = nil, baseFat: Double? = nil,
         baseFiber: Double? = nil, baseSugar: Double? = nil, baseSodium: Double? = nil,
         imageName: String? = nil,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.name = name
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugar = sugar
        self.sodium = sodium
        self.waterIntake = waterIntake
        self.portion = portion
        self.meal = meal
        self.date = date
        self.weightGram = weightGram
        self.baseCalories = baseCalories
        self.baseProtein = baseProtein
        self.baseCarbs = baseCarbs
        self.baseFat = baseFat
        self.baseFiber = baseFiber
        self.baseSugar = baseSugar
        self.baseSodium = baseSodium
        self.imageName = imageName
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// 健康指标
@Model final class HealthMetric {
    var metric: String          // 体重/身高/心率/BMI/体检预约...
    var value: String           // 指标值：可能是数字（如 68）或日期字符串（如 2026-08-30）
    var unit: String            // kg / cm / bpm / 空
    var date: Date

    // 本地识别原图文件名（仅本地存储，不参与云同步）
    var imageName: String?

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(metric: String, value: String, unit: String, date: Date = .now,
         imageName: String? = nil,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.metric = metric
        self.value = value
        self.unit = unit
        self.date = date
        self.imageName = imageName
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// 商户经验库（本地缓存 + 云端同步）
// 识别账单后把「商户名 → 分类」沉淀下来；用户也可在「记账工具-商户分类规则」里手动维护。
// 下次同类截图/文字记账时本地直接复用分类，减少 AI 调用。merchant 归一化（小写、去空格）后作为唯一键。
@Model final class MerchantMeta {
    @Attribute(.unique) var merchant: String   // 归一化商户名
    var category: String        // 常用分类，如 餐饮/交通/购物
    var isIncome: Bool          // 该商户通常为收入（如工资卡）还是支出
    var hitCount: Int           // 命中次数，用于置信度加权
    var lastSeen: Date

    // 云同步字段（2026-07-22：商户分类规则需跨设备同步）
    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(merchant: String, category: String, isIncome: Bool = false,
         hitCount: Int = 1, lastSeen: Date = .now,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.merchant = merchant
        self.category = category
        self.isIncome = isIncome
        self.hitCount = hitCount
        self.lastSeen = lastSeen
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// 食物营养经验库（本地缓存，纯本地、不上云）
// 本地硬编码 NutritionLibrary 未命中时，走云端查询营养并沉淀到此表；
// 下次同类食物可直接本地命中，减少 AI 调用与费用。name 归一化后作为唯一键。
@Model final class FoodMeta {
    @Attribute(.unique) var name: String   // 归一化食物名（小写、去空格）
    var displayName: String                 // 原始/展示食物名
    var kcal: Double                        // 每100g热量（千卡）
    var protein: Double                     // 每100g蛋白质（克）
    var carbs: Double                       // 每100g碳水（克）
    var fat: Double                         // 每100g脂肪（克）
    var fiber: Double                       // 每100g膳食纤维（克）
    var sugar: Double                       // 每100g糖（克）
    var sodium: Double                      // 每100g钠（毫克）
    var source: String                      // "builtin" / "cloud"
    var hitCount: Int                       // 命中次数
    var lastSeen: Date

    init(name: String, displayName: String? = nil,
         kcal: Double, protein: Double, carbs: Double, fat: Double,
         fiber: Double = 0, sugar: Double = 0, sodium: Double = 0,
         source: String = "cloud", hitCount: Int = 1, lastSeen: Date = .now) {
        self.name = FoodMeta.normalize(name)
        self.displayName = (displayName ?? name).trimmingCharacters(in: .whitespaces)
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugar = sugar
        self.sodium = sodium
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

// 手动饮水记录（独立模型，每点 +100ml = 一条记录）
// 与 FoodEntry.waterIntake 并存：聊天/拍照识别产生的饮水走 FoodEntry.waterIntake 字段；
// 饮食页 tap 加的水走本表，按 selectedDate 聚合。
@Model final class WaterLog {
    var date: Date              // 记录时间（默认 now，用 selectedDate 决定归属哪天）
    var amount: Double          // 饮水量（毫升），常驻 100/250/500

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(date: Date = .now, amount: Double = 100,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.date = date
        self.amount = amount
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// 食物备注（仅本地，不参与云同步）
// 关联 FoodEntry.syncId（1:1）；同一食物记录最多一条备注。
// 字段：备注文字 + 附加图片文件名列表（存于 LocalImageStore，仅本地）。
// 设计取舍：本地优先——饮食是隐私数据，备注里可能有口味/身体反应/禁忌等，
//          暂不上云；后续若需要跨设备同步可补 CloudSync push/pull，无需再改 schema。
@Model final class FoodNote {
    /// 关联 FoodEntry.syncId（1:1）
    var syncId: UUID
    /// 备注文字
    var note: String = ""
    /// 备注图片文件名列表（仅本地，存于 LocalImageStore）
    var imageNames: [String] = []
    /// 最近一次编辑时间
    var updatedAt: Date

    init(syncId: UUID, note: String = "", imageNames: [String] = [], updatedAt: Date = .now) {
        self.syncId = syncId
        self.note = note
        self.imageNames = imageNames
        self.updatedAt = updatedAt
    }
}
