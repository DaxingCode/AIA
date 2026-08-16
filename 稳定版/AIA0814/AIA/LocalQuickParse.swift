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

    static func parse(_ phrase: String, in context: ModelContext) async -> RecognitionResult? {
        let t = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        // 顺序：账单 > 饮食 > 健康 > 待办。健康放在待办之前，避免"记一下体重70"被当待办。
        if let r = parseBill(t, in: context) { return r }
        if let r = await parseFood(t, in: context) { return r }
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
            // time 传 nil：交给 RecognitionSaver.billTime 按餐次默认时刻（早餐08:00/
            // 午餐12:00/晚餐18:00）或当前时间兜底，与对话页文字路径行为一致；
            // 不硬填当天零点（todayISO），否则会跳过 mealDefaultTime 且时间不准。
            payloads.append(BillPayload(merchant: merchant.isEmpty ? nil : merchant,
                                        amount: amount, currency: "CNY",
                                        category: category, time: nil, note: nil,
                                        action: "create", targetTitle: nil))
        }
        guard !payloads.isEmpty else { return nil }
        return RecognitionResult(types: ["bill"], confidence: 1.0,
                                 bill: nil, bills: payloads,
                                 food: nil, todo: nil, health: nil)
    }

    // MARK: - 饮食（一句话多条，复用 ChatView.parseFoodItems）
    // 与 ChatView.createFoodFromCloud 同源：本地优先（canonicalFoodName 归一 → match），
    // 长尾回落云端 queryFood 查表（不走整句 LLM），命中后写入 FoodMetaStore 缓存。
    private static func parseFood(_ text: String, in context: ModelContext) async -> RecognitionResult? {
        // 纯饮水句（如「喝了100毫升水」）由 TellAIAIntent 饮水快捷单独处理，避免当食物重复记。
        if WaterIntakeParser.parse(text) != nil { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 解析「昨天/前天/上周X/M月D日」等相对日期词（没有则回退今天）。
        // 若用户还说了具体时刻（如「下午3点」），把完整时间也存进 FoodPayload。
        let (foodDate, foodHasTime) = RelativeDateParser.dateTimeOrToday(from: t)
        let foodDateStr = foodHasTime ? AppFormat.isoLocal.string(from: foodDate) : AppFormat.isoDate.string(from: foodDate)
        let items = ChatView.parseFoodItems(from: t)
        var payloads: [FoodPayload] = []
        if items.isEmpty {
            // 兼容无显式重量（如"苹果"）：整句作为单条食物名尝试匹配
            let cleaned = t.replacingOccurrences(of: "吃了", with: "").replacingOccurrences(of: "喝了", with: "")
            guard let (ref, fromCloud) = await resolveFoodRef(cleaned, in: context) else { return nil }
            if fromCloud { upsertFoodRef(ref, named: cleaned, in: context) }
            payloads.append(makeFoodPayload(ref, gram: 100, text: t, date: foodDateStr))
        } else {
            for (name, weight, _) in items {
                guard let (ref, fromCloud) = await resolveFoodRef(name, in: context) else { continue }
                if fromCloud { upsertFoodRef(ref, named: name, in: context) }
                let gram = weight > 0 ? Int(weight) : 100
                payloads.append(makeFoodPayload(ref, gram: gram, text: t, date: foodDateStr))
            }
        }
        guard !payloads.isEmpty else { return nil }
        return RecognitionResult(types: ["food"], confidence: 1.0,
                                 bill: nil, bills: nil, food: nil, foods: payloads,
                                 todo: nil, health: nil)
    }

    // 本地库优先 + 云端查表兜底（与聊天记饮食同一套逻辑），保证 Siri 与聊天数值一致。
    private static func resolveFoodRef(_ name: String, in context: ModelContext) async -> (FoodRef, Bool)? {
        // ① 归一后再匹配：红烧牛肉→牛肉、咖喱鸡肉饭→鸡肉 等，消除跨路径数值漂移
        let canonical = NutritionLibrary.canonicalFoodName(name, in: context)
        if let ref = NutritionLibrary.shared.match(canonical, in: context) {
            return (ref, false)
        }
        // ② 长尾：本地不识才走云端 queryFood（查表优先，非整句 LLM）。失败则回落上层 parseText。
        if let ref = try? await RecognizeService.queryFood(name: name) {
            return (ref, true)
        }
        return nil
    }

    private static func upsertFoodRef(_ ref: FoodRef, named name: String, in context: ModelContext) {
        FoodMetaStore.upsert(name: name,
                             displayName: ref.name,
                             kcal: ref.kcal, protein: ref.protein,
                             carbs: ref.carbs, fat: ref.fat,
                             fiber: ref.fiber, sugar: ref.sugar, sodium: ref.sodium,
                             source: "cloud", in: context)
    }

    // 构建饮食 payload（独立函数，避免大字面量触发 type-check 超时）
    private static func buildFoodPayload(ref: FoodRef, gram: Int, text: String) -> FoodPayload {
        let ratio = Double(gram) / 100.0
        let cal = ref.kcal * ratio
        let pro = ref.protein * ratio
        let car = ref.carbs * ratio
        let fat = ref.fat * ratio
        let fib = ref.fiber * ratio
        let sug = ref.sugar * ratio
        let sod = ref.sodium * ratio
        var payload = FoodPayload(name: ref.name, calories: cal, protein: pro,
                           carbs: car, fat: fat, fiber: fib, sugar: sug,
                           sodium: sod, portion: "\(gram)克",
                           meal: WaterIntakeParser.mealFromText(text),
                           action: "create", targetTitle: nil, weightGram: Double(gram))
        return payload
    }

    private static func makeFoodPayload(_ ref: FoodRef, gram: Int, text: String, date: String) -> FoodPayload {
        // 营养库每 100 克营养，按实际重量缩放成这一份的总量；日期在构造后回填（避免大字面量 type-check 超时）
        var payload = buildFoodPayload(ref: ref, gram: gram, text: text)
        payload.date = date
        return payload
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
            // 周期词提取（复用 ChatView.parseRepeatRule，与对话页文字/语音记录同一口径）
            let rr = ChatView.parseRepeatRule(from: seg)
            // 日期解析：优先片段自身，回退整句
            var due = extractDueDate(from: seg) ?? extractDueDate(from: text)
            // 无具体日期的周期待办：due 取今天此刻（而非默认 1 小时后），
            // 符合「每天/每周」从今天开始的直觉，首次完成后按周期顺延。
            if due == nil, rr != nil { due = Date() }
            var title = seg
            for kw in todoTriggers { title = title.replacingOccurrences(of: kw, with: "") }
            title = stripDateWords(title)
            // 移除相对时间表达（2分钟后/1小时后/半小时后），避免标题残留「2分钟后打开好记AIapp」
            title = title.replacingOccurrences(of: #"([\d一二两三四五六七八九十]+)\s*[分钟小时](后|以后)"#, with: "", options: .regularExpression)
            title = title.replacingOccurrences(of: "半小时(后|以后)?|一刻钟(后|以后)?", with: "", options: .regularExpression)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.：:、"))
            guard title.count >= 2 else { continue }
            payloads.append(TodoPayload(title: title, due: due.map { isoString(from: $0) },
                                        repeatRule: rr,
                                        priority: "normal",
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
        // 相对时间（2分钟后/1小时后/半小时后/一刻钟后）优先：文本已明确时刻偏移，
        // 不再走日期/默认逻辑。否则「2分钟后」会被解析成 nil → 落到默认 8:00。
        if let relative = parseRelativeDate(from: text) {
            return relative
        }
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
        } else if text.contains("大前天") {
            base = cal.date(byAdding: .day, value: -3, to: now)
        } else if text.contains("前天") {
            base = cal.date(byAdding: .day, value: -2, to: now)
        } else if text.contains("昨天") || text.contains("昨日") {
            base = cal.date(byAdding: .day, value: -1, to: now)
        } else if let wd = weekdayIn(text) {
            // 账单/待办回溯语义：含「上周X」时往过去推一整周
            if text.contains("上周") || text.contains("上星期") || text.contains("上礼拜") {
                let todayWd = cal.component(.weekday, from: now)
                var diff = wd - todayWd - 7
                if diff >= 0 { diff -= 7 }
                base = cal.date(byAdding: .day, value: diff, to: now)
            } else {
                let todayWd = cal.component(.weekday, from: now)
                var diff = wd - todayWd
                if diff < 0 { diff += 7 }
                base = cal.date(byAdding: .day, value: diff, to: now)
            }
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
        }

        var hour = 8, minute = 0
        var hasTime = false
        let isPM = text.contains("下午")
        let isAM = text.contains("上午")

        if let r = text.range(of: #"(\d{1,2}):(\d{2})"#, options: .regularExpression) {
            let p = extractInts(String(text[r]))
            if p.count >= 2 { hour = p[0]; minute = p[1]; hasTime = true }
        } else if let r = text.range(of: #"下午(\d{1,2})"#, options: .regularExpression) {
            if let h = extractInts(String(text[r])).first { hour = h; minute = 0; hasTime = true }
        } else if let r = text.range(of: #"上午(\d{1,2})"#, options: .regularExpression) {
            if let h = extractInts(String(text[r])).first { hour = h; minute = 0; hasTime = true }
        } else if let match = parseClockTime(from: text) {
            hour = match.hour; minute = match.minute; hasTime = true
        }

        // 12 小时制修正：HH:MM / H点 形式若带「下午/上午」需换算
        if hasTime {
            if isPM && hour < 12 { hour += 12 }
            if isAM && hour == 12 { hour = 0 }
        }
        if base == nil, hasTime { base = now }
        guard let b = base else { return nil }
        var comps = cal.dateComponents([.year, .month, .day], from: b)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        comps.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return cal.date(from: comps)
    }

    // 相对时间：N分钟后/小时后/半小时后/一刻钟后，基于当前时刻偏移。
    // 与 ChatView.parseRelativeTime 同源，本地快析也需支持，否则「2分钟后」解析成 nil → 默认 8:00。
    private static func parseRelativeDate(from text: String) -> Date? {
        let lower = text.lowercased()
        let cal = Calendar.current
        let now = Date()

        func extractNumber(_ match: NSTextCheckingResult, at idx: Int, in string: String) -> Int? {
            let range = match.range(at: idx)
            guard range.location != NSNotFound else { return nil }
            let s = (string as NSString).substring(with: range)
            // parseChineseNumber 现返回 Double?（支持「半」），相对时间只需整数分钟/小时，截断即可。
            return ChatView.parseChineseNumber(s).map(Int.init) ?? Int(s)
        }

        let quarter = try? NSRegularExpression(pattern: "一刻钟(后|以后)?")
        if let quarter, quarter.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)) != nil {
            return cal.date(byAdding: .minute, value: 15, to: now)
        }
        let half = try? NSRegularExpression(pattern: "半小时(后|以后)?")
        if let half, half.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)) != nil {
            return cal.date(byAdding: .minute, value: 30, to: now)
        }

        let minute = try? NSRegularExpression(pattern: "([\\d一二两三四五六七八九十]+)\\s*分钟(后|以后)")
        if let minute,
           let match = minute.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)),
           let n = extractNumber(match, at: 1, in: lower) {
            return cal.date(byAdding: .minute, value: n, to: now)
        }

        let hour = try? NSRegularExpression(pattern: "([\\d一二两三四五六七八九十]+)\\s*小时(后|以后)")
        if let hour,
           let match = hour.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)),
           let n = extractNumber(match, at: 1, in: lower) {
            return cal.date(byAdding: .hour, value: n, to: now)
        }

        return nil
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

    /// 解析「X点X分 / X点半 / 三点半」等中文数字时间，返回 (hour, minute)。
    private static func parseClockTime(from text: String) -> (hour: Int, minute: Int)? {
        let pattern = #"([\d一二两三四五六七八九十]{1,3})\s*点(?:\s*(半|([\d一二两三四五六七八九十]+)\s*分))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return nil }

        let hStr = (text as NSString).substring(with: m.range(at: 1))
        guard let h = parseChineseOrArabicNumber(hStr), h <= 23 else { return nil }

        var mi = 0
        if m.range(at: 2).location != NSNotFound {
            let ms = (text as NSString).substring(with: m.range(at: 2))
            if ms.contains("半") {
                mi = 30
            } else {
                let minStr = ms.replacingOccurrences(of: "分", with: "").trimmingCharacters(in: .whitespaces)
                if let mNum = parseChineseOrArabicNumber(minStr), mNum <= 59 { mi = mNum }
            }
        }
        return (h, mi)
    }

    private static func parseChineseOrArabicNumber(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return n }
        // parseChineseNumber 现返回 Double?，小时/分钟只需整数，截断即可。
        if let d = ChatView.parseChineseNumber(t) { return Int(d) }
        return nil
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
                        // 带「下午/上午」的 HH:MM / X点X分 / X点半（支持中文数字）
                        #"(?:下午|上午)\s*(?:\d{1,2}:\d{2}|(?:\d{1,2}|[一二两三四五六七八九十]{1,3})\s*点(?:\s*(半|(?:\d{1,2}|[一二两三四五六七八九十]{1,3})\s*分))?)"#,
                        // 单独的阿拉伯数字时间点
                        #"\d{1,2}点|\d{1,2}:\d{2}"#]
        var out = s
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return out
    }

    private static func isoString(from d: Date) -> String {
        AppFormat.isoLocal.string(from: d)
    }
}
