import Foundation
import SwiftData

/// 本地快速解析：对 Siri / 语音里常见的「单意图短指令」做纯本地、零网络的毫秒级解析，
/// 跳过云端 LLM 往返（消除冷启动 + LLM 推理延迟）。
///
/// 只有本地能**干净识别**时才返回非 nil；任何不确定 / 命中不了本地营养库 / 多意图含糊句，
/// 一律返回 nil，交由调用方走云端 `parseText` 兜底。绝不对拿不准的内容瞎记。
enum LocalQuickParse {

    /// 尝试本地解析一句话。返回非 nil 表示本地已搞定，可直接入库。
    /// - Parameter context: 主容器 context，用于查询云端经验库 `FoodMetaStore`（本地 SQLite，非网络）。
    static func parse(_ text: String, in context: ModelContext) -> RecognitionResult? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // 优先级：账单（消费/餐次 + 金额）> 食物（进食动词 + 本地库命中）> 待办（提醒词 + 可提取标题）
        if let r = parseBill(t) { return r }
        if let r = parseFood(t, in: context) { return r }
        if let r = parseTodo(t) { return r }
        return nil
    }

    // MARK: - 账单

    private static let spendKeywords = ["花了","花掉","花去","付了","付掉","支付了","支出","消费",
                                        "买","用了","用掉","开销","花费","付款","扫码","结账","充值","缴纳","交了","缴了"]
    private static let incomeKeywords = ["工资","收入","报销","退款","返现","奖金","收到","收益","进账","分红","津贴","补贴","利息"]
    private static let mealWords = ["午饭","午餐","早饭","早餐","晚饭","晚餐","夜宵","加餐"]

    private static func parseBill(_ t: String) -> RecognitionResult? {
        let hasSpend = spendKeywords.contains { t.contains($0) }
        let hasIncome = incomeKeywords.contains { t.contains($0) }
        let hasMeal = mealWords.contains { t.contains($0) }
        guard hasSpend || hasIncome || hasMeal else { return nil }

        guard let amount = firstAmount(in: t) else { return nil }

        let category: String
        let isIncome: Bool
        if hasIncome {
            isIncome = true
            category = "工资"
        } else {
            isIncome = false
            category = inferBillCategory(t)
        }
        _ = isIncome // autoSave 按 category 推断 isIncome，这里不另用

        let payload = BillPayload(merchant: nil, amount: amount, currency: "CNY",
                                  category: category, time: todayISO(), note: nil,
                                  action: "create", targetTitle: nil)
        return RecognitionResult(types: ["bill"], confidence: 1.0,
                                 bill: nil, bills: [payload],
                                 food: nil, todo: nil, health: nil)
    }

    private static func inferBillCategory(_ t: String) -> String {
        if t.contains("打车") || t.contains("滴滴") || t.contains("地铁") || t.contains("公交")
            || t.contains("加油") || t.contains("停车") || t.contains("高铁") || t.contains("火车")
            || t.contains("机票") || t.contains("打车费") || t.contains("出租车") {
            return "交通"
        }
        if t.contains("超市") || t.contains("买菜") || t.contains("购物") || t.contains("网购")
            || t.contains("淘宝") || t.contains("京东") || t.contains("拼多多") || t.contains("便利店") {
            return "购物"
        }
        if t.contains("电影") || t.contains("娱乐") || t.contains("游戏") || t.contains("会员")
            || t.contains("KTV") || t.contains("演出") {
            return "娱乐"
        }
        if t.contains("水电") || t.contains("物业") || t.contains("话费") || t.contains("房租") || t.contains("燃气") || t.contains("宽带") {
            return "居住"
        }
        if t.contains("午饭") || t.contains("午餐") || t.contains("早饭") || t.contains("早餐")
            || t.contains("晚饭") || t.contains("晚餐") || t.contains("夜宵") || t.contains("吃了")
            || t.contains("喝") || t.contains("餐") || t.contains("饭") || t.contains("奶茶") || t.contains("咖啡") {
            return "餐饮"
        }
        return "" // autoSave 会用 "账单" 兜底 merchant
    }

    // MARK: - 食物

    private static let eatVerbs = ["吃了","喝了","来份","点了个","点了","来一个","啃了","尝了","吃","喝"]

    private static func parseFood(_ t: String, in context: ModelContext) -> RecognitionResult? {
        let hasEat = eatVerbs.contains { t.contains($0) }
        guard hasEat else { return nil }

        guard let foodName = extractFoodName(t) else { return nil }
        // 统一查询路径：NutritionLibrary.match 保留别名/子串/调料护栏智能，
        // 最终从 FoodMetaStore（含内置 seed + 云端沉淀）取数。无匹配才交云端。
        guard let ref = NutritionLibrary.shared.match(foodName, in: context) else { return nil }

        let portion = extractGramPortion(t) ?? "100克"
        let payload = FoodPayload(name: ref.name, calories: ref.kcal, protein: ref.protein,
                                  carbs: ref.carbs, fat: ref.fat, fiber: ref.fiber, sugar: ref.sugar,
                                  sodium: ref.sodium, portion: portion, meal: nil,
                                  action: "create", targetTitle: nil)
        return RecognitionResult(types: ["food"], confidence: 1.0,
                                 bill: nil, bills: nil, food: payload, todo: nil, health: nil)
    }

    private static func extractFoodName(_ t: String) -> String? {
        var rest = t
        for v in ["吃了","喝了","来份","点了个","点了","来一个","啃了","尝了"] {
            if let r = t.range(of: v) {
                rest = String(t[r.upperBound...])
                break
            }
        }
        if rest == t {
            for v in ["吃","喝"] {
                if let r = t.range(of: v) {
                    rest = String(t[r.upperBound...])
                    break
                }
            }
        }
        // 去掉数字、量词、标点、语气词，保留食物名主体
        let cleaned = rest
            .replacingOccurrences(of: #"[\d]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[克g个碗份片根杯块只串两半元块钱￥¥，,。.、：:（）()的的和与及了啦啊呢哦吗哟]"#,
                                  with: "", options: .regularExpression)
        let name = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return String(name.prefix(10))
    }

    /// 仅当用户明确说“X克/g”时才用该数字作克数；其它单位（碗/个/份）返回 nil，
    /// 让 autoSave 用默认 100 克（避免 “1碗” 被误当成 1 克导致营养全 0）。
    private static func extractGramPortion(_ t: String) -> String? {
        guard let r = t.range(of: #"(\d+(?:\.\d+)?)\s*(?:克|g|G|克重)"#, options: .regularExpression) else { return nil }
        let nums = extractInts(String(t[r]))
        guard let n = nums.first else { return nil }
        return "\(n)克"
    }

    // MARK: - 待办

    private static let todoKeywords = ["提醒我","提醒","待办","记一下","记得","别忘","别忘了","备忘","任务",
                                       "设置一个提醒","设置一个","帮我记","帮我设置一个","交报表"]

    private static func parseTodo(_ t: String) -> RecognitionResult? {
        let hasTodo = todoKeywords.contains { t.contains($0) }
        guard hasTodo else { return nil }

        let due = extractDueDate(t)
        var title = t
        for kw in ["提醒我","提醒","待办","记一下","记得","别忘","别忘了","备忘","任务",
                   "设置一个提醒","设置一个","帮我记","帮我设置一个"] {
            title = title.replacingOccurrences(of: kw, with: "")
        }
        title = stripDateWords(title)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.：:、"))
        guard title.count >= 2 else { return nil }

        let payload = TodoPayload(title: title,
                                  due: due.map { isoString(from: $0) },
                                  repeatRule: "none", priority: "normal",
                                  action: "create", targetTitle: nil)
        return RecognitionResult(types: ["todo"], confidence: 1.0,
                                 bill: nil, bills: nil, food: nil, todo: payload, health: nil)
    }

    private static func extractDueDate(_ t: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        var base: Date?

        if t.contains("大后天") {
            base = cal.date(byAdding: .day, value: 3, to: now)
        } else if t.contains("后天") {
            base = cal.date(byAdding: .day, value: 2, to: now)
        } else if t.contains("明天") {
            base = cal.date(byAdding: .day, value: 1, to: now)
        } else if t.contains("今天") {
            base = now
        } else if let r = t.range(of: #"(\d{1,2})月(\d{1,2})[日号]"#, options: .regularExpression) {
            let nums = extractInts(String(t[r]))
            if nums.count == 2 { base = makeDate(month: nums[0], day: nums[1]) }
        } else if let r = t.range(of: #"(\d{1,2})[日号]"#, options: .regularExpression) {
            if let d = extractInts(String(t[r])).first {
                var comps = cal.dateComponents([.year, .month], from: now)
                comps.day = d
                if var cand = cal.date(from: comps), cand < now {
                    cand = cal.date(byAdding: .month, value: 1, to: cand) ?? cand
                }
                base = cal.date(from: comps)
            }
        } else if let wd = weekdayIn(t) {
            let todayWd = cal.component(.weekday, from: now)
            var diff = wd - todayWd
            if diff < 0 { diff += 7 }
            base = cal.date(byAdding: .day, value: diff, to: now)
        }

        // 时间点
        var hour = 8, minute = 0
        var hasTime = false
        if let r = t.range(of: #"(\d{1,2}):(\d{2})"#, options: .regularExpression) {
            let p = extractInts(String(t[r]))
            if p.count >= 2 { hour = p[0]; minute = p[1]; hasTime = true }
        } else if let r = t.range(of: #"下午(\d{1,2})"#, options: .regularExpression) {
            if let h = extractInts(String(t[r])).first { hour = h + 12; minute = 0; hasTime = true }
        } else if let r = t.range(of: #"上午(\d{1,2})"#, options: .regularExpression) {
            if let h = extractInts(String(t[r])).first { hour = h; minute = 0; hasTime = true }
        } else if let r = t.range(of: #"(\d{1,2})点"#, options: .regularExpression) {
            if let h = extractInts(String(t[r])).first { hour = h; minute = 0; hasTime = true }
        }

        // 只有时间点（如“下午3点开会”）默认今天
        if base == nil, hasTime { base = now }
        guard let b = base else { return nil }

        var comps = cal.dateComponents([.year, .month, .day], from: b)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        comps.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return cal.date(from: comps)
    }

    // MARK: - 工具

    private static func firstAmount(in t: String) -> Double? {
        guard let r = t.range(of: #"(\d+(?:\.\d+)?)\s*(?:元|块|块钱|元钱|￥|¥)?"#,
                              options: .regularExpression) else { return nil }
        let cleaned = String(t[r]).replacingOccurrences(of: #"[^\d.]"#, with: "", options: .regularExpression)
        guard let v = Double(cleaned), v > 0 else { return nil }
        return v
    }

    private static func extractInts(_ s: String) -> [Int] {
        var out: [Int] = []
        var i = s.startIndex
        while i < s.endIndex {
            if let r = s[i...].range(of: #"^\d+"#, options: .regularExpression) {
                if let n = Int(String(s[r])) { out.append(n) }
                i = r.upperBound
            } else {
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func weekdayIn(_ t: String) -> Int? {
        let map: [(String, Int)] = [
            ("周日", 1), ("星期日", 1), ("星期天", 1),
            ("周一", 2), ("星期一", 2),
            ("周二", 3), ("星期二", 3),
            ("周三", 4), ("星期三", 4),
            ("周四", 5), ("星期四", 5),
            ("周五", 6), ("星期五", 6),
            ("周六", 7), ("星期六", 7)
        ]
        for (p, v) in map where t.contains(p) { return v }
        return nil
    }

    private static func makeDate(month: Int, day: Int) -> Date? {
        var comps = DateComponents()
        comps.year = Calendar.current.component(.year, from: .now)
        comps.month = month
        comps.day = day
        comps.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return Calendar.current.date(from: comps)
    }

    private static func stripDateWords(_ s: String) -> String {
        let patterns = [#"大后天|后天|明天|今天"#,
                        #"\d{1,2}月\d{1,2}[日号]"#,
                        #"\d{1,2}[日号]"#,
                        #"周[一二三四五六日天]|星期[一二三四五六日天]"#,
                        #"下午\d{1,2}|上午\d{1,2}|\d{1,2}点|\d{1,2}:\d{2}"#]
        var out = s
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return out
    }

    private static func todayISO() -> String {
        let cal = Calendar.current
        let d = cal.date(bySettingHour: 0, minute: 0, second: 0, of: .now) ?? .now
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: d)
    }

    private static func isoString(from d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: d)
    }
}
