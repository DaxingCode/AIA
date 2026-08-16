// Models.swift
// 本地数据库模型（SwiftData）。识别结果确认后，存入对应模型。
import Foundation
import SwiftData

// 识别记录（历史流水）
// 保存每次识别的时间、识别文字、命中类型、本地原图文件名；文字同步云端，图片仅本地。
@Model public final class RecognitionRecord {
    public var recognizedAt: Date      // 识别时间
    public var rawText: String         // 识别出的文字/结构化 JSON（本地+云端同步）
    public var types: String           // 逗号分隔的类型，如 "bill,todo"
    public var imageName: String?      // 本地原图文件名（仅本地，不上云）

    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(recognizedAt: Date = .now, rawText: String, types: [String] = [], imageName: String? = nil,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.recognizedAt = recognizedAt
        self.rawText = rawText
        self.types = types.joined(separator: ",")
        self.imageName = imageName
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }

    public var typesArray: [String] {
        types.split(separator: ",").map { String($0) }
    }
}

// 聊天记录（本地 + 云端同步）
@Model public final class ChatMessage {
    public enum Role: String, Codable { case ai, user }

    public var roleRaw: String         // "ai" / "user"，存字符串避免 SwiftData enum 兼容问题
    public var text: String            // 消息内容
    public var createdAt: Date         // 消息时间，用于排序

    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(role: Role, text: String, createdAt: Date = .now,
         syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }

    public var role: Role { Role(rawValue: roleRaw) ?? .ai }
}

// 账单
@Model public final class Bill {
    public var merchant: String        // 商户，如「滴滴出行」
    public var amount: Double          // 金额
    public var currency: String        // 货币，默认 CNY
    public var category: String        // 分类，如 餐饮/交通/购物
    public var time: Date              // 消费时间
    public var note: String            // 备注
    public var confirmed: Bool         // 是否用户已确认
    public var isIncome: Bool          // 是否收入（如工资/退款/报销等）

    // 本地识别原图文件名（仅本地存储，不参与云同步）
    public var imageName: String?

    // 导入批次关联（仅本地，不参与云同步）。nil 表示非导入产生的账单。
    public var importBatchId: UUID?

    // 云同步字段（新增，带默认值：轻量迁移，不会破坏旧库）
    public var syncId: UUID            // 全局唯一 id，用于跨设备 upsert
    public var syncUpdatedAt: Date     // 最后修改时间，冲突时后写胜出
    public var syncDeleted: Bool       // 软删除标记（后续可传播删除）

