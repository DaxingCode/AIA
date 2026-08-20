// RecognitionSaver.swift
// 识别结果「自动入库」：识别完成后立即写入 SwiftData 各业务表 + 识别记录流水，
// 并触发可安全的副作用（待办通知排程）。返回 SavedSession 持有已存记录引用，
// 供确认页在用户「保存修改」时直接覆盖更新。
//
// 设计要点：
//  - SavedSession 是纯内存引用容器（非 SwiftData 模型），不改动任何 @Model schema，无需升级 schemaVersion。
//  - 卡路里 / 健康指标写 HealthKit 属于「确认后副作用」，放到用户点「保存」时触发（applyAndSave），
//    避免自动入库阶段重复累加且难以撤销。
//  - 待办通知使用 syncId 作 identifier，schedule 内部先 cancel 再排程，重复安全，故自动入库即排程，
//    用户不修改也能收到提醒；用户改期后重新 schedule 自动覆盖。
//  - 自动入库写入的是模型原始抽取结果；用户点「保存」时确认页用 NutritionLibrary 等校正后的值覆盖。
import UIKit
import SwiftData
import AIAKit

final class SavedSession: Identifiable {
    let id = UUID()
    let result: RecognitionResult
    let rawText: String
    let sourceImage: UIImage?
    /// 识别来源（本地 / 云端），确认页据此展示「免费版AI识别 / Pro版AI识别」标签。
    var source: RecognitionSource = .cloud
    var imageName: String?
    var bills: [Bill] = []
    var todo: Reminder?
    var food: FoodEntry?
    /// 预存的全部食物记录（多食物场景确认页覆盖时需整组替换；food 恒为 foods.first）。
    var foods: [FoodEntry] = []
    var foodCaloriesTotal: Double = 0
    var health: HealthMetric?
    var recognition: RecognitionRecord?
    /// 自动保存类别入库后，对应的「已保存态」识别卡片（携带真实模型的 syncId），
    /// 由 processRecognition 汇总进 ChatMessage 协议消息，进入对话气泡。
    var savedItems: [RecognitionItem] = []
    weak var context: ModelContext?

    /// 疑似重复提示（图片命中历史指纹但仍自动入库）。非 nil 表示这张图之前识别过，
    /// 确认页据此显示「似乎已记录过」警告，由用户决定编辑/保留/删除。
    var duplicateHint: DuplicateHint?

    init(result: RecognitionResult, rawText: String, sourceImage: UIImage?, context: ModelContext?,
         source: RecognitionSource = .cloud) {
        self.result = result
        self.rawText = rawText
        self.sourceImage = sourceImage
        self.context = context
        self.source = source
    }
}

/// processRecognition 的处理结论，由调用方（首页截图 pending / 聊天 / 相册相机链路）消费：
/// - inserted：已向对话流插入一条「识别结果」气泡消息（消息内部按类别分 已保存态 / 待确认态 卡片）。
///   调用方只需清掉自身的 pending / 关闭 cover 即可，无需再弹确认页。
/// - nothing：本次未识别出任何有效类别 → 调用方清 pending，不插入消息。
enum RecognitionOutcome {
    case inserted([ChatMessage])
    case nothing
}

@MainActor
enum RecognitionSaver {
    /// 从模型给的 due 字符串解析日期（兼容 ISO8601 / yyyy-MM-dd / 含时间串），失败回退到今天 8:00。
    static func dueDate(from dueString: String?) -> Date {
        let calendar = Calendar.current
        let todayAtEight = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
        guard let dueString = dueString, !dueString.isEmpty else { return todayAtEight }

        // 完整 ISO 时间（含 T 和 :）直接按本地时区解析，避免 date-only + 正则拆小时导致时区漂移
        if dueString.range(of: #"[T\s]\d{1,2}:\d{2}"#, options: .regularExpression) != nil,
           let d = AppFormat.isoLocal.date(from: dueString)
            ?? AppFormat.iso.date(from: dueString)
            ?? AppFormat.isoLocalNoFrac.date(from: dueString)
            ?? AppFormat.isoNoFrac.date(from: dueString) {
            return d
        }

        var baseDate: Date?
        if let d = AppFormat.isoDate.date(from: dueString) {
            baseDate = d
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            baseDate = f.date(from: dueString)
        }
        guard let date = baseDate else { return todayAtEight }

        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        let timePattern = #"\d{1,2}:\d{2}(?::\d{2})?"#
        if let range = dueString.range(of: timePattern, options: .regularExpression) {
            let matched = String(dueString[range])
            let parts = matched.components(separatedBy: ":").compactMap { Int($0) }
            let h = parts.first ?? 8
            let m = parts.count > 1 ? parts[1] : 0
            let s = parts.count > 2 ? parts[2] : 0
            if h == 0 && m == 0 && s == 0 {
                comps.hour = 8; comps.minute = 0; comps.second = 0
            } else {
                comps.hour = h; comps.minute = m; comps.second = s
            }
        } else {
            comps.hour = 8; comps.minute = 0; comps.second = 0
        }
        return calendar.date(from: comps) ?? todayAtEight
    }

    /// 按识别时间自动判断餐次：5–10 点早餐，11–15 点午餐，16–21 点晚餐，其余为加餐
    nonisolated static func defaultMeal(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<11:  return "早餐"
        case 11..<16: return "午餐"
        case 16..<22: return "晚餐"
        default:      return "加餐"
        }
    }

    static func isIncomeCategory(_ category: String) -> Bool {
        let incomeKeywords = ["工资", "收入", "报销", "退款", "返现", "奖金", "津贴", "补贴", "转账收入", "投资收益", "利息"]
        let lowered = category.lowercased()
        return incomeKeywords.contains { lowered.contains($0) }
    }

