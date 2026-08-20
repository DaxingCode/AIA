// RelativeDateParser.swift
// 统一的中文相对日期解析工具：覆盖「昨天/前天/大前天/今天/明天/后天/大后天」
// 「周X/星期X/礼拜X（最近一个，往过去推）」「上周X/上星期X/上礼拜X（往过去推一整周）」
// 「M月D日」，并支持可选带时刻（HH:MM 或 中文点分）。
// 设计目标：聊天饮食、Siri 饮食、账单快析共用同一套口径，避免各入口漂移。
import Foundation

enum RelativeDateParser {
    /// 解析一段中文文本里的相对日期，返回「(目标日期, 是否已指定日期, 是否已指定时刻)」。
    /// 已指定日期（昨天/前天/M月D日/周X/上周X 等）→ hasDate = true。
    /// 仅含餐次/时刻但无日期词 → hasDate = false（调用方按"今天"或餐次兜底）。
    /// 完全无日期信号 → 返回 nil。
    ///
    /// 日期限定在「上海时区」口径，与 AppFormat.iso 序列化端对称，
    /// 避免 Simulator 时区差异导致"昨天"被算成今天。
    static func parse(from text: String) -> (date: Date, hasDate: Bool, hasTime: Bool)? {
        let cal = Calendar.current
        let now = Date()
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? cal.timeZone

        // 先抓时刻分量（与 RecognitionResult.parseRelativeDateTime 同口径）
        let (hour, minute, hasTime) = extractTime(from: text)

        // ---- 目标日期 ----
        var targetDate: Date?

        // 1) 显式 M月D日 / MM-DD（最高优先）
        if let md = extractMonthDay(text) {
            targetDate = md
        }
        // 2) 上周X / 上星期X / 上礼拜X（往过去推一整周，新增盲区修复）
        else if let wd = extractLastWeekWeekday(text) {
            targetDate = dateForWeekday(wd, weeksAgo: 1)
        }
        // 3) 昨天 / 前天 / 大前天
        else if text.contains("大前天") {
            targetDate = cal.date(byAdding: .day, value: -3, to: now)
        } else if text.contains("前天") {   // 「前天」必须在「大前天」之后判断
            targetDate = cal.date(byAdding: .day, value: -2, to: now)
        } else if text.contains("昨天") || text.contains("昨日") {
            targetDate = cal.date(byAdding: .day, value: -1, to: now)
        }
        // 4) 明天 / 后天 / 大后天
        else if text.contains("大后天") {
            targetDate = cal.date(byAdding: .day, value: 3, to: now)
        } else if text.contains("后天") {
            targetDate = cal.date(byAdding: .day, value: 2, to: now)
        } else if text.contains("明天") || text.contains("明日") {
            targetDate = cal.date(byAdding: .day, value: 1, to: now)
        }
        // 5) 今天（显式说"今天/今日"也视为已指定，不回退餐次）
        else if text.contains("今天") || text.contains("今日") {
            targetDate = now
        }
        // 6) 周X / 星期X / 礼拜X（找最近一个已过去的该星期几，用于饮食回溯）
        else if let wd = extractWeekday(text) {
            targetDate = dateForWeekday(wd, weeksAgo: 0)
        }

        guard let base = targetDate else {
            // 没有任何日期词：返回 nil（调用方按"今天"处理）
            return nil
        }

        var comps = cal.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.timeZone = tz
        guard let result = cal.date(from: comps) else { return nil }
        return (date: result, hasDate: true, hasTime: hasTime)
    }

    /// 直接返回 Date（未指定日期时回退 today）。饮食新建默认就是今天，符合老行为。
    static func dateOrToday(from text: String) -> Date {
        parse(from: text)?.date ?? Date()
    }

    /// 返回完整日期时间，并告知调用方用户是否真的说了具体时刻。
    /// 已解析到日期/时刻（昨天/前天/M月D日/下午3点…）→ 原样返回，保留餐次整点等老行为。
    /// 完全无日期信号（也没说餐次）→ 回退「当前这一刻」并 hasTime = true，
    /// 让上游序列化成带完整时刻的串（如 2026-08-11T11:23:00+08:00），
    /// 下游 RecognitionSaver 直接保留该时刻，不再套「午餐12:00」这类标准钟点
    /// （用户 2026-08-11 拍板：没说时间就记当前时刻，餐次标签仍按当前小时自动猜）。
    static func dateTimeOrToday(from text: String) -> (date: Date, hasTime: Bool) {
        if let r = parse(from: text) {
            return (r.date, r.hasTime)
        }
        return (Date(), true)
    }

    // MARK: - 内部工具

