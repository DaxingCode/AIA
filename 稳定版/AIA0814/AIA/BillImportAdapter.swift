// BillImportAdapter.swift
// 把 BillFileReader 解析出的二维数组，按 微信/支付宝 列头映射成 ImportableBill。
// 列定位全部用「包含关键字」容错，不写死列序，抗改版。
import Foundation

struct BillImportAdapter {

    static func adapt(_ raw: BillRawFile, parseDate: (String) -> Date?) -> [ImportableBill] {
        switch raw.source {
        case .wechat:
            return adapt(rows: raw.rows, parseDate: parseDate,
                         isIncomeValues: ["收入", "转账收入", "退款", "零钱充值"],
                         excludeIncomeValues: [],
                         categoryFromType: false)
        case .alipay:
            return adaptAlipay(rows: raw.rows, parseDate: parseDate)
        case .unknown:
            // 兜底：尝试通用模板（含「时间」列头）
            return adapt(rows: raw.rows, parseDate: parseDate,
                         isIncomeValues: ["收入", "进账", "入账"],
                         excludeIncomeValues: [],
                         categoryFromType: false)
        }
    }

    // MARK: - 通用映射（微信 / 兜底）
    private static func adapt(rows: [[String]], parseDate: (String) -> Date?,
                              isIncomeValues: [String], excludeIncomeValues: [String],
                              categoryFromType: Bool) -> [ImportableBill] {
        guard let header = rows.first else { return [] }
        let map = locateColumns(header: header)

        guard let timeIdx = map["time"], let amountIdx = map["amount"] else {
            return []
        }

        var result: [ImportableBill] = []
        for line in rows.dropFirst() {
            let bill = parseLine(line, map: map, timeIdx: timeIdx, amountIdx: amountIdx,
                                 parseDate: parseDate, isIncomeValues: isIncomeValues,
                                 excludeIncomeValues: excludeIncomeValues,
                                 categoryFromType: categoryFromType)
            result.append(bill)
        }
        return result
    }

    // MARK: - 支付宝专用（含不计收支丢弃 + 交易状态过滤）
    private static func adaptAlipay(rows: [[String]], parseDate: (String) -> Date?) -> [ImportableBill] {
        guard let header = rows.first else { return [] }
        let map = locateColumns(header: header)
        guard let timeIdx = map["time"], let amountIdx = map["amount"] else { return [] }
        let typeIdx = map["type"]
        let statusIdx = header.firstIndex { $0.contains("交易状态") || $0.contains("状态") }

        var result: [ImportableBill] = []
        for line in rows.dropFirst() {
            guard line.count > max(timeIdx, amountIdx) else { continue }
            let typeVal = typeIdx != nil && line.count > typeIdx! ? line[typeIdx!] : ""

            // 不计收支（余额宝收益/转账/充值提现）——整行丢弃
            if typeVal.contains("不计收支") { continue }

            // 交易状态过滤：未成功的不计
            if let sIdx = statusIdx, line.count > sIdx {
                let st = line[sIdx]
                let ok = st.contains("交易成功") || st.contains("已记账") ||
                         st.contains("已入账") || st.contains("成功")
                if !ok && !st.isEmpty { continue }
            }

            let bill = parseLine(line, map: map, timeIdx: timeIdx, amountIdx: amountIdx,
                                 parseDate: parseDate,
                                 isIncomeValues: ["收入", "进账", "入账"],
                                 excludeIncomeValues: [], categoryFromType: false)
            result.append(bill)
        }
        return result
    }

    // MARK: - 列定位（容错）
    private static func locateColumns(header: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (idx, h) in header.enumerated() {
            let c = h.trimmingCharacters(in: .whitespaces)
            if c.contains("时间") || c.contains("日期") { map["time"] = idx }
            if c.contains("收/支") || c.contains("收支") || c.contains("类型") { map["type"] = idx }
            if c.contains("分类") || c.contains("类别") { map["category"] = idx }
            if c.contains("金额") || c.contains("数额") || c.contains("钱") { map["amount"] = idx }
            // 商户列：优先「交易对方/商品」，避免命中「商户单号」这类单号列
            if c.contains("交易对方") || c.contains("商品") || c.contains("店名") {
                if map["merchant"] == nil { map["merchant"] = idx }
            } else if c.contains("商户") && !c.contains("单号") {
                if map["merchant"] == nil { map["merchant"] = idx }
            }
            if c.contains("备注") || c.contains("说明") || c.contains("描述") { map["note"] = idx }
        }
        return map
    }

    // MARK: - 单行解析
    private static func parseLine(_ line: [String], map: [String: Int],
                                  timeIdx: Int, amountIdx: Int,
                                  parseDate: (String) -> Date?,
                                  isIncomeValues: [String], excludeIncomeValues: [String],
                                  categoryFromType: Bool) -> ImportableBill {
        var invalidReason = ""

        func val(_ key: String) -> String {
            guard let i = map[key], i < line.count else { return "" }
            return line[i].trimmingCharacters(in: .whitespaces)
        }

        // 时间
        let timeStr = val("time")
        var time = Date()
        if timeStr.isEmpty {
            invalidReason = "缺少时间"
        } else if let d = parseDate(timeStr) {
            time = d
        } else {
            invalidReason = "时间格式无法识别：\(timeStr)"
        }

        // 收/支方向
        let typeStr = val("type")
        var isIncome = false
        if typeStr.contains("收入") || typeStr.contains("进账") || typeStr.contains("入账") {
            isIncome = true
        } else if typeStr.contains("支出") || typeStr.contains("消费") || typeStr.contains("出") {
            isIncome = false
        } else if !typeStr.isEmpty {
            // 类型列存在但不含明确方向词：按 isIncomeValues 兜底
            isIncome = isIncomeValues.contains(where: { typeStr.contains($0) })
        }
        // 明确标注的不计收支按支出处理（已在上游过滤的不计收支不会到这里）

        // 金额
        let amountStr = val("amount")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        let amount = Double(amountStr) ?? 0
        if amountStr.isEmpty {
            invalidReason = invalidReason.isEmpty ? "缺少金额" : invalidReason
        } else if amount <= 0 {
            invalidReason = invalidReason.isEmpty ? "金额须大于 0" : invalidReason
        }

        let category = val("category")
        let merchant = val("merchant")
        let note = val("note")

        return ImportableBill(
            time: time,
            isIncome: isIncome,
            category: category,
            amount: amount,
            merchant: merchant,
            note: note,
            isValid: invalidReason.isEmpty,
            invalidReason: invalidReason
        )
    }
}
