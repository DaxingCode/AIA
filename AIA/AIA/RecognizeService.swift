// RecognizeService.swift
// 调用云端「识别」云函数。App 只跟自己的云函数说话，不直接碰大模型 Key。
import UIKit
import Vision
import SwiftData

struct RecognizeService {
    // ↓↓↓ 替换成你在 CloudBase 控制台拿到的「HTTP 触发」地址
    static let endpoint = URL(string: "https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/recognize")!

    /// 把 UIImage 压缩后发送，返回解析结果 + 服务端原始 JSON 字符串（用于识别记录页保存文字）。
    static func recognize(image: UIImage) async throws -> (result: RecognitionResult, rawText: String) {
        guard let data = image.jpegData(compressionQuality: 1) ?? image.pngData() else {
            throw NSError(domain: "Recognize", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "图片压缩失败"])
        }
        return try await recognizeResilient(imageData: data)
    }

    /// 把图片二进制压缩成可上传的 base64（默认最大边 1024、JPEG 质量 0.8、目标二进制 < 60KB）。
    /// 快捷指令后台传来的原图（常是整张 PNG 截屏）必须经此压缩，否则会触发 CloudBase 413 超限。
    /// CloudBase 实际限制的是「请求体总大小」：binary 经 base64 膨胀约 4/3，再加 JSON 包裹，
    /// 因此目标 binary 控制在 60KB 以下，最终请求体通常 < 90KB，可安全通过。
    /// 可通过 maxSide / targetBytes 在 413 重试时逐级收紧。
    static func compressedBase64(from imageData: Data, maxSide: CGFloat = 1024, targetBytes: Int = 60 * 1024) -> String? {
        guard let image = UIImage(data: imageData) else { return nil }
        let resized = image.preparingThumbnail(of: CGSize(width: maxSide, height: maxSide)) ?? image
        var quality: CGFloat = 0.8
        guard var data = resized.jpegData(compressionQuality: quality) else { return nil }

        // 自适应压缩：目标二进制 < targetBytes，给 JSON 包裹 + base64(4/3) 留出余量
        while data.count > targetBytes && quality > 0.2 {
            quality -= 0.05
            guard let d = resized.jpegData(compressionQuality: quality) else { break }
            data = d
        }

        let base64 = data.base64EncodedString()
        print("[图片大小] \(data.count / 1024) KB, base64 \(base64.count / 1024) KB")
        return base64
    }

    /// 带 413 自动重试的图片识别：
    /// 先用常规压缩上传；若云端返回 413（请求体超限），自动用更小尺寸/更狠压缩重试，
    /// 最多四级（1024/<60KB → 1024/<40KB → 768/<30KB → 512/<20KB），保证大截屏也不会因超限直接失败。
    /// 第一档保守设为 60KB，避免 binary → base64 → JSON 后再次触发 CloudBase 请求体限制。
    static func recognizeResilient(imageData: Data) async throws -> (result: RecognitionResult, rawText: String) {
        let attempts: [(CGFloat, Int)] = [
            (1024, 60 * 1024),
            (1024, 40 * 1024),
            (768, 30 * 1024),
            (512, 20 * 1024),
        ]
        var lastErr: Error?
        for (side, target) in attempts {
            guard let base64 = compressedBase64(from: imageData, maxSide: side, targetBytes: target) else { continue }
            do {
                return try await recognize(base64: base64)
            } catch {
                let desc = "\(error)"
                if desc.contains("413") || desc.contains("EXCEED_MAX_PAYLOAD") {
                    lastErr = error
                    continue   // 超限，换更小尺寸重试
                }
                throw error    // 非超限错误，直接抛出
            }
        }
        throw lastErr ?? NSError(domain: "Recognize", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "图片压缩失败，无法上传"])
    }

    /// 发送 OCR 提取出的文字，让云端**文本模型**（qwen-plus）解析意图。
    /// 比视觉模型便宜一档，且不占用图片 token。
    static func recognizeOCRText(_ text: String) async throws -> (result: RecognitionResult, rawText: String) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body: [String: Any] = [
            "text": text,
            "provider": "sensenovaText", // 显式走文本模型（日日新 SenseChat-Turbo）
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawText = String(data: respData, encoding: .utf8) ?? ""

        guard (200...299).contains(status) else {
            let preview = rawText.isEmpty ? "" : "，云端返回：\(rawText.prefix(200))"
            throw NSError(domain: "Recognize", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "请求失败 (HTTP \(status))\(preview)。请检查：1) 是否已重新部署最新归档.zip；2) CloudBase HTTP 触发是否关闭了「集成响应」；3) 云函数环境变量 DASHSCOPE_API_KEY 是否配置"])
        }

        let wrapper = try JSONDecoder().decode(CloudResponse.self, from: respData)
        guard wrapper.ok, let result = wrapper.result else {
            throw NSError(domain: "Recognize", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: wrapper.error ?? "解析失败"])
        }
        return (result, rawText)
    }

    /// 发送纯文本，让云端解析意图（饮食/账单/待办），返回结构化的识别结果。
    /// 复用同一个 /recognize 云函数，传 text 字段即可。
    static func parseText(_ text: String) async throws -> (result: RecognitionResult, rawText: String) {
        return try await parseText(text, recentMessages: [])
    }

    static func parseText(_ text: String, recentMessages: [[String: String]]) async throws -> (result: RecognitionResult, rawText: String) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        var body: [String: Any] = ["text": text, "provider": "sensenovaText"]
        if !recentMessages.isEmpty {
            body["recentMessages"] = recentMessages
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawText = String(data: respData, encoding: .utf8) ?? ""

        guard (200...299).contains(status) else {
            let preview = rawText.isEmpty ? "" : "，云端返回：\(rawText.prefix(200))"
            throw NSError(domain: "Recognize", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "请求失败 (HTTP \(status))\(preview)。请检查：1) 是否已重新部署最新归档.zip；2) CloudBase HTTP 触发是否关闭了「集成响应」；3) 云函数环境变量 DASHSCOPE_API_KEY 是否配置"])
        }

        let wrapper = try JSONDecoder().decode(CloudResponse.self, from: respData)
        guard wrapper.ok, let result = wrapper.result else {
            throw NSError(domain: "Recognize", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: wrapper.error ?? "解析失败"])
        }
        return (result, rawText)
    }

    /// 食物营养专用查询：本地食物库未命中时，直接问云端该食物每100g的营养。
    /// 返回 FoodRef（每100g基准），失败返回 nil。
    static func queryFood(name: String) async throws -> FoodRef? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body: [String: Any] = [
            "mode": "queryFood",
            "foodName": name,
            "provider": "sensenovaText"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawText = String(data: respData, encoding: .utf8) ?? ""

        guard (200...299).contains(status) else {
            print("[queryFood] HTTP \(status)：\(rawText.prefix(200))")
            return nil
        }

        let wrapper = try JSONDecoder().decode(CloudResponse.self, from: respData)
        guard wrapper.ok,
              let result = wrapper.result,
              let food = result.food,
              let foodName = food.name, !foodName.isEmpty,
              let calories = food.calories, calories > 0 else {
            print("[queryFood] 无有效营养数据：\(rawText.prefix(300))")
            return nil
        }
        return FoodRef(name: foodName,
                       kcal: calories,
                       protein: food.protein ?? 0,
                       carbs: food.carbs ?? 0,
                       fat: food.fat ?? 0)
    }

    static func recognize(base64: String) async throws -> (result: RecognitionResult, rawText: String) {
        print("[发送 base64 长度] \(base64.count)")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body: [String: Any] = ["imageBase64": base64, "provider": "sensenova"]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[HTTP 状态码] \(status)")
        let rawText = String(data: respData, encoding: .utf8) ?? ""
        if !rawText.isEmpty {
            print("[云端返回] \(rawText)")
        }

        // 如果 HTTP 状态码不是 2xx，说明请求被网关拦截（如 EXCEED_MAX_PAYLOAD_SIZE）
        guard (200...299).contains(status) else {
            let preview = rawText.isEmpty ? "" : "，云端返回：\(rawText.prefix(200))"
            throw NSError(domain: "Recognize", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "请求失败 (HTTP \(status))\(preview)。请检查：1) 是否已重新部署最新归档.zip；2) CloudBase HTTP 触发是否关闭了「集成响应」；3) 图片是否过大"])
        }

        let wrapper = try JSONDecoder().decode(CloudResponse.self, from: respData)
        guard wrapper.ok, let result = wrapper.result else {
            throw NSError(domain: "Recognize", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: wrapper.error ?? "识别失败"])
        }
        return (result, rawText)
    }

    // Agent 聊天：走云端 mode:"agent"（带工具调用的智能助理）。
    // 云函数内部失败会自动降级回本地摘要兜底，保证始终有回复。
    static func chat(text: String, context: [String: Any]) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        // 切到 Agent 模式：mode:"agent" + 注入 userId + 改用商汤 sensechat-turbo。
        // 其余（超时 60s、错误提示、返回值）保持与原来一致。
        let request = AgentChatRequest(text: text, context: context)
        let body: [String: Any] = request.toDictionary()
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawText = String(data: respData, encoding: .utf8) ?? ""

        guard (200...299).contains(status) else {
            let preview = rawText.isEmpty ? "" : "，云端返回：\(rawText.prefix(200))"
            throw NSError(domain: "Chat", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "请求失败 (HTTP \(status))\(preview)。请检查：1) 是否已重新部署最新归档.zip；2) CloudBase HTTP 触发是否关闭了「集成响应」"])
        }

        let wrapper = try JSONDecoder().decode(ChatResponse.self, from: respData)
        guard wrapper.ok, let reply = wrapper.reply else {
            throw NSError(domain: "Chat", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: wrapper.error ?? "聊天失败"])
        }
        return reply
    }

    // MARK: - 本地优先识别层（OCR + 规则，0 成本、离线）
    // 设计：截图/照片先跑设备端 OCR，再用规则解析金额/商户/日期，并查本地 MerchantMeta 经验库补全分类。
    // 能解析出明确账单则直接返回（跳过云端视觉模型，成本≈0）；否则回退云端。

    /// 识别来源：用于统计/调试，本地命中则不消耗云端 token。
    enum RecognitionSource: String, Sendable, Codable {
        case local
        case cloudText
        case cloud
    }

    /// 设备端 OCR：把图片里的文字提取为多行文本（不调云端）。失败返回 nil。
    static func localOCRText(from imageData: Data) -> String? {
        return localOCR(from: imageData)?.text
    }

    /// 设备端 OCR：同时返回文字和所有文本块的 bounding box，供营养成分表等需要版面分析的模块使用。
    /// - Parameter customWords: 可选词典偏置（已知商户名/常见商户名），提升易混字识别率。
    private static func localOCR(from imageData: Data,
                                 customWords: [String]? = nil) -> (text: String, observations: [VNRecognizedTextObservation], candidates: [[(string: String, confidence: Float)]])? {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en"]
        // ② 词典偏置：把已知商户名/常见商户名喂给 OCR，提升易混字的识别率；
        //    同时设最小文字高度，过滤状态栏/水印等微小噪点（占图高比例 < 0.8% 忽略）。
        if let words = customWords, !words.isEmpty {
            request.customWords = Array(Set(words)).map { $0 as String }
        }
        request.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let obs = request.results, !obs.isEmpty else { return nil }
        let lines = obs.compactMap { $0.topCandidates(1).first?.string }
        // ③ OCR 多候选：每个块取 top5 候选 + 置信度，供金额/时间提取做「多候选+置信度打分」纠正易混数字。
        let cands = obs.map { $0.topCandidates(5).map { (string: $0.string, confidence: $0.confidence) } }
        guard !lines.isEmpty else { return nil }
        return (lines.joined(separator: "\n"), obs, cands)
    }

    // MARK: - ② OCR 词典偏置词源

    /// 常见商户种子词：无任何本地数据时也能给 OCR 一点偏置，减少常见品牌的易混字错误。
    private static let merchantSeeds: [String] = [
        "微信支付", "支付宝", "云闪付", "星巴克", "瑞幸咖啡", "麦当劳", "肯德基", "必胜客",
        "美团", "大众点评", "饿了么", "滴滴出行", "高德地图", "京东", "淘宝", "天猫",
        "拼多多", "盒马", "永辉", "沃尔玛", "大润发", "家乐福", "华润万家", "物美",
        "7-ELEVEN", "全家", "罗森", "便利蜂", "喜茶", "奈雪的茶", "蜜雪冰城",
        "阿里云", "腾讯云", "华为云", "百度云", "京东云", "中国移动", "中国联通", "中国电信",
        "中国石油", "中国石化", "国家电网", "顺丰", "中通", "圆通", "韵达", "邮政"
    ]

    /// 收集用于 OCR 词典偏置的商户词：已知 MerchantMeta + 历史 Bill.merchant + 常见商户种子。
    private static func merchantBiasWords(in context: ModelContext) -> [String] {
        var set = Set<String>()
        if let metas = try? context.fetch(FetchDescriptor<MerchantMeta>()) {
            for m in metas where !m.syncDeleted && !m.merchant.isEmpty && !isLikelyTime(m.merchant) {
                set.insert(m.merchant)
            }
        }
        if let bills = try? context.fetch(FetchDescriptor<Bill>()) {
            for b in bills where !b.merchant.isEmpty {
                set.insert(b.merchant)
            }
        }
        for s in merchantSeeds { set.insert(s) }
        return Array(set)
    }

    /// 本地账单规则解析：从 OCR 文字提取金额/商户/日期，并查 MerchantMeta 经验库补全分类。
    /// 能解析出「明确金额」则返回本地识别结果；否则返回 nil（交给云端）。
    /// - Parameter context: 用于查 MerchantMeta 经验库；传 nil 时跳过经验库，分类按关键词猜。
    /// - Parameter preferredTimeLine: 来自一图多账单拆分时定位到的列表项时间（如「7月21日15:39」「昨天 19:09」），
    ///   是**这笔交易的实际支付时间**（用户明确声明）。当 extractISODateTime 提取不到「支付时间」标签时，
    ///   用它替代 .now 作为支付时间。
    static func localParseBill(text: String,
                                in context: ModelContext?,
                                referenceDate: Date? = nil,
                                preferredMerchant: String? = nil,
                                forceAmount: Bool = false,
                                candidates: [[(string: String, confidence: Float)]]? = nil,
                                preferredTimeLine: String? = nil,
                                defaultListItemYesterday: Bool = false) -> RecognitionResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 强账单场景词：命中说明这大概率是支付/账单类截图，可放宽金额提取策略。
        let billSignals = [
            // 移动支付
            "交易成功", "支付时间", "付款方式", "账单详情", "收款方", "付款金额",
            "支付金额", "交易金额", "订单金额", "实付金额", "支付成功", "已付款",
            "微信支付", "支付宝", "经营码", "收款码", "付款码", "转账", "扫一扫付款",
            // 超市/便利店/餐饮收银小票
            "小票", "收银", "应收", "实收", "找零", "成交价", "合计", "总计", "总金额",
            "件数", "数量", "永辉", "华润", "沃尔玛", "大润发", "盒马", "物美", "家乐福",
            "便利店", "超市", "商場", "商场", "购物中心"
        ]
        let hasBillSignal = billSignals.contains { trimmed.localizedCaseInsensitiveContains($0) }

        // 反向信号：微信群聊通知/活动海报/培训/会议/招募等截图，即使里面夹带金额（如报名费 ¥18），
        // 本地正则也无法可靠区分「带价格的培训通知」与「真账单」。这类一律不让本地声称账单，
        // 直接返回 nil 交云端（文本模型 / 视觉模型，云端均明确归 todo）处理。
        // 注意：不叠加 !hasBillSignal 判断——只要像事件/通知就交给云端，避免本地误判。
        let eventSignals = [
            "培训", "训练营", "招募", "报名", "上课", "课程", "讲座", "会议", "开会",
            "活动时间", "培训时间", "上课时间", "地点", "会议室", "教室", "群聊", "微信群",
            "通知", "公告", "海报", "邀请函", "日程", "议程", "参训", "招募令", "活动报名"
        ]
        let hasEventSignal = eventSignals.contains { trimmed.localizedCaseInsensitiveContains($0) }
        if hasEventSignal { return nil }

        // 1) 金额：先取 top1 文本解析；再用 OCR 多候选（置信度+规则打分）兜底/纠正易混数字（8↔3、1↔7）。
        let force = hasBillSignal || forceAmount
        let topAmount = extractAmount(trimmed, force: force)
        var amount: Double?
        if let top = topAmount {
            amount = top
            // 易混数字纠正：仅在「产出 top1 的那个 OCR 块内部」寻找易混替代候选
            // （如该块 top1 把 38 误读成 83，块内候选同时给出 38）。
            // 关键：只在同一块内纠正，绝不受其他块（如商品明细价 ¥38）影响，避免跨块误改总额。
            if let corrected = confusableCorrection(top, candidates: candidates ?? [], force: force) {
                amount = corrected
            }
        } else {
            amount = extractAmountCandidates(candidates ?? [], force: force)?.value
        }
        guard let amount else { return nil }

        // 策略：只要本地能确定金额（且不是事件/通知截图），就优先返回本地结果。
        // merchant/time 即使部分缺失，也使用默认值（"账单"/当前时间），避免把控制权交给
        // 更容易犯错的云端视觉模型（如云账单常被误判为交通、状态栏时间被当支付时间）。
        // 取舍：可能降低商户/时间质量，但显著减少「商户=19:09、时间=状态栏时间」这类离谱错误。

        // 2) 商户：一图多账单拆分时已向上精准定位到商户标题，优先采用（避免对多行 block 重新跑
        //     extractMerchant 把整段当成商户名）；否则走常规 MerchantMeta > 标签 > 首行。
        let rawMerchant: String
        if let pref = preferredMerchant, !pref.isEmpty {
            rawMerchant = pref
        } else {
            rawMerchant = extractMerchant(trimmed, in: context)
        }
        // ① 商户模糊纠错：extractMerchant 已给出候选（可能带 OCR 错字，如「星已克」），
        //    尝试与已知商户库对齐纠正为正确名（如「星巴克」），避免退化为默认「账单」。
        let correctedMerchant = fuzzyCorrectMerchant(rawMerchant, in: context) ?? rawMerchant
        // 防御（v4）：即便 extractMerchant 仍返回时间串（如"19:09"，极端 OCR/经验库差异下），
        // 也绝不允许它成为商户名。强制回退空串（最终显示"账单"），并跳过 MerchantMeta 对该坏 key 的查询/写入。
        let merchant = (correctedMerchant.isEmpty || isLikelyTime(correctedMerchant)) ? "" : correctedMerchant

        // 3) 时间：优先精确提取「支付时间」行含时分秒的完整时间戳；
        //    只提取到日期时（有日期无时刻）用当天零点；
        //    完全提取失败（截图里没有任何时间线索）则按优先级：
        //    ① 列表项时间（如「7月21日15:39」「昨天 19:09」——用户明确这是支付时间）
        //    ② .now（系统当前时间）
        //    符合用户要求：有支付时间标签则取之，有列表项时间则用之，都没有才记 .now。
        let timeCands = candidates ?? []
        let isoTime = extractISODateTime(trimmed, referenceDate: referenceDate)
            ?? (timeCands.flatMap { $0 }.isEmpty ? nil : extractISODateTimeCandidates(timeCands, referenceDate: referenceDate))
            ?? parseListItemTime(preferredTimeLine, referenceDate: referenceDate, defaultYesterday: defaultListItemYesterday)
            ?? (defaultListItemYesterday ? yesterdayStart(referenceDate: referenceDate) : nil)
            ?? ISO8601DateFormatter().string(from: .now)

        // 4) 分类：优先 MerchantMeta 经验库，未命中按关键词猜
        var category = "其他"
        let isIncome: Bool
        if let ctx = context, !merchant.isEmpty,
           let (cat, inc) = MerchantMetaStore.lookup(merchant, in: ctx) {
            category = cat
            isIncome = inc
        } else {
            (category, isIncome) = guessCategory(merchant, trimmed)
        }
        _ = isIncome // 分类已含收支语义；结果确认页通过 category 再推断 isIncome

        let payload = BillPayload(
            merchant: merchant.isEmpty ? "账单" : merchant,
            amount: amount,
            currency: "CNY",
            category: category,
            time: isoTime,
            note: "",
            action: "create",
            targetTitle: nil
        )
        return RecognitionResult(types: ["bill"], confidence: 0.75, bill: nil,
                                  bills: [payload], food: nil, todo: nil, health: nil)
    }

    // MARK: - 一图多账单拆分

    /// 判断文本是否为超市/便利店收银小票（含传统商超、会员店、便利店）。
    /// 单张小票里「商品价、应收、实收、找零、支付方式」等多行金额属于同一笔交易。
    private static func isSupermarketReceipt(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let signals = [
            "小票", "收银", "应收", "实收", "找零", "件数", "成交价",
            "永辉", "沃尔玛", "盒马", "大润发", "家乐福", "物美", "华润",
            "苏果", "卜蜂莲花", "麦德龙", "山姆", "costco", "超市", "便利店",
            "商场", "量贩", " shopping", "receipt"
        ]
        return signals.contains(where: { lowered.contains($0.lowercased()) })
    }

    /// 判断 OCR 文本是否为「账单列表/多条记录」截图，而非单条账单详情。
    /// 触发条件：存在至少 2 条明确金额行，且至少 2 条能向上找到不同商户标题。
    /// 额外排除：超市/便利店收银小票，避免 1 张小票被拆成 N 笔错账。
    private static func detectMultiBillList(_ text: String) -> Bool {
        if isSupermarketReceipt(text) { return false }

        let entries = extractBillEntries(text)
        let validMerchants = entries.compactMap { $0.merchant }.filter { !$0.isEmpty }
        let distinctMerchants = Set(validMerchants)
        let hasMultipleBills = entries.count >= 2 && distinctMerchants.count >= 2

        // 强列表信号（如「支付消息」「服务消息」）直接认定为多账单，即使含「付款成功」也不必按单账单排除。
        // 支付宝「支付消息」页每条记录都带「付款成功」，但它本质是多笔历史记录列表。
        let strongListSignals = ["支付消息", "服务消息", "支付记录", "账单列表", "我的账单"]
        if strongListSignals.contains(where: { text.localizedCaseInsensitiveContains($0) }) && entries.count >= 2 {
            return true
        }

        // 支付/交易成功页 / 账单详情页：本质是单笔交易的结果页，金额在状态栏+金额行+同行右栏
        // 重复出现 2~3 次都是同一笔。强制走单账单路径，避免「同一笔拆 2~3 笔」。
        // 但若能拆出 2 个以上不同商户，说明不是单笔结果页，放行多账单。
        if isPaymentSuccessScreen(text), distinctMerchants.count < 2 {
            return false
        }

        // 强单页信号：「账单详情」且没有列表页信号 → 本质上是单笔详情页，不应拆条。
        // 配合 isAmountLine 长度限制，防御订单号/交易号被误拆成多笔。
        let singleDetailSignals = ["账单详情"]
        if singleDetailSignals.contains(where: { text.localizedCaseInsensitiveContains($0) }),
           !strongListSignals.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return false
        }

        return hasMultipleBills
    }

    /// 列表页/历史记录页：微信/支付宝「账单」列表、支付宝「交易记录」、美团「我的订单」等。
    /// 这类截图**每条都是历史交易**，适合逐条入库（多笔账单），但需要比支付详情更严的边界切分。
    /// 用于：在多账单路径里给 confirm 页加「检测到列表，逐条记录」提示；同时影响 extractBillEntries
    /// 的切分策略（按 row group 而非金额行向上扫描）。
    private static func isBillListScreen(_ text: String) -> Bool {
        let signals = [
            "全部账单", "我的账单", "我的订单", "搜索交易记录", "搜索我的订单",
            "收支统计", "收支分析", "查找交易", "本月已省",
            "大额消费", "自动扣款", "花呗付款", "分期付款", "支付消息",
            "待付款", "待收货", "待使用", "待到店", "退款/售后",
            "订单", "账单管理"   // 单条详情页也含「账单管理」，需配合其他信号
        ]
        // 至少命中 2 个列表页信号才认定（避免误把详情页里"账单管理"当列表页）
        var hit = 0
        for s in signals where text.localizedCaseInsensitiveContains(s) {
            hit += 1
            if hit >= 2 { return true }
        }
        return false
    }

    /// 支付/交易结果页：单笔交易的结果页（含状态文案、订单信息、可能的红包/广告）。
    /// 典型：支付宝「支付成功」、微信「支付成功」、银联「交易成功」。
    private static func isPaymentSuccessScreen(_ text: String) -> Bool {
        let signals = [
            "支付成功", "交易成功", "付款成功", "支付完成", "交易完成", "已付款", "收款成功"
        ]
        return signals.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// 把账单列表拆成若干条目文本块，每块交给 localParseBill 解析。
    /// 切分策略：以金额行为锚点，向上越过时间/UI 噪声找到商户标题，构造最小独立 block。
    private static func splitBillEntries(_ text: String) -> [String] {
        return extractBillEntries(text).map { $0.block }
    }

    /// 内部结构：一图多账单拆分后的单个条目。
    private struct BillEntry {
        let merchant: String
        let timeLine: String?
        let block: String
    }

    /// 核心拆分算法：从每个金额行向上扫描，跳过时间和 UI 噪声，找到真正的商户标题。
    /// 这样避免中点切分把营销文案（如"+3积分"）或时间串错当成商户。
    private static func extractBillEntries(_ text: String) -> [BillEntry] {
        let rawLines = text.components(separatedBy: .newlines)
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }

        let uiNoise: Set<String> = ["全部", "支出", "收入", "转账", "退款", "订单", "筛选", "搜索",
                                     "收支分析", "我的账单", "支付服务", "摇优惠", "服务消息", "支付消息",
                                     "账单", "全部账单", "查找交易", "Q", "X", "说", "出分",
                                     "本月已省", "账单详情", "查看详情", "音看详情",
                                     "付款方式", "支付方式", "支付奖励", "本次奖励", "联系收款方",
                                     "付款成功", "交易成功", "已付款", "支付成功", "自动扣款成功", "自动续费",
                                     "优惠", "保险名称", "被保人", "缴费计划",
                                     "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
        let bankNoise = ["信用卡", "储蓄卡", "银行卡", "借记卡", "通过", "使用"]
        let categoryWords = ["餐饮美食", "医疗健康", "充值缴费", "投资理财", "信用借还", "其他", "交通", "购物"]

        func isUINoise(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return true }
            if uiNoise.contains(t) { return true }
            if t.hasPrefix("Q ") || t.hasPrefix("搜索") || t.hasPrefix("本月已省") { return true }
            // 状态栏 / 悬浮岛时间：23:35、21:021、21.010 等（OCR 把冒号/小数点读混）
            if t.range(of: #"^\d{1,2}[:\.]\d{2,4}$"#, options: .regularExpression) != nil { return true }
            // 单个图标 / 符号（悬浮岛 X 读成 IX、圆点读成 ◎、括号等）
            if t.range(of: #"^[\(\)\[\]\{\}◎◆◇○●□■▢▣◉◈◇◆<＜>＞]+$"#, options: .regularExpression) != nil { return true }
            if ["IX", "X", "Q", "◎", "◆", "◇"].contains(t) { return true }
            return false
        }

        let amountIndices = lines.enumerated().compactMap { i, line -> Int? in
            guard isAmountLine(line), !isSummaryAmountLine(line), !isUINoise(line) else { return nil }
            return i
        }
        guard amountIndices.count >= 2 else { return [] }

        func isPotentialMerchant(_ line: String) -> Bool {
            if isUINoise(line) { return false }
            // 支付/交易结果文案：绝不能当商户
            let resultNoise: Set<String> = [
                "支付成功", "交易成功", "付款成功", "支付完成", "交易完成", "已付款", "收款成功",
                "回首页", "完成", "◎ 支付成功"
            ]
            if resultNoise.contains(line) || resultNoise.contains(where: { line.localizedCaseInsensitiveContains($0) && line.count <= $0.count + 4 }) {
                return false
            }
            if isLikelyTime(line) { return false }
            if isAmountLine(line) { return false }
            // 允许中文单字商户（如收款人"娟"），仅过滤完全空串；纯噪声短串已由 isUINoise 兜底。
            if line.isEmpty { return false }
            if bankNoise.contains(where: { line.contains($0) }) { return false }
            if categoryWords.contains(where: { line.contains($0) }) { return false }
            // 订单/交易号上下文：这类长串前面常有标签，整行不能当商户
            let orderNoise = ["业务交易号", "交易号", "订单号", "订单编号", "商家订单号", "流水号", "流水编号"]
            if orderNoise.contains(where: { line.localizedCaseInsensitiveContains($0) }) { return false }
            // 超市小票常见噪声：纯重量/规格（400g、0g、1kg、500ml）、计量单位头（件、件数、数量）、商品条码
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^[\d.oO]+\s*[gG克kg千克ml毫升l升]$"#, options: .regularExpression) != nil { return false }
            if t.range(of: #"^[\d.oO]+\s*(个|件|瓶|包|袋|盒|罐)$"#, options: .regularExpression) != nil { return false }
            if ["件", "件数", "数量", "单位", "规格"].contains(t) { return false }
            if t.range(of: #"^\d{12,}$"#, options: .regularExpression) != nil { return false }
            // 月份/年份选择器、账单区间标题（如「2026年7月」「7月」「2026/7」）不能当商户
            if t.range(of: #"^\d{4}年\d{1,2}月(份?)$"#, options: .regularExpression) != nil { return false }
            if t.range(of: #"^\d{1,2}月(份?)$"#, options: .regularExpression) != nil { return false }
            if t.range(of: #"^\d{4}[/-]\d{1,2}$"#, options: .regularExpression) != nil { return false }
            if t.range(of: #"^\d{4}年$"#, options: .regularExpression) != nil { return false }
            // 绝不允许纯符号/图标成为商户（如悬浮岛读出的 "(" "◎" 等）
            let meaningful = t.filter { $0.isLetter || $0.isNumber }
            if meaningful.isEmpty && t.count <= 2 { return false }
            return true
        }

        var entries: [BillEntry] = []
        for (k, idx) in amountIndices.enumerated() {
            let prevAmountIdx = (k > 0) ? amountIndices[k - 1] : -1

            // 向上扫描：收集所有时间候选 + 商户候选。
            var timeCandidates: [String] = []
            var merchantCandidates: [String] = []
            var scanJ = idx - 1
            while scanJ > prevAmountIdx && scanJ >= 0 {
                let line = lines[scanJ]
                if isLikelyTime(line) {
                    timeCandidates.append(line)
                } else if isPotentialMerchant(line) {
                    merchantCandidates.append(line)
                }
                scanJ -= 1
            }

            // 选时间：优先含「昨天/今天/M月D日」等日期信号的时间，再取纯 HH:MM；
            // 同分组内取最靠近金额行（索引最大）的那一个，避免顶部状态栏时间抢位。
            let timeLine: String? = {
                var best: (text: String, score: Int, index: Int)? = nil
                for (i, t) in timeCandidates.enumerated() {
                    let hasDateSignal = t.range(of: #"(昨天|今天|明天|\d{1,2}月\d{1,2}日)"#, options: .regularExpression) != nil
                    let score = (hasDateSignal ? 1000 : 0) + i
                    if best == nil || score > best!.score {
                        best = (t, score, i)
                    }
                }
                return best?.text
            }()

        // 选商户：优先最近（紧邻金额的文本最可能是商户），避免把更上方的营销文案（如
        // "+3积分|抢黑人清新双效牙膏"、"领88元余额宝体验金"）错当成商户。
        guard let m = merchantCandidates.first else { continue }

            // 构造最小 block：商户 + 时间 + 金额 + 后 1 行分类/说明。
            // 若后 1 行本身像商户标题（多为下一笔账单的标题），则跳过，避免把邻居账单的文本
            // 污染到当前条目的商户/分类识别。
            var blockLines: [String] = [m]
            if let t = timeLine { blockLines.append(t) }
            blockLines.append(lines[idx])
            if idx + 1 < lines.count {
                let nxt = lines[idx + 1]
                if !isAmountLine(nxt), !isUINoise(nxt), !isLikelyTime(nxt), !isPotentialMerchant(nxt) {
                    blockLines.append(nxt)
                }
            }
            entries.append(BillEntry(merchant: normalizeMerchant(m), timeLine: timeLine, block: blockLines.joined(separator: "\n")))
        }
        return entries
    }

    /// 尝试把 OCR 文本按多条账单拆分，逐条解析后合并返回。
    /// 只要解析出 ≥1 条有效账单即返回，不再 fallback 云端。
    static func localParseMultiBillsIfNeeded(text: String, in context: ModelContext?) -> RecognitionResult? {
        guard detectMultiBillList(text) else { return nil }
        let entries = extractBillEntries(text)
        var payloads: [BillPayload] = []
        // 支付消息/账单列表多为历史记录，若 OCR 只给出纯 HH:MM 默认用昨天。
        let hasYesterdaySignal = text.localizedCaseInsensitiveContains("昨天")
        let strongListSignals = ["支付消息", "服务消息", "支付记录", "账单列表", "我的账单"]
        let isStrongList = strongListSignals.contains(where: { text.localizedCaseInsensitiveContains($0) })
        let defaultYesterday = hasYesterdaySignal || isStrongList
        for e in entries {
            // 多账单列表里每条都是独立支付记录：强制放宽金额提取，并直接采用拆分时已定位好的商户。
            // 列表项时间（如「7月21日15:39」「昨天 19:09」）是支付时间，作为 preferredTimeLine 传入。
            guard let single = localParseBill(text: e.block, in: context,
                                              referenceDate: nil,
                                              preferredMerchant: e.merchant,
                                              forceAmount: true,
                                              preferredTimeLine: e.timeLine,
                                              defaultListItemYesterday: defaultYesterday),
                  let bills = single.bills, !bills.isEmpty else { continue }
            payloads.append(contentsOf: bills)
        }
        guard payloads.count >= 1 else { return nil }
        return RecognitionResult(types: ["bill"], confidence: 0.75, bill: nil,
                                  bills: payloads, food: nil, todo: nil, health: nil)
    }

    // MARK: - 营养成分表本地识别（食物包装背面）

    /// 判断 OCR 文本是否包含「营养成分表」及核心项目，避免普通食物描述被误判。
    private static func hasNutritionTable(in lines: [String]) -> Bool {
        let tableSignals = ["营养成分表", "营养成份表", "nutrition information", "nutrition facts"]
        let itemSignals = ["能量", "蛋白质", "脂肪", "碳水化合物"]
        let hasTable = lines.contains { line in
            let lowered = line.lowercased()
            return tableSignals.contains { lowered.contains($0) }
        }
        let hasItems = lines.contains { line in
            itemSignals.contains { line.localizedCaseInsensitiveContains($0) }
        }
        return hasTable && hasItems
    }

    /// 从营养成分表行中提取能量（优先 kJ → kcal）。
    /// 返回的是「每 100g」千卡数。
    private static func parseEnergy(from lines: [String]) -> Double? {
        // 匹配：能量 379kJ / 能量 379千焦 / 能量 90kcal / 热量 90千卡
        let pattern = #"(?:能量|热量|energy)\s*[:：]?\s*(\d+(?:\.\d+)?)\s*(kJ|千焦|KJ|kj|千卡|kcal|Kcal|大卡)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for line in lines {
            let ns = line as NSString
            if let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let value = Double(ns.substring(with: m.range(at: 1))) {
                let unitRange = m.range(at: 2)
                let unit = unitRange.location != NSNotFound ? ns.substring(with: unitRange).lowercased() : ""
                if unit.contains("千") || unit.contains("kcal") || unit.contains("大卡") {
                    return value
                }
                // 默认按 kJ 处理（国标营养成分表常见）
                return value / 4.184
            }
        }
        return nil
    }

    /// 从营养成分表行中提取三大营养素（每 100g，克）。
    private static func parseMacros(from lines: [String]) -> (protein: Double?, carbs: Double?, fat: Double?) {
        var protein: Double?
        var carbs: Double?
        var fat: Double?

        func extract(_ line: String, keywords: [String]) -> Double? {
            let lowered = line.lowercased()
            guard keywords.contains(where: { lowered.contains($0) }) else { return nil }
            // 匹配行中第一个 "数字 g"，如 "蛋白质 3.1g" / "3.1 克"
            let pattern = #"(\d+(?:\.\d+)?)\s*(g|克|g/100g)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            let ns = line as NSString
            if let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                return Double(ns.substring(with: m.range(at: 1)))
            }
            return nil
        }

        for line in lines {
            if protein == nil, let v = extract(line, keywords: ["蛋白质", "protein"]) { protein = v }
            if fat == nil, let v = extract(line, keywords: ["脂肪", "fat"]) { fat = v }
            if carbs == nil, let v = extract(line, keywords: ["碳水化合物", "碳水", "carbohydrate", "carbs"]) { carbs = v }
        }
        return (protein, carbs, fat)
    }

    /// 从产品信息行提取食物名称（文本版）。
    private static func extractProductName(from lines: [String]) -> String? {
        // 1) 显式标签
        let labelPatterns = [
            #"产品种类[:：]\s*(.+)"#,
            #"品名[:：]\s*(.+)"#,
            #"产品名称[:：]\s*(.+)"#,
            #"名称[:：]\s*(.+)"#
        ]
        for pattern in labelPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            for line in lines {
                if let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let r = Range(m.range(at: 1), in: line) {
                    let name = String(line[r]).trimmingCharacters(in: .whitespaces)
                    if name.count >= 2 { return name }
                }
            }
        }

        // 2) 营养成分表上方最近的非噪声短文本
        guard let tableIdx = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("营养成分") ||
                                                         $0.localizedCaseInsensitiveContains("nutrition") }) else { return nil }
        let noise = ["配料", "成分", "贮存", "保质期", "生产日期", "产品标准", "温馨提示", "注意事项",
                     "产地", "地址", "电话", "传真", "网址", "含有", "本产品", "添加", "果酱", "添加量",
                     "生产商", "制造商", "出品", "集团", "股份", "有限公司", "有限责任公司"]
        for i in (0..<tableIdx).reversed() {
            let line = lines[i]
            if line.count < 4 || line.count > 40 { continue }
            if noise.contains(where: { line.localizedCaseInsensitiveContains($0) }) { continue }
            if line.range(of: #"^\d"#, options: .regularExpression) != nil { continue }
            return line
        }
        return nil
    }

    /// 文本版营养成分表解析（OCR 质量高、行序完整时使用）。
    static func localParseNutritionTable(text: String) -> RecognitionResult? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard hasNutritionTable(in: lines) else { return nil }
        guard let energyKcal = parseEnergy(from: lines) else { return nil }
        let macros = parseMacros(from: lines)
        guard macros.protein != nil || macros.fat != nil || macros.carbs != nil else { return nil }

        return makeNutritionFoodResult(name: extractProductName(from: lines),
                                       energyKcal: energyKcal,
                                       macros: macros)
    }

    // MARK: - 营养成分表版面分析（处理 Vision OCR 把左右两列拆成列序输出的情况）

    private struct NutritionItem {
        let text: String
        let box: CGRect
    }

    /// 从 Vision OCR 观察结果中按版面列序提取营养成分数值。
    /// 核心假设：营养成分表是左右两栏，右栏数值从上到下依次对应 能量/蛋白质/脂肪/碳水化合物/钠/钙…
    private static func localParseNutritionTable(observations: [VNRecognizedTextObservation]) -> RecognitionResult? {
        guard !observations.isEmpty else { return nil }

        var items: [NutritionItem] = []
        for o in observations {
            guard let c = o.topCandidates(1).first else { continue }
            items.append(NutritionItem(text: c.string, box: o.boundingBox))
        }

        let fullText = items.map { $0.text }.joined(separator: "\n")
        guard hasNutritionTable(in: fullText.components(separatedBy: .newlines)) else { return nil }

        // 找到「营养成分表」标题位置；表格主体在它下方（Vision 坐标原点在左下，y 越小越靠下）。
        guard let tableItem = items.first(where: { $0.text.localizedCaseInsensitiveContains("营养成分") ||
                                                    $0.text.localizedCaseInsensitiveContains("nutrition") }) else { return nil }

        let bodyItems = items.filter { $0.box.midY < tableItem.box.midY - 0.005 }
        guard bodyItems.count >= 2 else { return nil }

        // 按「数值型文本」与「标签型文本」的 x 重心分成左右两列。
        // 营养成分表的右栏（数值）通常包含 kJ/g/mg/%；左栏是中文项目名。
        let valueUnits: Set<String> = ["kJ", "千焦", "KJ", "kcal", "千卡", "大卡", "g", "克", "mg", "%"]
        let labelKeywords: Set<String> = ["能量", "热量", "蛋白质", "脂肪", "碳水化合物", "碳水", "钠", "钙", "项目", "每100"]
        func matchesValue(_ text: String) -> Bool {
            return extractValue(text, units: Array(valueUnits)) != nil
        }
        func matchesLabel(_ text: String) -> Bool {
            return labelKeywords.contains { text.localizedCaseInsensitiveContains($0) }
        }
        let valueItems = bodyItems.filter { matchesValue($0.text) }
        let labelItems = bodyItems.filter { matchesLabel($0.text) }
        guard !valueItems.isEmpty else { return nil }
        let valueCenter = valueItems.map { $0.box.midX }.reduce(0, +) / CGFloat(valueItems.count)
        let labelCenter = labelItems.isEmpty ? 0.2 : labelItems.map { $0.box.midX }.reduce(0, +) / CGFloat(labelItems.count)

        let rightItems = bodyItems.filter { abs($0.box.midX - valueCenter) <= abs($0.box.midX - labelCenter) }
            .sorted { $0.box.midY > $1.box.midY } // 从上到下
        let leftItems = bodyItems.filter { abs($0.box.midX - valueCenter) > abs($0.box.midX - labelCenter) }
            .sorted { $0.box.midY > $1.box.midY }

        // 分别把左右栏聚合成行（同 y 坐标带内的文本拼成一行）。
        let rowThreshold: CGFloat = 0.05
        func groupRows(_ items: [NutritionItem]) -> [(text: String, midY: CGFloat)] {
            var rows: [(text: String, midY: CGFloat)] = []
            var currentRow: [NutritionItem] = []
            for item in items {
                if let last = currentRow.last, abs(item.box.midY - last.box.midY) > rowThreshold {
                    let text = currentRow.sorted { $0.box.midX < $1.box.midX }.map { $0.text }.joined(separator: " ")
                    rows.append((text, currentRow.reduce(0) { $0 + $1.box.midY } / CGFloat(currentRow.count)))
                    currentRow = []
                }
                currentRow.append(item)
            }
            if !currentRow.isEmpty {
                let text = currentRow.sorted { $0.box.midX < $1.box.midX }.map { $0.text }.joined(separator: " ")
                rows.append((text, currentRow.reduce(0) { $0 + $1.box.midY } / CGFloat(currentRow.count)))
            }
            return rows
        }
        let leftRows = groupRows(leftItems)
        let rightRows = groupRows(rightItems)

        // 按左栏标签找到最近的右栏数值行并解析。
        var energyKcal: Double?
        var protein: Double?
        var fat: Double?
        var carbs: Double?
        var gramOrder: [Double] = []

        for lRow in leftRows {
            guard let nearestR = rightRows.min(by: { abs($0.midY - lRow.midY) < abs($1.midY - lRow.midY) }) else { continue }
            let lText = lRow.text
            if lText.localizedCaseInsensitiveContains("能量") || lText.localizedCaseInsensitiveContains("热量") {
                if let kj = extractValue(nearestR.text, units: ["kJ", "千焦", "KJ"]) { energyKcal = kj / 4.184 }
                else if let kcal = extractValue(nearestR.text, units: ["kcal", "千卡", "大卡"]) { energyKcal = kcal }
            } else if lText.localizedCaseInsensitiveContains("蛋白质") {
                if let v = extractValue(nearestR.text, units: ["g", "克"]) { protein = v }
            } else if lText.localizedCaseInsensitiveContains("脂肪") {
                if let v = extractValue(nearestR.text, units: ["g", "克"]) { fat = v }
            } else if lText.localizedCaseInsensitiveContains("碳水化合物") || lText.localizedCaseInsensitiveContains("碳水") {
                if let v = extractValue(nearestR.text, units: ["g", "克"]) { carbs = v }
            }
        }

        // 兜底：扫描所有右栏数值行，按单位再补一遍（能量/宏量缺失时）。
        for rRow in rightRows where !rRow.text.contains("每100") {
            if energyKcal == nil, let kj = extractValue(rRow.text, units: ["kJ", "千焦", "KJ"]) {
                energyKcal = kj / 4.184
            }
            if energyKcal == nil, let kcal = extractValue(rRow.text, units: ["kcal", "千卡", "大卡"]) {
                energyKcal = kcal
            }
            if let v = extractValue(rRow.text, units: ["g", "克"]) {
                gramOrder.append(v)
            }
        }

        if protein == nil, gramOrder.count > 0 { protein = gramOrder[0] }
        if fat == nil, gramOrder.count > 1     { fat = gramOrder[1] }
        if carbs == nil, gramOrder.count > 2   { carbs = gramOrder[2] }

        // 如果能量缺失但三大营养素都有，按 4/9/4 估算。
        if energyKcal == nil, let p = protein, let f = fat, let c = carbs {
            energyKcal = p * 4 + f * 9 + c * 4
        }

        guard energyKcal != nil || !gramOrder.isEmpty else { return nil }

        // 食物名：优先从版面左栏显式标签取，否则文本兜底。
        let name = extractProductName(fromObservations: leftItems, fullText: fullText)
        return makeNutritionFoodResult(name: name,
                                       energyKcal: energyKcal ?? 0,
                                       macros: (protein, carbs, fat))
    }

    /// 从行文本中提取带单位的数值。
    /// 说明：单位按长度降序拼进 alternation（如 "mg" 排在 "g" 前），保证 "60mg" 优先命中 mg；
    /// 且**不使用** `\b` 词边界——OCR 常把数字与单位紧贴输出（"379kJ"/"3.19克"），此时 `9` 与 `k`/`克`
    /// 两侧都是词字符、不存在词边界，加了 `\b` 反而永远匹配不到。查询 ["g","克"] 时 "60mg" 也不会误命中，
    /// 因为其 "g" 前一位是 "m" 而非数字，`\d+\s*(?:g|克)` 无法从任何起点匹配。
    private static func extractValue(_ text: String, units: [String]) -> Double? {
        let sorted = units.sorted { $0.count > $1.count }
        let escaped = sorted.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = #"(\d+(?:\.\d+)?)\s*(?:"# + escaped + #")"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        if let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let v = Double(ns.substring(with: m.range(at: 1))) { return v }
        return nil
    }

    /// 从版面左栏提取产品名称。
    private static func extractProductName(fromObservations items: [NutritionItem], fullText: String) -> String? {
        let lines = items.map { $0.text }
        if let name = extractProductName(from: lines) { return name }
        // 兜底：从整段 OCR 里按标签正则再试一次
        return extractProductName(from: fullText.components(separatedBy: .newlines))
    }

    /// 统一构造营养成分表识别结果。
    private static func makeNutritionFoodResult(name: String?,
                                                 energyKcal: Double,
                                                 macros: (protein: Double?, carbs: Double?, fat: Double?)) -> RecognitionResult {
        let foodName = (name?.trimmingCharacters(in: .whitespaces).isEmpty == false) ? name! : "包装食品"
        let payload = FoodPayload(
            name: foodName,
            calories: energyKcal,
            protein: macros.protein,
            carbs: macros.carbs,
            fat: macros.fat,
            portion: "100克",
            meal: nil,
            action: "create",
            targetTitle: nil
        )
        return RecognitionResult(types: ["food"], confidence: 0.82,
                                  bill: nil, bills: nil, food: payload,
                                  todo: nil, health: nil)
    }

    /// 本地优先识别入口（UIImage 版）。先 OCR+规则；命中返回 local，否则回退云端。
    static func recognizeWithLocalPriority(image: UIImage, in context: ModelContext) async throws -> (result: RecognitionResult, rawText: String, source: RecognitionSource) {
        guard let data = image.jpegData(compressionQuality: 0.9) ?? image.pngData() else {
            // 无法转 data（极罕见）：直接 visual 兜底
            let output = try await recognize(image: image)
            return (output.result, output.rawText, .cloud)
        }
        return try await recognizeWithLocalPriority(imageData: data, in: context)
    }

    /// 本地优先识别入口（Data 版，省一次压缩）。
    ///
    /// 【识别链路 · 2026-07-22 重构，单一清晰路径】
    ///   ① 本地 OCR（离线、零成本）——仅用于：判断是否营养成分表 + 视觉模型失败时兜底。
    ///   ② 营养成分表 → 本地版面解析（成分表密集数字视觉模型反而易错，本地更准）。命中即返回 .local。
    ///   ③ 其它所有图片（单账单 / 多账单 / 食物 / 体检 / 待办 / 普通照片）→ 统一走视觉模型（.cloud）。
    ///   ④ 视觉模型失败 → 本地规则尽力兜底（多账单/单账单）；都没有则抛错，由上层提示，绝不返回 0.00 空账单。
    ///
    /// 设计原则：「全部传图给模型，精度优先」。不再按免费/付费档位拦截视觉；不再让本地规则提前胜出。
    /// 唯一的本地强规则例外是营养成分表（有专门的版面分析，且零成本更准）。
    static func recognizeWithLocalPriority(imageData: Data, in context: ModelContext) async throws -> (result: RecognitionResult, rawText: String, source: RecognitionSource) {
        // ① 本地 OCR
        let ocr = localOCR(from: imageData, customWords: merchantBiasWords(in: context))
        let cleanText = ocr?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let observations = ocr?.observations ?? []

        // ② 营养成分表快速通道（唯一的本地强规则例外）
        let nutritionLines = cleanText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if hasNutritionTable(in: nutritionLines) {
            if let food = localParseNutritionTable(observations: observations)
                        ?? localParseNutritionTable(text: cleanText) {
                print("[识别] 营养成分表本地解析命中，source=local")
                return (food, cleanText, .local)
            }
            // 检测到成分表但本地解析失败：先让视觉模型试着读品牌/名称，失败再用占位 food。
            // 关键：绝不落到账单路径（避免把「3.1g/12.0g」当金额）。
            print("[识别] 营养成分表检测到但本地解析失败，改走视觉模型，失败则占位 food")
            do {
                let vision = try await recognizeResilient(imageData: imageData)
                return (vision.result, vision.rawText, .cloud)
            } catch {
                let placeholderFood = RecognitionResult(
                    types: ["food"], confidence: 0,
                    bill: nil, bills: nil,
                    food: FoodPayload(name: "包装食品", calories: 0,
                                      protein: nil, carbs: nil, fat: nil,
                                      portion: "100克", meal: nil,
                                      action: "create", targetTitle: nil),
                    todo: nil, health: nil)
                return (placeholderFood, cleanText, .local)
            }
        }

        // ③ 其它所有图片 → 统一视觉模型
        // 例外：支付宝/微信「支付消息/服务消息/账单列表」等强列表页，本地拆条对商户/时间的
        // 识别更稳定（视觉模型对列表常把商户/时间搞错），因此本地优先；本地拆不出 ≥2 笔再回退视觉。
        let strongListSignals = ["支付消息", "服务消息", "支付记录", "账单列表", "我的账单"]
        let isStrongList = strongListSignals.contains(where: { cleanText.localizedCaseInsensitiveContains($0) })
        if isStrongList, !cleanText.isEmpty {
            if let localMulti = localParseMultiBillsIfNeeded(text: cleanText, in: context),
               let bills = localMulti.bills, bills.count >= 2 {
                print("[识别] 强列表信号命中，本地多账单拆条优先，source=local")
                return (localMulti, cleanText, .local)
            }
        }

        do {
            let vision = try await recognizeResilient(imageData: imageData)
            print("[识别] 视觉模型命中，source=cloud")

            // ③-1 视觉模型返回 none / 空账单，但本地 OCR 明显能拆出账单时，用本地结果补救。
            // 典型情况：支付消息列表、账单详情等截图因构图/质量被模型误判为 none。
            let types = vision.result.types ?? []
            let hasBill = vision.result.billList.contains { $0.amount != nil }
            if (types.contains("none") || types.isEmpty || !hasBill), !cleanText.isEmpty {
                if let localMulti = localParseMultiBillsIfNeeded(text: cleanText, in: context) {
                    print("[识别] 视觉模型返回 none，本地多账单拆条补救命中，source=local")
                    return (localMulti, cleanText, .local)
                }
                if let local = localParseBill(text: cleanText, in: context, candidates: ocr?.candidates ?? []) {
                    print("[识别] 视觉模型返回 none，本地单账单规则补救命中，source=local")
                    return (local, cleanText, .local)
                }
            }
            return (vision.result, vision.rawText, .cloud)
        } catch {
            // ④ 视觉失败 → 本地规则尽力兜底（有 OCR 文本时）
            print("[识别] 视觉模型失败，尝试本地兜底：\(error)")
            if !cleanText.isEmpty {
                if let localMulti = localParseMultiBillsIfNeeded(text: cleanText, in: context) {
                    print("[识别] 视觉失败，本地多账单拆条兜底命中，source=local")
                    return (localMulti, cleanText, .local)
                }
                if let local = localParseBill(text: cleanText, in: context, candidates: ocr?.candidates ?? []) {
                    print("[识别] 视觉失败，本地单账单规则兜底命中，source=local")
                    return (local, cleanText, .local)
                }
            }
            // 本地也兜不住：抛错让上层提示「识别失败，请重试」，绝不返回 0.00 空账单。
            throw error
        }
    }

    // MARK: 本地规则解析辅助

    /// 提取金额：优先匹配 ¥/￥/元等明确货币标识；在 force 模式下（已命中账单场景词），
    /// 也支持「-18.00」这类支付详情里的裸金额，或带两位小数的数字。
    /// 取金额置信度最高的候选，并主动排除银行卡/信用卡号、手机号等噪声。
    private static func extractAmount(_ text: String, force: Bool = false) -> Double? {
        let ns = text as NSString

        // 辅助：判断某个数字是否处在银行卡/手机号/订单号/会员卡号等噪声上下文中
        func isNoiseContext(range: NSRange) -> Bool {
            let windowLen = 22
            let start = max(0, range.location - windowLen)
            let end = min(ns.length, range.location + range.length + windowLen)
            let ctx = ns.substring(with: NSRange(location: start, length: end - start))
            let noiseKeywords = [
                "信用卡", "储蓄卡", "银行卡", "借记卡", "尾号", "卡号", "卡(",
                "phone", "电话", "手机",
                "订单号", "订单编号", "订单", "流水号", "流水", "会员卡", "会员", "会员号",
                "开票号", "发票代码", "发票号码", "电子发票", "税号", "客服电话", "客服"
            ]
            return noiseKeywords.contains { ctx.localizedCaseInsensitiveContains($0) }
        }

        // 辅助：判断数字是否紧邻小票金额标签（应收/实收/合计/总计/成交价/微信/支付宝等），增加置信度
        func nearAmountLabel(range: NSRange) -> Bool {
            let windowLen = 18
            let start = max(0, range.location - windowLen)
            let end = min(ns.length, range.location + range.length + windowLen)
            let ctx = ns.substring(with: NSRange(location: start, length: end - start))
            let labels = ["应收", "实收", "合计", "总计", "总金额", "成交价", "实付", "应付", "支付", "微信", "支付宝", "现金"]
            return labels.contains { ctx.localizedCaseInsensitiveContains($0) }
        }

        // 辅助：判断数字是否处在「日期串」内部（如 2026-07-21 19:09:35 里的月/日/时分秒）。
        // 这些数字不是金额，force 模式下若当成候选（尤其 YYYY-MM-DD 里带负号的月/日），
        // 会因负号 + 紧邻「支付」标签而得分过高，需直接跳过。
        func isDateContext(range: NSRange) -> Bool {
            let datePattern = #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})(?:[\sT](\d{1,2}):(\d{2})(?::(\d{2}))?)?"#
            guard let regex = try? NSRegularExpression(pattern: datePattern, options: []) else { return false }
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let dr = m.range
                if range.location >= dr.location && range.location + range.length <= dr.location + dr.length {
                    return true
                }
            }
            return false
        }

        struct Candidate: Comparable {
            let value: Double
            let score: Int           // 越高越可信
            let hasNegative: Bool    // 是否是支出负号
            static func < (lhs: Candidate, rhs: Candidate) -> Bool { lhs.score < rhs.score }
        }
        var candidates: [Candidate] = []

        // 1) 明确货币：¥/￥数字 或 数字元（最高置信度）
        let explicitPattern = #"(?:¥|￥)\s*([+-]?\d+(?:\.\d{1,2})?)|([+-]?\d+(?:\.\d{1,2})?)\s*元\b"#
        if let regex = try? NSRegularExpression(pattern: explicitPattern, options: []) {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                for i in 1...2 where i < m.numberOfRanges {
                    let r = m.range(at: i)
                    guard r.location != NSNotFound, let v = Double(ns.substring(with: r)) else { continue }
                    if abs(v) > 1_000_000 { continue }
                    candidates.append(Candidate(value: abs(v), score: 100, hasNegative: false))
                }
            }
        }

        // 1.5) 金额独占一行且带负号或两位小数：在账单截图中是真实支付金额的强信号，
        //     直接加入候选并跳过噪声上下文检查（避免被上方「订单号」等标签误杀）。
        if force {
            let amountOnlyPattern = #"^([+-]?)\s*(\d+(?:\.\d{1,2})?)$"#
            // .anchorsMatchLines 让 ^/$ 匹配每一行的开头/结尾，从而在多行 OCR 文本中逐行检测。
            if let regex = try? NSRegularExpression(pattern: amountOnlyPattern, options: .anchorsMatchLines) {
                for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let signRange = m.range(at: 1)
                    let numRange = m.range(at: 2)
                    guard numRange.location != NSNotFound,
                          let v = Double(ns.substring(with: numRange)) else { continue }
                    if v > 1_000_000 { continue }
                    let sign = signRange.location != NSNotFound ? ns.substring(with: signRange) : ""
                    let hasNegative = sign == "-"
                    let hasDecimal = numRange.length > 1 && ns.substring(with: numRange).contains(".")
                    guard hasNegative || hasDecimal else { continue }
                    let score = hasNegative ? 100 : 95
                    candidates.append(Candidate(value: abs(v), score: score, hasNegative: hasNegative))
                }
            }
        }

        // 2) 强账单场景下：匹配「-数字」或带两位小数的金额（如 -18.00 / 18.00）。
        //    负号支出金额优先；同时过滤银行卡号/手机号/年份。
        if force {
            let loosePattern = #"([+-]?)\s*(\d+(?:\.\d{1,2})?)"#
            if let regex = try? NSRegularExpression(pattern: loosePattern, options: []) {
                for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let signRange = m.range(at: 1)
                    let numRange = m.range(at: 2)
                    guard numRange.location != NSNotFound,
                          let v = Double(ns.substring(with: numRange)) else { continue }

                    // 4 位整数且像年份（1900-2100）不算金额
                    if v >= 1900 && v <= 2100 && floor(v) == v && numRange.length == 4 { continue }
                    if v > 1_000_000 { continue }

                    // 银行卡/手机号等噪声上下文直接跳过
                    if isNoiseContext(range: numRange) { continue }

                    // 日期串内部数字（如 2026-07-21 里的 -07 / -21、时分秒）不是金额，跳过
                    if isDateContext(range: numRange) { continue }

                    let hasNegative = signRange.location != NSNotFound && ns.substring(with: signRange) == "-"
                    // 负号金额 / 紧邻金额标签 / 带小数点 → 更像真实金额
                    var score = (hasNegative ? 90 : 50)
                    if nearAmountLabel(range: numRange) { score += 25 }
                    if numRange.length > 2 { score += 5 }
                    candidates.append(Candidate(value: v, score: score, hasNegative: hasNegative))
                }
            }
        }

        guard let best = candidates.max() else { return nil }
        return best.value
    }

    // MARK: - ③ OCR 多候选增强（金额/时间）

    /// 跨 OCR 多候选提取金额：对每个候选串跑「强金额信号」正则（货币符号/两位小数/独占金额行），
    /// 按「规则得分 + OCR 置信度」综合打分取最高分。解决数字易混（8↔3、1↔7 等）问题。
    /// 易混数字纠正：在「产出 top1 的那个 OCR 块内部」寻找与 top 仅易混数字不同的高置信替代候选。
    /// 返回纠正后的金额；无可靠纠正时返回 nil。
    /// 设计要点：只检查与 top1 同块的候选（block.first 即该块 top1 读数），
    /// 因此不会被同图其他块（如商品明细价）干扰。
    private static func confusableCorrection(_ top: Double,
                                             candidates: [[(string: String, confidence: Float)]],
                                             force: Bool) -> Double? {
        for block in candidates {
            guard let top1 = block.first,
                  let blockTop = amountFromCandidateText(top1.string, force: force),
                  blockTop == top else { continue }
            // 此块即产出 top1 的块：在块内其余候选里找易混替代
            for cand in block.dropFirst() {
                guard let v = amountFromCandidateText(cand.string, force: force),
                      v != top,
                      isConfusableDigits(top, v),
                      cand.string.range(of: #"[¥￥]"#, options: .regularExpression) != nil,
                      cand.confidence >= 0.5 else { continue }
                return v
            }
        }
        return nil
    }

    private static func extractAmountCandidates(_ candidates: [[(string: String, confidence: Float)]], force: Bool) -> (value: Double, score: Int)? {
        var best: (value: Double, score: Int)?
        for block in candidates {
            for cand in block {
                guard let v = amountFromCandidateText(cand.string, force: force) else { continue }
                // 得分：带货币符号基础分更高；再叠加 OCR 置信度（0~1 → 0~50）。
                var s = cand.string.range(of: #"[¥￥]"#, options: .regularExpression) != nil ? 100 : 95
                s += Int(cand.confidence * 50)
                if best == nil || s > best!.score { best = (v, s) }
            }
        }
        return best
    }

    /// 从单条候选文本提取金额（复用与 extractAmount 一致的强信号正则）。
    private static func amountFromCandidateText(_ text: String, force: Bool) -> Double? {
        let ns = text as NSString
        let explicit = #"(?:¥|￥)\s*([+-]?\d+(?:\.\d{1,2})?)|([+-]?\d+(?:\.\d{1,2})?)\s*元\b"#
        if let regex = try? NSRegularExpression(pattern: explicit, options: []),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            for i in 1...2 where i < m.numberOfRanges {
                let r = m.range(at: i)
                if r.location != NSNotFound, let v = Double(ns.substring(with: r)), abs(v) <= 1_000_000 {
                    return abs(v)
                }
            }
        }
        let dec = #"(\d+\.\d{2})"#
        if let regex = try? NSRegularExpression(pattern: dec, options: []),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let v = Double(ns.substring(with: m.range(at: 1))), v <= 1_000_000 {
            return v
        }
        if force {
            let loose = #"^[+-]?\s*(\d+(?:\.\d{1,2})?)$"#
            if let regex = try? NSRegularExpression(pattern: loose, options: .anchorsMatchLines),
               let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let v = Double(ns.substring(with: m.range(at: 1))), v <= 1_000_000 {
                return v
            }
        }
        return nil
    }

    /// 判断两个金额是否「仅字符易混不同」（数字形态相近，OCR 常混淆）。
    /// 用于候选纠正：当 top1 金额与高置信候选仅易混数字不同时，采信候选。
    private static func isConfusableDigits(_ a: Double, _ b: Double) -> Bool {
        let sa = String(format: "%.2f", a).filter { $0.isNumber }
        let sb = String(format: "%.2f", b).filter { $0.isNumber }
        guard a != b else { return false } // 完全相同不可能被混淆
        guard sa.count == sb.count, !sa.isEmpty else { return false }
        let confusable: Set<Set<Character>> = [
            ["0","8"],["1","7"],["3","8"],["5","6"],["2","7"],["6","8"],["4","9"],
            ["3","5"],["7","9"],["0","6"],["8","9"],["4","7"]
        ]
        for (ca, cb) in zip(sa, sb) {
            if ca == cb { continue }
            guard confusable.contains(where: { $0.contains(ca) && $0.contains(cb) }) else { return false }
        }
        return true
    }

    /// 跨 OCR 多候选提取时间：对每个候选串复用 extractISODateTime，按完整度+置信度打分取最优。
    private static func extractISODateTimeCandidates(_ candidates: [[(string: String, confidence: Float)]], referenceDate: Date?) -> String? {
        var best: (iso: String, score: Int)?
        for block in candidates {
            for cand in block {
                guard let iso = extractISODateTime(cand.string, referenceDate: referenceDate) else { continue }
                // 完整时间戳（含 T）+20；纯日期 +10；再叠加 OCR 置信度（0~1 → 0~30）。
                var s = iso.contains("T") ? 20 : 10
                s += Int(cand.confidence * 30)
                if best == nil || s > best!.score { best = (iso, s) }
            }
        }
        return best?.iso
    }

    /// 判断字符串是否像时间或日期，商户名绝不应是时间/日期。
    /// 覆盖：纯时分秒、YYYY-MM-DD、今天/昨天+时刻、星期X+时刻、M月D日+时刻、纯 M月D日、列表项短格式。
    /// 注意：只用于「不要把它当商户」的过滤；不代表「可作为支付时间」——支付时间仍由
    /// extractISODateTime 严格匹配「支付时间/付款时间/交易时间/创建时间」标签。
    private static func isLikelyTime(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        // OCR 常把冒号读成点号（如 19.09），统一按冒号判断；末尾可能带 | 等噪声
        let tn = t.replacingOccurrences(of: ".", with: ":")
                  .trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "|〉＞>）)")))
        // 纯时分秒（如 19:11、09:00:30）
        let timeOnly = tn.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
        // 日期串（含分隔符的 YYYY-MM-DD 或 YYYY-MM-DD HH:MM[:SS]）
        let dateLike = t.range(of: #"^\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}"#, options: .regularExpression) != nil
        // 今天/昨天 + 时刻（如 今天 19:09、昨天10:40、昨天 19.09）
        let relTime = tn.range(of: #"^(?:今天|昨天)\s*\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
        // 今天/昨天 + 无冒号4位/3位时刻（如 昨天1714、昨天909）——支付宝列表常见简写
        let relShortTime = t.range(of: #"^(?:今天|昨天)\s*\d{3,4}$"#, options: .regularExpression) != nil
        // 星期X + 时刻（如 星期四 18:26、星期四18:37）
        let weekdayTime = tn.range(of: #"^星期[一二三四五六日天]\s*\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
        // M月D日 + 时刻（如 7月21日 15:39、7月21日15:39、7月21日 15:39:07）
        let mdTime = tn.range(of: #"^\d{1,2}月\d{1,2}日\s*\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
        // 纯 M月D日（如 7月21日、07-21）——列表项简写
        let mdOnly = t.range(of: #"^\d{1,2}月\d{1,2}日$"#, options: .regularExpression) != nil
        // MM-DD HH:MM / MM-DD（如 07-21 15:39、07-21）——列表项短格式
        let shortDateTime = t.range(of: #"^\d{1,2}[-/.]\d{1,2}(\s+\d{1,2}:\d{2}(?::\d{2})?)?$"#, options: .regularExpression) != nil
        return timeOnly || dateLike || relTime || relShortTime || weekdayTime || mdTime || mdOnly || shortDateTime
    }

    /// 判断字符串是否为重量/规格/单位，商户名绝不应是「400g」「0g」「件数」等。
    private static func isWeightOrUnit(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.range(of: #"^[\d.oO]+\s*[gG克kg千克ml毫升l升]$"#, options: .regularExpression) != nil
            || t.range(of: #"^[\d.oO]+\s*(个|件|瓶|包|袋|盒|罐)$"#, options: .regularExpression) != nil
            || ["件", "件数", "数量", "单位", "规格"].contains(t)
    }

    // MARK: - 一图多账单拆分辅助

    /// 判断单行是否为金额：¥/￥ 开头 或 裸数字（可带 +- 号）。
    /// 排除 "¥398:00" 这类 OCR 把原价小数点误识别为冒号的噪声，以及纯年月。
    private static func isAmountLine(_ line: String) -> Bool {
        // 含冒号不是金额
        if line.contains(":") || line.contains("：") { return false }
        let hasCurrency = line.range(of: #"[¥￥]\s*\d"#, options: .regularExpression) != nil
        // 裸金额：限制整数部分最多 7 位，避免把订单号/业务交易号/流水号（通常 ≥10 位）误判为金额行。
        let hasBare = line.range(of: #"^\s*[+-]?\s*\d{1,7}(?:\.\d{1,2})?\s*$"#, options: .regularExpression) != nil
        return hasCurrency || hasBare
    }

    /// 汇总金额行：顶部统计、本月已省、支出/收入合计等，不应被识别为单条账单。
    private static func isSummaryAmountLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let summaryKeywords = ["本月已省", "收支统计", "本月支出", "本月收入", "本月总额",
                               "支出合计", "收入合计", "总支出", "总收入", "累计支出", "累计收入"]
        if summaryKeywords.contains(where: { lowered.contains($0) }) { return true }
        // 同时出现 支出+金额 和 收入+金额 的汇总行
        let hasExpense = line.range(of: #"支出.*\d+(?:\.\d{1,2})?"#, options: .regularExpression) != nil
        let hasIncome = line.range(of: #"收入.*\d+(?:\.\d{1,2})?"#, options: .regularExpression) != nil
        if hasExpense && hasIncome { return true }
        // 单侧的支出/收入汇总（如「本月支出¥391.35，较上月降低＞」、「上月支出¥254.50」）
        if line.contains("支出") || line.contains("收入") {
            // 明确是汇总统计：含「较上月」「同比」「今年」「近30天」等统计语境
            let statSignals = ["较上月", "同比", "今年", "近30天", "近7天", "比上月", "统计", "汇总"]
            if statSignals.contains(where: { lowered.contains($0) }) { return true }
        }
        // 微信账单顶部常见：「支出 391.35」「收入 254.50」等纯汇总数字（无交易商户）。
        // 注意：必须含「支出/收入」关键字才判为汇总，避免误伤正常交易金额。
        if lowered.contains("支出") || lowered.contains("收入") {
            if line.range(of: #"\d+(?:\.\d{1,2})?"#, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// 从一图多账单的所有行中，取出某个金额行对应的上下文区域。
    private static func extractRegionLines(lines: [String], amountIndex: Int, amountIndices: [Int]) -> [String] {
        guard let pos = amountIndices.firstIndex(of: amountIndex) else { return [] }
        let prev = (pos > 0) ? amountIndices[pos - 1] : -1
        let next = (pos + 1 < amountIndices.count) ? amountIndices[pos + 1] : lines.count
        let start = (prev == -1) ? 0 : (prev + amountIndex) / 2
        let end = (next == lines.count) ? lines.count - 1 : (amountIndex + next) / 2
        guard start <= end, start >= 0, end < lines.count else { return [] }
        return Array(lines[start...end])
    }

    /// 在一个条目文本块内寻找最可能的商户名（不查 MerchantMeta，只做文本规则）。
    /// 用于一图多账单的 detect 阶段，避免依赖 context。
    private static func findMerchantInBlock(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let blocklist: Set<String> = [
            "支付成功", "交易成功", "付款成功", "已付款", "支付完成", "交易完成",
            "订单金额", "支付金额", "交易金额", "付款金额", "实付金额", "应收", "实收",
            "合计", "总计", "总金额", "支付有礼", "完成", "返回", "首页", "账单详情",
            "支付方式", "付款方式", "交易方式", "付款方", "收款方",
            "支付时间", "付款时间", "交易时间", "创建时间",
            "订单号", "订单编号", "商家订单号", "流水号", "业务交易号"
        ]
        let uiNoise: Set<String> = ["全部", "支出", "收入", "转账", "退款", "订单", "筛选", "搜索",
                                     "收支分析", "我的账单", "支付服务", "摇优惠", "服务消息", "支付消息",
                                     "账单", "全部账单", "查找交易", "Q", "X", "本月已省",
                                     "账单详情", "查看详情", "音看详情", "付款方式", "支付方式",
                                     "支付奖励", "本次奖励", "联系收款方", "优惠"]
        let bankNoise = ["信用卡", "储蓄卡", "银行卡", "借记卡", "通过", "使用"]

        for (i, line) in lines.enumerated() {
            // 金额独占一行时，其正上方或正下方有效行是商户
            if line.range(of: #"^[+-]?\s*\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil ||
               line.range(of: #"[¥￥]\s*\d"#, options: .regularExpression) != nil {
                for delta in [-1, 1] {
                    let j = i + delta
                    guard j >= 0, j < lines.count else { continue }
                    let cand = lines[j]
                    if uiNoise.contains(cand) { continue }
                    if blocklist.contains(cand) { continue }
                    if isLikelyTime(cand) { continue }
                    if bankNoise.contains(where: { cand.contains($0) }) { continue }
                    if cand.count >= 2 { return normalizeMerchant(cand) }
                }
            }
        }
        return nil
    }

    /// 提取商户名：MerchantMeta 命中 > 标签提取 > 金额同行文本 > 首行文本。
    private static func extractMerchant(_ text: String, in context: ModelContext?) -> String {
        // 非商户词：即使被正则命中也应忽略（金额标签、状态提示、支付结果语、页面 UI 文字等）。
        let blocklist: Set<String> = [
            "支付成功", "交易成功", "付款成功", "已付款", "支付完成", "交易完成",
            "订单金额", "支付金额", "交易金额", "付款金额", "实付金额", "应收", "实收",
            "合计", "总计", "总金额", "支付有礼", "完成", "返回", "首页", "账单详情",
            "支付方式", "付款方式", "交易方式", "付款方", "收款方",
            "支付时间", "付款时间", "交易时间", "创建时间",
            "订单号", "订单编号", "商家订单号", "流水号", "业务交易号"
        ]
        func isValidMerchant(_ raw: String) -> Bool {
            let s = normalizeMerchant(raw)
            return s.count >= 2 && !s.isEmpty && !isLikelyTime(s) && !blocklist.contains(s) && !isWeightOrUnit(s)
        }

        if let ctx = context {
            let all = (try? ctx.fetch(FetchDescriptor<MerchantMeta>())) ?? []
            for m in all {
                // 防御（v4）：跳过被污染的时间串 key（如"19:09"/"2026-07-21"）。
                // 否则用户曾保存过错误记录（merchant="19:09"、category="交通"）后，
                // 下次扫描的 OCR 文本里只要出现支付时间"19:09:35"就会命中该 key，
                // 把时间误当商户名、并锁死分类为交通 —— 这正是真机复现「商户=19:09」的根因。
                guard !m.merchant.isEmpty,
                      !isLikelyTime(m.merchant),
                      !isWeightOrUnit(m.merchant) else { continue }
                if text.localizedCaseInsensitiveContains(m.merchant) {
                    return m.merchant
                }
            }
        }

        // 按优先级排列的标签提取规则（越靠前越优先）。
        // 支付宝账单常用「收款方全称」+ 脱敏 ** 前缀；微信用「付款方/收款方」；小票用「商家/店名」。
        // 注意：「收款方」类捕获要求至少 3 个字，避免两栏布局 OCR 把「全称」残字（如「金称」）误当商户值。
        let labelPatterns = [
            // 注意：\s 在 Swift 正则中会匹配换行，导致两栏布局把下一行标签误当值捕获。
            // 这里用 [\t ]* 限制为水平空白，确保只匹配同一行。
            #"收款方全称[\t ]*[:：]?[\t ]*\*{0,2}([^\n，,*()（）]{3,})"#,
            #"收款方[\t ]*[:：]?[\t ]*\*{0,2}([^\n，,*()（）]{3,})"#,
            #"商户[名称]*[:：][\t ]*([^\n，,]{2,})"#,
            #"对方账户[:：][\t ]*([^\n，,]{2,})"#,
            #"对方户名[:：][\t ]*([^\n，,]{2,})"#,
            #"商家[:：][\t ]*([^\n，,]{2,})"#,
            #"店名[:：][\t ]*([^\n，,]{2,})"#,
            #"商品说明[:：][\t ]*([^\n，,]{3,})"#,
            #"^[\t ]*([^\n，,()（）]+?)(?:[\t ]*[（(].*?[）)][\t ]*)?欢迎您"#  // 小票顶部店名，如「永辉(95HC 南宁盛隆世界店)欢迎您」
        ]
        for p in labelPatterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: []),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { continue }
            let found = String(text[r])
            if isValidMerchant(found) { return normalizeMerchant(found) }
        }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 金额独占一行时，其正上方一行通常是商户名（支付宝/微信账单详情页布局）。
        // 例如 Vision OCR 输出中，「阿里云」的下一行就是「-10.00」。
        let amountOnlyPattern = #"^[+-]?\s*\d+(?:\.\d{1,2})?$"#
        if let regex = try? NSRegularExpression(pattern: amountOnlyPattern, options: []) {
            for (i, line) in lines.enumerated() where i > 0 {
                let range = NSRange(location: 0, length: (line as NSString).length)
                guard regex.firstMatch(in: line, range: range) != nil else { continue }
                let prev = lines[i - 1]
                if isValidMerchant(prev) { return normalizeMerchant(prev) }
            }
        }

        // 跨行标签兜底：Vision OCR 两栏布局常把左栏标签和右栏值拆成多行。
        // 例如「收款方全称」与「阿里云计算有限公司」分别在两行；
        // 本兜底在标签后续若干行内寻找有效商户名，跳过其他标签与噪声。
        let merchantLabels = [
            "收款方全称", "收款方", "商户", "商户名称", "商家", "商家名称",
            "对方户名", "对方账户", "店名", "商品说明"
        ]
        let otherLabels: Set<String> = [
            "支付时间", "付款时间", "交易时间", "创建时间",
            "支付方式", "付款方式", "交易方式",
            "订单号", "订单编号", "商家订单号", "流水号",
            "账单详情", "账单分类", "支付奖励",
            "付款金额", "支付金额", "交易金额", "实付金额", "订单金额",
            "合计", "总计", "总金额", "应收", "实收",
            "账单管理", "标签", "备注", "计入收支"
        ]
        let knownCloudVendors = [
            "阿里云计算有限公司", "阿里云",
            "腾讯云计算（北京）有限责任公司", "腾讯云",
            "华为软件技术有限公司", "华为云",
            "北京百度网讯科技有限公司", "百度云",
            "京东云计算有限公司", "京东云"
        ]
        func isOtherLabel(_ line: String) -> Bool {
            otherLabels.contains(where: { line.localizedCaseInsensitiveContains($0) })
        }
        func isPureNumericOrOrder(_ s: String) -> Bool {
            let cleaned = s.replacingOccurrences(of: " ", with: "")
            if cleaned.range(of: #"^\d{10,}$"#, options: .regularExpression) != nil { return true }
            if cleaned.range(of: #"^[A-Z0-9]{10,}$"#, options: .regularExpression) != nil { return true }
            return false
        }
        for (i, line) in lines.enumerated() {
            guard merchantLabels.contains(where: { line.localizedCaseInsensitiveContains($0) }) else { continue }
            // 同一行值（如 "收款方全称：阿里云计算有限公司"）已由 labelPatterns 处理，
            // 这里只处理标签与值不在同一行的场景。
            for j in (i + 1)..<min(i + 16, lines.count) {
                let candidate = lines[j]
                if isOtherLabel(candidate) { continue }
                // 已知云厂商完整名直接命中（避免被后续通用规则截断或误清洗）
                for vendor in knownCloudVendors where candidate.localizedCaseInsensitiveContains(vendor) {
                    return normalizeMerchant(vendor)
                }
                // 去掉可能残留的标签前缀后验证
                let stripped = candidate.replacingOccurrences(
                    of: #"^(收款方全称|收款方|商户名称|商户|商家名称|商家|对方户名|对方账户|店名|商品说明)\s*[:：]?\s*"#,
                    with: "",
                    options: .regularExpression)
                if isValidMerchant(stripped), !isPureNumericOrOrder(stripped) {
                    return normalizeMerchant(stripped)
                }
            }
        }

        // 金额同行商户：形如 "阿里云    ¥10.00"，取金额左侧文本作为商户名。
        // 这是支付宝账单详情页常见布局，收款方没有独立标签，而是和金额在同一行左侧。
        let amountLinePattern = #"^(.+?)\s*[¥￥]\s*\d"#
        if let regex = try? NSRegularExpression(pattern: amountLinePattern, options: []),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            let found = String(text[r])
            if isValidMerchant(found) { return normalizeMerchant(found) }
        }

        if let first = lines.first, !first.isEmpty,
           extractAmount(first) == nil, isValidMerchant(first) {
            return normalizeMerchant(first)
        }
        return ""
    }

    /// 清理商户名：去掉支付宝/微信常见的星号脱敏、首尾空格、以及「(个人)」等后缀。
    /// 小票店名如「永辉(95HC 南宁盛隆世界店)」保留「永辉」即可。
    private static func normalizeMerchant(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "（", with: "(")
        s = s.replacingOccurrences(of: "）", with: ")")
        // 优先去掉小票/列表里常见的分店/位置后缀，保留品牌名。
        // 规则：
        //  ① 命中已知小票/商户后缀关键词（个人/商户/官方/店/世界/广场/中心/HC）→ 剥
        //  ② 括号内含地址/位置/分店号/分店提示词 → 剥
        //  ③ 括号紧跟"（）...（）"中内容是中文地址/街道/学院/分店 → 剥
        //  ④ 开头有 `（` 但 OCR 截掉了 `）`（如「老汤和·乌鸡米线（西乡塘大学东..."）→ 剥
        if let r = s.range(of: #"\([^)]*\)"#, options: .regularExpression) {
            let suffix = String(s[r]).lowercased()
            let inside = String(suffix.dropFirst().dropLast())
            let knownSuffix = ["个人", "商户", "官方", "店", "世界", "广场", "中心", "hc"]
            let locationHint = ["路", "街", "号", "区", "市", "省", "东", "西", "南", "北",
                                "学院", "大学", "医院", "楼", "层", "室", "栋", "座", "园",
                                "店", "分店", "门店", "地址", "位置", "印象城", "广场"]
            if knownSuffix.contains(where: { inside.contains($0) }) ||
                locationHint.contains(where: { inside.contains($0) }) {
                s.removeSubrange(r)
            }
        } else if let openParenIdx = s.firstIndex(of: "(") {
            // ④ 截断的左括号：含位置/地址/分店关键词时剥到末尾
            let inside = String(s[s.index(after: openParenIdx)...])
            let locationHint = ["路", "街", "号", "区", "市", "省", "东", "西", "南", "北",
                                "学院", "大学", "医院", "楼", "层", "室", "栋", "座", "园",
                                "分店", "门店", "印象城", "广场"]
            if locationHint.contains(where: { inside.contains($0) }) {
                s = String(s[..<openParenIdx])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ① 商户模糊纠错

    /// OCR 出的商户名与已知商户库做相似度匹配，超阈值自动纠正。
    /// 已知库 = 未删除的 MerchantMeta + 历史 Bill.merchant。返回纠正后的展示名（保留原始大小写/脱敏格式）。
    /// 匹配优先级：精确归一化 → 子串包含（任一方向）→ 编辑距离相似度 ≥ 0.6。
    private static func fuzzyCorrectMerchant(_ ocr: String, in context: ModelContext?) -> String? {
        guard let context, !ocr.isEmpty else { return nil }
        let norm = normalizeMerchant(ocr)
        guard norm.count >= 2, !isLikelyTime(norm), !isWeightOrUnit(norm) else { return nil }

        var known: [(display: String, key: String)] = []
        if let metas = try? context.fetch(FetchDescriptor<MerchantMeta>()) {
            for m in metas where !m.syncDeleted && !m.merchant.isEmpty
                                && !isLikelyTime(m.merchant)
                                && !isWeightOrUnit(m.merchant) {
                known.append((m.merchant, m.merchant))
            }
        }
        if let bills = try? context.fetch(FetchDescriptor<Bill>()) {
            for b in bills where !b.merchant.isEmpty && !isWeightOrUnit(b.merchant) {
                known.append((b.merchant, normalizeMerchant(b.merchant)))
            }
        }
        guard !known.isEmpty else { return nil }

        // 1) 精确归一化匹配（补齐 Bill 来源的已知商户）
        if let exact = known.first(where: { $0.key == norm }) { return exact.display }

        // 2) 子串包含（任一方向）→ 高置信纠正
        if let sub = known.first(where: { !$0.key.isEmpty && ($0.key.contains(norm) || norm.contains($0.key)) }) {
            return sub.display
        }

        // 3) 编辑距离相似度：归一化后相似度 ≥ 0.6 才纠正，避免误改正确的独特商户
        var best: (display: String, score: Double)?
        for k in known {
            let d = normalizedEditDistance(norm, k.key)
            let sim = 1.0 - Double(d) / Double(max(norm.count, k.key.count))
            if sim >= 0.6, best == nil || sim > best!.score {
                best = (k.display, sim)
            }
        }
        return best?.display
    }

    /// 归一化编辑距离：忽略大小写与空格，只比较字符序列。
    private static func normalizedEditDistance(_ a: String, _ b: String) -> Int {
        let sa = Array(a.lowercased().filter { !$0.isWhitespace })
        let sb = Array(b.lowercased().filter { !$0.isWhitespace })
        let m = sa.count, n = sb.count
        guard m > 0, n > 0 else { return max(m, n) }
        var dp = Array(repeating: 0, count: n + 1)
        for j in 0...n { dp[j] = j }
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let tmp = dp[j]
                if sa[i - 1] == sb[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = min(prev + 1, dp[j] + 1, dp[j - 1] + 1)
                }
                prev = tmp
            }
        }
        return dp[n]
    }

    /// 提取日期时间并转 ISO8601（含时区）。优先从「支付时间/付款时间/交易时间」行精确提取，
    /// 其次尝试任意位置的完整时间戳；未识别返回 nil（绝不回退 Date()/当前时刻）。
    ///
    /// 支持的格式示例：
    ///   "支付时间   2026-07-21 13:31:19"
    ///   "付款时间：2026/07/21 15:30"
    ///   "2026-07-21T13:31:19+08:00"
    ///   "2026年7月21日 13点31分"
    ///   "今天 19:09" / "昨天 10:40" / "7月21日 15:39"
    /// - Parameter referenceDate: 保留参数以兼容调用方；当前实现已不使用（仅靠「支付时间」标签匹配）。
    private static func extractISODateTime(_ text: String, referenceDate: Date? = nil) -> String? {
        // 业务规则（2026-07-22 用户明确）：
        // 1) 优先「支付时间/付款时间/交易时间/创建时间」标签下的时间戳。
        // 2) 没有就 fallback 到 .now（localParseBill 处理），**绝不**用状态栏时间或裸 HH:MM。
        // 因此「今天/M月D日/星期X + 时刻」/「纯 HH:MM」等任何不含支付时间标签的相对/裸时间
        // 都不再参与返回，强制走 .now。
        _ = referenceDate

        // ── 第 1 优先级：带标签的时间行（支付宝/微信账单标准格式）──
        // 匹配 "支付时间/付款时间/交易时间/创建时间" 后跟的完整时间戳。
        // 注意：day 之后允许可选「日」（如「2026年7月22日 15:31:11」），否则会被 dateOnly 截走。
        let labeledPatterns = [
            #"(?:支付时间|付款时间|交易时间|创建时间)\s*[:：]?\s*(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?(?:\s+[T\s]?(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#,
            #"(?:支付时间|付款时间|交易时间|创建时间)\s*[:：]?\s*(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?"#,
        ]
        if let result = tryExtractDateTime(from: text, using: labeledPatterns) {
            return result
        }

        // ── 第 2 优先级：任意位置的完整时间戳（含时分秒）──
        let fullPatterns = [
            #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})[\sT](\d{1,2}):(\d{2})(?::(\d{2}))?"#,
            #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#,
        ]
        if let result = tryExtractDateTime(from: text, using: fullPatterns) {
            return result
        }

        // ── 第 3 优先级：纯日期（无时间）──
        let dateOnlyPatterns = [
            #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#,
            #"(\d{1,2})[-/.月](\d{1,2})[日]"#,
        ]
        if let result = tryExtractDateTime(from: text, using: dateOnlyPatterns) {
            return result
        }

        // ── 兜底：两栏布局（Vision OCR 常把支付宝左栏标签和右栏值分成多行）──
        // 先找到「支付时间」等标签，再在它附近（同一行或后续若干行）找完整时间戳。
        // 实测截图中标签与值可相隔 8 行以上，因此窗口放宽到 15 行，同时仍优先匹配完整日期+时间，
        // 避免把状态栏时间（如 21:42，无日期）误判为支付时间。
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let timeLabels = ["支付时间", "付款时间", "交易时间", "创建时间"]
        for (i, line) in lines.enumerated() {
            guard timeLabels.contains(where: { line.localizedCaseInsensitiveContains($0) }) else { continue }
            // 同一行
            if let result = tryExtractDateTime(from: line, using: fullPatterns) { return result }
            // 后续 15 行内（覆盖两栏布局中标签与值的远距离错位）
            let nearby = Array(lines[i..<min(i + 16, lines.count)]).joined(separator: "\n")
            if let result = tryExtractDateTime(from: nearby, using: fullPatterns) { return result }
        }

        return nil
    }

    /// 解析列表项时间格式：支付列表/服务消息卡片中显示的相对或短日期时间。
    /// 用户明确声明「列表项时间就是支付时间」，因此在多账单路径中，定位到的 timeLine
    /// 应作为支付时间使用。
    /// 支持格式：7月21日15:39、7月21日 15:39、昨天19:09、昨天 19:09、昨天1714、7月21日、今天02:08、纯 HH:MM。
    /// - Parameter defaultYesterday: 纯 HH:MM 无日期线索时，是否默认昨天（支付消息列表多为历史记录）。
    /// - Returns: ISO8601 格式字符串，失败返回 nil。
    private static func parseListItemTime(_ timeLine: String?, referenceDate: Date? = nil, defaultYesterday: Bool = false) -> String? {
        guard let raw = timeLine, !raw.isEmpty else { return nil }
        // OCR 常把冒号读成点号，末尾可能粘附带状线/箭头（如 19.09|），先归一化
        let text = raw
            .replacingOccurrences(of: ".", with: ":")
            .trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "|〉＞>）)")))
        guard !text.isEmpty else { return nil }
        let ref = referenceDate ?? Date()
        let cal = Calendar.current
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!

        func iso(year: Int, month: Int, day: Int, h: Int, min: Int, s: Int) -> String? {
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            comps.hour = h; comps.minute = min; comps.second = s
            comps.timeZone = shanghai
            guard let d = cal.date(from: comps) else { return nil }
            let f = ISO8601DateFormatter(); f.timeZone = shanghai
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: d)
        }

        let ns = text as NSString

        // 1) M月D日 HH:MM[:SS] / M月D日HH:MM
        let mdTime = #"(\d{1,2})[月](\d{1,2})[日]?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"#
        if let re = try? NSRegularExpression(pattern: mdTime),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let mo = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let d = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let h = Int(ns.substring(with: m.range(at: 3))) ?? 0
            let mi = Int(ns.substring(with: m.range(at: 4))) ?? 0
            let s = m.numberOfRanges > 5 && m.range(at: 5).location != NSNotFound
                ? Int(ns.substring(with: m.range(at: 5))) ?? 0 : 0
            let y = cal.component(.year, from: ref)
            return iso(year: y, month: mo, day: d, h: h, min: mi, s: s)
        }

        // 2) 今天/昨天 HH:MM[:SS] / 今天HH:MM
        let relTime = #"(今天|昨天)\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"#
        if let re = try? NSRegularExpression(pattern: relTime),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let h = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let mi = Int(ns.substring(with: m.range(at: 3))) ?? 0
            let s = m.numberOfRanges > 4 && m.range(at: 4).location != NSNotFound
                ? Int(ns.substring(with: m.range(at: 4))) ?? 0 : 0
            let base: Date
            if ns.substring(with: m.range(at: 1)) == "昨天" {
                base = cal.date(byAdding: .day, value: -1, to: ref) ?? ref
            } else {
                base = ref
            }
            let y = cal.component(.year, from: base)
            let mo = cal.component(.month, from: base)
            let d = cal.component(.day, from: base)
            return iso(year: y, month: mo, day: d, h: h, min: mi, s: s)
        }

        // 2.5) 今天/昨天 + 无冒号3~4位时刻（如 昨天1714、昨天909）
        let relShortTime = #"(今天|昨天)\s*(\d{3,4})"#
        if let re = try? NSRegularExpression(pattern: relShortTime),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let raw = ns.substring(with: m.range(at: 2))
            let isYesterday = ns.substring(with: m.range(at: 1)) == "昨天"
            // 3位：HMM；4位：HHMM
            guard raw.count == 3 || raw.count == 4,
                  let n = Int(raw) else { return nil }
            let h: Int
            let mi: Int
            if raw.count == 4 {
                h = n / 100
                mi = n % 100
            } else {
                h = n / 100
                mi = n % 100
            }
            guard (0...23).contains(h), (0...59).contains(mi) else { return nil }
            let base = isYesterday
                ? (cal.date(byAdding: .day, value: -1, to: ref) ?? ref)
                : ref
            let y = cal.component(.year, from: base)
            let mo = cal.component(.month, from: base)
            let d = cal.component(.day, from: base)
            return iso(year: y, month: mo, day: d, h: h, min: mi, s: 0)
        }

        // 3) 纯 HH:MM（无日期线索）：支付消息列表多为昨天记录，可按 defaultYesterday 回退。
        let timeOnly = #"^(\d{1,2}):(\d{2})(?::(\d{2}))?$"#
        if let re = try? NSRegularExpression(pattern: timeOnly),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let h = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let mi = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let s = m.numberOfRanges > 2 && m.range(at: 3).location != NSNotFound
                ? Int(ns.substring(with: m.range(at: 3))) ?? 0 : 0
            let base = defaultYesterday
                ? (cal.date(byAdding: .day, value: -1, to: ref) ?? ref)
                : ref
            let y = cal.component(.year, from: base)
            let mo = cal.component(.month, from: base)
            let d = cal.component(.day, from: base)
            return iso(year: y, month: mo, day: d, h: h, min: mi, s: s)
        }

        return nil
    }

    /// 返回 referenceDate 前一天 00:00:00 的 ISO8601 字符串。
    /// 用于列表项时间完全缺失、但用户已声明「列表项时间就是支付时间」且截图含「昨天」时的兜底。
    private static func yesterdayStart(referenceDate: Date? = nil) -> String {
        let ref = referenceDate ?? Date()
        let cal = Calendar.current
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: ref) else {
            return ISO8601DateFormatter().string(from: ref)
        }
        var comps = cal.dateComponents(in: shanghai, from: yesterday)
        comps.hour = 0; comps.minute = 0; comps.second = 0
        guard let d = cal.date(from: comps) else {
            return ISO8601DateFormatter().string(from: ref)
        }
        let f = ISO8601DateFormatter(); f.timeZone = shanghai
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// 按给定的正则模式数组逐一尝试提取日期时间，第一个成功即返回。
    private static func tryExtractDateTime(from text: String, using patterns: [String]) -> String? {
        let ns = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }

            var y = Calendar.current.component(.year, from: Date())
            var mo = 0, d = 0, h = 0, min = 0, s = 0
            var hasTime = false

            // 按捕获组顺序解析：第1组通常是年份或月份（取决于是否有年份组）
            var idx = 1
            func nextInt() -> Int? {
                guard idx < m.numberOfRanges else { return nil }
                let r = m.range(at: idx); idx += 1
                guard r.location != NSNotFound else { return nil }
                return Int(ns.substring(with: r))
            }

            // 判断第一个捕获组是否为 4 位数字（年份）
            let firstRange = m.range(at: 1)
            guard firstRange.location != NSNotFound else { continue }
            let firstStr = ns.substring(with: firstRange)
            idx = 2  // 第 1 组已消费，后续从第 2 组开始读取
            if firstStr.count == 4, let yearVal = Int(firstStr) {
                y = yearVal           // 第1组是年份
                mo = nextInt() ?? 0; d = nextInt() ?? 0
                h = nextInt() ?? 0; min = nextInt() ?? 0; s = nextInt() ?? 0
            } else {
                // 第1组是月份（无年份）
                mo = Int(firstStr) ?? 0; d = nextInt() ?? 0
                h = nextInt() ?? 0; min = nextInt() ?? 0; s = nextInt() ?? 0
            }

            guard (1...12).contains(mo), (1...31).contains(d) else { continue }

            // 有明确时分说明用户意图包含时间
            hasTime = h > 0 || min > 0 || s > 0

            var comps = DateComponents(year: y, month: mo, day: d)
            if hasTime {
                comps.hour = h; comps.minute = min; comps.second = s
                comps.timeZone = TimeZone(identifier: "Asia/Shanghai")
            }
            if let date = Calendar.current.date(from: comps) {
                let formatter = ISO8601DateFormatter()
                if hasTime {
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                } else {
                    formatter.formatOptions = [.withFullDate]
                }
                return formatter.string(from: date)
            }
        }
        return nil
    }

    /// 无经验库时按关键词猜测分类/收支方向。
    /// merchant 优先：先根据已提取的商户名判断；未命中再看全文关键词。
    private static func guessCategory(_ merchant: String, _ text: String) -> (String, Bool) {
        let m = merchant.trimmingCharacters(in: .whitespaces)

        // 云服务：必须优先于全文关键词判断，避免被截图里的"打车券/红包"等优惠信息带偏。
        let cloudMerchants = [
            "阿里云", "阿里云计算有限公司",
            "腾讯云", "腾讯云计算（北京）有限责任公司",
            "华为云", "华为软件技术有限公司",
            "天翼云", "百度云", "京东云", "移动云", "金山云", "ucloud"
        ]
        if cloudMerchants.contains(where: { m.localizedCaseInsensitiveContains($0) }) ||
           text.localizedCaseInsensitiveContains("阿里云") || text.localizedCaseInsensitiveContains("腾讯云") ||
           text.localizedCaseInsensitiveContains("华为云") || text.localizedCaseInsensitiveContains("云计算") ||
           text.localizedCaseInsensitiveContains("云服务器") || text.localizedCaseInsensitiveContains("云数据库") ||
           text.localizedCaseInsensitiveContains("对象存储") || text.localizedCaseInsensitiveContains("ECS") ||
           text.localizedCaseInsensitiveContains("OSS") || text.localizedCaseInsensitiveContains("CDN") {
            return ("云服务", false)
        }

        if text.contains("工资") { return ("工资", true) }
        if text.contains("退款") || text.contains("收款") || text.contains("入账") || text.contains("收入") {
            return ("其他", true)
        }
        if text.contains("餐饮") || text.contains("饭") || text.contains("餐") || text.contains("经营码") {
            return ("餐饮", false)
        }
        if text.contains("医疗健康") || text.contains("医院") || text.contains("诊所") || text.contains("药店") {
            return ("医疗", false)
        }
        if text.contains("地铁") || text.contains("打车") || text.contains("公交") || text.contains("车费") {
            return ("交通", false)
        }
        if text.contains("购物") || text.contains("买") || text.contains("超市") || text.contains("便利店") {
            return ("购物", false)
        }
        if text.contains("医") { return ("医疗", false) }
        return ("其他", false)
    }

    // MARK: - 纠错样本回流（让识别越用越懂用户习惯）
    /// App 在确认页修改识别结果后，把「原始识别」与「用户修正」上报云端（/recognize?action=feedback），
    /// 写入 aia_corrections 集合，供后续识别作为 few-shot 注入。失败静默忽略，绝不阻塞主流程。
    static func reportCorrection(type: String, original: [String: Any], corrected: [String: Any]) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "action": "feedback",
            "type": type,
            "original": original,
            "corrected": corrected
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // 尽力而为：不等待、不抛错
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // 云函数返回外层包裹：{ ok, result, error }
    private struct CloudResponse: Decodable, Sendable {
        let ok: Bool
        let result: RecognitionResult?
        let error: String?
    }

    private struct ChatResponse: Decodable, Sendable {
        let ok: Bool
        let reply: String?
        let error: String?
    }
}
