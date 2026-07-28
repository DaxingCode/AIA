// LocalQuickParse.swift
// 本地快析：不调云端，直接从一句口语里解析出账单/食物/待办/健康结构化结果。
// 一句话多条：账单/待办/饮食/健康均按连词切分后逐条解析，全部进入 RecognitionResult 的复数数组字段。
import Foundation
import SwiftData

struct LocalQuickParse {
    static let knownBillCats: Set<String> = ["餐饮", "交通", "购物", "居住", "娱乐", "医疗", "教育", "旅行", "其他", "工资", "红包", "理财", "人情", "通讯", "数码", "服饰", "运动", "宠物", "订阅", "收入"]
    static let incomeCats: Set<String> = ["工资", "红包", "理财", "收入", "人情", "报销", "退款", "返现", "奖金", "分红", "利息", "收款", "进账", "提成", "劳务费", "兼职", "补贴"]

    private static let spendKeywords = ["花了", "花掉", "付了", "付给", "消费", "支出", "账单", "花销", "开销", "扫码付", "买单", "结账", "购买"]
    private static let incomeKeywords = ["工资", "薪资", "薪水", "收入", "报销", "退款", "返现", "奖金", "分红", "利息", "红包", "补贴", "收款", "进账", "提成", "劳务费", "兼职", "到账"]
    private static let mealWords = ["吃饭", "餐", "外卖", "点餐", "喝", "吃"]
    private static let eatVerbs = ["吃", "喝了", "喝", "食", "进", "尝", "品", "早餐", "午餐", "晚餐", "夜宵", "加餐", "零食", "宵夜", "早饭", "午饭", "晚饭"]

    // 待办：触发词（可剥离前缀）与主题词（本身即待办内容，如"交电费"）
    private static let todoTriggers = ["提醒我", "提醒", "记一下", "记一个", "记一条", "记着", "帮我记", "记得", "别忘", "别忘记", "待办", "加个待办", "增加一个提醒", "加提醒"]
    private static let todoTopics = ["交报表", "交作业", "交电费", "交党费", "交税", "还信用卡", "还花呗", "还房贷", "还车贷", "取快递", "拿快递", "取药", "拿药"]

    static func parse(_ phrase: String, in context: ModelContext) -> RecognitionResult? {
        let t = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        // 顺序：账单 > 饮食 > 健康 > 待办。健康放在待办之前，避免"记一下体重70"被当待办。
        if let r = parseBill(t, in: context) { return r }
        if let r = parseFood(t, in: context) { return r }
        if let r = parseHealth(t) { return r }
        if let r = parseTodo(t) { return r }
        return nil
    }

    // MARK: - 账单（一句话多条）
    private static func parseBill(_ text: String, in context: ModelContext) -> RecognitionResult? {
        let hasSpend = spendKeywords.contains { text.contains($0) }
        let hasIncome = incomeKeywords.contains { text.contains($0) }
        let hasMeal = mealWords.contains { text.contains($0) }
        // 对齐聊天页 createBillLocally：账单必须带货币单位（元/块/￥/¥），
        // 否则「喝了100毫升水」里的 100 会被误当金额建档成账单。
        let hasMoneyUnit = text.contains("元") || text.contains("块") || text.contains("￥") || text.contains("¥")
        let isFoodWithAmount = hasMeal && hasMoneyUnit
        let isIncomeWithAmount = hasIncome
        guard hasSpend || isIncomeWithAmount || isFoodWithAmount else { return nil }

        var payloads: [BillPayload] = []
        for seg in IntentTextUtils.splitByConjunction(text) {
            guard let amount = firstAmount(in: seg) else { continue }
            var merchant = IntentTextUtils.cleanMerchant(seg)
            if merchant.isEmpty { merchant = inferBillCategory(seg) }
            let category = inferBillCategory(seg)
            payloads.append(BillPayload(merchant: merchant.isEmpty ? nil : merchant,
                                        amount: amount, currency: "CNY",
                                        category: category, time: todayISO(), note: nil,
                                        action: "create", targetTitle: nil))
        }
        guard !payloads.isEmpty else { return nil }
        return RecognitionResult(types: ["bill"], confidence: 1.0,
                                 bill: nil, bills: payloads,
                                 food: nil, todo: nil, health: nil)
    }

