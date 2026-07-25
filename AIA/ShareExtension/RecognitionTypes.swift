// RecognitionTypes.swift
// 云函数返回的结构化识别结果，与 JSON 字段一一对应。
import Foundation

struct RecognitionResult: Codable, Sendable {
    let types: [String]?                // 命中的类型数组：food/bill/todo/health/none；为空/缺失时兼容
    let confidence: Double?
    let bill: BillPayload?
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
}

struct FoodPayload: Codable, Sendable {
    let name: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let portion: String?
}

struct TodoPayload: Codable, Sendable {
    let title: String?
    let due: String?
    let repeatRule: String?             // none/daily/weekly/monthly
    let priority: String?               // high/medium/low

    // 模型给的字段叫 "repeat"，Swift 里是关键字，用 CodingKeys 改名
    enum CodingKeys: String, CodingKey {
        case title, due, priority
        case repeatRule = "repeat"
    }
}

struct HealthPayload: Codable, Sendable {
    let metric: String?
    let value: String?                // 健康指标值：可能是数字（体重）或日期字符串（体检预约）
    let unit: String?
}

// 工具：把模型给的 ISO8601 时间字符串转成 Date
extension RecognitionResult {
    static func date(from iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter(); f.timeZone = .current; return f.date(from: iso) ?? Date()
    }
}
