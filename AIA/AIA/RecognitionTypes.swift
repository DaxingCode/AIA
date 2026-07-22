// RecognitionTypes.swift
// 云函数返回的结构化识别结果，与 JSON 字段一一对应。
import Foundation

struct RecognitionResult: Codable, Sendable {
    let types: [String]?                // 命中的类型数组：food/bill/todo/health/none；为空/缺失时兼容
    let confidence: Double?
    let bill: BillPayload?              // 兼容旧云函数：单条账单（已废弃，统一改用 bills）
    let bills: [BillPayload]?           // 一图/一消息多账单：每条独立记录标题/日期/时间/金额
    let food: FoodPayload?
    let todo: TodoPayload?
    let health: HealthPayload?
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
    let portion: String?
    let meal: String?           // 餐次：早餐/午餐/晚餐/加餐；文字输入时从用户消息推断
    let action: String?         // create（默认）/ update / delete
    let targetTitle: String?    // 用于 update/delete 时匹配目标饮食（食物名）
}

struct TodoPayload: Codable, Sendable {
    let title: String?
    let due: String?
    let repeatRule: String?             // none/daily/weekly/monthly
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

// 工具：把模型给的 ISO8601 时间字符串转成 Date
// 注意：iso 为 nil 或解析失败时返回 nil，绝不回退 Date()/当前时刻，
// 否则支付宝截图会错误地记录为截图拍摄时间（如 15:41）而非真实支付时间。
extension RecognitionResult {
    static func date(from iso: String?) -> Date? {
        guard let iso else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    /// 统一账单列表：优先用新的 bills 数组；兼容旧云函数返回的单条 bill（包成数组）。
    /// 这样云端升级前后 App 都能正确读取多/单账单。
    var billList: [BillPayload] {
        if let arr = bills, !arr.isEmpty { return arr }
        if let single = bill { return [single] }
        return []
    }
}
