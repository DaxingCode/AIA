// regression_harness.swift
// QA 回归验证脚本（严过关）
//
// 说明：本文件是 RecognizeService.swift 中"纯逻辑"解析函数的 **逐字副本**（verbatim copy），
// 仅把 `extractMerchant(... in: ModelContext?)` 的 context 参数改为 `Any?` 以脱离 SwiftData 编译，
// 并在 `localParseBill` 副本中跳过 MerchantMeta 经验库（等同 context=nil 的运行路径）。
// 这样可以在 macOS 上用 `swift` 直接运行，对三处修复做可执行回归验证。
// 注意：这是验证副本，不修改任何生产代码。

import Foundation

// MARK: - 轻量结果结构（对应生产 BillPayload / RecognitionResult 的字段子集）
struct BillResult {
    let merchant: String
    let amount: Double
    let isoTime: String
    let category: String
}

// MARK: - 复制自 RecognizeService.swift 的纯逻辑函数（逐字）

private func extractAmount(_ text: String, force: Bool = false) -> Double? {
    let ns = text as NSString

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

    func nearAmountLabel(range: NSRange) -> Bool {
        let windowLen = 18
        let start = max(0, range.location - windowLen)
        let end = min(ns.length, range.location + range.length + windowLen)
        let ctx = ns.substring(with: NSRange(location: start, length: end - start))
        let labels = ["应收", "实收", "合计", "总计", "总金额", "成交价", "实付", "应付", "支付", "微信", "支付宝", "现金"]
        return labels.contains { ctx.localizedCaseInsensitiveContains($0) }
    }

    func isDateContext(range: NSRange) -> Bool {
        // 生产代码：判断该数字是否完整落在某个日期串范围内，避免窗口误判。
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
        let score: Int
        let hasNegative: Bool
        static func < (lhs: Candidate, rhs: Candidate) -> Bool { lhs.score < rhs.score }
    }
    var candidates: [Candidate] = []

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

    if force {
        let loosePattern = #"([+-]?)\s*(\d+(?:\.\d{1,2})?)"#
        if let regex = try? NSRegularExpression(pattern: loosePattern, options: []) {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let signRange = m.range(at: 1)
                let numRange = m.range(at: 2)
                guard numRange.location != NSNotFound,
                      let v = Double(ns.substring(with: numRange)) else { continue }

                if v >= 1900 && v <= 2100 && floor(v) == v && numRange.length == 4 { continue }
                if v > 1_000_000 { continue }
                if isNoiseContext(range: numRange) { continue }
                if isDateContext(range: numRange) { continue }   // 缺陷1修复：跳过日期串内的数字

                let hasNegative = signRange.location != NSNotFound && ns.substring(with: signRange) == "-"
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

private func isLikelyTime(_ s: String) -> Bool {
    if s.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil { return true }
    // 缺陷2修复：同时识别日期串（含分隔符的 YYYY-MM-DD 或 YYYY-MM-DD HH:MM[:SS]）
    if s.range(of: #"^\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}(?:[ Tt]\d{1,2}:\d{2}(?::\d{2})?)?"#, options: .regularExpression) != nil { return true }
    return false
}

// 副本：context 改为 Any? 以脱离 SwiftData；MerchantMeta 经验库分支在 context==nil 时跳过
private func extractMerchant(_ text: String, in context: Any? = nil) -> String {
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
        return s.count >= 2 && !s.isEmpty && !isLikelyTime(s) && !blocklist.contains(s)
    }

    // 副本：生产里这里是 ModelContext + MerchantMetaStore.lookup；此处 context 恒为 nil，跳过
    _ = context

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
        #"^[\t ]*([^\n，,()（）]+?)(?:[\t ]*[（(].*?[）)][\t ]*)?欢迎您"#
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
        for j in (i + 1)..<min(i + 16, lines.count) {
            let candidate = lines[j]
            if isOtherLabel(candidate) { continue }
            for vendor in knownCloudVendors where candidate.localizedCaseInsensitiveContains(vendor) {
                return normalizeMerchant(vendor)
            }
            let stripped = candidate.replacingOccurrences(
                of: #"^(收款方全称|收款方|商户名称|商户|商家名称|商家|对方户名|对方账户|店名|商品说明)\s*[:：]?\s*"#,
                with: "",
                options: .regularExpression)
            if isValidMerchant(stripped), !isPureNumericOrOrder(stripped) {
                return normalizeMerchant(stripped)
            }
        }
    }

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

private func normalizeMerchant(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    s = s.replacingOccurrences(of: "*", with: "")
    s = s.replacingOccurrences(of: "（", with: "(")
    s = s.replacingOccurrences(of: "）", with: ")")
    if let r = s.range(of: #"\([^)]*\)"#, options: .regularExpression) {
        let suffix = String(s[r]).lowercased()
        if suffix.contains("个人") || suffix.contains("商户") || suffix.contains("官方") ||
           suffix.contains("店") || suffix.contains("世界") || suffix.contains("广场") ||
           suffix.contains("中心") || suffix.contains("HC") {
            s.removeSubrange(r)
        }
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func extractISODateTime(_ text: String) -> String? {
    let labeledPatterns = [
        #"(?:支付时间|付款时间|交易时间|创建时间)\s*[:：]?\s*(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})(?:\s+[T\s]?(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#,
        #"(?:支付时间|付款时间|交易时间|创建时间)\s*[:：]?\s*(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#
    ]
    if let result = tryExtractDateTime(from: text, using: labeledPatterns) {
        return result
    }

    let fullPatterns = [
        #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})[\sT](\d{1,2}):(\d{2})(?::(\d{2}))?"#,
        #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#
    ]
    if let result = tryExtractDateTime(from: text, using: fullPatterns) {
        return result
    }

    let dateOnlyPatterns = [
        #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#,
        #"(\d{1,2})[-/.月](\d{1,2})[日]"#
    ]
    if let result = tryExtractDateTime(from: text, using: dateOnlyPatterns) {
        return result
    }

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

private func tryExtractDateTime(from text: String, using patterns: [String]) -> String? {
    let ns = text as NSString
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }

        var y = Calendar.current.component(.year, from: Date())
        var mo = 0, d = 0, h = 0, min = 0, s = 0
        var hasTime = false

        var idx = 1
        func nextInt() -> Int? {
            guard idx < m.numberOfRanges else { return nil }
            let r = m.range(at: idx); idx += 1
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }

        let firstRange = m.range(at: 1)
        guard firstRange.location != NSNotFound else { continue }
        let firstStr = ns.substring(with: firstRange)
        idx = 2
        if firstStr.count == 4, let yearVal = Int(firstStr) {
            y = yearVal
            mo = nextInt() ?? 0; d = nextInt() ?? 0
            h = nextInt() ?? 0; min = nextInt() ?? 0; s = nextInt() ?? 0
        } else {
            mo = Int(firstStr) ?? 0; d = nextInt() ?? 0
            h = nextInt() ?? 0; min = nextInt() ?? 0; s = nextInt() ?? 0
        }

        guard (1...12).contains(mo), (1...31).contains(d) else { continue }

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

private func guessCategory(_ merchant: String, _ text: String) -> (String, Bool) {
    let m = merchant.trimmingCharacters(in: .whitespaces)

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

// MARK: - localParseBill 副本（context 恒为 nil，跳过经验库）
private func localParseBill(text: String) -> BillResult? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let billSignals = [
        "交易成功", "支付时间", "付款方式", "账单详情", "收款方", "付款金额",
        "支付金额", "交易金额", "订单金额", "实付金额", "支付成功", "已付款",
        "微信支付", "支付宝", "经营码", "收款码", "付款码", "转账", "扫一扫付款",
        "小票", "收银", "应收", "实收", "找零", "成交价", "合计", "总计", "总金额",
        "件数", "数量", "永辉", "华润", "沃尔玛", "大润发", "盒马", "物美", "家乐福",
        "便利店", "超市", "商場", "商场", "购物中心"
    ]
    let hasBillSignal = billSignals.contains { trimmed.localizedCaseInsensitiveContains($0) }

    let eventSignals = [
        "培训", "训练营", "招募", "报名", "上课", "课程", "讲座", "会议", "开会",
        "活动时间", "培训时间", "上课时间", "地点", "会议室", "教室", "群聊", "微信群",
        "通知", "公告", "海报", "邀请函", "日程", "议程", "参训", "招募令", "活动报名"
    ]
    let hasEventSignal = eventSignals.contains { trimmed.localizedCaseInsensitiveContains($0) }
    if hasEventSignal { return nil }

    guard let amount = extractAmount(trimmed, force: hasBillSignal) else { return nil }

    let rawMerchant = extractMerchant(trimmed, in: nil)
    // 防御（v4，与生产代码一致）：时间串绝不可能是商户名，强制回退空（最终显示"账单"）
    let merchant = (rawMerchant.isEmpty || isLikelyTime(rawMerchant)) ? "" : rawMerchant

    let isoTime = extractISODateTime(trimmed) ?? ISO8601DateFormatter().string(from: .now)

    let (category, _) = guessCategory(merchant, trimmed)

    return BillResult(
        merchant: merchant.isEmpty ? "账单" : merchant,
        amount: amount,
        isoTime: isoTime,
        category: category
    )
}

// MARK: - 测试执行
var passCount = 0
var failCount = 0

func check(_ name: String, _ actual: String, _ expected: String, file: String = #function) {
    if actual == expected {
        passCount += 1
        print("✅ PASS  \(name)")
        print("        actual = \(actual)")
    } else {
        failCount += 1
        print("❌ FAIL  \(name)")
        print("        expected = \(expected)")
        print("        actual   = \(actual)")
    }
}

func checkContains(_ name: String, _ actual: String, _ needle: String) {
    if actual.contains(needle) {
        passCount += 1
        print("✅ PASS  \(name)  (contains \"\(needle)\")")
        print("        actual = \(actual)")
    } else {
        failCount += 1
        print("❌ FAIL  \(name)  (should contain \"\(needle)\")")
        print("        actual = \(actual)")
    }
}

func checkAmount(_ name: String, _ actual: Double, _ expected: Double) {
    if abs(actual - expected) < 0.001 {
        passCount += 1
        print("✅ PASS  \(name)  amount = \(actual)")
    } else {
        failCount += 1
        print("❌ FAIL  \(name)  expected \(expected), actual \(actual)")
    }
}

// ---- 样例 A：两栏布局 + 收款方 OCR 错字（"收款方金称\n阿里云计算有限公司"）应得 merchant=阿里云 ----
let sampleA = """
收款方金称
阿里云计算有限公司
阿里云
-10.00
支付时间
2026-07-21 11:09:35
"""
print("\n===== 样例 A：两栏 + 收款方 OCR 错字 =====")
if let r = localParseBill(text: sampleA) {
    check("A.merchant", r.merchant, "阿里云")
    checkAmount("A.amount", r.amount, 10.0)
    // 源码固定输出 UTC/Z 时间戳：上海 11:09:35 = UTC 03:09:35（含 .000 小数秒）
    checkContains("A.isoTime", r.isoTime, "2026-07-21T03:09:35")
    check("A.category", r.category, "云服务")
    print("   raw:", r)
} else {
    failCount += 1
    print("❌ FAIL  A: localParseBill returned nil")
}

// ---- 样例 B：支付时间跨行（"支付时间\n2026-07-21 19:09:35"）应得 isoTime 正确 ----
let sampleB = """
支付时间
2026-07-21 19:09:35
阿里云
-10.00
"""
print("\n===== 样例 B：支付时间跨行 =====")
if let r = localParseBill(text: sampleB) {
    check("B.merchant", r.merchant, "阿里云")
    // 期望金额 10.0；注意：当前 extractAmount 的 force 模式会把日期里的 "-07"（月份）误判为金额
    // （它紧邻「支付」标签 → nearAmountLabel 加分，得分 115 > "-10.00" 的 95），此为预存源码缺陷。
    checkAmount("B.amount", r.amount, 10.0)
    // 源码固定输出 UTC/Z 时间戳：上海 19:09:35 = UTC 11:09:35
    checkContains("B.isoTime", r.isoTime, "2026-07-21T11:09:35")
    check("B.category", r.category, "云服务")
    print("   raw:", r)
} else {
    failCount += 1
    print("❌ FAIL  B: localParseBill returned nil")
}

// ---- 样例 C：金额同行商户（"阿里云   ¥10.00"）应得 merchant=阿里云 ----
let sampleC = "阿里云   ¥10.00"
print("\n===== 样例 C：金额同行商户 =====")
if let r = localParseBill(text: sampleC) {
    check("C.merchant", r.merchant, "阿里云")
    checkAmount("C.amount", r.amount, 10.0)
    print("   raw:", r, "  (isoTime 回退为当前时间，符合设计：C 无时间线索)")
} else {
    failCount += 1
    print("❌ FAIL  C: localParseBill returned nil")
}

// ---- 样例 D：真实 macOS Vision OCR 输出（两栏布局 + 跨行标签） ----
let sampleD = """
21:42⑦
账单详情
全部账单
支付时间
付款方式
商品说明
支付奖励
收款方全称
订单号
商家订单号
阿里云
-10.00
交易成功
2026-07-21 19:09:35
余额宝＞
充值：阿里云服务购买，业务交易号：CFP20
2607211909122928
• 立即领取2积分
阿里云计算有限公司
2026072122001429431437175176
HJPGP14778872160721
账单管理
为您统计了最近的花费趋势，去看看分析吧"＞
账单分类
其他＞
标签
请选择＞
使用记账本，查看自定义分类、标签统计
计入收支
备注
添加＞
"""
print("\n===== 样例 D：真实 Vision OCR 输出（用户反馈图） =====")
if let r = localParseBill(text: sampleD) {
    check("D.merchant", r.merchant, "阿里云")
    checkAmount("D.amount", r.amount, 10.0)
    checkContains("D.isoTime", r.isoTime, "2026-07-21T11:09:35")
    check("D.category", r.category, "云服务")
    print("   raw:", r)
} else {
    failCount += 1
    print("❌ FAIL  D: localParseBill returned nil")
}

// ---- 附加压力测试（验证缺陷2修复）：金额独占行上方若是时间标签/日期串 ----
let stressEdge = """
支付时间
-10.00
"""
print("\n===== 附加压力②：金额独占行紧邻「支付时间」标签（验证缺陷2修复）=====")
if let r = localParseBill(text: stressEdge) {
    // 修复后 extractMerchant 不再把「支付时间」当商户，localParseBill 对空商户回退为默认 "账单"
    check("压力②.merchant", r.merchant, "账单")
    print("   raw:", r, "  ← 修复后不再误吞时间标签行（原为\"支付时间\"）")
} else {
    failCount += 1
    print("❌ FAIL  压力②: localParseBill returned nil")
}

// 前置账单信号词「账单详情」（命中 billSignals 且本身在 blocklist，不会被误当商户），
// 让 localParseBill 走到商户抽取；验证「日期串紧贴金额行上方」被 isLikelyTime 拦截。
let stressEdge2 = """
账单详情
2026-07-21 19:09:35
-10.00
"""
print("\n===== 附加压力②b：金额独占行紧贴日期串（验证缺陷2修复）=====")
if let r = localParseBill(text: stressEdge2) {
    check("压力②b.merchant", r.merchant, "账单")
    print("   raw:", r, "  ← 修复后日期串被 isLikelyTime 拦截（原为日期串本身）")
} else {
    failCount += 1
    print("❌ FAIL  压力②b: localParseBill returned nil")
}

print("\n========================================")
print("回归结果：PASS = \(passCount), FAIL = \(failCount)")
print("========================================")

// ---- 样例 G：v4 真实设备截图 — macOS Vision OCR 对「支付宝阿里云 -10.00 账单详情」原图的逐字输出 ----
// 来源：clipboard-2026-07-21T15-06-42-923Z-b2a7ae8c.png（用户反馈第二张图，支付宝账单详情页原截图）
// 关键特征：
//   1) 顶部状态栏时间 23:06/23:05（绝不能当支付时间或商户名）
//   2) 「阿里云」与「-10.00」分行（金额上方=商户 模式）
//   3) 「支付时间」与「2026-07-21 19:09:35」在同一行（labeledPatterns 可直接命中）
//   4) 「收款方金称」（OCR 错字，金≠全）与「阿里云计算有限公司」跨行（cross-line 兜底需命中）
//   5) 商品说明含「充值：阿里云服务购买」（guessCategory 需命中云服务）
// 正确结果：merchant=阿里云, amount=10.0, time=19:09:35, category=云服务, localParseBill≠nil（不 fallback 云端）
let sampleG = """
23:06
三今
23:05
全部账单
<
账单详情
白
阿里云
-10.00
交易成功
支付时间
2026-07-21 19:09:35
余额宝＞
付款方式
商品说明|
充值：阿里云服务购买，业务交易号：CFP20
2607211909122928
支付奖励
立即领取2积分
收款方金称
阿里云计算有限公司
更多～
为您統计了最近的花费趋势，去看看分析吧~〉
账单管理
账单分类
其他》
标签
请选择＞
使用记账本，查看自定义分类、标签统计＞
计入收支
备注
添加＞
回 联系商冢
园 查看往来记录
日 往来流水证明
门 申请电子回单
"""
print("\n===== 样例 G：v4 真实 Vision OCR（支付宝阿里云 -10.00 原图）=====")
if let r = localParseBill(text: sampleG) {
    check("G.本地命中(不回退云端)", "hit", "hit")
    check("G.merchant(含'阿里云')", r.merchant, "阿里云")
    checkAmount("G.amount", r.amount, 10.0)
    checkContains("G.isoTime(19:09:35→UTC)", r.isoTime, "2026-07-21T11:09:35")
    check("G.category(云服务)", r.category, "云服务")
    print("   raw:", r)
} else {
    failCount += 1
    print("❌ FAIL  G: localParseBill returned nil → 会 fallback 云端（将产生 merchant=19:09/time=23:05/cat=交通 的云端错误）")
}

print("\n========================================")
print("回归结果（含 v4 样例 G）：PASS = \(passCount), FAIL = \(failCount)")
print("========================================")

// ---- 样例 H：模拟「经验库缓存污染」真机复现场景（根因 #3 验证）----
// 用户曾保存过错误记录（merchant="19:09"、category="交通"），该坏 key 写入 MerchantMeta。
// 下次扫描同图时，OCR 文本里的支付时间 "19:09:35" 会命中该 key，
// 旧代码（无 v4 防御）会把 "19:09" 当商户并锁死分类=交通。
// v4 修复：extractMerchant 的 MerchantMeta 查询块跳过时间串 key；MerchantMetaStore.upsert/lookup 也拒绝时间串。
// 此处用真实 OCR 文本 + 污染缓存，验证最终商户仍是「阿里云」而非「19:09」。
func extractMerchantWithCache(_ text: String, cache: [(merchant: String, category: String)]) -> String {
    // 逐字模拟生产 extractMerchant 的 MerchantMeta 查询块（v4 修复后）
    for (m, _) in cache {
        // v4 防御：跳过时间串 key（如 "19:09"），否则 OCR 里的支付时间会误命中
        guard !m.isEmpty, !isLikelyTime(m) else { continue }
        if text.localizedCaseInsensitiveContains(m) {
            return m
        }
    }
    // 否则回退到纯规则提取
    return extractMerchant(text, in: nil)
}

print("\n===== 样例 H：经验库缓存污染（19:09 到 交通）真机复现验证 =====")
// 最坏情况：缓存里只有坏 key "19:09"→"交通"（无正确 key）
let pollutedCacheWorst = [("19:09", "交通")]
let hWorst = extractMerchantWithCache(sampleG, cache: pollutedCacheWorst)
check("H.污染缓存(仅坏key).merchant", hWorst, "阿里云")
// 混合情况：缓存里同时有坏 key 与正确 key，坏 key 不得抢占
let pollutedCacheMixed = [("19:09", "交通"), ("阿里云", "云服务")]
let hMixed = extractMerchantWithCache(sampleG, cache: pollutedCacheMixed)
check("H.污染缓存(混合).merchant", hMixed, "阿里云")
// 验证 guessCategory 在被污染 key 干扰下仍正确：以"阿里云"为商户 → 云服务
let (hCat, _) = guessCategory(hWorst, sampleG)
check("H.污染缓存.category", hCat, "云服务")
print("   H worst raw merchant = '\(hWorst)', mixed raw merchant = '\(hMixed)'")

print("\n========================================")
print("回归结果（含 v4 样例 G/H）：PASS = \(passCount), FAIL = \(failCount)")
print("========================================")
exit(failCount == 0 ? 0 : 1)
