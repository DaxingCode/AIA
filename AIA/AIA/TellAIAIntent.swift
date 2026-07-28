// TellAIAIntent.swift
// 语音 / 一句话记账：配合快捷指令 + Siri，「跟阿宝说 午饭35」后台直接记一笔
// （账单 + 食物热量营养），「跟阿宝说 25日提醒我交报表」直接建待办提醒。
//
// 设计：
//  - openAppWhenRun = false：Siri 后台运行，不弹 UI，做到「直接记一笔」。
//  - 复用主 App 的 RecognizeService.parseText（云端 /recognize 文本解析）+ RecognitionSaver.autoSave，
//    与截屏识别同一套入库逻辑，确保账单/食物/待办都正确写入。
//  - App Intents 后台运行时在 App 沙盒内，用 AppPersistence 打开同一个 SwiftData 库。
//  - 返回 Siri 播报对话框，告知记录结果。
import AppIntents
import SwiftData
import UIKit

@available(iOS 17, *)
struct TellAIAIntent: AppIntent {
    static var title: LocalizedStringResource = "用阿宝记"
    static var description = IntentDescription("一句话记账或设提醒：如「午饭35」「25日提醒我交报表」。")
    static var openAppWhenRun: Bool = false   // 后台静默运行，直接记一笔、不弹 UI
    static var parameterSummary: some ParameterSummary {
        Summary("用阿宝记 \(\.$phrase)")
    }

    @Parameter(title: "内容", description: "想记录的内容，如 午饭35 / 25日提醒我交报表")
    var phrase: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 复用 App 主容器而非自建新容器：避免「两个 ModelContainer 同时操作同一 SQLite」
        // 导致 WAL 锁死（App 打开时卡住不动）。
        guard let container = AppDelegate.sharedContainer else {
            return .result(dialog: "App 还没准备好，稍后再试。")
        }
        let context = container.mainContext

        // 饮水快捷解析（零网络，与聊天共用 WaterIntakeParser）。
        let waterParsed = WaterIntakeParser.parse(phrase)
        // 本地快析（只算一次）：纯饮水句据此判断是否「纯水」从而直接记水退出。
        let localResult = LocalQuickParse.parse(phrase, in: context)

        // 纯饮水句：WaterIntakeParser 命中 且 本地快析无任何账单/食物/待办/健康类型
        // → 直接记水并退出，不劳云端，行为最稳（消除「喝了100毫升水」被云端误记成账单）。
        if let (ml, display) = waterParsed, localResult == nil {
            if WaterIntakeParser.checkDuplicateAndRegister(phrase, type: "water") {
                return .result(dialog: "这杯水我刚记过啦～")
            }
            let meal = WaterIntakeParser.mealFromText(phrase) ?? RecognitionSaver.defaultMeal(for: .now)
            let entry = FoodEntry(
                name: "饮用水",
                calories: 0, protein: 0, carbs: 0, fat: 0,
                fiber: 0, sugar: 0, sodium: 0,
                waterIntake: ml,
                portion: display,
                meal: meal,
                imageName: nil
            )
            context.insert(entry)
            try? context.save()
            CloudSyncManager.shared.syncAfterLocalChange(context: context)
            return .result(dialog: "已记录：饮水 \(Int(ml)) 毫升")
        }

        // 复合句里的水（如「喝了水，午饭35元」）：记水但不提前退出，下面与账单一起返回。
        var waterSummary: String?
        if let (ml, display) = waterParsed, localResult != nil {
            if !WaterIntakeParser.checkDuplicateAndRegister(phrase, type: "water") {
                let meal = WaterIntakeParser.mealFromText(phrase) ?? RecognitionSaver.defaultMeal(for: .now)
                let entry = FoodEntry(
                    name: "饮用水",
                    calories: 0, protein: 0, carbs: 0, fat: 0,
                    fiber: 0, sugar: 0, sodium: 0,
                    waterIntake: ml,
                    portion: display,
                    meal: meal,
                    imageName: nil
                )
                context.insert(entry)
                try? context.save()
                CloudSyncManager.shared.syncAfterLocalChange(context: context)
                waterSummary = "饮水 \(Int(ml)) 毫升"
            }
        }

        // 1. 本地快速解析优先（毫秒级、零网络）；识别不了再走云端 LLM
        let result: RecognitionResult
        if let localResult {
            result = localResult
        } else {
            do {
                result = try await RecognizeService.parseText(phrase).result
            } catch {
                return .result(dialog: "没连上，稍后再试？或者打开 App 手动记。")
            }
        }

        let types = result.types ?? []
        guard !types.isEmpty, !types.contains("none") else {
            // 用户可能只说了模块名（如「记账、记饮食、记待办」），没有具体内容可记
            if let ws = waterSummary {
                return .result(dialog: "已记录：\(ws)")
            }
            let hints = Self.moduleHints(in: phrase)
            if !hints.isEmpty {
                return .result(dialog: "想记\(hints.joined(separator: "、"))？打开阿宝，用语音或截图就能记啦。")
            }
            return .result(dialog: "没听懂，换个说法试试？比如「午饭35」或「25日提醒我交报表」。")
        }

        // 2. 直接入库（账单 + 食物热量营养 + 待办 + 健康），与截屏识别同一逻辑
        let session = RecognitionSaver.autoSave(result: result, rawText: phrase, image: nil, context: context)

        // 3. 食物热量同步到 HealthKit（无权限时内部自动跳过，不崩）
        if session.foodCaloriesTotal > 0 {
            HealthManager.shared.saveCaloriesConsumed(session.foodCaloriesTotal, date: .now)
        }

        let summary = RecognitionSaver.summary(of: result)
        // 显式保存，确保数据在 Intent 返回前已刷入磁盘，避免 autosave 竞态
        try? context.save()

        if let ws = waterSummary {
            return .result(dialog: "已记录：\(summary) · \(ws)")
        }
        return .result(dialog: "已记录：\(summary)")
    }

    /// 从用户口语里提取提到的模块（用于「叫阿宝 记账、记饮食、记待办」这类只说模块名、没给具体内容的情况）
    private static func moduleHints(in text: String) -> [String] {
        var out: [String] = []
        if text.contains("账") || text.contains("记账") || text.contains("花") { out.append("账单") }
        if text.contains("饮食") || text.contains("吃") || text.contains("饭") || text.contains("喝") { out.append("饮食") }
        if text.contains("待办") || text.contains("提醒") || text.contains("任务") { out.append("待办") }
        if text.contains("健康") || text.contains("体重") || text.contains("运动") { out.append("健康") }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
