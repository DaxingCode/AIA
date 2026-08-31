import Foundation

/// 饮水解析与防重复去重。
/// 聊天（`ChatView`）与 Siri/快捷指令（`TellAIAIntent`）共用，保证两条入口记录饮水的行为一致：
/// 解析规则、餐次推断、去重窗口完全一致，避免「用好记AI记 喝了300毫升水」与 App 内语音记水结果不一致。
@MainActor
enum WaterIntakeParser {

    // MARK: - 解析

    /// 解析文本中的饮水量。返回 (amount_ml, displayText)。
    /// 命中条件：含「水」+ 含喝类动词（喝/饮/灌） + 不含其他真实食物词。
    /// 单位映射：升/L→1000、毫升/ml→1、杯→250、瓶→500、壶→1000、碗→300。
    /// 示例：
    ///   "喝了 1 升水"    → (1000, "1升水")
    ///   "喝了 500ml 水"  → (500,  "500ml水")
    ///   "喝了两杯水"     → (200,  "2杯水")
    ///   "喝了 1.5 升水"  → (1500, "1.5升水")
    ///   "喝水"           → (100,  "1杯水")
    nonisolated static func parse(_ text: String) -> (ml: Double, display: String)? {
        // 必须含「水」+ 喝类动词
        let hasWater = text.contains("水") || text.contains("汤") // 汤也走这条罕见 case
        let hasDrinkVerb = text.contains("喝") || text.contains("饮") || text.contains("灌")
        guard hasWater, hasDrinkVerb else { return nil }

        // 排除「汤/糖水」以外的「其他真实食物」：含蛋/饭/面/菜/肉/鱼/鸡/奶/粥/麦/汤 等就当复合饮食场景，不走水路径
        let foodKeywords = ["蛋", "饭", "面", "菜", "肉", "鱼", "鸡", "鸭", "牛", "羊", "猪", "奶",
                            "粥", "麦", "汤", "果", "豆", "瓜", "薯", "汤圆", "面包", "饼", "燕"]
        for kw in foodKeywords where text.contains(kw) {
            // 含食物词就直接放弃水路径，避免「喝了 1 碗燕麦粥 1 杯水」漏记食物
            return nil
        }

        // 单位 → 毫升映射（按常见容量排序，确保长的先匹配，避免「ml」被「m」截胡）
        let units: [(String, Double)] = [
            ("毫升", 1), ("mL", 1), ("ML", 1), ("ml", 1),
            ("升", 1000), ("L", 1000), ("l", 1000),
            ("杯", 100),
            ("瓶", 500),
            ("壶", 1000),
            ("碗", 300),
        ]

        let ns = text as NSString
        // 1) 优先匹配「数量+单位」组合
        for (unit, mlPerUnit) in units {
            let escaped = NSRegularExpression.escapedPattern(for: unit)
            let pattern = "([\\d.]+|[一二两三四五六七八九十百千]+)\\s*\(escaped)"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let numStr = ns.substring(with: m.range(at: 1))
                let count: Double
                if let n = ChatView.parseChineseNumber(numStr) { count = Double(n) }
                else if let d = Double(numStr) { count = d }
                else { count = 1 }
                return (count * mlPerUnit, "\(numStr)\(unit)水")
            }
        }

        // 2) 没数量+单位：单纯「喝水」「饮水」「灌水」 → 默认 1 杯（100ml ≈ 100g）
        if text.contains("喝水") || text.contains("饮水") || text.contains("灌水") {
            return (100, "1杯水")
        }

        return nil
    }

    /// 从文本推断餐次（早餐/午餐/晚餐/加餐），无则 nil。
    nonisolated static func mealFromText(_ text: String) -> String? {
        let lowered = text.lowercased()
        if lowered.contains("早餐") || lowered.contains("早饭") || lowered.contains("早上") || lowered.contains("今早") { return "早餐" }
        if lowered.contains("午餐") || lowered.contains("午饭") || lowered.contains("中午") || lowered.contains("正午") { return "午餐" }
        if lowered.contains("晚餐") || lowered.contains("晚饭") || lowered.contains("晚上") || lowered.contains("今晚") || lowered.contains("夜宵") { return "晚餐" }
        if lowered.contains("加餐") || lowered.contains("点心") || lowered.contains("零食") { return "加餐" }
        return nil
    }

    // MARK: - 防重复去重

    /// 饮水去重直接复用聊天的去重实现（`ChatView.checkDuplicateAndRegister` / `clearDedupKey`），
    /// 保证聊天与 Siri/快捷指令两条入口共用同一去重窗口与键规则，避免「记过啦」判定不一致。
    static func checkDuplicateAndRegister(_ text: String, type: String) -> Bool {
        ChatView.checkDuplicateAndRegister(text, type: type)
    }

    static func clearDedupKey(_ text: String, type: String? = nil) {
        ChatView.clearDedupKey(text, type: type)
    }
}