    /// 解析账单时间，失败时按「来源 + 三餐关键词」回退，规则：
    /// 1. 优先用模型给的时间字符串（ISO8601 / 中文相对日期 / 纯时间）。
    /// 2. 模型未给时间，但商户名/分类含三餐关键词 → 落到当天对应默认时刻
    ///    （早饭·早餐 → 08:00，午饭·午餐 → 12:00，晚饭·晚餐 → 18:00，夜宵·宵夜 → 22:00）。
    /// 3. 仍无匹配则按来源回退：
    ///    text（聊天/语音/Siri）：当前时间（用户口头/文字描述的就是当下发生的事）；
    ///    image + 快捷指令无感截图（screenshotShortcut=true）：当前时间（无感截图本就是用户当下发生的支付，记识别时更准）；
    ///    聊天页发图/拍照/相册/分享扩展/上传（entryOrigin=="image" 且 screenshotShortcut=false）：当天 0:00（避免截图拍摄时间污染真实交易时间）。
    static func billTime(from time: String?, merchant: String?, category: String?, entryOrigin: String,
                         screenshotShortcut: Bool = false) -> Date {
        if let t = RecognitionResult.date(from: time) { return t }
        let text = [merchant, category].compactMap { $0 }.joined(separator: " ")
        if let mealTime = mealDefaultTime(from: text) { return mealTime }
        if entryOrigin == "image" {
            // 快捷指令截图：图上没付款/支付时间时记「识别时那一刻」；其余 image 来源保持当天 0:00
            if screenshotShortcut { return .now }
            return Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: .now) ?? .now
        }
        return .now
    }

    /// 从中文文本识别三餐关键词，返回当天对应默认时刻；无匹配返回 nil。
    private static func mealDefaultTime(from text: String) -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let map: [(keywords: [String], hour: Int, minute: Int)] = [
            (["早饭", "早餐", "早点", "早點"], 8, 0),
            (["午饭", "午餐", "中饭", "中餐"], 12, 0),
            (["晚饭", "晚餐", "夜饭"], 18, 0),
            (["夜宵", "宵夜", "夜消"], 22, 0),
        ]
        for (keywords, h, m) in map {
            if keywords.contains(where: { text.contains($0) }) {
                return cal.date(bySettingHour: h, minute: m, second: 0, of: today) ?? .now
            }
        }
        return nil
    }

    /// 从份量字符串解析克数。仅当份量字符串含「克/g」单位时返回数字；遇到「2个」「1碗」「3片」
    /// 等不带克单位的份量返回 nil，避免调用方误用「首个数字」当克数（旧版 bug：2个 → 2g）。
    nonisolated static func weightFromPortion(_ portion: String?) -> Double? {
        guard let p = portion, !p.isEmpty else { return nil }
        // 只匹配「数字 + 克/g」组合（支持中文克/英文 g/G），避开「2个」「1碗」这类文本
        let pattern = #"(\d+(?:\.\d+)?)\s*(克|g|G)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: p, range: NSRange(location: 0, length: p.utf16.count)) {
            let numStr = (p as NSString).substring(with: match.range(at: 1))
            if let v = Double(numStr), v > 0 { return v }
        }
        return nil
    }

    /// 常见「份量单位 → 每单位克数」换算表（经验均值，用户可在详情页手动改）。
    /// 仅用于照片识别里模型只给「1碗/1个/1片」等无量词场景，避免一律兜底 100g。
    private nonisolated static let servingUnitGrams: [String: Double] = [
        "碗": 300, "碟": 100, "盘": 200, "份": 120, "个": 100, "颗": 100,
        "只": 100, "枚": 100, "片": 30, "块": 50, "根": 80, "条": 80,
        "杯": 240, "瓶": 500, "罐": 330, "勺": 15, "匙": 15, "把": 50,
        "串": 80, "瓣": 5, "口": 25, "张": 40, "粒": 5, "尾": 120
    ]

    /// 从份量字符串解析「模糊单位」（碗/个/片…）对应的克数。
    /// 仅在 `weightFromPortion` 未命中（即不含「克/g」）时调用，避免把「1碗」误当 1 克。
    nonisolated static func weightFromServingUnit(_ portion: String?) -> Double? {
        guard let p = portion, !p.isEmpty else { return nil }
        let units = servingUnitGrams.keys.joined(separator: "|")
        let pattern = "(\\d+(?:\\.\\d+)?)\\s*(" + units + ")"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: p, range: NSRange(location: 0, length: p.utf16.count)),
              let numRange = Range(match.range(at: 1), in: p),
              let unitRange = Range(match.range(at: 2), in: p),
              let num = Double(p[numRange]), num > 0,
              let unitGrams = servingUnitGrams[String(p[unitRange])]
        else { return nil }
        return num * unitGrams
    }

    /// 从原始用户输入文本解析食物克数（如「吃了50克苹果」→ 50）。
    /// 作为食物入库的「最终兜底」：当 FoodPayload 既无 weightGram、portion 也没带克单位时，
    /// 直接从用户原话里取「数字+克/g」组合，避免一律 fallback 成 100 克。
    /// 带量词单位（个/碗/片…）的不在此解析，交由营养估算默认值。
    static func weightFromText(_ text: String?) -> Double? {
        guard let t = text, !t.isEmpty else { return nil }
        let pattern = #"(\d+(?:\.\d+)?)\s*(克|g|G)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: t, range: NSRange(location: 0, length: t.utf16.count)) {
            let numStr = (t as NSString).substring(with: match.range(at: 1))
            if let v = Double(numStr), v > 0 { return v }
        }
        // 中文「两」：如「吃了二两苹果」
        let liangPattern = #"(\d*(?:[一二两三四五六七八九十]+)?)\s*两"#
        if let regex = try? NSRegularExpression(pattern: liangPattern),
           let match = regex.firstMatch(in: t, range: NSRange(location: 0, length: t.utf16.count)) {
            let numStr = (t as NSString).substring(with: match.range(at: 1))
            let liang = numStr.isEmpty ? 1 : (Int(numStr) ?? 1)
            if liang > 0 { return Double(liang) * 50 }
        }
        return nil
    }

    /// 识别完成后立即入库，返回已存记录引用（供确认页覆盖更新）。
    /// - Parameter allowedTypes: 非 nil 时只入库这些类别（按类别「自动保存」设置过滤）；
    ///   nil = 全部入库（确认页点「存入」的旧路径，行为不变）。
    static func autoSave(result: RecognitionResult, rawText: String, image: UIImage?, context: ModelContext,
                         source: RecognitionSource = .cloud,
                         allowedTypes: Set<String>? = nil,
                         entryOrigin: String = "image",
                         screenshotShortcut: Bool = false,
                         presavedImageName: String? = nil,
                         skipCloudSync: Bool = false,
                         duplicateHint: DuplicateHint? = nil) -> SavedSession {
        let session = SavedSession(result: result, rawText: rawText, sourceImage: image, context: context, source: source)
        session.duplicateHint = duplicateHint
        // presavedImageName：对话页「用户发图气泡」已把原图落过盘，直接复用同一份，避免同图存两次
        let imageName = presavedImageName ?? LocalImageStore.save(image)
        session.imageName = imageName
        let itemSource = (entryOrigin == "image") ? "image" : "text"
        let rawTypes = result.types ?? []
        let types = allowedTypes.map { allowed in rawTypes.filter { allowed.contains($0) } } ?? rawTypes

        if types.contains("bill") {
            for b in result.billList {
                guard let amt = b.amount else { continue }
                // 空商户兜底：用分类名或"账单"，绝不 continue（曾致 Siri 说"记下了"但账单未存）。
                let merchant = (b.merchant ?? "").isEmpty ? (b.category ?? "账单") : b.merchant!
                // 时间解析失败：按「来源 + 三餐关键词」回退（截图→0点防污染，文字→当前，三餐关键词→对应时刻）
                let time = Self.billTime(from: b.time, merchant: b.merchant, category: b.category, entryOrigin: entryOrigin,
                                         screenshotShortcut: screenshotShortcut)
                // 方案2：模型自由文本分类归并到预设大类，保证分类明细页聚合一致
                let rawCategory = b.category ?? ""
                let normalizedCat = BillCategoryHelpers.normalizedCategory(rawCategory)
                // 收入判定基于原始分类（归一化可能把"报销"等并入"工资"，丢失关键词子串）
                let income = isIncomeCategory(rawCategory)
                let bill = Bill(merchant: merchant, amount: amt,
                                category: normalizedCat, time: time,
                                isIncome: income, imageName: imageName)
                context.insert(bill)
                context.insert(RecogSource(syncId: bill.syncId, kind: "bill", recogSourceRaw: RecogSource.raw(from: source)))
                session.bills.append(bill)
                session.savedItems.append(RecognitionItem(id: UUID(), type: .bill,
                                                          syncId: bill.syncId.uuidString,
                                                          imageName: imageName, source: itemSource,
                                                          recogSource: RecogSource.raw(from: source),
                                                          payload: .bill(b)))
            }
        }

        if types.contains("todo") {
            for t in result.todoList {
                guard let title = t.title, !title.isEmpty, title.count >= 2 else { continue }
                let due = dueDate(from: t.due)
                let r = Reminder(title: title, due: due,
                                repeatRule: t.repeatRule ?? "none",
                                imageName: imageName)
                DefaultReminderSettings.shared.apply(to: r)
                context.insert(r)
                context.insert(RecogSource(syncId: r.syncId, kind: "todo", recogSourceRaw: RecogSource.raw(from: source)))
                ReminderNotificationManager.schedule(r)   // 自动入库即排程，用户不修改也提醒
                if session.todo == nil { session.todo = r }
                session.savedItems.append(RecognitionItem(id: UUID(), type: .todo,
                                                          syncId: r.syncId.uuidString,
                                                          imageName: imageName, source: itemSource,
                                                          recogSource: RecogSource.raw(from: source),
                                                          payload: .todo(t)))
            }
        }

        if types.contains("food") {
            var totalFoodCal: Double = 0
            for f in result.foodList {
                guard let name = f.name, !name.isEmpty else { continue }
                let weight = f.weightGram ?? weightFromPortion(f.portion) ?? weightFromServingUnit(f.portion) ?? 100
                let ratio = weight / 100
                // 模型给的是该份量「总营养」，反推每100g基准 = 总 × 100 / weight，
                // 使入库总营养 == 模型估算；营养表(100g)/显式克路径 ratio=1 等价不变。
                let per100 = weight > 0 ? 100.0 / weight : 1.0
                let baseCal = (f.calories ?? 0) * per100
                let basePro = (f.protein ?? 0) * per100
                let baseCar = (f.carbs   ?? 0) * per100
                let baseFat = (f.fat     ?? 0) * per100
                let baseFib = (f.fiber   ?? 0) * per100
                let baseSug = (f.sugar   ?? 0) * per100
                let baseSod = (f.sodium  ?? 0) * per100

                // 校验：所有营养值（宏量 + 微量）为零 → 跳过保存空壳记录
                if baseCal > 0 || basePro > 0 || baseCar > 0 || baseFat > 0
                    || baseFib > 0 || baseSug > 0 || baseSod > 0 {
                    // 文字输入带「昨天/前天/上周X/M月D日」时，f.date 已含 ISO 日期；
                    // 若用户还说了具体时刻（如「下午3点」），f.date 为完整 ISO 时间，保留该时刻。
                    // 若仅传 yyyy-MM-dd 或无时刻，按 meal 给默认时刻，避免显示 00:00 或时区漂移成 8:00。
                    let foodDate: Date = {
                        if let d = f.date {
                            // 新格式：ISO8601 完整时间（如 2026-08-09T15:00:00+08:00）
                            if d.count > 10, let parsed = AppFormat.isoLocal.date(from: d)
                                ?? AppFormat.iso.date(from: d)
                                ?? AppFormat.isoLocalNoFrac.date(from: d)
                                ?? AppFormat.isoNoFrac.date(from: d) {
                                return parsed
                            }
                            // 旧格式/无时刻：纯 yyyy-MM-dd
                            if let parsed = AppFormat.isoDate.date(from: d) {
                                let meal = f.meal ?? defaultMeal(for: parsed)
                                let hour: Int
                                switch meal {
                                case let m where m.contains("早"): hour = 8
                                case let m where m.contains("午") || m.contains("中"): hour = 12
                                case let m where m.contains("晚"): hour = 18
                                case let m where m.contains("夜") || m.contains("宵"): hour = 22
                                default: hour = 12
                                }
                                return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: parsed) ?? parsed
                            }
                        }
                        return Date()
                    }()
                    let entry = FoodEntry(name: name,
                                          calories: baseCal * ratio,
                                          protein: basePro * ratio,
                                          carbs: baseCar * ratio,
                                          fat: baseFat * ratio,
                                          fiber: baseFib * ratio,
                                          sugar: baseSug * ratio,
                                          sodium: baseSod * ratio,
                                          portion: "\(Int(weight))克",
                                          meal: f.meal ?? defaultMeal(for: foodDate),
                                          date: foodDate,
                                          weightGram: weight,
                                          baseCalories: baseCal,
                                          baseProtein: basePro,
                                          baseCarbs: baseCar,
                                          baseFat: baseFat,
                                          baseFiber: baseFib,
                                          baseSugar: baseSug,
                                          baseSodium: baseSod,
                                          imageName: imageName)
                    context.insert(entry)
                    context.insert(FoodSource(foodSyncId: entry.syncId, origin: entryOrigin))
                    context.insert(RecogSource(syncId: entry.syncId, kind: "food", recogSourceRaw: RecogSource.raw(from: source)))
                    totalFoodCal += baseCal * ratio
                    session.foods.append(entry)
                    if session.food == nil { session.food = entry }
                    session.savedItems.append(RecognitionItem(id: UUID(), type: .food,
                                                              syncId: entry.syncId.uuidString,
                                                              imageName: imageName, source: itemSource,
                                                              recogSource: RecogSource.raw(from: source),
                                                              payload: .food(f)))
                    // 卡路里同步放确认时（applyAndSave），避免自动阶段重复累加
                } else {
                    print("[autoSave] 跳过空壳食物记录：\(name)（所有营养值均为零）")
                }
            }
            session.foodCaloriesTotal = totalFoodCal
        }

        if types.contains("health") {
            for h in result.healthList {
                guard let metricName = h.metric, !metricName.isEmpty else { continue }
                let metric = HealthMetric()
                metric.metric = metricName
                metric.value = h.value ?? ""
                metric.unit = h.unit ?? ""
                metric.imageName = imageName
                context.insert(metric)
                context.insert(RecogSource(syncId: metric.syncId, kind: "health", recogSourceRaw: RecogSource.raw(from: source)))
                if session.health == nil { session.health = metric }
                session.savedItems.append(RecognitionItem(id: UUID(), type: .health,
                                                          syncId: metric.syncId.uuidString,
                                                          imageName: imageName, source: itemSource,
                                                          recogSource: RecogSource.raw(from: source),
                                                          payload: .health(h)))
                // 健康指标同步放确认时
            }
        }

        if !types.isEmpty && !types.contains("none") {
            let rec = RecognitionRecord(recognizedAt: .now, rawText: rawText, types: types, imageName: imageName)
            context.insert(rec)
            session.recognition = rec
        }

        try? context.save()
        // 使用统计：记录「由识别产生」的各类数据条数，用于分析识别渠道的贡献占比
        if !session.bills.isEmpty { UsageAnalytics.logAdd("bill", source: "recognition") }
        if session.todo != nil { UsageAnalytics.logAdd("todo", source: "recognition") }
        if !session.foods.isEmpty { UsageAnalytics.logAdd("food", source: "recognition") }
        if session.health != nil { UsageAnalytics.logAdd("health", source: "recognition") }
        // 识别结果自动入库后，触发防抖同步，尽快把新记录推上云端。
        // skipCloudSync=true（如 Siri/后台 Intent 在主线程跑 perform）时跳过：避免在主线程
        // 发起云端 await 把主 App 的 UI 线程锁住导致首页卡死；云同步留给 App 回前台统一做。
        if !skipCloudSync {
            CloudSyncManager.shared.syncAfterLocalChange(context: context)
        }
        return session
    }

    /// 兜底：把「零金额且形态像票据」的 bill 降级为 todo。
    /// 解决电影票/演出票/机票等被误判为账单（截图无本单金额）的问题——
    /// 这类截图有影院/座位/时间但无实付金额，应按日程待办处理而非账单。
    /// 触发条件：amount <= 0（无本单实付）且商户/分类/备注含票据关键词且不含支付上下文关键词。
    static func downgradeTicketBills(_ input: RecognitionResult) -> RecognitionResult {
        let ticketKeywords = ["电影", "影院", "影城", "剧院", "演出", "演唱会", "音乐会",
                              "话剧", "歌剧", "歌舞剧", "机票", "航班", "登机", "值机",
                              "火车票", "高铁", "高铁票", "门票", "景区", "乐园",
                              "观影", "取票", "扫码入场", "电影票", "演出票", "入场券", "观影凭证"]
        // 支付上下文关键词：仅这些才算"本单已支付"，广告里的"¥/元起"不算（避免误判电影票）。
        let paymentKeywords = ["支付", "付款", "实付", "已付", "微信支付", "支付宝",
                               "总计", "合计", "订单金额", "收款", "转账", "退款"]

        var convertedTodos: [TodoPayload] = []
        var keptBills: [BillPayload] = []

        for b in input.billList {
            let amount = b.amount ?? 0
            let blob = "\(b.merchant ?? "") \(b.category ?? "") \(b.note ?? "")".lowercased()
            let looksLikeTicket = ticketKeywords.contains { blob.contains($0) }
            let hasPayment = paymentKeywords.contains { blob.contains($0) }
            // 金额 <= 0（无本单实付）且像票据且不含支付关键词 → 降级为待办
            if amount <= 0, looksLikeTicket, !hasPayment {
                // 标题压缩：优先提取片名/演出名，避免「影院名 片名 场次 座位」连成一大串；
                // 完整详情（含场次/座位/票价）进备注（ReminderNote），不上卡片。
                let rawTitle = b.merchant ?? b.category ?? "待办事项"
                let title = RecognizeService.compactTitle(rawTitle)
                convertedTodos.append(TodoPayload(
                    title: title,
                    due: b.time,
                    repeatRule: nil,
                    priority: "medium",
                    action: "create",
                    targetTitle: nil
                ))
                continue
            }
            keptBills.append(b)
        }

        // 没有任何可降级项 → 原样返回，零开销
        if convertedTodos.isEmpty { return input }

        let newBills = keptBills.isEmpty ? nil : keptBills
        let newTodos = (input.todos ?? []) + convertedTodos
        var newTypes = input.types ?? []
        if !newTypes.contains("todo") { newTypes.append("todo") }
        // 账单全部被降级且无既有账单 → 移除 bill 标记，避免生成空账单卡片
        if keptBills.isEmpty, let idx = newTypes.firstIndex(of: "bill") { newTypes.remove(at: idx) }

        return RecognitionResult(
            types: newTypes,
            confidence: input.confidence,
            bill: nil,
            bills: newBills,
            food: input.food,
            foods: input.foods,
            todo: nil,
            todos: newTodos.isEmpty ? nil : newTodos,
            health: input.health,
            healths: input.healths
        )
    }

    /// 食物名「退化补刀」后处理：云端视觉模型（尤其端侧 LLM 不可用时回落的 GLM）常把
    /// 「燕麦粥 / 皮蛋瘦肉粥」这类具体食物名退化成泛称「粥」，导致营养被错配成「粥」（46kcal）
    /// 严重低估。本地 vN seed 虽已补齐精确长词，但云端这条路不经过本地匹配护栏。
    ///
    /// 策略：用本地 OCR 原文补刀——若云端给的食物名是「泛称」（粥/炒饭/面条/米饭/汤…），
    /// 且 OCR 原文里存在该泛称的「具体前缀」（如「燕麦粥」以「粥」结尾），且本地库确有这个
    /// 具体词的精确营养，就把食物名升级回具体词并从本地库取精确营养回填（保留云端给的
    /// 重量/餐次/份量）。无对应具体词则不改动，零误伤。
    ///
    /// 仅当本地库确实存在该具体词才升级（不会无中生有）。
    static func upgradeFoodNames(_ input: RecognitionResult, ocrText: String, in context: ModelContext) -> RecognitionResult {
        // 泛称集合：这些短词在本地库里是「兜底碎片」，云端退化后需回查具体长词。
        let genericNames = ["粥", "炒饭", "米饭", "面条", "汤", "包子", "饺子", "馒头", "饼", "沙拉", "炒菜", "盖饭", "粉"]
        let blob = ocrText
        // 在 OCR 原文里找「以泛称结尾的具体食物词」（如「燕麦粥」含「粥」且比泛称更长更具体）。
        func concretize(_ generic: String) -> String? {
            // 取 OCR 中出现的、以该泛称结尾、且长度大于泛称的词。
            // 简单窗口扫描：2~8 字，结尾片段恰为 generic，整体在本地库有精确匹配。
            let maxLen = 8
            for len in (generic.count + 1)...maxLen {
                // 遍历原文，找所有长度=len 且 suffix==generic 的子串
                let chars = Array(blob)
                guard len <= chars.count else { break }
                for start in 0...(chars.count - len) {
                    let sub = String(chars[start..<start + len])
                    guard sub.hasSuffix(generic) else { continue }
                    // 具体词必须在本地库有精确 FoodMeta（builtin 或 cloud 沉淀）。
                    if FoodMetaStore.peek(name: sub, in: context) != nil {
                        return sub
                    }
                }
            }
            return nil
        }

        // 泛称升级：库命中具体词 → 用本地精确营养回填（独立函数，避免大字面量触发 type-check 超时）
        func buildUpgradedPayload(specific: String, ref: FoodRef, f: FoodPayload, ratio: Double) -> FoodPayload {
            let cal = ref.kcal * ratio
            let pro = ref.protein * ratio
            let car = ref.carbs * ratio
            let fat = ref.fat * ratio
            let fib = ref.fiber * ratio
            let sug = ref.sugar * ratio
            let sod = ref.sodium * ratio
            return FoodPayload(name: specific, calories: cal, protein: pro, carbs: car, fat: fat,
                               fiber: fib, sugar: sug, sodium: sod, portion: f.portion, meal: f.meal,
                               date: f.date, action: f.action, targetTitle: f.targetTitle, weightGram: f.weightGram)
        }
        // 泛称升级：库有具体词但 match 失败（极端竞态）→ 仅改名，营养用云端原值
        func buildRenamedPayload(specific: String, f: FoodPayload) -> FoodPayload {
            return FoodPayload(name: specific, calories: f.calories, protein: f.protein, carbs: f.carbs, fat: f.fat,
                               fiber: f.fiber, sugar: f.sugar, sodium: f.sodium, portion: f.portion, meal: f.meal,
                               date: f.date, action: f.action, targetTitle: f.targetTitle, weightGram: f.weightGram)
        }
        func upgrade(_ f: FoodPayload) -> FoodPayload {
            guard let name = f.name, !name.isEmpty else { return f }
            // 已经是具体词（不在泛称表里）则不处理。
            guard genericNames.contains(name) else { return f }
            guard let specific = concretize(name) else { return f }
            // 用本地精确营养回填（云端给的 weightGram/meal/portion 保留）。
            if let ref = NutritionLibrary.shared.match(specific, in: context) {
                let ratio = (f.weightGram ?? 100) / 100.0
                return buildUpgradedPayload(specific: specific, ref: ref, f: f, ratio: ratio)
            }
            // 库有具体词但 match 失败（极端竞态）→ 仅改名，营养用云端原值。
            return buildRenamedPayload(specific: specific, f: f)
        }

        let newFood = input.food.map(upgrade)
        let newFoods = input.foods?.map(upgrade)
        // 没有任何食物 → 原样返回（零开销）。
        if input.food == nil, input.foods == nil { return input }

        return RecognitionResult(
            types: input.types,
            confidence: input.confidence,
            bill: input.bill,
            bills: input.bills,
            food: newFood,
            foods: newFoods,
            todo: input.todo,
            todos: input.todos,
            health: input.health,
            healths: input.healths
        )
    }