    // MARK: - 饮食（一句话多条，复用 ChatView.parseFoodItems）
    private static func parseFood(_ text: String, in context: ModelContext) -> RecognitionResult? {
        // 纯饮水句（如「喝了100毫升水」）由 TellAIAIntent 饮水快捷单独处理，避免当食物重复记。
        if WaterIntakeParser.parse(text) != nil { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = ChatView.parseFoodItems(from: t)
        var payloads: [FoodPayload] = []
        if items.isEmpty {
            // 兼容无显式重量（如"苹果"）：整句作为单条食物名尝试匹配
            let cleaned = t.replacingOccurrences(of: "吃了", with: "").replacingOccurrences(of: "喝了", with: "")
            guard let ref = NutritionLibrary.shared.match(cleaned, in: context) else { return nil }
            payloads.append(makeFoodPayload(ref, gram: 100, text: t))
        } else {
            for (name, weight, _) in items {
                guard let ref = NutritionLibrary.shared.match(name, in: context) else { continue }
                let gram = weight > 0 ? Int(weight) : 100
                payloads.append(makeFoodPayload(ref, gram: gram, text: t))
            }
        }
        guard !payloads.isEmpty else { return nil }
        return RecognitionResult(types: ["food"], confidence: 1.0,
                                 bill: nil, bills: nil, food: nil, foods: payloads,
                                 todo: nil, health: nil)
    }

    private static func makeFoodPayload(_ ref: FoodRef, gram: Int, text: String) -> FoodPayload {
        FoodPayload(name: ref.name, calories: ref.kcal, protein: ref.protein,
                    carbs: ref.carbs, fat: ref.fat, fiber: ref.fiber, sugar: ref.sugar,
                    sodium: ref.sodium, portion: "\(gram)克",
                    meal: WaterIntakeParser.mealFromText(text),
                    action: "create", targetTitle: nil)
    }

    // MARK: - 健康（一句话多条，新增本地解析）
    private static func parseHealth(_ text: String) -> RecognitionResult? {
        let payloads = IntentTextUtils.parseHealthMetrics(text)
        guard !payloads.isEmpty else { return nil }
        return RecognitionResult(types: ["health"], confidence: 1.0,
                                 bill: nil, bills: nil, food: nil, todo: nil, health: nil,
                                 healths: payloads)
    }

    // MARK: - 待办（一句话多条）
    private static func parseTodo(_ text: String) -> RecognitionResult? {
        guard todoTriggers.contains(where: { text.contains($0) }) ||
              todoTopics.contains(where: { text.contains($0) }) else { return nil }
        let hasGlobalTrigger = todoTriggers.contains(where: { text.contains($0) }) ||
                               todoTopics.contains(where: { text.contains($0) })
        var payloads: [TodoPayload] = []
        for seg in IntentTextUtils.splitByConjunction(text) {
            // 整句有触发/主题词时所有片段都算待办；否则片段需自带触发/主题词
            if !hasGlobalTrigger {
                guard todoTriggers.contains(where: { seg.contains($0) }) ||
                      todoTopics.contains(where: { seg.contains($0) }) else { continue }
            }
            let due = extractDueDate(from: seg) ?? extractDueDate(from: text)
            var title = seg
            for kw in todoTriggers { title = title.replacingOccurrences(of: kw, with: "") }
            title = stripDateWords(title)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.：:、"))
            guard title.count >= 2 else { continue }
            payloads.append(TodoPayload(title: title, due: due.map { isoString(from: $0) },
                                        repeatRule: "none", priority: "normal",
                                        action: "create", targetTitle: nil))
        }
        guard !payloads.isEmpty else { return nil }
        return RecognitionResult(types: ["todo"], confidence: 1.0,
                                 bill: nil, bills: nil, food: nil, todo: nil, todos: payloads,
                                 health: nil)
    }

    // MARK: - 工具
    private static func firstAmount(in t: String) -> Double? {
        guard let r = t.range(of: #"(\d+(?:\.\d+)?)\s*(?:元|块|块钱|元钱|￥|¥)?"#,
                              options: .regularExpression) else { return nil }
        let cleaned = String(t[r]).replacingOccurrences(of: #"[^\d.]"#, with: "", options: .regularExpression)
        guard let v = Double(cleaned), v > 0 else { return nil }
        return v
    }

    private static func isIncomeCategory(_ category: String) -> Bool {
        return incomeCats.contains(category)
    }

    private static func inferBillCategory(_ t: String) -> String {
        if incomeKeywords.contains(where: { t.contains($0) }) { return "工资" }
        if t.contains("打车") || t.contains("地铁") || t.contains("公交") || t.contains("加油") || t.contains("停车") || t.contains("高铁") || t.contains("火车") || t.contains("机票") || t.contains("滴滴") { return "交通" }
        if t.contains("奶茶") || t.contains("咖啡") || t.contains("餐厅") || t.contains("饭店") || t.contains("外卖") || t.contains("食堂") || t.contains("宵夜") || t.contains("早餐") || t.contains("午餐") || t.contains("晚餐") || t.contains("聚餐") || t.contains("火锅") || t.contains("烧烤") || t.contains("汉堡") || t.contains("零食") || t.contains("蛋糕") || t.contains("面包") || t.contains("水果") || t.contains("菜") || t.contains("饭") || t.contains("餐") || t.contains("喝") || t.contains("吃") { return "餐饮" }
        if t.contains("淘宝") || t.contains("京东") || t.contains("拼多多") || t.contains("天猫") || t.contains("超市") || t.contains("商场") || t.contains("购物") || t.contains("买") || t.contains("衣服") || t.contains("鞋") || t.contains("包") || t.contains("数码") || t.contains("手机") || t.contains("电脑") { return "购物" }
        if t.contains("房租") || t.contains("物业") || t.contains("水电") || t.contains("燃气") || t.contains("宽带") || t.contains("话费") || t.contains("住宿") || t.contains("家居") { return "居住" }
        if t.contains("电影") || t.contains("游戏") || t.contains("娱乐") || t.contains("ktv") || t.contains("KTV") || t.contains("演出") || t.contains("门票") { return "娱乐" }
        if t.contains("医院") || t.contains("药店") || t.contains("体检") || t.contains("诊所") || t.contains("医疗") || t.contains("药") { return "医疗" }
        if t.contains("学费") || t.contains("书") || t.contains("培训") || t.contains("课程") || t.contains("考试") { return "教育" }
        if t.contains("机票") || t.contains("酒店") || t.contains("旅游") || t.contains("景点") || t.contains("签证") { return "旅行" }
        if t.contains("红包") || t.contains("份子") || t.contains("礼金") || t.contains("人情") { return "人情" }
        if t.contains("话费") || t.contains("流量") || t.contains("宽带") || t.contains("网费") || t.contains("通讯") { return "通讯" }
        if t.contains("健身") || t.contains("运动") || t.contains("装备") { return "运动" }
        if t.contains("宠物") || t.contains("猫") || t.contains("狗") { return "宠物" }
        if t.contains("会员") || t.contains("订阅") { return "订阅" }
        return ""
    }

    private static func extractDueDate(from text: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        var base: Date?
        if text.contains("明天") || text.contains("明日") {
            base = cal.date(byAdding: .day, value: 1, to: now)
        } else if text.contains("后天") {
            base = cal.date(byAdding: .day, value: 2, to: now)
        } else if text.contains("大后天") {
            base = cal.date(byAdding: .day, value: 3, to: now)
        } else if text.contains("今天") || text.contains("今日") {
            base = now
        } else if let r = text.range(of: #"(\d{1,2})月(\d{1,2})[日号]"#, options: .regularExpression) {
            let nums = extractInts(String(text[r]))
            if nums.count == 2 { base = makeDate(month: nums[0], day: nums[1]) }
        } else if let r = text.range(of: #"(\d{1,2})[日号]"#, options: .regularExpression) {
            if let d = extractInts(String(text[r])).first {
                var comps = cal.dateComponents([.year, .month], from: now)
                comps.day = d
                var cand = cal.date(from: comps)
                if let c = cand, c < now { cand = cal.date(byAdding: .month, value: 1, to: c) }
                base = cand
            }
        } else if let wd = weekdayIn(text) {
            let todayWd = cal.component(.weekday, from: now)
            var diff = wd - todayWd
            if diff < 0 { diff += 7 }
            base = cal.date(byAdding: .day, value: diff, to: now)
        }

        var hour = 8, minute = 0
        var hasTime = false
        if let r = text.range(of: #"(\d{1,2}):(\d{2})"#, options: .regularExpression) {
            let p = extractInts(String(text[r]))
            if p.count >= 2 { hour = p[0]; minute = p[1]; hasTime = true }
        } else if let r = text.range(of: #"下午(\d{1,2})"#, options: .regularExpression) {
            if let h = extractInts(String(text[r])).first { hour = h + 12; minute = 0; hasTime = true }
        } else if let r = text.range(of: #"上午(\d{1,2})"#, options: .regularExpression) {
            if let h = extractInts(String(text[r])).first { hour = h; minute = 0; hasTime = true }
        } else if let r = text.range(of: #"(\d{1,2})点"#, options: .regularExpression) {
            if let h = extractInts(String(text[r])).first { hour = h; minute = 0; hasTime = true }
        }
        if base == nil, hasTime { base = now }
        guard let b = base else { return nil }
        var comps = cal.dateComponents([.year, .month, .day], from: b)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        comps.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return cal.date(from: comps)
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
