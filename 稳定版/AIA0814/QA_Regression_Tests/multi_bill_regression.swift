// multi_bill_regression.swift
// QA 回归：一图多账单拆分 + 本地解析（对应 RecognizeService 新增的多账单能力）
//
// 本文件是 RecognizeService.swift 中相关纯逻辑函数的副本，脱离 SwiftData 运行。
// 运行方式：cd AIA/QA_Regression_Tests && swift multi_bill_regression.swift

import Foundation

// MARK: - 轻量结构
struct BillResult {
    let merchant: String
    let amount: Double
    let isoTime: String
    let category: String
}

// MARK: - 复制自 RecognizeService.swift 的辅助函数（逐字）

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

private func isLikelyTime(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    let timeOnly = t.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    let dateLike = t.range(of: #"^\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}"#, options: .regularExpression) != nil
    let relTime = t.range(of: #"^(?:今天|昨天)\s*\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
    let weekdayTime = t.range(of: #"^星期[一二三四五六日天]\s*\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
    let mdTime = t.range(of: #"^\d{1,2}月\d{1,2}日[\s]*\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
    return timeOnly || dateLike || relTime || weekdayTime || mdTime
}

private func extractAmount(_ text: String, force: Bool = false) -> Double? {
    let ns = text as NSString
    func isNoiseContext(range: NSRange) -> Bool {
        let windowLen = 22
        let start = max(0, range.location - windowLen)
        let end = min(ns.length, range.location + range.length + windowLen)
        let ctx = ns.substring(with: NSRange(location: start, length: end - start))
        let noiseKeywords = ["信用卡", "储蓄卡", "银行卡", "借记卡", "尾号", "卡号", "卡(", "phone", "电话", "手机", "订单号", "订单编号", "订单", "流水号", "流水", "会员卡", "会员", "会员号", "开票号", "发票代码", "发票号码", "电子发票", "税号", "客服电话", "客服"]
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
        let datePattern = #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})(?:[\sT](\d{1,2}):(\d{2})(?::(\d{2}))?)?"#
        guard let regex = try? NSRegularExpression(pattern: datePattern, options: []) else { return false }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let dr = m.range
            if range.location >= dr.location && range.location + range.length <= dr.location + dr.length { return true }
        }
        return false
    }
    struct Candidate: Comparable { let value: Double; let score: Int; let hasNegative: Bool; static func < (lhs: Candidate, rhs: Candidate) -> Bool { lhs.score < rhs.score } }
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
    if force {
        let amountOnlyPattern = #"^([+-]?)\s*(\d+(?:\.\d{1,2})?)$"#
        if let regex = try? NSRegularExpression(pattern: amountOnlyPattern, options: .anchorsMatchLines) {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let signRange = m.range(at: 1)
                let numRange = m.range(at: 2)
                guard numRange.location != NSNotFound, let v = Double(ns.substring(with: numRange)) else { continue }
                if v > 1_000_000 { continue }
                let sign = signRange.location != NSNotFound ? ns.substring(with: signRange) : ""
                let hasNegative = sign == "-"
                let hasDecimal = numRange.length > 1 && ns.substring(with: numRange).contains(".")
                guard hasNegative || hasDecimal else { continue }
                let score = hasNegative ? 100 : 95
                candidates.append(Candidate(value: abs(v), score: score, hasNegative: hasNegative))
            }
        }
        let loosePattern = #"([+-]?)\s*(\d+(?:\.\d{1,2})?)"#
        if let regex = try? NSRegularExpression(pattern: loosePattern, options: []) {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let signRange = m.range(at: 1)
                let numRange = m.range(at: 2)
                guard numRange.location != NSNotFound, let v = Double(ns.substring(with: numRange)) else { continue }
                if v >= 1900 && v <= 2100 && floor(v) == v && numRange.length == 4 { continue }
                if v > 1_000_000 { continue }
                if isNoiseContext(range: numRange) { continue }
                if isDateContext(range: numRange) { continue }
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

private func extractRelativeDateTime(_ text: String, referenceDate: Date? = nil) -> String? {
    let calendar = Calendar.current
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    let reference = referenceDate ?? Date()

    func iso(from date: Date, h: Int, min: Int, s: Int) -> String? {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = h; comps.minute = min; comps.second = s
        comps.timeZone = shanghai
        guard let d = calendar.date(from: comps) else { return nil }
        let f = ISO8601DateFormatter(); f.timeZone = shanghai
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    // 1) 今天/昨天 HH:MM[:SS]
    let relPattern = #"(?:今天|昨天)\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"#
    if let regex = try? NSRegularExpression(pattern: relPattern, options: []),
       let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let ns = text as NSString
        let h = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let min = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let s = m.numberOfRanges > 3 && m.range(at: 3).location != NSNotFound
            ? Int(ns.substring(with: m.range(at: 3))) ?? 0 : 0
        let base: Date = text.contains("昨天")
            ? (calendar.date(byAdding: .day, value: -1, to: reference) ?? reference)
            : reference
        if let r = iso(from: base, h: h, min: min, s: s) { return r }
    }

    // 2) M月D日 HH:MM[:SS]
    let mdPattern = #"(\d{1,2})[月](\d{1,2})[日]?[\s]*(\d{1,2}):(\d{2})(?::(\d{2}))?"#
    if let regex = try? NSRegularExpression(pattern: mdPattern, options: []),
       let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let ns = text as NSString
        let mo = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let d = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let h = Int(ns.substring(with: m.range(at: 3))) ?? 0
        let min = Int(ns.substring(with: m.range(at: 4))) ?? 0
        let s = m.numberOfRanges > 5 && m.range(at: 5).location != NSNotFound
            ? Int(ns.substring(with: m.range(at: 5))) ?? 0 : 0
        let y = calendar.component(.year, from: reference)
        var comps = DateComponents(year: y, month: mo, day: d, hour: h, minute: min, second: s)
        comps.timeZone = shanghai
        if let date = calendar.date(from: comps) {
            let f = ISO8601DateFormatter(); f.timeZone = shanghai
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: date)
        }
    }

    // 3) 星期X HH:MM[:SS]：取不晚于参考日期最近的那一个星期X
    let weekdayPattern = #"星期([一二三四五六日天])\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"#
    let weekdayMap: [String: Int] = ["一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"日":7,"天":7]
    if let regex = try? NSRegularExpression(pattern: weekdayPattern, options: []),
       let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let ns = text as NSString
        let wdName = ns.substring(with: m.range(at: 1))
        if let targetWD = weekdayMap[wdName] {
            let h = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let min = Int(ns.substring(with: m.range(at: 3))) ?? 0
            let s = m.numberOfRanges > 4 && m.range(at: 4).location != NSNotFound
                ? Int(ns.substring(with: m.range(at: 4))) ?? 0 : 0
            let refWD = calendar.component(.weekday, from: reference)
            let refWDMon = (refWD == 1) ? 7 : (refWD - 1)
            var delta = refWDMon - targetWD
            if delta < 0 { delta += 7 }
            if let base = calendar.date(byAdding: .day, value: -delta, to: reference),
               let r = iso(from: base, h: h, min: min, s: s) { return r }
        }
    }

    // 4) 纯 HH:MM[:SS]（独占一行）：用参考日期补齐
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    for line in lines {
        guard line.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil else { continue }
        let parts = line.components(separatedBy: ":")
        let h = Int(parts[0]) ?? 0
        let min = Int(parts[1]) ?? 0
        let s = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        if let r = iso(from: reference, h: h, min: min, s: s) { return r }
    }
    return nil
}

private func extractISODateTime(_ text: String, referenceDate: Date? = nil) -> String? {
    // ── 第 0 优先级：相对日期 + 时刻 ──
    if let result = extractRelativeDateTime(text, referenceDate: referenceDate) { return result }

    // ── 第 1 优先级：带标签的时间行 ──
    let labeledPatterns = [
        #"(?:支付时间|付款时间|交易时间|创建时间)\s*[:：]?\s*(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})(?:\s+[T\s]?(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#,
        #"(?:支付时间|付款时间|交易时间|创建时间)\s*[:：]?\s*(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#,
    ]
    if let result = tryExtractDateTime(from: text, using: labeledPatterns) { return result }

    // ── 第 2 优先级：任意位置的完整时间戳 ──
    let fullPatterns = [
        #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})[\sT](\d{1,2}):(\d{2})(?::(\d{2}))?"#,
        #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#,
    ]
    if let result = tryExtractDateTime(from: text, using: fullPatterns) { return result }

    // ── 第 3 优先级：纯日期 ──
    let dateOnlyPatterns = [
        #"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#,
        #"(\d{1,2})[-/.月](\d{1,2})[日]"#,
    ]
    if let result = tryExtractDateTime(from: text, using: dateOnlyPatterns) { return result }
    return nil
}

/// 按给定正则模式数组逐一尝试提取日期时间，第一个成功即返回。
private func tryExtractDateTime(from text: String, using patterns: [String]) -> String? {
    let ns = text as NSString
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
        var y = Calendar.current.component(.year, from: Date())
        var mo = 0, d = 0, h = 0, min = 0, s = 0
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
            y = yearVal; mo = nextInt() ?? 0; d = nextInt() ?? 0
            h = nextInt() ?? 0; min = nextInt() ?? 0; s = nextInt() ?? 0
        } else {
            mo = Int(firstStr) ?? 0; d = nextInt() ?? 0
            h = nextInt() ?? 0; min = nextInt() ?? 0; s = nextInt() ?? 0
        }
        guard (1...12).contains(mo), (1...31).contains(d) else { continue }
        let hasTime = h > 0 || min > 0 || s > 0
        var comps = DateComponents(year: y, month: mo, day: d)
        if hasTime {
            comps.hour = h; comps.minute = min; comps.second = s
            comps.timeZone = TimeZone(identifier: "Asia/Shanghai")
        }
        if let date = Calendar.current.date(from: comps) {
            let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            f.formatOptions = hasTime ? [.withInternetDateTime, .withFractionalSeconds] : [.withFullDate]
            return f.string(from: date)
        }
    }
    return nil
}

private func extractMerchant(_ text: String) -> String {
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

    let labelPatterns = [
        #"收款方全称[\t ]*[:：]?[\t ]*\*{0,2}([^\n，,*()（）]{3,})"#,
        #"收款方[\t ]*[:：]?[\t ]*\*{0,2}([^\n，,*()（）]{3,})"#,
        #"商户[名称]*[:：][\t ]*([^\n，,]{2,})"#,
        #"对方账户[:：][\t ]*([^\n，,]{2,})"#,
        #"对方户名[:：][\t ]*([^\n，,]{2,})"#,
        #"商家[:：][\t ]*([^\n，,]{2,})"#,
        #"店名[:：][\t ]*([^\n，,]{2,})"#,
        #"商品说明[:：][\t ]*([^\n，,]{3,})"#,
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

    let amountOnlyPattern = #"^[+-]?\s*\d+(?:\.\d{1,2})?$"#
    if let regex = try? NSRegularExpression(pattern: amountOnlyPattern, options: []) {
        for (i, line) in lines.enumerated() where i > 0 {
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard regex.firstMatch(in: line, range: range) != nil else { continue }
            let prev = lines[i - 1]
            if isValidMerchant(prev) { return normalizeMerchant(prev) }
        }
    }

    let merchantLabels = ["收款方全称", "收款方", "商户", "商户名称", "商家", "商家名称", "对方户名", "对方账户", "店名", "商品说明"]
    let otherLabels: Set<String> = ["支付时间", "付款时间", "交易时间", "创建时间", "支付方式", "付款方式", "交易方式", "订单号", "订单编号", "商家订单号", "流水号", "账单详情", "账单分类", "支付奖励", "付款金额", "支付金额", "交易金额", "实付金额", "订单金额", "合计", "总计", "总金额", "应收", "实收", "账单管理", "标签", "备注", "计入收支"]
    let knownCloudVendors = ["阿里云计算有限公司", "阿里云", "腾讯云计算（北京）有限责任公司", "腾讯云", "华为软件技术有限公司", "华为云", "北京百度网讯科技有限公司", "百度云", "京东云计算有限公司", "京东云"]
    func isOtherLabel(_ line: String) -> Bool { otherLabels.contains(where: { line.localizedCaseInsensitiveContains($0) }) }
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
            for vendor in knownCloudVendors where candidate.localizedCaseInsensitiveContains(vendor) { return normalizeMerchant(vendor) }
            let stripped = candidate.replacingOccurrences(of: #"^(收款方全称|收款方|商户名称|商户|商家名称|商家|对方户名|对方账户|店名|商品说明)\s*[:：]?\s*"#, with: "", options: .regularExpression)
            if isValidMerchant(stripped), !isPureNumericOrOrder(stripped) { return normalizeMerchant(stripped) }
        }
    }

    let amountLinePattern = #"^(.+?)\s*[¥￥]\s*\d"#
    if let regex = try? NSRegularExpression(pattern: amountLinePattern, options: []),
       let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let r = Range(m.range(at: 1), in: text) {
        let found = String(text[r])
        if isValidMerchant(found) { return normalizeMerchant(found) }
    }

    if let first = lines.first, !first.isEmpty, extractAmount(first) == nil, isValidMerchant(first) {
        return normalizeMerchant(first)
    }
    return ""
}

private func guessCategory(_ merchant: String, _ text: String) -> (String, Bool) {
    let m = merchant.trimmingCharacters(in: .whitespaces)
    let cloud = ["阿里云", "阿里云计算有限公司", "腾讯云", "腾讯云计算（北京）有限责任公司", "华为云", "华为软件技术有限公司", "百度云", "京东云"]
    if cloud.contains(where: { m.localizedCaseInsensitiveContains($0) }) ||
       text.localizedCaseInsensitiveContains("阿里云") || text.localizedCaseInsensitiveContains("腾讯云") ||
       text.localizedCaseInsensitiveContains("云计算") || text.localizedCaseInsensitiveContains("云服务器") ||
       text.localizedCaseInsensitiveContains("ECS") || text.localizedCaseInsensitiveContains("OSS") {
        return ("云服务", false)
    }
    if text.contains("工资") { return ("工资", true) }
    if text.contains("退款") || text.contains("收款") || text.contains("入账") || text.contains("收入") || text.contains("收益") { return ("其他", true) }
    if text.contains("医疗健康") || text.contains("医院") || text.contains("诊所") || text.contains("药店") || text.contains("保险") || text.contains("惠民保") || text.contains("众安") { return ("医疗", false) }
    if text.contains("地铁") || text.contains("打车") || text.contains("公交") || text.contains("车费") || text.contains("停车") || text.contains("P云") { return ("交通", false) }
    if text.contains("餐饮") || text.contains("饭") || text.contains("餐") || text.contains("经营码") || text.contains("米线") || text.contains("馆") { return ("餐饮", false) }
    if text.contains("话费") || text.contains("充值缴费") { return ("通讯", false) }
    if text.contains("购物") || text.contains("超市") || text.contains("便利店") || text.contains("农夫山泉") { return ("购物", false) }
    if text.contains("医") { return ("医疗", false) }
    return ("其他", false)
}

private func localParseBill(text: String, referenceDate: Date? = nil, preferredMerchant: String? = nil, forceAmount: Bool = false) -> BillResult? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let eventSignals = ["培训", "训练营", "招募", "报名", "上课", "课程", "讲座", "会议", "开会", "活动时间", "培训时间", "上课时间", "地点", "会议室", "教室", "群聊", "微信群", "通知", "公告", "海报", "邀请函", "日程", "议程", "参训", "招募令", "活动报名"]
    let hasEventSignal = eventSignals.contains { trimmed.localizedCaseInsensitiveContains($0) }
    if hasEventSignal { return nil }
    let billSignals = ["交易成功", "支付时间", "付款方式", "账单详情", "收款方", "付款金额", "支付金额", "交易金额", "订单金额", "实付金额", "支付成功", "已付款", "微信支付", "支付宝", "经营码", "收款码", "付款码", "转账", "扫一扫付款", "小票", "收银", "应收", "实收", "找零", "成交价", "合计", "总计", "总金额", "件数", "数量"]
    let hasBillSignal = billSignals.contains { trimmed.localizedCaseInsensitiveContains($0) }
    guard let amount = extractAmount(trimmed, force: hasBillSignal || forceAmount) else { return nil }
    let rawMerchant: String
    if let pref = preferredMerchant, !pref.isEmpty {
        rawMerchant = pref
    } else {
        rawMerchant = extractMerchant(trimmed)
    }
    let merchant = (rawMerchant.isEmpty || isLikelyTime(rawMerchant)) ? "" : rawMerchant
    let isoTime = extractISODateTime(trimmed, referenceDate: referenceDate) ?? ISO8601DateFormatter().string(from: Date())
    let (category, _) = guessCategory(merchant, trimmed)
    return BillResult(merchant: merchant.isEmpty ? "账单" : merchant, amount: amount, isoTime: isoTime, category: category)
}