/// 识别完成后的统一处理入口：按「来源 × 类别」二维设置（ImageAutoRecogSettings.mode(for:source:)）
/// 把每个命中类别分流到 自动保存 / 确认后再保存，最终组装成一条「识别结果」气泡消息插入对话流。
///
/// 行为（known = 命中的已知类别 bill/todo/food/health；sourceKey = image / text）：
/// - 自动保存类别：直接入库，卡片进入「已保存态」（持有真实模型 syncId，与模块页双向同步）。
/// - 确认后再保存类别：不入库，卡片进入「待确认态」，由用户点「保存」才 applyAndSave 入库。
/// 全部命中类别都无有效处理、或全部未识别 → 不插入消息（.nothing）。
    ///
    /// 重复守卫：有图且命中历史指纹时，把原本要「自动保存」的类别降级为「待确认」，
    /// 强制用户确认，避免无感重复入库（与旧版弹确认页警告等效，但统一收敛到对话气泡）。
    static func processRecognition(result: RecognitionResult, rawText: String,
                                   image: UIImage?, context: ModelContext,
                                   source: RecognitionSource = .cloud,
                                   entryOrigin: String = "image",
                                   screenshotShortcut: Bool = false,
                                   presavedImageName: String? = nil,
                                   forceAutoSave: Bool = false,
                                   skipCloudSync: Bool = false) async -> RecognitionOutcome {
        let sourceKey = (entryOrigin == "image") ? "image" : "text"
        let types = result.types ?? []
        let known = ImageAutoRecogSettings.knownTypes.filter { types.contains($0) }

        // 未识别出任何已知类别 / 全部命中类别都无有效处理 → 不插入消息
        guard !known.isEmpty else { return .nothing }

        let modes = Dictionary(uniqueKeysWithValues: known.map { ($0, ImageAutoRecogSettings.mode(for: $0, source: sourceKey)) })
        // forceAutoSave（如 Siri 后台「直接记一笔」来源）：无视设置页的 pending/discard，
        // 全部类别按自动保存处理，保证「说一句话就记下来」的核心体验不被 pending 卡住。
        let saveTypes = forceAutoSave ? Set(known) : Set(known.filter { modes[$0] == .autoSave })
        let pendingTypes = forceAutoSave ? Set<String>() : Set(known.filter { modes[$0] == .pending })
        guard !saveTypes.isEmpty || !pendingTypes.isEmpty else { return .nothing }

        // 重复指纹：命中历史指纹时**不阻断入库**（与 DuplicateStore 顶部注释一致），
        // 而是照常自动保存，仅在对话开场白带「疑似之前记过」轻提示，由用户决定保留/删除。
        var duplicateHint: String? = nil
        if let img = image, let fp = ImageHasher.fingerprint(img) {
            if let existing = DuplicateStore.match(fp.hash, ratio: fp.ratio) {
                duplicateHint = existing.summary
            } else {
                DuplicateStore.add(DuplicateEntry(hashD: fp.hash, ratio: fp.ratio, recognizedAt: .now,
                                                  types: known.joined(separator: ","),
                                                  summary: RecognitionSaver.summary(of: result)))
            }
        }

        // 自动保存类别：入库并携带真实 syncId（重复命中也不降级，仍自动保存）
        var savedItems: [RecognitionItem] = []
        if !saveTypes.isEmpty {
            let session = autoSave(result: result, rawText: rawText, image: image, context: context,
                                   source: source, allowedTypes: saveTypes, entryOrigin: entryOrigin,
                                   screenshotShortcut: screenshotShortcut,
                                   presavedImageName: presavedImageName, skipCloudSync: skipCloudSync,
                                   duplicateHint: duplicateHint.map {
                                       DuplicateHint(recognizedAt: .now, summary: $0,
                                                     existingTypes: known.joined(separator: ","))
                                   })
            savedItems = session.savedItems
            performSilentSideEffects(session: session, savedTypes: saveTypes)
        }

        // 待确认类别：未入库卡片（沿用自动保存路径已落盘的原图 presavedImageName，照片进备注）
        let pendingItems = buildPendingItems(from: result, source: sourceKey, allowed: pendingTypes,
                                             recogSource: RecogSource.raw(from: source),
                                             imageName: presavedImageName)

        let items = savedItems + pendingItems
        guard !items.isEmpty else { return .nothing }

        let msgs = insertRecognitionGroup(types: known, source: sourceKey,
                                          autoSaved: !savedItems.isEmpty, items: items,
                                          context: context, duplicateHint: duplicateHint)
        // 识别落地（自动保存/待确认卡片）后刷新桌面小组件，避免 widget 停在旧快照/空态
        WidgetSnapshot.refreshAfterWrite()
        return .inserted(msgs)
    }

    // MARK: - 对话气泡化：统一「先文字、后逐张独立卡片」

    /// 把一组识别卡片插入对话流为「1 条文字开场白 + N 条独立卡片气泡」。
    /// 文字永远只有一条、且 createdAt 早于所有卡片，保证「好记AI先发文字 → 再发卡片；
    /// 一次识别多卡时文字仍只一条」。
    /// - Parameters:
    ///   - autoSaved: 本组是否含「已保存」类别（决定开场白措辞）。
    ///   - items: 单卡数组；每张生成一条独立气泡消息，payload.items 只含该卡。
    /// - Returns: 插入的消息数组（[0]=文字，[1...]=卡片）；空 items 返回空数组。
    static func insertRecognitionGroup(types: [String], source: String, autoSaved: Bool,
                                       items: [RecognitionItem], context: ModelContext,
                                       duplicateHint: String? = nil) -> [ChatMessage] {
        guard !items.isEmpty else { return [] }
        let hasPending = items.contains { $0.syncId == nil }
        let base = Date()
        var opener = recognitionOpener(types: types, autoSaved: autoSaved, hasPending: hasPending)
        // 方案 X：疑似重复但已自动保存时，开场白追加轻提示，由用户自行判断是否删除
        if let dup = duplicateHint, !dup.isEmpty {
            opener += "\n⚠️ 这张图疑似之前记过（原记录：\(dup)），如果重复了你可以直接删掉这条记录～"
        }
        let textMsg = ChatMessage(role: .ai, text: opener, createdAt: base)
        context.insert(textMsg)
        var msgs: [ChatMessage] = [textMsg]
        for (i, item) in items.enumerated() {
            let payload = RecognitionResultPayload(types: types, source: source,
                                                   autoSaved: item.syncId != nil, items: [item])
            let cardMsg = ChatMessage(role: .ai, text: encodeRecognitionPayload(payload),
                                      createdAt: base.addingTimeInterval(0.1 * Double(i + 1)))
            context.insert(cardMsg)
            msgs.append(cardMsg)
        }
        // 与 ChatView.send() 保持一致：主动 save 让 SwiftData 立即广播
        // NSManagedObjectContextDidSaveNotification，ChatView 的 onReceive 会立即
        // fetchMessages() 刷新气泡，避免识别结果依赖不定时的 autosave 而延迟/不出现。
        try? context.save()
        // 主动广播滚动信号（AIA.chatScrollToBottom），Cover 拍照/相册/截屏/ShareExtension
        // /语音等所有入口——让 ChatView 在刷新后立即多段校正滚动，对抗识别卡片异步高度。
        NotificationCenter.default.post(name: Notification.Name("AIA.chatScrollToBottom"), object: nil)
        return msgs
    }

        /// 开场白措辞：按「识别类型 × 是否含自动保存」动态生成。
        /// 单类型逐一定制（活泼且准确对应业务语义），多类型/未知类型用兜底文案。
    /// 识别开场白的全部话术前缀（与 ResultRowCard.removePairedOpener 同源）。
    /// 用于渲染层识别「这是一条识别开场白」——只有配对的识别卡片气泡存在时才显示，
    /// 否则（卡片被删而开场白残留）应作为空壳隐藏，避免退化成「小圆点」。
    static let recognitionOpenerPrefixes: [String] = chatConfirmOpeners + [
        "帮你把这笔账记好啦", "这顿都帮你记上啦", "给你安排上啦", "健康数据收到啦",
        "测到些健康数据", "我已帮你自动保存部分内容", "搞定啦，我已自动帮你保存",
        "识别到以下内容", "识别到账单信息", "看看这顿吃了啥",
        "给你记了待办", "识别到以下信息"
    ]

    /// 判断一条 AI 消息是否为「识别结果开场白」。
    static func isRecognitionOpener(_ text: String) -> Bool {
        recognitionOpenerPrefixes.contains { text.hasPrefix($0) }
    }

    /// 判断某条开场白消息之后（createdAt 更大）是否仍存在配对的识别卡片气泡。
    /// 依据 insertRecognitionGroup：开场白 createdAt 严格早于其所有卡片，故只看「之后」即可。
    /// 无配对卡片 → 该开场白为空壳，应隐藏。
    static func hasPairedCard(after opener: ChatMessage, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { !$0.syncDeleted },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        guard let all = try? context.fetch(descriptor) else { return false }
        var reachedOpener = false
        for m in all {
            if m.persistentModelID == opener.persistentModelID {
                reachedOpener = true
                continue
            }
            guard reachedOpener else { continue }
            // 已经越过开场白，遇到下一条 AI 文本（非卡片）说明本组已结束，且没卡片 → 无配对
            if m.text.hasPrefix(RECOGNITION_RESULT_PREFIX) { return true }
            if m.role == .ai, !m.text.hasPrefix(RECOGNITION_RESULT_PREFIX) { return false }
        }
        return false
    }

    private static func recognitionOpener(types: [String], autoSaved: Bool, hasPending: Bool) -> String {
        // 单类型：逐一定制，活泼自然且准确对应业务语义
        if types.count == 1 {
            switch (types[0], autoSaved) {
            case ("bill",   true):  return "帮你把这笔账记好啦，已自动保存👇"
            case ("bill",   false): return "识别到账单信息，需你确认后点击✅才会保存哦👇"
            case ("food",   true):  return "这顿都帮你记上啦，已自动保存👇"
            case ("food",   false): return "看看这顿吃了啥，需你确认后点击✅才会保存哦👇"
            case ("todo",   true):  return "给你安排上啦，已自动保存👇"
            case ("todo",   false): return "给你记了待办，需你确认后点击✅才会保存哦👇"
            case ("health", true):  return "健康数据收到啦，已自动保存👇"
            case ("health", false): return "测到些健康数据，需你确认后点击✅才会保存哦👇"
            default: break
            }
        }
        // 多类型 / 未知类型兜底
        switch (autoSaved, hasPending) {
        case (true, true):   return "我已帮你自动保存部分内容，下方卡片的信息需你确认后，点击✅才会保存哦👇"
        case (true, false):  return "搞定啦，我已自动帮你保存以下内容 ，如果你想修改，可点击卡片进行修改哦👇"
        case (false, true):  return "识别到以下内容，卡片的信息需你确认后，点击✅才会保存哦👇"
        case (false, false): return "识别到以下信息，需你确认后，点击✅才会保存哦👇"
        }
    }

    // MARK: - 对话气泡化：确认页回插（关键决策 4 接线）

    /// 确认页「保存」后回插「已保存态」气泡：卡片用真实模型的 syncId（来自 session.savedItems），
    /// 与模块页 @Query(!syncDeleted) 指向同一实例，任一边的改/删响应式刷新。
    @discardableResult
    static func insertSavedBubble(session: SavedSession, context: ModelContext) -> [ChatMessage] {
        let items = session.savedItems
        // 空 items 不插气泡，否则渲染成「（无识别结果）」空壳
        guard !items.isEmpty else { return [] }
        let types = Array(Set(items.map { $0.type.rawValue }))
        return insertRecognitionGroup(types: types, source: "image", autoSaved: true, items: items, context: context)
    }

