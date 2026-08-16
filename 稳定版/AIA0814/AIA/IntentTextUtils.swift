import Foundation

/// 一句话多条记录的共享文本工具：按连词切分、账单商户清洗、健康指标解析。
/// 被 Siri 本地快析（LocalQuickParse）与聊天页本地记账（ChatView）共用。
enum IntentTextUtils {

    /// 按连词/标点把一句话拆成多个子句（用于一句话多条账单/待办/健康）。
    /// 不按「和/与」切分，因为它们常是商户名的一部分（如"汉堡和薯条"）。
    static func splitByConjunction(_ text: String) -> [String] {
        let separators = [",", "，", "。", "；", ";", "、", "\n", "以及", "还有", "另外", "然后", "接着", "并且", "再加上"]
        var segments = [text]
        for sep in separators {
            var next: [String] = []
            for seg in segments {
                for piece in seg.components(separatedBy: sep) {
                    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { next.append(trimmed) }
                }
            }
            segments = next
        }
        return segments.isEmpty ? [text] : segments
    }

    /// 一笔账单的餐次关键词表（与 RecognitionSaver.mealDefaultTime 保持一致）。
    /// 用于把「午餐花了10元晚餐花了15元」这种无连词的整句按餐次切开成多笔。
    static let billMealWords: [String] = [
        "早餐", "早饭", "早点", "早點",
        "午餐", "午饭", "中饭", "中餐",
        "晚餐", "晚饭", "夜饭",
        "夜宵", "宵夜", "夜消",
        "加餐", "点心", "零食"
    ]

    /// 把一句可能含多个餐次词的账单文本，按「餐次词」切成多条独立记账单元。
    /// 仅当文本里出现 ≥2 个餐次词时才切（否则原样返回，避免误伤「汉堡和薯条」这类正常商户名）。
    /// 例：「午餐花了10元晚餐花了15元」→ ["午餐花了10元", "晚餐花了15元"]
    static func splitBillsByMeal(_ text: String) -> [String] {
        let found = billMealWords.filter { text.contains($0) }
        guard found.count >= 2 else { return [text] }

        // 找到所有餐次词的起始位置，按出现顺序切分
        var cuts: [(range: Range<String.Index>, word: String)] = []
        for w in billMealWords where text.contains(w) {
            if let r = text.range(of: w) {
                cuts.append((r, w))
            }
        }
        cuts.sort { $0.range.lowerBound < $1.range.lowerBound }

        guard !cuts.isEmpty else { return [text] }

        var result: [String] = []
        for i in 0..<cuts.count {
            let start = cuts[i].range.lowerBound
            let end = (i + 1 < cuts.count) ? cuts[i + 1].range.lowerBound : text.endIndex
            let piece = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
        }
        return result.isEmpty ? [text] : result
    }

