// Models.swift
// 本地数据库模型（SwiftData）。识别结果确认后，存入对应模型。
import Foundation
import SwiftData

// 账单
@Model final class Bill {
    var merchant: String        // 商户，如「滴滴出行」
    var amount: Double          // 金额
    var currency: String        // 货币，默认 CNY
    var category: String        // 分类，如 餐饮/交通/购物
    var time: Date              // 消费时间
    var note: String            // 备注
    var confirmed: Bool         // 是否用户已确认

    // 云同步字段（新增，带默认值：轻量迁移，不会破坏旧库）
    var syncId: UUID            // 全局唯一 id，用于跨设备 upsert
    var syncUpdatedAt: Date     // 最后修改时间，冲突时后写胜出
    var syncDeleted: Bool       // 软删除标记（后续可传播删除）

    init(merchant: String, amount: Double, currency: String = "CNY",
         category: String, time: Date, note: String = "", confirmed: Bool = false,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.merchant = merchant
        self.amount = amount
        self.currency = currency
        self.category = category
        self.time = time
        self.note = note
        self.confirmed = confirmed
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// 待办提醒
@Model final class Reminder {
    var title: String
    var due: Date?              // 截止时间
    var repeatRule: String      // none / daily / weekly / monthly
    var priority: String        // high / medium / low
    var done: Bool

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(title: String, due: Date? = nil, repeatRule: String = "none",
         priority: String = "medium", done: Bool = false,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.title = title
        self.due = due
        self.repeatRule = repeatRule
        self.priority = priority
        self.done = done
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
    var portion: String         // 份量，如「1碗」
    var meal: String            // 早餐/午餐/晚餐/加餐
    var date: Date

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(name: String, calories: Double, protein: Double = 0, carbs: Double = 0,
         fat: Double = 0, portion: String = "", meal: String = "午餐", date: Date = .now,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.name = name
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.portion = portion
        self.meal = meal
        self.date = date
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

    var syncId: UUID
    var syncUpdatedAt: Date
    var syncDeleted: Bool

    init(metric: String, value: String, unit: String, date: Date = .now,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.metric = metric
        self.value = value
        self.unit = unit
        self.date = date
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}
