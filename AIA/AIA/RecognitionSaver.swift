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

enum RecognitionSaver {
    /// 从模型给的 due 字符串解析日期（兼容 ISO8601 / yyyy-MM-dd / 含时间串），失败回退到今天 8:00。
    static func dueDate(from dueString: String?) -> Date {
        let calendar = Calendar.current
        let todayAtEight = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
        guard let dueString = dueString, !dueString.isEmpty else { return todayAtEight }

        var baseDate: Date?
        if let d = ISO8601DateFormatter().date(from: dueString) {
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
    @MainActor
    static func autoSave(result: RecognitionResult, rawText: String, image: UIImage?, context: ModelContext) -> SavedSession {
        let session = SavedSession(result: result, rawText: rawText, sourceImage: image, context: context)
        let imageName = LocalImageStore.save(image)
        session.imageName = imageName
        let types = result.types ?? []

        if types.contains("bill") {
            for b in result.billList {
                guard let amt = b.amount,
                      let merchant = b.merchant, !merchant.isEmpty else { continue }
                // 时间解析失败时用今天零点（绝不 .now，否则截图时间 15:41 会污染支付记录）
                let fallbackTime = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: .now) ?? .now
                let time = RecognitionResult.date(from: b.time) ?? fallbackTime
                let income = isIncomeCategory(b.category ?? "")
                let bill = Bill(merchant: merchant, amount: amt,
                                category: b.category ?? "", time: time,
                                isIncome: income, imageName: imageName)
                context.insert(bill)
                // 沉淀商户经验：下次同类账单本地直接复用分类，减少 AI 调用
                if let cat = b.category, !cat.isEmpty {
                    MerchantMetaStore.upsert(merchant: merchant, category: cat, isIncome: income, in: context)
                }
                session.bills.append(bill)
            }
        }

        if types.contains("todo"),
           let t = result.todo, let title = t.title, !title.isEmpty {
            let due = dueDate(from: t.due)
            let r = Reminder(title: title, due: due, imageName: imageName)
            DefaultReminderSettings.shared.apply(to: r)
            context.insert(r)
            ReminderNotificationManager.schedule(r)   // 自动入库即排程，用户不修改也提醒
            session.todo = r
        }

        if types.contains("food"),
           let f = result.food, let name = f.name, !name.isEmpty {
            let weight = weightFromPortion(f.portion)
            let ratio = weight / 100
            let baseCal = f.calories ?? 0
            let basePro = f.protein ?? 0
            let baseCar = f.carbs ?? 0
            let baseFat = f.fat ?? 0
            let entry = FoodEntry(name: name,
                                  calories: baseCal * ratio,
                                  protein: basePro * ratio,
                                  carbs: baseCar * ratio,
                                  fat: baseFat * ratio,
                                  portion: "\(Int(weight))克",
                                  meal: defaultMeal(for: .now),
                                  weightGram: weight,
                                  baseCalories: baseCal,
                                  baseProtein: basePro,
                                  baseCarbs: baseCar,
                                  baseFat: baseFat,
                                  imageName: imageName)
            context.insert(entry)
            session.food = entry
            // 卡路里同步放确认时（applyAndSave），避免自动阶段重复累加
        }

        if types.contains("health"),
           let h = result.health, let metricName = h.metric, !metricName.isEmpty {
            let metric = HealthMetric(metric: metricName, value: h.value ?? "",
                                      unit: h.unit ?? "", imageName: imageName)
            context.insert(metric)
            session.health = metric
            // 健康指标同步放确认时
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

    /// 识别完成后的「入库 + 疑似重复提示」决策：
    /// - 图片类：先算 aHash 指纹，与历史指纹比对。无论是否命中重复都**正常 autoSave 入库**
    ///   （命中重复时把原记录摘要挂到 session.duplicateHint，确认页顶部显示「似乎已记录过」警告，
    ///   由用户决定编辑/保留/删除，不再硬拦）；未命中正常登记指纹。
    /// - 无图类（语音等）：直接 autoSave（无图则无指纹可比，永不走重复分支）。
    @MainActor
    static func saveOrCheckDuplicate(result: RecognitionResult, rawText: String,
                                     image: UIImage?, context: ModelContext,
                                     source: RecognizeService.RecognitionSource = .cloud) -> SaveDecision {
        if let img = image, let hash = ImageHasher.aHash(img) {
            let existing = DuplicateStore.match(hash)
            let session = autoSave(result: result, rawText: rawText, image: image, context: context)
            session.source = source
            DuplicateStore.add(DuplicateEntry(hash: hash, recognizedAt: .now,
                                              types: (result.types ?? []).joined(separator: ","),
                                              summary: summary(of: result)))
            if let existing {
                session.duplicateHint = DuplicateHint(recognizedAt: existing.recognizedAt,
                                                      summary: existing.summary,
                                                      existingTypes: existing.types)
            }
            return .saved(session)
        }
        let session = autoSave(result: result, rawText: rawText, image: image, context: context)
        session.source = source
        return .saved(session)
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
        if types.contains("todo"), let t = result.todo, let title = t.title {
            parts.append("待办 \(title)")
        }
        if types.contains("food"), let f = result.food, let name = f.name {
            parts.append("食物 \(name)")
        }
        if types.contains("health"), let h = result.health, let metric = h.metric {
            parts.append("健康 \(metric)")
        }
        return parts.isEmpty ? "其他" : parts.joined(separator: " · ")
    }
}
