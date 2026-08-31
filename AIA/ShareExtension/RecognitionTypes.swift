// RecognitionTypes.swift
// 云函数返回的结构化识别结果，与 JSON 字段一一对应。
// ⚠️ 与「主 App / AIA / RecognitionTypes.swift」保持字段完全一致：
//    分享扩展把结果写进 App Group，主 App 打开时按同一套结构 decode，
//    字段不一致会导致 decode 丢数据。扩展版仅保留纯数据结构（不依赖 AppFormat 的日期解析方法）。
// >>> CHANGE-[2026-08-21 10:00:00]-[分享扩展打通] 开始
import Foundation

enum RecognitionSource: String, Sendable, Codable {
    case local
    case cloudText
    case cloud
}

struct RecognitionResult: Codable, Sendable {
    let types: [String]?                // 命中的类型数组：food/bill/todo/health/none；为空/缺失时兼容
    let confidence: Double?
    let bill: BillPayload?              // 兼容旧云函数：单条账单（已废弃，统一改用 bills）
    let bills: [BillPayload]?           // 一图/一消息多账单：每条独立记录标题/日期/时间/金额
    let food: FoodPayload?
    let foods: [FoodPayload]?          // 一句话多条饮食（Siri/聊天本地快析）
    let todo: TodoPayload?
    let todos: [TodoPayload]?          // 一句话多条待办
    let health: HealthPayload?
    let healths: [HealthPayload]?      // 一句话多条健康指标

    /// 显式成员初始化器：所有字段带默认值（types 除外），保证含 foods/todos/healths 的调用点都能编译。
    init(types: [String]?,
         confidence: Double? = nil,
         bill: BillPayload? = nil,
         bills: [BillPayload]? = nil,
         food: FoodPayload? = nil,
         foods: [FoodPayload]? = nil,
         todo: TodoPayload? = nil,
         todos: [TodoPayload]? = nil,
         health: HealthPayload? = nil,
         healths: [HealthPayload]? = nil) {
        self.types = types
        self.confidence = confidence
        self.bill = bill
        self.bills = bills
        self.food = food
        self.foods = foods
        self.todo = todo
        self.todos = todos
        self.health = health
        self.healths = healths
    }
}

struct BillPayload: Codable, Sendable {
    let merchant: String?
    let amount: Double?
    let currency: String?
    let category: String?
    let time: String?                   // ISO8601 字符串
    let note: String?
    let action: String?                 // create（默认）/ update / delete
    let targetTitle: String?            // 用于 update/delete 时匹配目标账单（商户名）

    enum CodingKeys: String, CodingKey {
        case merchant, amount, currency, category, time, note, action, targetTitle
    }
}

struct FoodPayload: Codable, Sendable {
    let name: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    var fiber: Double? = nil
    var sugar: Double? = nil
    var sodium: Double? = nil
    let portion: String?
    let meal: String?           // 餐次：早餐/午餐/晚餐/加餐；文字输入时从用户消息推断
    var date: String? = nil     // 相对日期：如「2026-08-09」(ISO日期)
    let action: String?         // create（默认）/ update / delete
    let targetTitle: String?    // 用于 update/delete 时匹配目标饮食（食物名）
    var weightGram: Double? = nil  // 显式保存克数，避免从 portion 字符串反解失败
}

struct TodoPayload: Codable, Sendable {
    let title: String?
    let due: String?
    let repeatRule: String?             // none/daily/weekly/biweekly/monthly/bimonthly/quarterly/semiannual/yearly
    let priority: String?               // high/medium/low
    let action: String?                 // create（默认）/ update / delete / complete
    let targetTitle: String?            // 用于 update/delete 时匹配目标待办

    // 模型给的字段叫 "repeat"，Swift 里是关键字，用 CodingKeys 改名
    enum CodingKeys: String, CodingKey {
        case title, due, priority, action, targetTitle
        case repeatRule = "repeat"
    }
}

struct HealthPayload: Codable, Sendable {
    let metric: String?
    let value: String?                // 健康指标值：可能是数字（体重）或日期字符串（体检预约）
    let unit: String?
}

extension RecognitionResult {
    /// 统一账单列表：优先用新的 bills 数组；兼容旧云函数返回的单条 bill（包成数组）。
    var billList: [BillPayload] {
        if let arr = bills, !arr.isEmpty { return arr }
        if let single = bill { return [single] }
        return []
    }

    /// 统一食物列表：优先用新的 foods 数组；兼容旧版单条 food。
    var foodList: [FoodPayload] {
        if let arr = foods, !arr.isEmpty { return arr }
        if let single = food { return [single] }
        return []
    }

    /// 统一待办列表：优先用新的 todos 数组；兼容旧版单条 todo。
    var todoList: [TodoPayload] {
        if let arr = todos, !arr.isEmpty { return arr }
        if let single = todo { return [single] }
        return []
    }

    /// 统一健康指标列表：优先用新的 healths 数组；兼容旧版单条 health。
    var healthList: [HealthPayload] {
        if let arr = healths, !arr.isEmpty { return arr }
        if let single = health { return [single] }
        return []
    }
}
// <<< CHANGE-[2026-08-21 10:00:00]-[分享扩展打通] 结束
