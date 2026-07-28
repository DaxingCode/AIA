// RecognitionTypes.swift
// 云函数返回的结构化识别结果，与 JSON 字段一一对应。
import Foundation

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

// 工具：把模型给的时间字符串转成 Date
// 支持三种格式：
//   1. ISO8601（标准，如 "2026-07-22T12:58:00+08:00"）
//   2. 中文相对日期（如 "昨天 12:58"、"星期二 19:09"、"前天 15:30"）→ 以今天倒推绝对日期
//   3. 纯时间（如 "12:58"、"19:09"）→ 当天该时刻
//
// 注意：iso 为 nil 或解析失败时返回 nil，绝不回退 Date()/当前时刻，
// 否则支付宝截图会错误地记录为截图拍摄时间（如 15:41）而非真实支付时间。
extension RecognitionResult {
    static func date(from raw: String?) -> Date? {
        guard let raw = raw, !raw.isEmpty else { return nil }

        // 1) 标准 ISO8601 → 直接解析
        let isoFmt = ISO8601DateFormatter(); isoFmt.timeZone = .current
        if let d = isoFmt.date(from: raw) { return d }

        // 2) 中文相对日期 / 星期几 / 纯时间 → 倒推为绝对日期
        return parseRelativeDateTime(raw)
    }

    /// 解析中文相对日期表达式，返回绝对 Date。
    /// 支持格式：
    /// - "昨天 12:58" / "昨天下午3点" / "昨天"          → 昨天
    /// - "前天 15:30" / "前天"                          → 前天
    /// - "大前天"                                       → 大前天
    /// - "今天 09:00" / "今天"                          → 今天
    /// - "星期二 19:09" / "周二 19:09" / "周二"         → 最近的一个周二
    /// - "12:58" / "19:09:30"                           → 今天该时刻（纯时间无日期词）
    private static func parseRelativeDateTime(_ text: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? cal.timeZone

        // ---- 提取时间分量（HH:MM[:SS] 或 中文时间词）----
        var hour = 0, minute = 0, second = 0
        if let r = text.range(of: #"(\d{1,2}):(\d{2})(?::(\d{2}))?"#, options: .regularExpression) {
            let parts = String(text[r]).components(separatedBy: ":").compactMap { Int($0) }
            hour = parts[0]
            minute = parts.count > 1 ? parts[1] : 0
            second = parts.count > 2 ? parts[2] : 0
        } else if text.contains("中午") { hour = 12; minute = 0 }
        else if text.contains("下午") || text.contains("傍晚") { hour = 18; minute = 0 }
        else if text.contains("晚上") || text.contains("夜间") { hour = 20; minute = 0 }
        else if text.contains("早上") || text.contains("早晨") || text.contains("清晨") { hour = 8; minute = 0 }
        else if text.contains("上午") { hour = 10; minute = 0 }
        // 无时间词且无数字时间 → 默认 00:00（仅取日期）

        // ---- 判断目标日期 ----
        var targetDate: Date?

        if text.contains("昨天") {
            targetDate = cal.date(byAdding: .day, value: -1, to: now)
        } else if text.contains("前天") && !text.contains("大前") {
            targetDate = cal.date(byAdding: .day, value: -2, to: now)
        } else if text.contains("大前天") {
            targetDate = cal.date(byAdding: .day, value: -3, to: now)
        } else if text.contains("今天") {
            targetDate = now
        } else if let wd = extractWeekday(text) {
            // 星期X / 周X → 找最近的一个该星期几
            let todayWd = cal.component(.weekday, from: now)
            var diff = wd - todayWd
            // 如果是今天或未来几天（如今天周四、文字说"周五"），则取上周的
            if diff >= 0 { diff -= 7 }
            targetDate = cal.date(byAdding: .day, value: diff, to: now)
        } else if hasTimeOnly(text) {
            // 纯时间无任何日期关键词（如 "12:58"、"19:09"）→ 默认今天
            targetDate = now
        }

        guard let base = targetDate else { return nil }

        // 在目标日期上设置提取到的时间
        var comps = cal.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        comps.timeZone = tz
        return cal.date(from: comps)
    }

    /// 从中文文本中提取 weekday（1=Sunday ... 7=Saturday）
    private static func extractWeekday(_ text: String) -> Int? {
        let patterns: [(String, Int)] = [
            ("周日", 1), ("星期日", 1), ("星期天", 1),
            ("周一", 2), ("星期一", 2),
            ("周二", 3), ("星期二", 3),
            ("周三", 4), ("星期三", 4),
            ("周四", 5), ("星期四", 5),
            ("周五", 6), ("星期五", 6),
            ("周六", 7), ("星期六", 7),
        ]
        for (pat, val) in patterns {
            if text.contains(pat) { return val }
        }
        return nil
    }

    /// 判断文本是否只含时间不含日期词（用于区分 "19:09" 和 "昨天 19:09"）
    private static func hasTimeOnly(_ text: String) -> Bool {
        let dateKeywords = ["昨天", "前天", "大前天", "今天", "星期", "周", "月", "号", "日"]
        let hasDateKeyword = dateKeywords.contains { text.contains($0) }
        let hasTimePattern = text.range(of: #"(\d{1,2}):(\d{2})"#, options: .regularExpression) != nil
        return hasTimePattern && !hasDateKeyword
    }

    /// 统一账单列表：优先用新的 bills 数组；兼容旧云函数返回的单条 bill（包成数组）。
    /// 这样云端升级前后 App 都能正确读取多/单账单。
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