    /// 提取时刻分量：优先 HH:MM[:SS]，其次中文点分（下午3点 → 15:00 / 晚上8点半 → 20:30）。
    /// 返回值 hasTime：只有真正提取到数字时刻时才为 true；仅时段词兜底为 false。
    private static func extractTime(from text: String) -> (hour: Int, minute: Int, hasTime: Bool) {
        if let r = text.range(of: #"(\d{1,2}):(\d{2})(?::(\d{2}))?"#, options: .regularExpression) {
            let parts = String(text[r]).components(separatedBy: ":").compactMap { Int($0) }
            return (parts[0], parts.count > 1 ? parts[1] : 0, true)
        }
        // 中文点分：捕获「(上午/下午/晚上/早上/中午/清晨)?(数字)点(数字分)?(半)?」
        // 例：下午3点 / 晚上8点半 / 早上9点30 / 中午12点
        let lower = text.lowercased()
        // 先尝试「X点Y分」/「X点半」/「X点」
        if let r = lower.range(of: #"(\d{1,2})点(?:(\d{1,2})分|半)?"#, options: .regularExpression) {
            let seg = String(lower[r])
            let nums = seg.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            guard let h = nums.first else { return (0, 0, false) }
            var hour = h
            var minute = 0
            if seg.contains("半") { minute = 30 }
            else if nums.count > 1 { minute = nums[1] }
            // 下午/傍晚/晚上/夜间 且小时<12 → +12
            if (lower.contains("下午") || lower.contains("傍晚") || lower.contains("晚上") || lower.contains("夜间")), hour < 12 {
                hour += 12
            }
            return (hour, minute, true)
        }
        // 无具体点分，仅时段词 → 兜底时刻，但 hasTime=false
        if lower.contains("中午") { return (12, 0, false) }
        if lower.contains("下午") || lower.contains("傍晚") { return (18, 0, false) }
        if lower.contains("晚上") || lower.contains("夜间") { return (20, 0, false) }
        if lower.contains("早上") || lower.contains("早晨") || lower.contains("清晨") { return (8, 0, false) }
        if lower.contains("上午") { return (10, 0, false) }
        return (0, 0, false)
    }

    /// 提取「上周X / 上星期X / 上礼拜X」的星期值（1=周日...7=周六）。
    private static func extractLastWeekWeekday(_ text: String) -> Int? {
        let lower = text.lowercased()
        guard lower.contains("上周") || lower.contains("上星期") || lower.contains("上礼拜") else { return nil }
        let patterns: [(String, Int)] = [
            ("周日", 1), ("星期日", 1), ("星期天", 1), ("日", 1),
            ("周一", 2), ("星期一", 2), ("一", 2),
            ("周二", 3), ("星期二", 3), ("二", 3),
            ("周三", 4), ("星期三", 4), ("三", 4),
            ("周四", 5), ("星期四", 5), ("四", 5),
            ("周五", 6), ("星期五", 6), ("五", 6),
            ("周六", 7), ("星期六", 7), ("六", 7),
        ]
        // 找带「上周/上星期/上礼拜」前缀的星期词
        for (pat, val) in patterns {
            let full = ["上周", "上星期", "上礼拜"].map { $0 + pat }
            if full.contains(where: { lower.contains($0) }) { return val }
        }
        return nil
    }

    /// 提取「周X / 星期X / 礼拜X」的星期值（不含「上周」前缀）。
    /// 注意：绝不能用单字「一/二/三/四/五/六/日」做 contains 匹配，
    /// 否则「一个苹果」「二手书店」「三明治」等日常词会被误当成星期几（2026-08-11 修）。
    private static func extractWeekday(_ text: String) -> Int? {
        let lower = text.lowercased()
        // 先排除已被「上周」前缀消耗的
        guard !lower.contains("上周") && !lower.contains("上星期") && !lower.contains("上礼拜") else { return nil }
        let patterns: [(String, Int)] = [
            ("周日", 1), ("星期日", 1), ("星期天", 1),
            ("周一", 2), ("星期一", 2), ("礼拜一", 2),
            ("周二", 3), ("星期二", 3), ("礼拜二", 3),
            ("周三", 4), ("星期三", 4), ("礼拜三", 4),
            ("周四", 5), ("星期四", 5), ("礼拜四", 5),
            ("周五", 6), ("星期五", 6), ("礼拜五", 6),
            ("周六", 7), ("星期六", 7), ("礼拜六", 7),
        ]
        for (pat, val) in patterns {
            if lower.contains(pat) { return val }
        }
        return nil
    }

