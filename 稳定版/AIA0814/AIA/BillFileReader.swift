// BillFileReader.swift
// 账单导入解析层：把微信 xlsx / 支付宝 csv 读成统一的二维字符串数组。
// 零第三方依赖：xlsx 用 Compression 框架手动 inflate + XMLParser。
import Foundation
import CoreFoundation
import Compression
import UniformTypeIdentifiers

enum BillFileSource: String {
    case wechat
    case alipay
    case unknown
}

struct BillRawFile {
    let source: BillFileSource
    let rows: [[String]]   // 含表头行，已按列拆分
}

struct BillFileReader {

    /// 读取文件，自动按扩展名分流。失败时返回 nil 并写入 error。
    static func read(url: URL) -> (raw: BillRawFile?, error: String?) {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" || ext == "xls" {
            return readXLSX(url: url)
        }
        return readCSV(url: url)
    }

    // MARK: - CSV（含支付宝前导水印）
    private static func readCSV(url: URL) -> (BillRawFile?, String?) {
        // 编码容错：先 UTF-8，失败回退 GBK/GB18030（支付宝旧版导出）
        guard let data = try? Data(contentsOf: url) else {
            return (nil, "无法读取文件")
        }
        var text: String?
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            text = utf8
        } else if let gbk = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) ) {
            text = gbk
        }
        guard let raw = text, !raw.isEmpty else {
            return (nil, "文件编码无法识别（需 UTF-8 或 GBK）")
        }

        // 去 BOM
        var cleaned = raw
        if cleaned.hasPrefix("\u{FEFF}") { cleaned.removeFirst() }

        // 拆行，兼容 \r\n / \r / \n
        let lines = cleaned.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // 定位表头行：含"交易时间"的那一行
        var headerLineIndex: Int?
        for (i, line) in lines.enumerated() {
            if line.contains("交易时间") { headerLineIndex = i; break }
        }

        let dataLines: [String]
        let source: BillFileSource
        if let h = headerLineIndex {
            source = lineContainsAlipay(line: lines[h]) ? .alipay : .unknown
            dataLines = Array(lines[h...])
        } else {
            // 没有标准表头，兜底：过滤空行后整段交给适配器
            source = .unknown
            dataLines = lines.filter { !$0.isEmpty }
        }

        guard dataLines.count >= 2 else {
            return (nil, "CSV 内容不足，至少需要表头和一行数据")
        }

        var rows: [[String]] = []
        for line in dataLines {
            let cols = parseCSVLine(line)
            if cols.isEmpty || cols.allSatisfy({ $0.isEmpty }) { continue }
            // 跳过支付宝常见的"---"分隔线与纯空白水印
            if line.hasPrefix("---") || line.hasPrefix("----") { continue }
            rows.append(cols)
        }
        guard rows.count >= 2 else {
            return (nil, "未能从文件中解析出有效表头与数据")
        }
        return (BillRawFile(source: source, rows: rows), nil)
    }

    private static func lineContainsAlipay(line: String) -> Bool {
        line.contains("交易对方") || line.contains("收/支") || line.contains("交易分类")
    }

    // MARK: - XLSX（微信官方导出）
    private static func readXLSX(url: URL) -> (BillRawFile?, String?) {
        guard let data = try? Data(contentsOf: url) else {
            return (nil, "无法读取 xlsx 文件")
        }
        // 1. 解压出 sharedStrings.xml 与 sheet1.xml
        guard let (sharedXML, sheetXML) = unzipXLSX(data) else {
            return (nil, "xlsx 解压失败（文件可能损坏或非标准格式）")
        }
        // 2. 解析共享字符串表
        let shared = parseSharedStrings(sharedXML)
        // 3. 解析 sheet 单元格 -> 二维数组
        let rows = parseSheet(sheetXML, shared: shared)
        guard rows.count >= 2 else {
            return (nil, "xlsx 中没有有效数据行")
        }
        // 微信官方导出 xlsx 前几行常为说明行（如「微信支付账单明细列表」「统计时间：…」「注：…」），
        // 真正的表头（含「交易时间」）在后面，需要跳过前导说明行，否则 source 会被错判为 unknown 导致识别失败。
        var headerIndex: Int?
        for (i, row) in rows.enumerated() {
            if row.joined(separator: ",").contains("交易时间") {
                headerIndex = i
                break
            }
        }

        guard let headerIndex = headerIndex else {
            // 连「交易时间」都没找到，按 unknown 兜底交给适配器处理
            return (BillRawFile(source: .unknown, rows: rows), nil)
        }

        // 从表头行开始取数据，保证 rows.first 就是真正表头
        let dataRows = Array(rows[headerIndex...])
        let header = dataRows.first ?? []
        let headerJoined = header.joined(separator: ",")
        let source: BillFileSource = headerJoined.contains("交易时间") ? .wechat : .unknown
        return (BillRawFile(source: source, rows: dataRows), nil)
    }

    // MARK: 解压 xlsx（最小 zip 解析：定位 local file header，deflate 解压）
    private static func unzipXLSX(_ data: Data) -> (shared: String, sheet: String)? {
        let bytes = [UInt8](data)
        var shared: String?
        var sheet: String?

        var offset = 0
        while offset < bytes.count {
            // 找 local file header 签名 PK\x03\x04
            guard offset + 4 <= bytes.count,
                  bytes[offset] == 0x50, bytes[offset+1] == 0x4B,
                  bytes[offset+2] == 0x03, bytes[offset+3] == 0x04 else {
                offset += 1
                continue
            }
            // 跳过 version(2) + flag(2) + method(2)
            // time(2) date(2) crc(4) compSize(4) uncompSize(4)
            let compSize = Int(UInt32(bytes[offset+18]) | (UInt32(bytes[offset+19]) << 8) | (UInt32(bytes[offset+20]) << 16) | (UInt32(bytes[offset+21]) << 24))
            let nameLen = Int(bytes[offset+26]) | (Int(bytes[offset+27]) << 8)
            let extraLen = Int(bytes[offset+28]) | (Int(bytes[offset+29]) << 8)
            let nameStart = offset + 30
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(bytes: bytes[nameStart..<(nameStart+nameLen)], encoding: .utf8) ?? ""
            let dataStart = nameStart + nameLen + extraLen
            guard dataStart + compSize <= bytes.count else { break }

            let chunk = bytes[dataStart..<(dataStart+compSize)]
            if name == "xl/sharedStrings.xml" {
                shared = inflate(Data(chunk))
            } else if name == "xl/worksheets/sheet1.xml" {
                sheet = inflate(Data(chunk))
            } else if name.contains("sharedStrings.xml") {
                shared = inflate(Data(chunk))
            } else if name.contains("worksheets/sheet") {
                sheet = sheet ?? inflate(Data(chunk))
            }

            offset = dataStart + compSize
        }
        guard let s = shared, let sh = sheet else { return nil }
        return (s, sh)
    }

    private static func inflate(_ data: Data) -> String? {
        // 先探测：若已是纯 XML 文本则直转（cover store 压缩等边界）
        if let raw = String(data: data, encoding: .utf8), raw.hasPrefix("<?xml") {
            return raw
        }

        let srcSize = data.count
        let dstCapacity = srcSize * 8 + 4096
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { dstPtr in
            data.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!,
                    dstCapacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    srcSize,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        if written <= 0 { return nil }
        dst.count = written
        return String(data: dst, encoding: .utf8)
    }

    // MARK: 解析 sharedStrings.xml
    private static func parseSharedStrings(_ xml: String) -> [String] {
        let parser = SharedStringParser()
        let data = Data(xml.utf8)
        let xmlParser = Foundation.XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.result
    }

    // MARK: 解析 sheet1.xml
    private static func parseSheet(_ xml: String, shared: [String]) -> [[String]] {
        let parser = SheetParser(shared: shared)
        let data = Data(xml.utf8)
        let xmlParser = Foundation.XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.rows
    }

    // MARK: - CSV 行解析（支持引号包裹、双引号转义）
    static func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if char == "\"" {
                if inQuotes, let next = iterator.next(), next == "\"" {
                    current.append("\"")
                } else {
                    inQuotes.toggle()
                }
            } else if char == ",", !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - sharedStrings 解析 delegate
private class SharedStringParser: NSObject, XMLParserDelegate {
    var result: [String] = []
    private var currentText = ""
    private var inSI = false
    private var inT = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "si" { inSI = true; currentText = "" }
        else if elementName == "t" && inSI { inT = true; currentText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "t" { inT = false }
        else if elementName == "si" {
            inSI = false
            result.append(currentText)
        }
    }
}

// MARK: - sheet 解析 delegate（按 r 列引用 A/B/C 定位列索引）
private class SheetParser: NSObject, XMLParserDelegate {
    let shared: [String]
    private var currentRow: [String] = []
    private var maxCol = 0
    private var cellRef = ""
    private var cellType = ""   // "s"=shared string 索引；"inlineStr"/""=内联或数字
    private var cellValue = ""  // 当前单元格已确定的最终值
    private var inlineText = "" // inlineStr 的 <t> 文本累积
    private var inRow = false
    private var inC = false
    private var inV = false     // <v> 数字/共享索引
    private var inT = false     // <t> 内联文本
    private var isRowEmpty = true

    var rows: [[String]] = []

    init(shared: [String]) { self.shared = shared }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch elementName {
        case "row":
            inRow = true
            currentRow = []
            maxCol = 0
            isRowEmpty = true
        case "c":
            inC = true
            cellRef = attributes["r"] ?? ""
            cellType = attributes["t"] ?? ""
            cellValue = ""
            inlineText = ""
        case "v":
            inV = true
        case "t":
            inT = true
            inlineText = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV { cellValue += string }
        else if inT { inlineText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "v":
            inV = false
            finalizeCell()
        case "t":
            inT = false
        case "c":
            inC = false
            // inlineStr：文本已在 <t> 累积到 inlineText
            if cellType == "inlineStr" {
                let idx = columnIndex(from: cellRef)
                placeValue(inlineText, at: idx)
            }
        case "row":
            inRow = false
            while currentRow.count <= maxCol { currentRow.append("") }
            if !isRowEmpty { rows.append(currentRow) }
        default: break
        }
    }

    private func finalizeCell() {
        guard inC else { return }
        let idx = columnIndex(from: cellRef)
        if idx < 0 { return }
        let value: String
        if cellType == "s", let i = Int(cellValue.trimmingCharacters(in: .whitespaces)),
           i < shared.count {
            value = shared[i]
        } else {
            value = cellValue
        }
        placeValue(value, at: idx)
    }

    private func columnIndex(from ref: String) -> Int {
        var col = 0
        for ch in ref {
            if ch.isLetter { col = col * 26 + Int(ch.asciiValue! - 64) }
            else { break }
        }
        return col - 1   // 0-based
    }

    private func placeValue(_ value: String, at idx: Int) {
        while currentRow.count <= idx { currentRow.append("") }
        currentRow[idx] = value
        if idx > maxCol { maxCol = idx }
        if !value.isEmpty { isRowEmpty = false }
    }
}