    /// 账单商户名清洗：去掉金额、花费动词、记账动词、量词等，得到干净商户名。
    /// 与 LocalQuickParse.parseBill 的旧实现保持一致，集中在此避免两处漂移。
    static func cleanMerchant(_ text: String) -> String {
        // 先保护餐次整体词（早餐/午餐/晚餐/早饭/午饭/晚饭/夜宵/宵夜…），
        // 避免被下方单字清洗（吃/喝/饭/餐）砍残成「早」「晚」。占位符不含中文字符，
        // 不会被任何清洗规则误伤，清洗完再原样还原。
        let mealWords = ["早餐", "早饭", "早点", "午餐", "午饭", "中饭", "中餐",
                         "晚餐", "晚饭", "夜饭", "夜宵", "宵夜", "夜消", "加餐", "点心", "零食"]
        // 占位符数量须与 mealWords 一一对应（16 个）。
        // 历史 bug：只写了 15 个，文本含「零食」(index 15) 时 placeholders[i] 越界崩溃。
        let placeholders = ["ZMA", "ZMB", "ZMC", "ZMD", "ZME", "ZMF", "ZMG", "ZMH", "ZMI", "ZMJ", "ZMK", "ZML", "ZMM", "ZMN", "ZMO", "ZMP"]
        assert(mealWords.count == placeholders.count, "mealWords 与 placeholders 长度必须一致")
        var t = text
        for (w, ph) in zip(mealWords, placeholders) where t.contains(w) {
            t = t.replacingOccurrences(of: w, with: ph)
        }
        t = t
            // 同时处理货币符号在前（¥15 / ￥15）和在后（15元 / 15块 / 15¥）两种写法。
            // 注意：必须先匹配「符号+数字」整体，否则只删掉数字会残留「¥」进商户名。
            .replacingOccurrences(of: #"(?:[¥￥]\s*)?\d+(?:\.\d+)?\s*(?:元|块|块钱|元钱|¥|￥)?"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: "花了", with: "")
            .replacingOccurrences(of: "花费", with: "")
            .replacingOccurrences(of: "付了", with: "")
            .replacingOccurrences(of: "付款", with: "")
            .replacingOccurrences(of: "消费", with: "")
            .replacingOccurrences(of: "买了", with: "")
            .replacingOccurrences(of: "充值", with: "")
            .replacingOccurrences(of: "交了", with: "")
            .replacingOccurrences(of: "支出", with: "")
            .replacingOccurrences(of: "开销", with: "")
            .replacingOccurrences(of: "了", with: "")
            .replacingOccurrences(of: "付", with: "")
            .replacingOccurrences(of: "买", with: "")
            .replacingOccurrences(of: "充", with: "")
            .replacingOccurrences(of: "交", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "块", with: "")
            .replacingOccurrences(of: "花", with: "")
            // 注意：删掉原「吃/喝/饭/餐/外卖/点餐」单字清洗——这些词若残留进商户名，
            // 可由下方空串兜底改成 inferBillCategory；若直接删会把「早餐」砍成「早」。
            .replacingOccurrences(of: "的", with: "")
            .replacingOccurrences(of: "我", with: "")
            .replacingOccurrences(of: "给", with: "")
            .replacingOccurrences(of: "在", with: "")
            .replacingOccurrences(of: "去", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 还原受保护的餐次词
        for (w, ph) in zip(mealWords, placeholders) {
            t = t.replacingOccurrences(of: ph, with: w)
        }
        return t
    }

    /// 解析健康指标：把「体重70公斤，体脂20%，血压120/80」拆成多个 HealthPayload。
    /// 仅当文本中出现已知指标词才命中，避免误吞普通句子。
    static func parseHealthMetrics(_ text: String) -> [HealthPayload] {
        let metrics: [(canonical: String, aliases: [String])] = [
            ("体重", ["体重", "称了", "称重"]),
            ("身高", ["身高"]),
            ("体脂率", ["体脂率", "体脂", "脂肪率", "体脂肪"]),
            ("血压", ["血压"]),
            ("心率", ["心率", "心跳", "脉搏", "脉率"]),
            ("血糖", ["血糖"]),
            ("血氧", ["血氧", "spo2", "SpO2"]),
            ("体温", ["体温", "温度"]),
            ("睡眠时长", ["睡眠时长", "睡眠", "睡了"]),
            ("步数", ["步数", "步"]),
            ("运动时长", ["运动时长", "运动", "锻炼"])
        ]
        var result: [HealthPayload] = []
        for seg in splitByConjunction(text) {
            for (canonical, aliases) in metrics {
                guard aliases.contains(where: { seg.contains($0) }) else { continue }
                // 血压特殊：匹配 120/80
                if canonical == "血压" {
                    if let r = seg.range(of: #"(\d{2,3})\s*/\s*(\d{2,3})"#, options: .regularExpression) {
                        let nums = seg[r].replacingOccurrences(of: " ", with: "")
                        result.append(HealthPayload(metric: canonical, value: nums, unit: "mmHg"))
                        break
                    }
                }
                guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)"#),
                      let m = regex.firstMatch(in: seg, range: NSRange(location: 0, length: seg.utf16.count)) else { continue }
                let num = (seg as NSString).substring(with: m.range(at: 1))
                // 数字后紧跟的单位字符
                let afterStart = m.range(at: 1).upperBound
                var unit = ""
                if afterStart < seg.utf16.count {
                    let tail = (seg as NSString).substring(from: afterStart)
                    if let uRegex = try? NSRegularExpression(pattern: #"^\s*([公斤斤千克克gGkK%°℃度次分bpmBPMmmHg/*]+)"#, options: []),
                       let um = uRegex.firstMatch(in: tail, range: NSRange(location: 0, length: tail.utf16.count)) {
                        unit = (tail as NSString).substring(with: um.range(at: 1))
                    }
                }
                result.append(HealthPayload(metric: canonical, value: num, unit: unit))
                break
            }
        }
        return result
    }
}
