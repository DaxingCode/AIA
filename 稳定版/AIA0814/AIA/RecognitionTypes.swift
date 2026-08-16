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
    var date: String? = nil     // 相对日期：如「2026-08-09」(ISO日期)；文字输入里含"昨天/前天/M月D日/上周X"时填充，保存时优先用它而非默认今天
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

        // 0) 标准 ISO8601 → 直接解析（带完整时刻 + 时区，如 2026-08-10T04:00:00Z）。
        //    **必须先走这一步**：如果先走「空格分隔本地时间」解析器，
        //    它会无视末尾的 Z，把 UTC 小时当成上海本地小时，导致显示少 8 小时
        //    （如上海 12:00 序列化成的 04:00Z 被错显成 4:00）。
        //    先试带时刻的完整 ISO（含毫秒/时区偏移），再试纯日期（2026-08-10）。
        if let d = AppFormat.iso.date(from: raw)
            ?? AppFormat.isoLocal.date(from: raw)
            ?? AppFormat.isoNoFrac.date(from: raw)
            ?? AppFormat.isoLocalNoFrac.date(from: raw) { return d }
        if let d = AppFormat.isoDate.date(from: raw) { return d }

        // 1) 支付宝/微信标准时间戳：`2026-08-01 10:33:23` / `2026-08-01 10:33` / `2026-8-1 10:33:23`。
        //    默认 ISO8601Formatter 只认 `T` + 时区偏移，空格分隔格式会解析失败，
        //    进而退到 parseRelativeDateTime 把完整时间戳拆碎（状态栏时间 + 顺延年份）。
        if let d = parseSpaceSeparatedTimestamp(raw) { return d }

        // 2) 中文相对日期 / 星期几 / 纯时间 → 倒推为绝对日期
        //    注意：账单绝对日期（如识别出的「2026-08-01」）绝不顺延年份。
        //    allowRollforward=false 保证已过去的月-日按原样返回，不会 +1 年（bug: 2027/8/1）。
        return parseRelativeDateTime(raw, allowRollforward: false)
    }

    /// 解析「空格分隔」的完整时间戳：`yyyy-MM-dd HH:mm:ss` / `yyyy-MM-dd HH:mm` / `yyyy-M-d H:mm[:ss]`。
    /// 兼容 `-` / `/` 分隔符与单/双位数字，返回本地时区绝对日期；失败返回 nil。
    private static func parseSpaceSeparatedTimestamp(_ text: String) -> Date? {
        // 如果串里已经带有时区标记（如 2026-08-10T04:00:00Z / +08:00 / -0500），
        // 说明它是 ISO 格式，应由上方的 AppFormat.iso 解析，不能按上海本地时间硬算。
        let tzMarker = #"([+-]\d{2}:?\d{2}|Z)\s*$"#
        if text.range(of: tzMarker, options: .regularExpression) != nil { return nil }

        let pattern = #"(\d{4})[-/](\d{1,2})[-/](\d{1,2})[\sT](\d{1,2}):(\d{2})(?::(\d{2}))?"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        let seg = String(text[r])
        let nums = seg.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 5 else { return nil }
        let cal = Calendar.current
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? cal.timeZone
        var comps = DateComponents()
        comps.year = nums[0]
        comps.month = nums[1]
        comps.day = nums[2]
        comps.hour = nums[3]
        comps.minute = nums[4]
        comps.second = nums.count > 5 ? nums[5] : 0
        comps.timeZone = tz
        return cal.date(from: comps)
    }

    /// 解析中文相对日期表达式，返回绝对 Date。
    /// 支持格式：
    /// - "昨天 12:58" / "昨天下午3点" / "昨天"          → 昨天
    /// - "前天 15:30" / "前天"                          → 前天
    /// - "大前天"                                       → 大前天
    /// - "今天 09:00" / "今天"                          → 今天
    /// - "星期二 19:09" / "周二 19:09" / "周二"         → 最近的一个周二
    /// - "12:58" / "19:09:30"                           → 今天该时刻（纯时间无日期词）
    private static func parseRelativeDateTime(_ text: String, allowRollforward: Bool = true) -> Date? {
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

        // 显式日期（X月X日 / MM-DD，如「8月7日」「08-02」）优先级最高：
        // 必须在「今天/明天」之前。票面常写「今天 08-02 14:40」，此时 08-02 才是真正日期，
        // 若走「今天」分支会错误地把系统当前日期当成放映日。
        if let md = extractExplicitMonthDay(text, allowRollforward: allowRollforward) {
            targetDate = md
        } else if text.contains("昨天") {
            targetDate = cal.date(byAdding: .day, value: -1, to: now)
        } else if text.contains("前天") && !text.contains("大前") {
            targetDate = cal.date(byAdding: .day, value: -2, to: now)
        } else if text.contains("大前天") {
            targetDate = cal.date(byAdding: .day, value: -3, to: now)
        } else if text.contains("今天") {
            targetDate = now
        } else if text.contains("明天") {
            targetDate = cal.date(byAdding: .day, value: 1, to: now)
        } else if let md = extractMonthDay(text, allowRollforward: allowRollforward) {
            // 无年份的「X月X日 / X月X号」，如「8月7日 9:15-10:30」。
            // 放在「今天/明天」之后、星期几之前，避免普通日期被误当纯时间。
            targetDate = md
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

    /// 提取「显式日期」：优先匹配「MM-DD / M-D」横杠格式（如票面上的「08-02」「8-2」），
    /// 其次匹配「X月X日 / X月X号」。用当前年份补齐。
    /// 区别于 extractMonthDay：本函数也识别横杠格式，且语义优先级更高（见 parseRelativeDateTime 调用处）。
    private static func extractExplicitMonthDay(_ text: String, allowRollforward: Bool = true) -> Date? {
        // 横杠格式：08-02 / 8-2。用前后边界避免误匹配到时间「14:40」或电话。
        if let r = text.range(
            of: #"(?<![0-9０-９])(\d{1,2})[-/](\d{1,2})(?![0-9０-９])"#,
            options: .regularExpression) {
            let seg = String(text[r])
            let nums = seg.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }
            if nums.count >= 2, nums[0] >= 1, nums[0] <= 12, nums[1] >= 1, nums[1] <= 31,
               let d = buildMonthDay(month: nums[0], day: nums[1], allowRollforward: allowRollforward) {
                return d
            }
        }
        return extractMonthDay(text, allowRollforward: allowRollforward)
    }

    /// 用当前年份补齐「月/日」成绝对 Date，过去则顺延下一年（仅当 allowRollforward 为 true）。
    /// allowRollforward=false 用于账单绝对日期：已过去的月-日按原样返回，绝不顺延年份。
    private static func buildMonthDay(month: Int, day: Int, allowRollforward: Bool = true) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? cal.timeZone
        var comps = cal.dateComponents([.year, .month], from: now)
        comps.year = comps.year ?? cal.component(.year, from: now)
        comps.month = month
        comps.day = day
        comps.timeZone = tz
        var cand = cal.date(from: comps)
        // 若拼出的日期已明显早于今天（月份日期在过去），顺延到下一年。
        let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
        if allowRollforward, let c = cand, c < yesterday {
            comps.year = (comps.year ?? 0) + 1
            cand = cal.date(from: comps)
        }
        return cand
    }

    /// 从中文文本中提取「X月X日 / X月X号」形式的绝对日期（无年份，用当前年份补齐）。
    /// 支持「8月7日」「8月7号」「8月7日 9:15-10:30」（只取日期部分）。
    private static func extractMonthDay(_ text: String, allowRollforward: Bool = true) -> Date? {
        guard let r = text.range(of: #"(\d{1,2})月(\d{1,2})[日号]?"#, options: .regularExpression) else { return nil }
        let seg = String(text[r])
        let nums = seg.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        return buildMonthDay(month: nums[0], day: nums[1], allowRollforward: allowRollforward)
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
        let dateKeywords = ["昨天", "前天", "大前天", "今天", "明天", "星期", "周", "月", "号", "日"]
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
