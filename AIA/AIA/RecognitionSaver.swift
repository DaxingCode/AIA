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

final class SavedSession: Identifiable {
    let id = UUID()
    let result: RecognitionResult
    let rawText: String
    let sourceImage: UIImage?
    /// 识别来源（本地 / 云端），确认页据此展示「本地AI识别 / 云端AI识别」标签。
    var source: RecognizeService.RecognitionSource = .cloud
    var imageName: String?
    var bills: [Bill] = []
    var todo: Reminder?
    var food: FoodEntry?
    /// 预存的全部食物记录（多食物场景确认页覆盖时需整组替换；food 恒为 foods.first）。
    var foods: [FoodEntry] = []
    var foodCaloriesTotal: Double = 0
    var health: HealthMetric?
    var recognition: RecognitionRecord?
    weak var context: ModelContext?

    /// 疑似重复提示（图片命中历史指纹但仍自动入库）。非 nil 表示这张图之前识别过，
    /// 确认页据此显示「似乎已记录过」警告，由用户决定编辑/保留/删除。
    var duplicateHint: DuplicateHint?

    init(result: RecognitionResult, rawText: String, sourceImage: UIImage?, context: ModelContext?,
         source: RecognizeService.RecognitionSource = .cloud) {
        self.result = result
        self.rawText = rawText
        self.sourceImage = sourceImage
        self.context = context
        self.source = source
    }
}

/// processRecognition 的处理结论，由调用方（首页截图 pending / 聊天 / 相册相机链路）消费：
/// - present：弹确认页（.saved 已预存 / .pending 未入库 / .duplicate 重复警告）。
/// - silentlySaved：已静默入库的类别（按 bill/todo/food/health 顺序）→ 调用方清 pending + 弹 toast 引导。
/// - nothing：按设置丢弃本次识别 → 调用方清 pending，不弹不存。
enum RecognitionOutcome {
    case present(RecognitionPresent)
    case silentlySaved([String])
    case nothing
}

