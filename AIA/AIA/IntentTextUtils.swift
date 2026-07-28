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

    /// 账单商户名清洗：去掉金额、花费动词、记账动词、量词等，得到干净商户名。
    /// 与 LocalQuickParse.parseBill 的旧实现保持一致，集中在此避免两处漂移。
    static func cleanMerchant(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\d+(?:\.\d+)?\s*(?:元|块|块钱|元钱|￥|¥)"#,
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
            .replacingOccurrences(of: "吃", with: "")
            .replacingOccurrences(of: "喝", with: "")
            .replacingOccurrences(of: "饭", with: "")
            .replacingOccurrences(of: "餐", with: "")
            .replacingOccurrences(of: "外卖", with: "")
            .replacingOccurrences(of: "点餐", with: "")
            .replacingOccurrences(of: "的", with: "")
            .replacingOccurrences(of: "我", with: "")
            .replacingOccurrences(of: "给", with: "")
            .replacingOccurrences(of: "在", with: "")
            .replacingOccurrences(of: "去", with: "")
            .replacingOccurrences(of: "了", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