    public init(merchant: String, amount: Double, currency: String = "CNY",
         category: String, time: Date, note: String = "", confirmed: Bool = false,
         isIncome: Bool = false,
         imageName: String? = nil,
         importBatchId: UUID? = nil,
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
        self.importBatchId = importBatchId
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

/// 导入批次：每次用户在「账单导入」点「导入」时生成一条，记录本次导入的来源/文件/时间/条数。
/// 仅本地存储，不参与云同步（与 SleepSession v1 思路一致）。
@Model public final class ImportBatch {
    public var source: String         // "wechat" / "alipay" / "other" / "paste"
    public var fileName: String?      // 导入的文件名（用户回溯用），粘贴场景为 nil
    public var importedAt: Date       // 导入时间
    public var totalCount: Int        // 本次成功导入条数
    public var skippedCount: Int      // 跳过重复条数

    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(source: String, fileName: String? = nil, importedAt: Date = .now,
                totalCount: Int = 0, skippedCount: Int = 0,
                syncId: UUID = UUID(), syncUpdatedAt: Date = .now, syncDeleted: Bool = false) {
        self.source = source
        self.fileName = fileName
        self.importedAt = importedAt
        self.totalCount = totalCount
        self.skippedCount = skippedCount
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}

// 待办提醒
@Model public final class Reminder {
    public var title: String
    public var due: Date?              // 截止时间
    public var remindAt: Date?         // 本地通知提醒时间（保留兼容旧数据；新数据优先使用 remindTimes）
    public var repeatRule: String      // none / daily / weekly / biweekly / monthly / bimonthly / quarterly / semiannual
    public var priority: String        // high / medium / low
    public var done: Bool

    // 本地识别原图文件名（仅本地存储，不参与云同步）
    public var imageName: String?

    // 新增：最多 3 个通知时间点（绝对时间）。空数组表示不提醒。
    public var remindTimes: [Date]

    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(title: String, due: Date? = nil, remindAt: Date? = nil, repeatRule: String = "none",
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
@Model public final class FoodEntry {
    public var name: String
    public var calories: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var fiber: Double            // 膳食纤维（克）
    public var sugar: Double            // 糖（克）
    public var sodium: Double           // 钠（毫克）
    public var waterIntake: Double      // 饮水量（毫升），0 表示未记录
    public var portion: String         // 份量显示文本，如「50克」「1碗」
    public var meal: String            // 早餐/午餐/晚餐/加餐
    public var date: Date

    // 重量与营养基准：用于编辑时按重量自动反算热量/三大营养素。
    // base* 为每100g的含量；weightGram 为实际食用克数。
    // 旧数据或未解析重量时可能为 nil，编辑页会按当前营养做兜底反推。
    public var weightGram: Double?
    public var baseCalories: Double?
    public var baseProtein: Double?
    public var baseCarbs: Double?
    public var baseFat: Double?
    public var baseFiber: Double?       // 每100g膳食纤维
    public var baseSugar: Double?       // 每100g糖
    public var baseSodium: Double?      // 每100g钠（毫克）

    // 本地识别原图文件名（仅本地存储，不参与云同步）
    public var imageName: String?

    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(name: String, calories: Double, protein: Double = 0, carbs: Double = 0,
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
@Model public final class HealthMetric {
    public var metric: String          // 体重/身高/心率/BMI/体检预约...
    public var value: String           // 指标值：可能是数字（如 68）或日期字符串（如 2026-08-30）
    public var unit: String            // kg / cm / bpm / 空
    public var date: Date

    // 本地识别原图文件名（仅本地存储，不参与云同步）
    public var imageName: String?

    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(metric: String, value: String, unit: String, date: Date = .now,
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

    /// 无参构造：主 App 多处用 HealthMetric() 空构造后逐字段赋值，保留兼容。
    public init() {
        self.metric = ""
        self.value = ""
        self.unit = ""
        self.date = .now
        self.imageName = nil
        self.syncId = UUID()
        self.syncUpdatedAt = .now
        self.syncDeleted = false
    }
}

// 商户经验库（本地缓存 + 云端同步）
// 识别账单后把「商户名 → 分类」沉淀下来；用户也可在「记账工具-商户分类规则」里手动维护。
// 下次同类截图/文字记账时本地直接复用分类，减少 AI 调用。merchant 归一化（小写、去空格）后作为唯一键。
@Model public final class MerchantMeta {
    @Attribute(.unique) public var merchant: String   // 归一化商户名
    public var category: String        // 常用分类，如 餐饮/交通/购物
    public var isIncome: Bool          // 该商户通常为收入（如工资卡）还是支出
    public var hitCount: Int           // 命中次数，用于置信度加权
    public var lastSeen: Date

    // 云同步字段（2026-07-22：商户分类规则需跨设备同步）
    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(merchant: String, category: String, isIncome: Bool = false,
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
@Model public final class FoodMeta {
    @Attribute(.unique) public var name: String   // 归一化食物名（小写、去空格）
    public var displayName: String                 // 原始/展示食物名
    public var kcal: Double                        // 每100g热量（千卡）
    public var protein: Double                     // 每100g蛋白质（克）
    public var carbs: Double                       // 每100g碳水（克）
    public var fat: Double                         // 每100g脂肪（克）
    public var fiber: Double                       // 每100g膳食纤维（克）
    public var sugar: Double                       // 每100g糖（克）
    public var sodium: Double                      // 每100g钠（毫克）
    public var source: String                      // "builtin" / "cloud"
    public var hitCount: Int                       // 命中次数
    public var lastSeen: Date

    public init(name: String, displayName: String? = nil,
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

    public static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }
}

// 手动饮水记录（独立模型，每点 +100ml = 一条记录）
// 与 FoodEntry.waterIntake 并存：聊天/拍照识别产生的饮水走 FoodEntry.waterIntake 字段；
// 饮食页 tap 加的水走本表，按 selectedDate 聚合。
@Model public final class WaterLog {
    public var date: Date              // 记录时间（默认 now，用 selectedDate 决定归属哪天）
    public var amount: Double          // 饮水量（毫升），常驻 100/250/500

    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(date: Date = .now, amount: Double = 100,
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
@Model public final class FoodNote {
    /// 关联 FoodEntry.syncId（1:1）
    public var syncId: UUID
    /// 备注文字
    public var note: String
    /// 备注图片文件名列表（仅本地，存于 LocalImageStore）
    public var imageNames: [String]
    /// 最近一次编辑时间
    public var updatedAt: Date

    public init(syncId: UUID, note: String = "", imageNames: [String] = [], updatedAt: Date = Date()) {
        self.syncId = syncId
        self.note = note
        self.imageNames = imageNames
        self.updatedAt = updatedAt
    }
    // 注意：不要给 Date 属性写 `= .now` 作为默认值——SwiftData 宏会把默认值写进
    // `defaultValue: .now`，而该参数是 `Any?` 类型，`.now` 成员访问无法解析会编译失败。
    // 用 `Date()`（构造调用，与 `UUID()` 同理）或依赖自定义 init 的默认即可。
}

// 待办备注（仅本地，不参与云同步）
// 关联 Reminder.syncId（1:1）；同一条待办最多一条备注。
// 字段：备注文字（不带图片附件，参照 Bill.note 简洁模式）。
// 适用场景：用户的待办可能有上下文背景（如「给 XX 打电话前先看 XXX 文档」），
//          标题装不下或易过期，写到备注里随编辑页一起展示更顺手。
// 设计取舍：独立 @Model 而非直接加 `Reminder.note` 字段——参照 FoodNote 风格，
//          仅本地存储（不上云），且不污染 Reminder 的云同步 payload；
//          未来若需要图片附件，扩字段即可，不需要再动 schema。
@Model public final class ReminderNote {
    /// 关联 Reminder.syncId（1:1）
    public var syncId: UUID
    /// 备注文字
    public var note: String
    /// 最近一次编辑时间
    public var updatedAt: Date

    public init(syncId: UUID, note: String = "", updatedAt: Date = Date()) {
        self.syncId = syncId
        self.note = note
        self.updatedAt = updatedAt
    }
}

// 健康指标备注（仅本地，不参与云同步）
// 关联 HealthMetric.syncId（1:1）；同一条健康记录最多一条备注。
// 字段：备注文字。原图缩略图直接读取 HealthMetric.imageName，不重复存储。
// 设计取舍：独立 @Model 而非直接加 `HealthMetric.note` 字段——与 ReminderNote/FoodNote
//          风格一致，仅本地存储（不上云），不污染 HealthMetric 的云同步 payload。
@Model public final class HealthNote {
    /// 关联 HealthMetric.syncId（1:1）
    public var syncId: UUID
    /// 备注文字
    public var note: String
    /// 最近一次编辑时间
    public var updatedAt: Date

    public init(syncId: UUID, note: String = "", updatedAt: Date = Date()) {
        self.syncId = syncId
        self.note = note
        self.updatedAt = updatedAt
    }
}

// MARK: - 饮食记录来源标记（仅本地，不参与云同步）
/// 跨端绑定小程序后，从小程序分区 pull 进来的饮食记录，在此表 1:1 标记 origin="miniprogram"，
/// 供饮食列表/详情显示「好好吃饭小程序」来源。App 本机创建的饮食记录无对应 FoodSource，即不显示来源。
/// 1:1 关联 FoodEntry.syncId。仅本地展示用途，不进入云同步 payload。
@Model public final class FoodSource {
    /// 关联 FoodEntry.syncId（1:1）
    @Attribute(.unique) public var foodSyncId: UUID
    /// 来源标记："miniprogram" = 小程序添加
    public var origin: String

    public init(foodSyncId: UUID, origin: String) {
        self.foodSyncId = foodSyncId
        self.origin = origin
    }

    // MARK: 静态工具

    /// 根据 origin rawValue 返回中文展示标签，未知值返回 nil
    public static func displayLabel(for origin: String) -> String? {
        switch origin {
        case "miniprogram": return "好好吃饭小程序"
        default: return nil
        }
    }

    /// 根据 origin rawValue 返回 SF Symbol 图标名，未知值返回通用图标
    public static func icon(for origin: String) -> String {
        switch origin {
        case "miniprogram": return "fork.knife"
        default: return "doc.text"
        }
    }
}

// MARK: - 识别引擎来源标记（1:1 关联 Bill/Reminder/FoodEntry/HealthMetric.syncId，仅本地展示，不参与云同步）
/// 用于列表/详情显示「免费版AI识别 / Pro版AI识别 / Pro版文字识别」中文标签。
/// recogSourceRaw 存 RecognitionSource.rawValue（local/cloudText/cloud）。
@Model public final class RecogSource {
    /// 关联记录的 syncId（1:1）
    @Attribute(.unique) public var syncId: UUID
    /// 记录种类："bill" / "todo" / "food" / "health"
    public var kind: String
    /// 识别来源 rawValue：local / cloudText / cloud
    public var recogSourceRaw: String

    public init(syncId: UUID, kind: String, recogSourceRaw: String) {
        self.syncId = syncId
        self.kind = kind
        self.recogSourceRaw = recogSourceRaw
    }

    // MARK: 静态工具

    /// 把 RecognitionSource 枚举转成可存的 rawValue 字符串
    public static func raw(from source: RecognitionSource) -> String {
        source.rawValue
    }

    /// 根据 rawValue 返回中文展示标签，未知值返回 nil
    public static func displayLabel(for raw: String) -> String? {
        switch raw {
        case "local": return "免费版AI识别"
        case "cloudText": return "Pro版文字识别"
        case "cloud": return "Pro版AI识别"
        default: return nil
        }
    }
}

// MARK: - 手动睡眠记录（仅本地，不参与云同步）
// 与 WaterLog 同构：带 syncId / syncUpdatedAt / syncDeleted 三件套以支持云端同步（sleep 已上云 type）。
// 归属规则（用户 2026-08-01 定）：按「醒来的那天」归属 = startOfDay(wakeAt)；
// 跨天熟睡算到醒来当天。活跃会话（wakeAt == nil）尚无归属日，按天聚合时不计入，待醒来后并入。
// 「正在睡」判定只看 wakeAt == nil，与归属日解耦，跨天也能正确显示状态。
// 放在 AIAKit（与 Bill/Reminder 等模型同模块），供 AIAMigrationPlan 的 SchemaVersion 引用。
@Model public final class SleepSession {
    /// 入睡时间（归届时按此 Date 的 startOfDay 分日）。
    public var sleepStart: Date
    /// 醒来时间；nil = 仍有一次睡眠未结束（正在睡）。
    public var wakeAt: Date?
    /// 醒来时算好的睡眠总时长（秒）；在睡中为 nil。
    public var durationSeconds: Double?

    // MARK: - sync 三件套
    public var syncId: UUID
    public var syncUpdatedAt: Date
    public var syncDeleted: Bool

    public init(
        sleepStart: Date = .now,
        wakeAt: Date? = nil,
        durationSeconds: Double? = nil,
        syncId: UUID = UUID(),
        syncUpdatedAt: Date = .now,
        syncDeleted: Bool = false
    ) {
        self.sleepStart = sleepStart
        self.wakeAt = wakeAt
        self.durationSeconds = durationSeconds
        self.syncId = syncId
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeleted = syncDeleted
    }
}