enum RecognitionSaver {
    /// 从模型给的 due 字符串解析日期（兼容 ISO8601 / yyyy-MM-dd / 含时间串），失败回退到今天 8:00。
    static func dueDate(from dueString: String?) -> Date {
        let calendar = Calendar.current
        let todayAtEight = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
        guard let dueString = dueString, !dueString.isEmpty else { return todayAtEight }

        var baseDate: Date?
        let isoFmt = ISO8601DateFormatter(); isoFmt.timeZone = .current
        if let d = isoFmt.date(from: dueString) {
            baseDate = d
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            baseDate = f.date(from: dueString)
        }
        guard let date = baseDate else { return todayAtEight }

        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        let timePattern = #"(\d{1,2}):(\d{2})(?::(\d{2}))?"#
        if let range = dueString.range(of: timePattern, options: .regularExpression) {
            let parts = dueString[range].components(separatedBy: ":").compactMap { Int($0) }
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
    static func defaultMeal(for date: Date) -> String {
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

    /// 从模型给的份量字符串解析重量（克），默认 100。
    static func weightFromPortion(_ portion: String?) -> Double {
        let p = portion ?? "100克"
        if let match = p.range(of: #"\d+"#, options: .regularExpression) {
            return Double(p[match]) ?? 100
        }
        return 100
    }

    /// 识别完成后立即入库，返回已存记录引用（供确认页覆盖更新）。
    /// - Parameter allowedTypes: 非 nil 时只入库这些类别（按类别「自动保存」设置过滤）；
    ///   nil = 全部入库（确认页点「存入」的旧路径，行为不变）。
    @MainActor
    static func autoSave(result: RecognitionResult, rawText: String, image: UIImage?, context: ModelContext,
                         source: RecognizeService.RecognitionSource = .cloud,
                         allowedTypes: Set<String>? = nil) -> SavedSession {
        let session = SavedSession(result: result, rawText: rawText, sourceImage: image, context: context, source: source)
        let imageName = LocalImageStore.save(image)
        session.imageName = imageName
        let rawTypes = result.types ?? []
        let types = allowedTypes.map { allowed in rawTypes.filter { allowed.contains($0) } } ?? rawTypes

        if types.contains("bill") {
            for b in result.billList {
                guard let amt = b.amount else { continue }
                // 空商户兜底：用分类名或"账单"，绝不 continue（曾致 Siri 说"记下了"但账单未存）。
                let merchant = (b.merchant ?? "").isEmpty ? (b.category ?? "账单") : b.merchant!
                // 时间解析失败时用今天零点（绝不 .now，否则截图时间 15:41 会污染支付记录）
                let fallbackTime = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: .now) ?? .now
                let time = RecognitionResult.date(from: b.time) ?? fallbackTime
                // 方案2：模型自由文本分类归并到预设大类，保证分类明细页聚合一致
                let rawCategory = b.category ?? ""
                let normalizedCat = BillCategoryHelpers.normalizedCategory(rawCategory)
                // 收入判定基于原始分类（归一化可能把"报销"等并入"工资"，丢失关键词子串）
                let income = isIncomeCategory(rawCategory)
                let bill = Bill(merchant: merchant, amount: amt,
                                category: normalizedCat, time: time,
                                isIncome: income, imageName: imageName)
                context.insert(bill)
                session.bills.append(bill)
            }
        }

        if types.contains("todo") {
            for t in result.todoList {
                guard let title = t.title, !title.isEmpty, title.count >= 2 else { continue }
                let due = dueDate(from: t.due)
                let r = Reminder(title: title, due: due, imageName: imageName)
                DefaultReminderSettings.shared.apply(to: r)
                context.insert(r)
                ReminderNotificationManager.schedule(r)   // 自动入库即排程，用户不修改也提醒
                if session.todo == nil { session.todo = r }
            }
        }

        if types.contains("food") {
            var totalFoodCal: Double = 0
            for f in result.foodList {
                guard let name = f.name, !name.isEmpty else { continue }
                let weight = weightFromPortion(f.portion)
                let ratio = weight / 100
                let baseCal = f.calories ?? 0
                let basePro = f.protein ?? 0
                let baseCar = f.carbs ?? 0
                let baseFat = f.fat ?? 0

                // 校验：所有宏量为零 → 跳过保存空壳记录
                if baseCal > 0 || basePro > 0 || baseCar > 0 || baseFat > 0 {
                    let entry = FoodEntry(name: name,
                                          calories: baseCal * ratio,
                                          protein: basePro * ratio,
                                          carbs: baseCar * ratio,
                                          fat: baseFat * ratio,
                                          portion: "\(Int(weight))克",
                                          meal: f.meal ?? defaultMeal(for: .now),
                                          weightGram: weight,
                                          baseCalories: baseCal,
                                          baseProtein: basePro,
                                          baseCarbs: baseCar,
                                          baseFat: baseFat,
                                          imageName: imageName)
                    context.insert(entry)
                    totalFoodCal += baseCal * ratio
                    session.foods.append(entry)
                    if session.food == nil { session.food = entry }
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
                let metric = HealthMetric(metric: metricName, value: h.value ?? "",
                                          unit: h.unit ?? "", imageName: imageName)
                context.insert(metric)
                if session.health == nil { session.health = metric }
                // 健康指标同步放确认时
            }
        }

        if !types.isEmpty && !types.contains("none") {
            let rec = RecognitionRecord(recognizedAt: .now, rawText: rawText, types: types, imageName: imageName)
            context.insert(rec)
            session.recognition = rec
        }

        try? context.save()
        // 识别结果自动入库后，触发防抖同步，尽快把新记录推上云端
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        return session
    }

    /// 识别完成后的统一处理入口：按「图片自动识别」设置（ImageAutoRecogSettings，按类别
    /// 自动保存 / 自动弹出）决定 入库 与 弹确认页 的组合，返回 RecognitionOutcome 由调用方消费。
    ///
    /// 行为矩阵（known = 命中的已知类别 bill/todo/food/health）：
    /// - known 为空（none / 未识别）：维持现状 → .present(.pending)，弹「未识别」卡片，不入库。
    /// - 有类别 自动弹出=开：弹确认页。其中 自动保存=开 的类别先预存（.saved(session)，
    ///   确认页点「保存」覆盖）；自动保存=关 的类别不预存，点「存入」时才插入（applyAndSave 补插）。
    ///   若全部弹出类别都不预存 → 走原「先不入库」的 .pending / .duplicate 流程。
    /// - 全部类别 自动弹出=关：
    ///   - 有类别 自动保存=开 → 静默入库这些类别 → .silentlySaved（调用方清 pending + 弹 toast）。
    ///     例外：图片命中历史指纹（疑似重复）时升级为 .present(.saved)，弹确认页警告，防止无感重复入库。
    ///   - 全部 自动保存=关 → .nothing（丢弃本次识别，调用方清 pending）。
    /// - 无图类（语音等）：无指纹可比，永不走重复分支。
    @MainActor
    static func processRecognition(result: RecognitionResult, rawText: String,
                                   image: UIImage?, context: ModelContext,
                                   source: RecognizeService.RecognitionSource = .cloud) -> RecognitionOutcome {
        let types = result.types ?? []
        let known = ImageAutoRecogSettings.knownTypes.filter { types.contains($0) }

        // 未识别出已知类别：维持现状，弹「未识别」卡片，不入库。
        guard !known.isEmpty else {
            return .present(.pending(result, rawText: rawText, image: image, source: source))
        }

        let popupTypes = known.filter { ImageAutoRecogSettings.autoPopup(for: $0) }
        let saveTypes = Set(known.filter { ImageAutoRecogSettings.autoSave(for: $0) })

        // 全部命中类别既不自动保存也不弹出 → 丢弃本次识别
        if popupTypes.isEmpty && saveTypes.isEmpty { return .nothing }

        // 没有任何类别需要预存：沿用「先不入库，确认页点保存才入库」流程
        if saveTypes.isEmpty {
            if let img = image, let fp = ImageHasher.fingerprint(img),
               let existing = DuplicateStore.match(fp.hash, ratio: fp.ratio) {
                return .present(.duplicate(DuplicatePayload(result: result, rawText: rawText,
                                                            sourceImage: image,
                                                            hash: fp.hash,
                                                            ratio: fp.ratio,
                                                            recognizedAt: existing.recognizedAt,
                                                            summary: existing.summary,
                                                            existingTypes: existing.types)))
            }
            return .present(.pending(result, rawText: rawText, image: image, source: source))
        }

        // 有需要预存的类别：按 saveTypes 过滤入库（弹出类别里 自动保存=关 的留待确认页点「存入」再插）
        let session = autoSave(result: result, rawText: rawText, image: image, context: context,
                               source: source, allowedTypes: saveTypes)
        var duplicateHit = false
        if let img = image, let fp = ImageHasher.fingerprint(img) {
            if let existing = DuplicateStore.match(fp.hash, ratio: fp.ratio) {
                session.duplicateHint = DuplicateHint(recognizedAt: existing.recognizedAt,
                                                      summary: existing.summary,
                                                      existingTypes: existing.types)
                duplicateHit = true
            } else {
                // 登记指纹，供后续相同截图去重提示（仅新鲜图片登记一次）
                DuplicateStore.add(DuplicateEntry(hashD: fp.hash, ratio: fp.ratio, recognizedAt: .now,
                                                  types: known.joined(separator: ","),
                                                  summary: RecognitionSaver.summary(of: result)))
            }
        }

        // 任一类别要弹出，或静默路径撞上疑似重复（升级为弹页警告）→ 弹确认页
        if !popupTypes.isEmpty || duplicateHit {
            return .present(.saved(session))
        }

        // 静默保存：补上原本在确认页保存时才做的 HealthKit 副作用，调用方负责清 pending + toast
        performSilentSideEffects(session: session, savedTypes: saveTypes)
        let ordered = ImageAutoRecogSettings.knownTypes.filter { saveTypes.contains($0) }
        return .silentlySaved(ordered)
    }

    /// 静默保存路径的 HealthKit 同步（确认页路径由 applyAndSave 做，这里对齐补上）。
    @MainActor
    private static func performSilentSideEffects(session: SavedSession, savedTypes: Set<String>) {
        if savedTypes.contains("food"), session.foodCaloriesTotal > 0 {
            HealthManager.shared.saveCaloriesConsumed(session.foodCaloriesTotal, date: .now)
        }
        if savedTypes.contains("health"), let h = session.health, let v = Double(h.value), v > 0 {
            let name = h.metric
            if name.contains("体重") || name.lowercased().contains("weight") {
                HealthManager.shared.saveWeight(v)
            } else if name.contains("身高") || name.lowercased().contains("height") {
                HealthManager.shared.saveHeight(v)
            } else if name.contains("心率") || name.lowercased().contains("heart") {
                HealthManager.shared.saveHeartRate(v)
            }
        }
    }

    /// 生成人类可读的识别摘要（用于重复警告横幅）。
    static func summary(of result: RecognitionResult) -> String {
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
