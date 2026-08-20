// TellAIAIntent.swift
// 语音 / 一句话记账：配合快捷指令 + Siri，「跟好记AI说 午饭35」后台直接记一笔
// （账单 + 食物热量营养），「跟好记AI说 25日提醒我交报表」直接建待办提醒。
//
// 设计：
//  - openAppWhenRun = false：Siri 后台运行，不弹 UI，做到「直接记一笔」。
//  - 复用主 App 的 RecognizeService.parseText（云端 /recognize 文本解析）+
//    RecognitionSaver.processRecognition(forceAutoSave:) 统一水槽，
//    与对话页文字/语音记录同一套入库/分流逻辑（含周期待办、HealthKit 卡路里同步等）。
//  - forceAutoSave：Siri 来源无视设置页的 pending/discard，全部类别自动保存，
//    保证「说一句话就记下来」的核心体验（待确认/丢弃只由前台对话页走）。
//  - App Intents 后台运行时在 App 沙盒内，用 AppPersistence 打开同一个 SwiftData 库。
//  - 返回 Siri 播报对话框，告知记录结果。
import AppIntents
import SwiftData
import UIKit

@available(iOS 17, *)
struct TellAIAIntent: AppIntent {
    static var title: LocalizedStringResource = "快速记录"
    static var description = IntentDescription("一句话记账或设提醒：如「午饭35」「25日提醒我交报表」。")
    static var openAppWhenRun: Bool = false   // 后台静默运行，直接记一笔、不弹 UI
    static var parameterSummary: some ParameterSummary {
        Summary("快速记录 \(\.$phrase)")
    }

    @Parameter(title: "内容", description: "想记录的内容，如 午饭35 / 25日提醒我交报表")
    var phrase: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 根治首页卡死：
        // 1) 整条写流程放后台线程，使用【独立 ModelContext】；
        // 2) 关键：容器用 AppPersistence.makeSiriWriteContainer() —— 与主 App 的 sharedContainer
        //    是**不同实例**，SwiftData 的跨 context 合并（NSManagedObjectContextDidSaveNotification）
        //    按 container 的 parentContext 链传播，不同 container 之间不会自动合并。
        //    因此前台 @Query 完全不被这次写入惊动 → 不卡首页（无论 App 前台/后台/冷启都走它）。
        // 3) 数据回到前台靠 .siriDidSaveData 通知（或现有 sceneDidBecomeActive 同步）。
        // 闭包只返回 dialog 文案（String），外层统一包 .result，避免不透明返回类型在 detached 闭包里推断失败。
        let dialog: String = await Task.detached(priority: .userInitiated) { [phrase] in
            guard let container = AppPersistence.makeSiriWriteContainer() else {
                return "App 还没准备好，稍后再试。"
            }
            let context = ModelContext(container)   // 独立后台上下文，非 mainContext

            // 数据写入独立容器后，主线程广播让前台 @Query 刷新（跨容器不自动合并）。三处写路径共用。
            let notifySiriSaved = {
                _ = Task { @MainActor in
                    NotificationCenter.default.post(name: .siriDidSaveData, object: nil)
                }
            }

            // 饮水快捷解析（零网络，与聊天共用 WaterIntakeParser）。
            let waterParsed = WaterIntakeParser.parse(phrase)
            // 本地快析（只算一次）：纯饮水句据此判断是否「纯水」从而直接记水退出。
            let localResult = await LocalQuickParse.parse(phrase, in: context)

            // 纯饮水句：WaterIntakeParser 命中 且 本地快析无任何账单/食物/待办/健康类型
            // → 直接记水并退出，不劳云端，行为最稳（消除「喝了100毫升水」被云端误记成账单）。
            if let (ml, display) = waterParsed, localResult == nil {
                let dup = await MainActor.run { WaterIntakeParser.checkDuplicateAndRegister(phrase, type: "water") }
                if dup {
                    return "这杯水我刚记过啦～"
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
                notifySiriSaved()
                return "已记录：饮水 \(Int(ml)) 毫升"
            }

            // 复合句里的水（如「喝了水，午饭35元」）：记水但不提前退出，下面与账单一起返回。
            var waterSummary: String?
            if let (ml, display) = waterParsed, localResult != nil {
                let dup = await MainActor.run { WaterIntakeParser.checkDuplicateAndRegister(phrase, type: "water") }
                if !dup {
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
                    notifySiriSaved()
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
                    return "没连上，稍后再试？或者打开 App 手动记。"
                }
            }

            let types = result.types ?? []
            guard !types.isEmpty, !types.contains("none") else {
                // 用户可能只说了模块名（如「记账、记饮食、记待办」），没有具体内容可记
                if let ws = waterSummary {
                    return "已记录：\(ws)"
                }
                let hints = Self.moduleHints(in: phrase)
                if !hints.isEmpty {
                    return "想记\(hints.joined(separator: "、"))？打开小记，用语音或截图就能记啦。"
                }
                return "没听懂，换个说法试试？比如「午饭35」或「25日提醒我交报表」。"
            }

            // 2. 统一入库水槽：与对话页文字/语音记录同一套逻辑（含周期待办、HealthKit 卡路里同步）。
            //    forceAutoSave=true → 无视设置页 pending/discard，Siri「直接记一笔」永远存（待确认/丢弃只由前台走）。
            //    skipCloudSync=true → 不触发云端同步（App 回前台由 sceneDidBecomeActive 统一同步）。
            _ = await RecognitionSaver.processRecognition(
                result: result, rawText: phrase, image: nil, context: context,
                source: .cloud, entryOrigin: "siri", forceAutoSave: true, skipCloudSync: true)

            // 3. HealthKit 卡路里同步由 processRecognition 内部的 performSilentSideEffects 完成（已后台跑）。

            let summary = RecognitionSaver.summary(of: result)
            // 显式保存，确保数据在 Intent 返回前已刷入磁盘，避免 autosave 竞态
            try? context.save()
            notifySiriSaved()

            // 记下「刚被 Siri 记的模块」到共享暂存：用户点 Siri 界面唤醒 App 后，
            // 首页对应卡片做一次高亮/微动脉冲（柔和提示，不跳页）。主 App 与后台 Intent
            // 同属一个 App 沙盒，UserDefaults.standard 共享、即时可见；消费即删除，无残留。
            if let firstType = types.compactMap({ HomeModule(recognitionType: $0) }).first {
                UserDefaults.standard.set(firstType.rawValue, forKey: "aia.siriHighlightModule")
            }

            if let ws = waterSummary {
                return "已记录：\(summary) · \(ws)"
            }
            return "已记录：\(summary)"
        }.value

        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    /// 从用户口语里提取提到的模块（用于「叫好记AI 记账、记饮食、记待办」这类只说模块名、没给具体内容的情况）
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