// MARK: - 一图多账单拆分（新增，与生产代码一致）

private func isAmountLine(_ line: String) -> Bool {
    if line.contains(":") || line.contains("：") { return false }
    let hasCurrency = line.range(of: #"[¥￥]\s*\d"#, options: .regularExpression) != nil
    let hasBare = line.range(of: #"^\s*[+-]?\s*\d+(?:\.\d{1,2})?\s*$"#, options: .regularExpression) != nil
    return hasCurrency || hasBare
}

private func isSummaryAmountLine(_ line: String) -> Bool {
    let lowered = line.lowercased()
    if lowered.contains("本月已省") || lowered.contains("收支统计") { return true }
    let hasExpense = line.range(of: #"支出.*\d+(?:\.\d{1,2})?"#, options: .regularExpression) != nil
    let hasIncome = line.range(of: #"收入.*\d+(?:\.\d{1,2})?"#, options: .regularExpression) != nil
    return hasExpense && hasIncome
}

private func extractRegionLines(lines: [String], amountIndex: Int, amountIndices: [Int]) -> [String] {
    guard let pos = amountIndices.firstIndex(of: amountIndex) else { return [] }
    let prev = (pos > 0) ? amountIndices[pos - 1] : -1
    let next = (pos + 1 < amountIndices.count) ? amountIndices[pos + 1] : lines.count
    let start = (prev == -1) ? 0 : (prev + amountIndex) / 2
    let end = (next == lines.count) ? lines.count - 1 : (amountIndex + next) / 2
    guard start <= end, start >= 0, end < lines.count else { return [] }
    return Array(lines[start...end])
}

private func findMerchantInBlock(_ text: String) -> String? {
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let blocklist: Set<String> = ["支付成功", "交易成功", "付款成功", "已付款", "支付完成", "交易完成", "订单金额", "支付金额", "交易金额", "付款金额", "实付金额", "应收", "实收", "合计", "总计", "总金额", "支付有礼", "完成", "返回", "首页", "账单详情", "支付方式", "付款方式", "交易方式", "付款方", "收款方", "支付时间", "付款时间", "交易时间", "创建时间", "订单号", "订单编号", "商家订单号", "流水号", "业务交易号"]
    let uiNoise: Set<String> = ["全部", "支出", "收入", "转账", "退款", "订单", "筛选", "搜索", "收支分析", "我的账单", "支付服务", "摇优惠", "服务消息", "支付消息", "账单", "全部账单", "查找交易", "Q", "X", "本月已省", "账单详情", "查看详情", "音看详情", "付款方式", "支付方式", "支付奖励", "本次奖励", "联系收款方", "优惠"]
    let bankNoise = ["信用卡", "储蓄卡", "银行卡", "借记卡", "通过", "使用"]
    for (i, line) in lines.enumerated() {
        if line.range(of: #"^[+-]?\s*\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil || line.range(of: #"[¥￥]\s*\d"#, options: .regularExpression) != nil {
            for delta in [-1, 1] {
                let j = i + delta
                guard j >= 0, j < lines.count else { continue }
                let cand = lines[j]
                if uiNoise.contains(cand) || blocklist.contains(cand) || isLikelyTime(cand) { continue }
                if bankNoise.contains(where: { cand.contains($0) }) { continue }
                if cand.count >= 2 { return normalizeMerchant(cand) }
            }
        }
    }
    return nil
}

private func detectMultiBillList(_ text: String) -> Bool {
    let entries = extractBillEntries(text)
    let validMerchants = entries.compactMap { $0.merchant }.filter { !$0.isEmpty }
    return entries.count >= 2 && Set(validMerchants).count >= 2
}

private func splitBillEntries(_ text: String) -> [String] {
    return extractBillEntries(text).map { $0.block }
}

private struct BillEntry {
    let merchant: String
    let timeLine: String?
    let block: String
}

private func extractBillEntries(_ text: String) -> [BillEntry] {
    let rawLines = text.components(separatedBy: .newlines)
    let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }

    let amountIndices = lines.enumerated().compactMap { i, line -> Int? in
        guard isAmountLine(line), !isSummaryAmountLine(line) else { return nil }
        return i
    }
    guard amountIndices.count >= 2 else { return [] }

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
        if t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    func isPotentialMerchant(_ line: String) -> Bool {
        if isUINoise(line) { return false }
        if isLikelyTime(line) { return false }
        if isAmountLine(line) { return false }
        if line.isEmpty { return false }
        if bankNoise.contains(where: { line.contains($0) }) { return false }
        if categoryWords.contains(where: { line.contains($0) }) { return false }
        return true
    }

    var entries: [BillEntry] = []
    for (k, idx) in amountIndices.enumerated() {
        let prevAmountIdx = (k > 0) ? amountIndices[k - 1] : -1
        var timeLine: String? = nil
        var merchantCandidates: [String] = []
        var scanJ = idx - 1
        while scanJ > prevAmountIdx && scanJ >= 0 {
            let line = lines[scanJ]
            if isLikelyTime(line) && timeLine == nil {
                timeLine = line
            } else if isPotentialMerchant(line) {
                merchantCandidates.append(line)
            }
            scanJ -= 1
        }
        guard let m = merchantCandidates.first else { continue }

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

private func localParseMultiBillsIfNeeded(text: String) -> [BillResult]? {
    guard detectMultiBillList(text) else { return nil }
    let entries = extractBillEntries(text)
    var results: [BillResult] = []
    for e in entries {
        if let r = localParseBill(text: e.block, referenceDate: nil, preferredMerchant: e.merchant, forceAmount: true) {
            results.append(r)
        }
    }
    return results.isEmpty ? nil : results
}

// MARK: - 真实 OCR 样例

let sampleH = """
23:34
服务消息
支付消息
阿里云
19:09
付款成功
¥10.00
音看详情〉
付款方式 余额宝
支付奖励
• 领88元余额宝体验金〉
红木棉越式小馆
17:14
付款成功
¥23.00
音看详情＞
付款方式 中国银行信用卡（6590）
支付奖励
+3积分|抢黑人清新双效牙膏＞
娟
13:31
付款成功
¥18.00
童看详情＞
付款方式 中国银行信用卡（6590）
本次奖励
C 领本周到店支付红包
去看看
联系收款方
"""

let sampleI = """
全部
23:34寸
Q 搜索交易记录
支出
转账 退款
本月已省 2.61元〉
搜索
订单 筛选•
收支分析
充值：阿里云服务购买，业务交易号…
其他
今天 19:09
-10.00
红木棉越式小馆
餐饮美食
今天 17:14
-23.00
扫经营码付款-给娟
医疗健康
今天 13:31
-18.00
话费自动充值
充值缴费
今天06:56
-19.96
自动扣款成功
余额宝-收益发放
投资理财|
今天02:12
0.02
花呗自动还款-2026年07月账单
信用借还
昨天10:40
158.99
"""

let sampleJ = """
23:35
X
账单
全部账单、
Q 查找交易
收支统计》
2026年7月～
支出¥2500.44 收入¥28.60
美团
上海票优文化科技有限公司
7月21日 15:39
-19.90
老汤和•乌鸡米线（西乡塘大学东..
7月18日 18:57
-23.40
腾讯云费用账户-移动支付
7月17日 12:18
-19.90
惠民保
7月16日 18:37
-139.00
众安健康
7月16日 18:26
-397.88
398.00
智慧城市合作商户
7月15日 17:17
-12.00
Pp
P云停车平台
7月14日 22:03
农夫山泉自贩机
7月14日 20:26
智慧城市合作商户
7月14日 13:39
-6.00
-4.00
-16.00
"""

let sampleK = """
23:36
出分
微信支付
星期四 18:26
Q
说
众安健康
使用中信银行信用卡（4273）支付
¥397.88
¥398:00
账单详情＞
优惠
银行卡立减金优惠0.12元
星期四18:37
惠民保
通过中信银行信用卡（4273）自动续费
¥139.00
账单详情＞
保险名称
被保人
2026南宁惠邕保
*圆
缴费计划 剩余1年，每年扣费Y139.00
我的账单
支付服务
摇优惠•
"""

// MARK: - 断言
var passCount = 0, failCount = 0

func check(_ name: String, _ actual: String, _ expected: String) {
    if actual.contains(expected) || expected.contains(actual) {
        passCount += 1; print("✅ PASS  \(name): '\(actual)'")
    } else {
        failCount += 1; print("❌ FAIL  \(name): actual='\(actual)' expected='\(expected)'")
    }
}

func checkAmount(_ name: String, _ actual: Double, _ expected: Double) {
    if abs(actual - expected) < 0.01 {
        passCount += 1; print("✅ PASS  \(name): \(actual)")
    } else {
        failCount += 1; print("❌ FAIL  \(name): actual=\(actual) expected=\(expected)")
    }
}

func runSample(_ name: String, _ text: String, expectedMinBills: Int, expected: [(merchant: String, amount: Double, timeHint: String, category: String)]) {
    print("\n===== 样例 \(name)：一图多账单 =====")
    guard let results = localParseMultiBillsIfNeeded(text: text) else {
        failCount += 1
        print("❌ FAIL \(name): 未触发多账单拆分")
        return
    }
    print("识别到 \(results.count) 条账单")
    if results.count >= expectedMinBills {
        passCount += 1; print("✅ PASS \(name).count >= \(expectedMinBills)")
    } else {
        failCount += 1; print("❌ FAIL \(name).count: actual=\(results.count) expected>=\(expectedMinBills)")
    }
    for (i, exp) in expected.enumerated() {
        guard i < results.count else { continue }
        let r = results[i]
        check("\(name)[\(i)].merchant", r.merchant, exp.merchant)
        checkAmount("\(name)[\(i)].amount", r.amount, exp.amount)
        check("\(name)[\(i)].time", r.isoTime, exp.timeHint)
        check("\(name)[\(i)].category", r.category, exp.category)
    }
}

runSample("H", sampleH, expectedMinBills: 3, expected: [
    ("阿里云", 10.0, "T19:09", "云服务"),
    ("红木棉", 23.0, "T17:14", "餐饮"),
    ("娟", 18.0, "T13:31", "其他")
])

runSample("I", sampleI, expectedMinBills: 4, expected: [
    ("阿里云", 10.0, "T19:09", "云服务"),
    ("红木棉", 23.0, "T17:14", "餐饮"),
    ("娟", 18.0, "T13:31", "餐饮"),
    ("话费", 19.96, "T06:56", "通讯")
])

runSample("J", sampleJ, expectedMinBills: 6, expected: [
    ("上海票优", 19.9, "T15:39", "其他"),
    ("老汤和", 23.4, "T18:57", "餐饮"),
    ("腾讯云", 19.9, "T12:18", "云服务"),
    ("惠民保", 139.0, "T18:37", "医疗"),
    ("众安健康", 397.88, "T18:26", "医疗"),
    ("智慧城市", 12.0, "T17:17", "其他")
])

runSample("K", sampleK, expectedMinBills: 2, expected: [
    ("众安健康", 397.88, "T18:26", "医疗"),
    ("惠民保", 139.0, "T18:37", "医疗")
])

print("\n========================================")
print("一图多账单回归结果：PASS = \(passCount), FAIL = \(failCount)")
print("========================================")
exit(failCount == 0 ? 0 : 1)
