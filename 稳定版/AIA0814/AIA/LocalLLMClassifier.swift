// LocalLLMClassifier.swift
// 端侧 LLM 意图分拣层（Apple Foundation Models 框架，iOS 26+）。
// 使用 `SystemLanguageModel`（设备端 ~3B 小模型）做轻量意图分类 + 字段抽取，
// 0 网络延迟、0 边际成本；不可用时自然回落云端/正则链。
// `@available(iOS 26, *)` + `#if canImport(FoundationModels)` 双保险。
// 验证：模拟器需宿主 Mac 已开启 Apple Intelligence；真机需 iOS 26.5+ 设置中已开启。
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// 本地 LLM 可识别的用户意图类别。
/// 每个 case 对应 `resolveLocally` 里的一个纯本地处理分支（除 .chat 走云端）。
@available(iOS 26, *)
enum LocalIntent: String, CaseIterable, Sendable {
    /// 记账：「记一笔星巴克35」「花了28块」「付了美团外卖」
    case bill
    /// 记饮食：「早餐吃了碗燕麦粥」「喝了一杯奶茶」
    case food
    /// 记待办：「提醒我明天交报表」「晚上8点开会」
    case todo
    /// 记饮水：「喝了500ml水」
    case water
    /// 食物查询：「苹果的热量」「牛肉的蛋白质」
    case foodQuery
    /// 闲聊 / 寒暄：「你好」「今天天气不错」
    case chat
    /// 无法分类（回落云端）
    case unknown
}

/// 端侧 Foundation Models 意图分类器。
/// 使用 SystemLanguageModel（设备端 ~3B 小模型）做轻量意图分拣 + 字段抽取。
/// 不可用时自然回落云端（`classify` 返回 nil）。
@available(iOS 26, *)
struct LocalLLMClassifier {

    // MARK: - 可用性探针

    /// 运行时检测端侧模型是否可用。
    /// - 编译时：依赖 FoundationModels 框架（`#if canImport(FoundationModels)`）。
    /// - 运行时：`SystemLanguageModel.default.isAvailable`。
    /// - 调试时：打印 `isAvailable` 值，方便在模拟器/真机验证环境是否就绪。
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        let available = SystemLanguageModel.default.isAvailable
        #if DEBUG
        print("[LocalLLMClassifier] SystemLanguageModel available = \(available)")
        #endif
        return available
        #else
        #if DEBUG
        print("[LocalLLMClassifier] FoundationModels not linked (iOS < 26)")
        #endif
        return false
        #endif
    }

    // MARK: - 意图分类

    /// 将用户输入文本分类为 `LocalIntent`。
    /// - Returns: 分类结果；不可用或分类失败时返回 `nil`（由调用方回落云端/正则）。
    static func classify(_ text: String) async -> LocalIntent? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            let session = LanguageModelSession()
            let prompt = """
            你是一个意图分类器。只输出下面类别中的一个词，不要解释。
            类别：bill, food, todo, water, foodQuery, chat
            用户输入：\(trimmed)
            分类：
            """
            let response = try await session.respond(to: prompt)
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // 取首个有效的 intent 词
            for intent in LocalIntent.allCases {
                if raw.hasPrefix(intent.rawValue) {
                    #if DEBUG
                    print("[LocalLLMClassifier] classify \"\(trimmed)\" → \(intent.rawValue)")
                    #endif
                    return intent
                }
            }
            #if DEBUG
            print("[LocalLLMClassifier] classify \"\(trimmed)\" → unmatched: \"\(raw)\"")
            #endif
            return nil
        } catch {
            #if DEBUG
            print("[LocalLLMClassifier] classify error: \(error)")
            #endif
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - 字段抽取

    /// 从用户输入中抽取出结构化字段（金额、商户名、食物名、重量等）。
    /// 仅对 supportedIntents（bill/food/todo/water）有效；其它 intent 返回 nil。
    static func extractFields(from text: String, intent: LocalIntent) async -> [String: String]? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let supported: Set<LocalIntent> = [.bill, .food, .todo, .water]
        guard supported.contains(intent) else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fieldDescriptions: [LocalIntent: String] = [
            .bill: "amount（金额数字）, merchant（商户名）, category（分类名）, isIncome（true/false）",
            .food: "name（食物名）, weight（克数数字）, portion（份量描述）, meal（餐次）",
            .todo: "title（标题文本）, due（截止日期，如「明天下午3点」或无）",
            .water: "ml（毫升数字）, display（份量描述）"
        ]

        do {
            let session = LanguageModelSession()
            let prompt = """
            从用户输入中提取以下 JSON 字段，只输出 JSON 不要解释。
            字段：\(fieldDescriptions[intent] ?? "")
            用户输入：\(trimmed)
            JSON：
            """
            let response = try await session.respond(to: prompt)
            guard let data = response.content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return nil
            }
            return json
        } catch {
            #if DEBUG
            print("[LocalLLMClassifier] extractFields error: \(error)")
            #endif
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - 账单字段抽取（本地没把握时的兜底智能层）

    /// 从 OCR 全文抽取一笔账单的结构化字段。
    /// 仅在「本地正则/规则已判断像账单、但抽取不出金额/商户」这种「没把握」场景调用，
    /// 作为端侧 LLM 兜底；不可用（iOS<26 / 未开启 Apple Intelligence）时返回 nil，回落云端。
    /// 返回字典键：amount / merchant / category / isIncome / datetime（人类可读或 ISO 片段）。
    static func extractBillFields(fromOCR text: String) async -> [String: String]? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return nil }
        do {
            let session = LanguageModelSession()
            let prompt = """
            下面是一张账单/支付/订单截图的 OCR 文本。请抽取第一笔账单的 JSON 字段，只输出 JSON 不要解释。
            字段：amount（金额数字，含正负，支出用负号或前带'-'，如 -38.00）, merchant（收款方/商户名）, category（分类，如 餐饮/购物/交通/其他）, isIncome（true/false）, datetime（出现的时间，如 "7月21日15:39" 或留空）
            OCR 文本：
            \(trimmed)
            JSON：
            """
            let response = try await session.respond(to: prompt)
            guard let data = response.content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return nil
            }
            // 至少要有金额或商户才有意义。
            guard json["amount"] != nil || json["merchant"] != nil else { return nil }
            return json
        } catch {
            #if DEBUG
            print("[LocalLLMClassifier] extractBillFields error: \(error)")
            #endif
            return nil
        }
        #else
        return nil
        #endif
    }
}