    /// 计算「最近一个（含今天）指定 weekday」的绝对日期；weeksAgo=1 表示再往过去退一整周。
    /// 饮食回溯语义：优先取「已过去的」该星期几，若今天就是该星期且 weeksAgo=0 则取今天。
    private static func dateForWeekday(_ wd: Int, weeksAgo: Int) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? cal.timeZone
        let todayWd = cal.component(.weekday, from: now)
        // weeksAgo=0：找「最近一个已过去的该星期几」（含今天）→ 已发生
        // weeksAgo=1：在 weeksAgo=0 结果基础上再减 7 天（上周同期）
        var diff = wd - todayWd
        if diff >= 0 { diff -= 7 }          // 今天或未来 → 取上一周该星期
        diff -= 7 * weeksAgo
        guard let base = cal.date(byAdding: .day, value: diff, to: now) else { return nil }
        var comps = cal.dateComponents([.year, .month, .day], from: base)
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = tz
        return cal.date(from: comps)
    }

    /// 提取 M月D日 / MM-DD / M月D号 为绝对日期（用当前年份补齐，过去则顺延下一年）。
    private static func extractMonthDay(_ text: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? cal.timeZone

        // 优先 MM-DD / M-D（前后边界防误匹配时间/电话）
        if let r = text.range(
            of: #"(?<![0-9０-９])(\d{1,2})[-/](\d{1,2})(?![0-9０-９])"#,
            options: .regularExpression) {
            let seg = String(text[r])
            let nums = seg.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }
            if nums.count >= 2, nums[0] >= 1, nums[0] <= 12, nums[1] >= 1, nums[1] <= 31,
               let d = buildMonthDay(month: nums[0], day: nums[1]) {
                return d
            }
        }
        // 其次 M月D日 / M月D号
        guard let r = text.range(of: #"(\d{1,2})月(\d{1,2})[日号]?"#, options: .regularExpression) else { return nil }
        let seg = String(text[r])
        let nums = seg.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        return buildMonthDay(month: nums[0], day: nums[1])
    }

    private static func buildMonthDay(month: Int, day: Int) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? cal.timeZone
        var comps = cal.dateComponents([.year, .month], from: now)
        comps.month = month
        comps.day = day
        comps.timeZone = tz
        var cand = cal.date(from: comps)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
        if let c = cand, c < yesterday {
            comps.year = (comps.year ?? 0) + 1
            cand = cal.date(from: comps)
        }
        return cand
    }

    // >>> CHANGE-[2026-08-20 15:30:00]-[小记查询跳转按钮] 开始
    // 原因：小记账单查询需支持"最近N天/本周/上周/这个月"等区间表达，复用本解析器口径。
    //       返回 [start, end) 半开区间（end 为次日 00:00），与账单按 time 过滤一致。
    // 回退：删除本方法即可（ChatView 内账单分支会回退到单日/最近7天兜底）。
    /// 解析中文相对日期"区间"，返回 (start, end)。不支持时返回 nil。
    /// 支持：最近N天 / 最近一周 / 本周 / 上周 / 这个月 / 本月 / 当月。
    static func parseRange(from text: String) -> (start: Date, end: Date)? {
        let cal = Calendar.current
        let now = Date()
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? cal.timeZone
        let lower = text.lowercased()

        // 这个月 / 本月 / 当月：自然月 [月初, 下月初)
        if lower.contains("本月") || lower.contains("这个月") || lower.contains("当月") {
            var comps = cal.dateComponents([.year, .month], from: now)
            comps.timeZone = tz
            guard let start = cal.date(from: comps),
                  let end = cal.date(byAdding: .month, value: 1, to: start) else { return nil }
            return (start, end)
        }

        // 本周 / 上周：以周一为一周起点
        if lower.contains("本周") || lower.contains("这周") || lower.contains("上周") {
            let weeksAgo = lower.contains("上周") ? 1 : 0
            var weekday = cal.component(.weekday, from: now) // 1=周日
            let mondayOffset = (weekday + 5) % 7 // 距本周一的天数（周日→6，周一→0）
            guard let thisMonday = cal.date(byAdding: .day, value: -mondayOffset, to: cal.startOfDay(for: now)),
                  let start = cal.date(byAdding: .day, value: -7 * weeksAgo, to: thisMonday),
                  let end = cal.date(byAdding: .day, value: 7, to: start) else { return nil }
            return (start, end)
        }

        // 最近N天 / 最近一周：抓数字
        if let r = lower.range(of: #"最近\s*(\d+)\s*天"#, options: .regularExpression) {
            let seg = String(lower[r])
            if let nStr = seg.range(of: #"\d+"#, options: .regularExpression),
               let n = Int(String(seg[nStr])) {
                let start = cal.date(byAdding: .day, value: -(n - 1), to: cal.startOfDay(for: now))!
                let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
                return (start, end)
            }
        }
        if lower.contains("最近一周") {
            let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            return (start, end)
        }

        return nil
    }
    // <<< CHANGE-[2026-08-20 15:30:00]-[小记查询跳转按钮] 结束
}