/// 确认页「返回 / 不保存」后回插「待确认态」气泡：所有项 syncId=nil（未入库），
/// 用户之后在气泡里点「保存」才真正入库。
/// - Parameter recogSource: 识别引擎来源 rawValue（"local"/"cloudText"/"cloud"），用于卡片顶部展示。
@discardableResult
static func insertPendingBubble(result: RecognitionResult, context: ModelContext,
                                recogSource: String? = nil,
                                imageName: String? = nil) -> [ChatMessage] {
    let types = result.types ?? []
    let known = ImageAutoRecogSettings.knownTypes.filter { types.contains($0) }
    let allowed = Set(known)
    let items = buildPendingItems(from: result, source: "image", allowed: allowed, recogSource: recogSource,
                                  imageName: imageName)
    // 全部类别被设为「丢弃」时 items 为空，不插空气泡
    guard !items.isEmpty else { return [] }
    return insertRecognitionGroup(types: Array(allowed), source: "image", autoSaved: false, items: items, context: context)
}

    /// 静默保存路径的副作用钩子。
    /// 注意：App 不回写 HealthKit（用户 2026-08-13 明确禁止），原 HealthKit 同步写入已移除；
    /// 此处保留函数壳以便调用方签名不变，后续如需新增「本地持久化」类副作用可在此扩展。
    private static func performSilentSideEffects(session: SavedSession, savedTypes: Set<String>) {
        // 不向 HealthKit 写数据（只读）。
    }

    /// 生成人类可读的识别摘要（用于重复警告横幅）。
    nonisolated static func summary(of result: RecognitionResult) -> String {
        let types = result.types ?? []
        var parts: [String] = []
        if types.contains("bill") {
            let list = result.billList
            if !list.isEmpty {
                let s = list.compactMap { b -> String? in
                    let amt = b.amount.map { "¥\($0)" } ?? ""
                    let m = b.merchant ?? ""
                    return "\(amt) \(m)".trimmingCharacters(in: .whitespaces)
                }.joined(separator: " · ")
                parts.append("账单 \(s)")
            }
        }
        if types.contains("todo"), !result.todoList.isEmpty {
            let s = result.todoList.compactMap { $0.title }.joined(separator: " · ")
            if !s.isEmpty { parts.append("待办 \(s)") }
        }
        if types.contains("food"), !result.foodList.isEmpty {
            let s = result.foodList.compactMap { $0.name }.joined(separator: " · ")
            if !s.isEmpty { parts.append("食物 \(s)") }
        }
        if types.contains("health"), !result.healthList.isEmpty {
            let s = result.healthList.compactMap { "\($0.metric ?? "")\($0.value ?? "")\($0.unit ?? "")" }.joined(separator: " · ")
            if !s.isEmpty { parts.append("健康 \(s)") }
        }
        return parts.isEmpty ? "其他" : parts.joined(separator: " · ")
    }
}
