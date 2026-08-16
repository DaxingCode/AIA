// BillImportView.swift
// 账单导入：支持 CSV 文件 / 粘贴文本导入，提供模板、预览、去重。
// 入口：账单管理页（BillListView）顶部「账单导入」。
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 一条待导入的账单
struct ImportableBill: Identifiable, Hashable {
    let id = UUID()
    var time: Date
    var isIncome: Bool
    var category: String
    var amount: Double
    var merchant: String
    var note: String
    var isValid: Bool
    var invalidReason: String
}

struct BillImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \Bill.time, order: .reverse) private var bills: [Bill]

    @State private var csvText: String = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var parsedBills: [ImportableBill] = []
    @State private var showFileImporter = false
    @State private var importResult: String?
    @State private var showResultAlert = false
    @State private var isLoading = false
    @State private var currentSource: String = ""   // 当前选中的账单来源：wechat/alipay/other
    @State private var currentFileName: String?       // 当前导入的文件名（用于批次记录）
    @State private var sharePayload: SharePayload?    // 标准模板导出分享载荷

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.timeZone = TimeZone.current
        return f
    }()

    private var templateCSV: String {
        """
        时间,类型,分类,金额,商户,备注
        2026-07-21 12:30,支出,餐饮,58.50,麦当劳,午餐
        2026-07-20 09:15,支出,交通,23.00,滴滴出行,上班打车
        2026-07-19 18:00,收入,工资,15000.00,公司,七月工资
        """
    }

    // MARK: - Body
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sourceCard
                hintSection
                actionButtons
                previewSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle("账单导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    NavigationRouter.shared.navigate(.importHistory)
                } label: {
                    Text("导入记录")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.sub)
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                UTType.commaSeparatedText,
                UTType.plainText,
                UTType(filenameExtension: "xlsx") ?? .data,
                UTType.data
            ],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .centeredAlert(isPresented: $showResultAlert,
                       title: "",
                       message: importResult ?? "",
                       dismissTitle: "知道了",
                       onDismiss: { if (importResult ?? "").hasPrefix("成功") { dismiss() } })
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
    }

    // MARK: - 导出标准模板文件
    private func exportTemplate() {
        let fileName = "账单导入模板.csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try templateCSV.write(to: url, atomically: true, encoding: .utf8)
            sharePayload = SharePayload(items: [url])
        } catch {
            importResult = "模板导出失败：\(error.localizedDescription)"
            showResultAlert = true
        }
    }

    // MARK: - 请选择账单来源
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("支持导入的账单来源")
                .font(AIATheme.Font.headline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                sourceRow(icon: { Image(systemName: "creditcard.fill") }, title: "支付宝", iconColor: Color(hex: 0x1677ff), iconBg: Color(hex: 0x1677ff).opacity(0.12), isOtherSource: false, source: "alipay")

                Divider().padding(.leading, 48)

                sourceRow(icon: { Image(systemName: "message.fill") }, title: "微信", iconColor: Color(hex: 0x07c160), iconBg: Color(hex: 0x07c160).opacity(0.12), isOtherSource: false, source: "wechat")

                Divider().padding(.leading, 48)

                sourceRow(icon: { Image(systemName: "doc.on.doc") }, title: "其他来源", iconColor: AIATheme.blue, iconBg: AIATheme.blue.opacity(0.12), isOtherSource: true, source: "other")
            }
        }
        .padding(14)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private func sourceRow(icon: @escaping () -> some View, title: String, iconColor: Color, iconBg: Color, isOtherSource: Bool, source: String) -> some View {
        Button {
            currentSource = source
            showFileImporter = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(iconBg)
                        .frame(width: 36, height: 36)
                    icon()
                        .font(AIATheme.Font.body.weight(.medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 20, height: 20)
                }
                Text(title)
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(AIATheme.iconInactive)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 说明文案
    private var hintSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(AIATheme.Font.callout)
                .foregroundStyle(AIATheme.blue)

            VStack(alignment: .leading, spacing: 4) {
                hintText
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    exportTemplate()
                } label: {
                    Text("下载标准模板")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.blue)
                        .underline(color: AIATheme.blue)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private var hintText: Text {
        let f = AIATheme.Font.caption
        let t1 = Text("支持微信、支付宝官方导出的账单（").font(f).foregroundStyle(AIATheme.sub)
        let t2 = Text(".xlsx").font(f).foregroundStyle(AIATheme.blue)
        let t3 = Text(" / ").font(f).foregroundStyle(AIATheme.sub)
        let t4 = Text(".csv").font(f).foregroundStyle(AIATheme.blue)
        let t5 = Text(" / ").font(f).foregroundStyle(AIATheme.sub)
        let t6 = Text(".txt").font(f).foregroundStyle(AIATheme.blue)
        let t7 = Text("），以及银行/财务类 App 的账单。若无法识别你的文件，可下载并填写标准模板").font(f).foregroundStyle(AIATheme.sub)
        return t1 + t2 + t3 + t4 + t5 + t6 + t7
    }

    // MARK: - 上传文件 / 查看交易记录
    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.doc.fill")
                        .font(AIATheme.Font.body)
                    Text("上传账单文件")
                        .font(AIATheme.Font.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AIATheme.blue)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)

            Button {
                // TODO: 查看交易记录
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(AIATheme.Font.body)
                    Text("查看交易记录")
                        .font(AIATheme.Font.body.weight(.semibold))
                }
                .foregroundStyle(AIATheme.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AIATheme.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 预览
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "预览")
                Spacer()
                if !parsedBills.isEmpty {
                    let valid = parsedBills.filter(\.isValid)
                    let dup = valid.filter { isDuplicate($0) }.count
                    let fresh = valid.count - dup
                    Text("共 \(parsedBills.count) 条，有效 \(valid.count) 条（新增 \(fresh) · 重复 \(dup)）")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }

            if parsedBills.isEmpty {
                Text("选择文件或粘贴 CSV 后，会在这里显示可导入的账单")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                let validIDs = Set(parsedBills.filter(\.isValid).map(\.id))
                                if selectedIDs.isSuperset(of: validIDs) {
                                    selectedIDs.subtract(validIDs)
                                } else {
                                    selectedIDs.formUnion(validIDs)
                                }
                            }
                        } label: {
                            Text(selectedIDs.isSuperset(of: Set(parsedBills.filter(\.isValid).map(\.id))) ? "取消全选" : "全选")
                                .font(AIATheme.Font.footnote.weight(.medium))
                                .foregroundStyle(AIATheme.blue)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text("已选 \(selectedIDs.intersection(Set(parsedBills.map(\.id))).count) 条")
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(AIATheme.muted)
                    }

                    ForEach(Array(parsedBills.enumerated()), id: \.offset) { _, bill in
                        previewRow(bill)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if bill.isValid {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if selectedIDs.contains(bill.id) {
                                            selectedIDs.remove(bill.id)
                                        } else {
                                            selectedIDs.insert(bill.id)
                                        }
                                    }
                                }
                            }
                    }

                    importButton
                }
                .padding(12)
                .background(AIATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
        }
    }

    // MARK: - 单条预览行
    private func previewRow(_ bill: ImportableBill) -> some View {
        let isSelected = selectedIDs.contains(bill.id)
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(AIATheme.Font.title2)
                .foregroundStyle(isSelected ? AIATheme.blue : AIATheme.muted)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(bill.isValid ? (bill.isIncome ? "收入" : "支出") : "无效")
                        .font(AIATheme.Font.micro.weight(.medium))
                        .foregroundStyle(bill.isValid ? (bill.isIncome ? AIATheme.income : AIATheme.expense) : AIATheme.warn)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((bill.isValid ? (bill.isIncome ? AIATheme.income : AIATheme.expense) : AIATheme.warn).opacity(0.12))
                        .clipShape(Capsule())

                    Text(bill.merchant.isEmpty ? "未命名" : bill.merchant)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(bill.isValid ? .primary : AIATheme.muted)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(bill.isValid ? formatMoney(bill.amount) : "-")
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(bill.isValid ? (bill.isIncome ? AIATheme.income : AIATheme.expense) : AIATheme.muted)
                }
                HStack(spacing: 6) {
                    Text(formatDate(bill.time))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                    if !bill.category.isEmpty {
                        Text("·")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                        Text(bill.category)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.sub)
                    }
                    Spacer(minLength: 0)
                }
                if !bill.isValid && !bill.invalidReason.isEmpty {
                    Text(bill.invalidReason)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.warn)
                }
                if !bill.note.isEmpty {
                    Text(bill.note)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
        .opacity(bill.isValid ? 1 : 0.55)
    }

    // MARK: - 导入按钮
    private var importButton: some View {
        let selected = parsedBills.filter { $0.isValid && selectedIDs.contains($0.id) }
        let newCount = selected.filter { !isDuplicate($0) }.count
        return Button {
            performImport()
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                }
                Image(systemName: "arrow.down.doc")
                Text(selected.isEmpty ? "无可导入账单" : "导入 \(newCount) 条账单")
            }
            .font(AIATheme.Font.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(selected.isEmpty ? AIATheme.blue.opacity(0.4) : AIATheme.blue)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty || isLoading)
    }

    // MARK: - 粘贴板
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importResult = "剪贴板为空"
            showResultAlert = true
            return
        }
        csvText = text
        parseCSV(text)
    }

    // MARK: - 文件导入
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if currentSource.isEmpty { currentSource = "other" }
            currentFileName = url.lastPathComponent
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            if ext == "xlsx" || ext == "xls" {
                importFromFile(url)
            } else {
                // csv / txt 等文本类：优先用统一 reader（自动跳水印），失败回退原 parseCSV
                let (raw, err) = BillFileReader.read(url: url)
                if let raw {
                    adaptAndSet(raw)
                } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                    csvText = text
                    parseCSV(text)
                } else {
                    importResult = err ?? "读取文件失败"
                    showResultAlert = true
                }
            }
        case .failure(let error):
            importResult = "选择文件失败：\(error.localizedDescription)"
            showResultAlert = true
        }
    }

    /// xlsx 文件：经 BillFileReader 解压 + BillImportAdapter 映射
    private func importFromFile(_ url: URL) {
        let (raw, err) = BillFileReader.read(url: url)
        guard let raw else {
            importResult = err ?? "文件解析失败"
            showResultAlert = true
            return
        }
        adaptAndSet(raw)
    }

    /// 把解析出的二维数组交由适配器映射成 ImportableBill
    private func adaptAndSet(_ raw: BillRawFile) {
        let bills = BillImportAdapter.adapt(raw) { s in self.parseDate(s) }
        if bills.isEmpty {
            importResult = "未能从该文件识别出账单（请确认是微信/支付宝官方导出文件）"
            showResultAlert = true
            return
        }
        parsedBills = bills
    }

    // MARK: - CSV 解析
    private func parseCSV(_ text: String) {
        // 去掉 BOM
        var cleaned = text
        if cleaned.hasPrefix("\u{FEFF}") { cleaned.removeFirst() }

        // 拆行，兼容 \r\n / \r / \n
        let lines = cleaned.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            importResult = "CSV 内容不足，至少需要表头和一行数据"
            showResultAlert = true
            return
        }

        let header = parseCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let colMap = buildColumnMap(header: header)

        var parsed: [ImportableBill] = []
        for (index, line) in lines.dropFirst().enumerated() {
            let cols = parseCSVLine(line)
            let bill = parseBill(columns: cols, map: colMap, lineIndex: index + 2)
            parsed.append(bill)
        }
        parsedBills = parsed
    }

    /// 简单 CSV 解析，支持引号包裹
    private func parseCSVLine(_ line: String) -> [String] {
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
        return result
    }

    private func buildColumnMap(header: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (idx, h) in header.enumerated() {
            switch h {
            case "时间", "time", "date", "日期": map["time"] = idx
            case "类型", "type", "收支": map["type"] = idx
            case "分类", "category": map["category"] = idx
            case "金额", "amount", "钱", "价钱": map["amount"] = idx
            case "商户", "merchant", "商家", "店名", "店铺": map["merchant"] = idx
            case "备注", "note", "说明", "描述": map["note"] = idx
            default: break
            }
        }
        return map
    }

    private func parseBill(columns: [String], map: [String: Int], lineIndex: Int) -> ImportableBill {
        var invalidReason = ""

        func value(_ key: String) -> String {
            guard let idx = map[key], idx < columns.count else { return "" }
            return columns[idx].trimmingCharacters(in: .whitespaces)
        }

        // 时间
        let timeStr = value("time")
        var time = Date()
        if timeStr.isEmpty {
            invalidReason = "缺少时间"
        } else if let d = parseDate(timeStr) {
            time = d
        } else {
            invalidReason = "时间格式无法识别：\(timeStr)"
        }

        // 类型
        let typeStr = value("type").lowercased()
        let isIncome: Bool
        if typeStr.isEmpty {
            invalidReason = invalidReason.isEmpty ? "缺少类型" : invalidReason
            isIncome = false
        } else if ["收入", "income", "进账", "入账", "收"].contains(typeStr) {
            isIncome = true
        } else if ["支出", "expense", "消费", "出", "花"].contains(typeStr) {
            isIncome = false
        } else {
            invalidReason = invalidReason.isEmpty ? "类型只能填「支出」或「收入」" : invalidReason
            isIncome = false
        }

        // 金额
        let amountStr = value("amount")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        let amount = Double(amountStr) ?? 0
        if amountStr.isEmpty {
            invalidReason = invalidReason.isEmpty ? "缺少金额" : invalidReason
        } else if amount <= 0 {
            invalidReason = invalidReason.isEmpty ? "金额须大于 0" : invalidReason
        }

        let category = value("category")
        let merchant = value("merchant")
        let note = value("note")

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

    private func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        // 微信 xlsx「交易时间」是 Excel 日期序列号（如 46241.4535），需转换
        if let serial = Double(trimmed), serial > 30000, serial < 80000 {
            // Excel 1900 日期系统：基准 1899-12-30，含 1900 闰年误差（用标准偏移近似）
            let seconds = (serial - 25569) * 86400  // 25569 = 1970-01-01 的 Excel 序列号
            return Date(timeIntervalSince1970: seconds)
        }
        let patterns = [
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd",
            "yyyy年MM月dd日 HH:mm",
            "yyyy年MM月dd日",
            "MM/dd/yyyy HH:mm",
            "MM-dd-yyyy HH:mm"
        ]
        for p in patterns {
            dateFormatter.dateFormat = p
            if let d = dateFormatter.date(from: trimmed) { return d }
        }
        return nil
    }

    // MARK: - 去重
    private func isDuplicate(_ bill: ImportableBill) -> Bool {
        let cal = Calendar.current
        return bills.contains { b in
            b.merchant == bill.merchant &&
            b.amount == bill.amount &&
            b.isIncome == bill.isIncome &&
            cal.isDate(b.time, inSameDayAs: bill.time)
        }
    }

    // MARK: - 执行导入
    private func performImport() {
        let selected = parsedBills.filter { $0.isValid && selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isLoading = true

        // 先建批次记录（来源/文件名在选文件时已记录）
        let batch = ImportBatch(
            source: currentSource.isEmpty ? "other" : currentSource,
            fileName: currentFileName
        )
        context.insert(batch)

        var imported = 0
        var skipped = 0

        // 批量插入到 SwiftData，依赖 autosave 自动持久化；重复项跳过
        for bill in selected {
            guard !isDuplicate(bill) else { skipped += 1; continue }
            let new = Bill(
                merchant: bill.merchant.isEmpty ? "未命名" : bill.merchant,
                amount: bill.amount,
                currency: "CNY",
                category: bill.category.isEmpty ? "其他" : bill.category,
                time: bill.time,
                note: bill.note,
                confirmed: true,
                isIncome: bill.isIncome,
                importBatchId: batch.syncId
            )
            context.insert(new)
            imported += 1
        }
        batch.totalCount = imported
        batch.skippedCount = skipped

        // 延迟一帧关闭加载态并提示
        DispatchQueue.main.async {
            isLoading = false
            if skipped > 0 {
                importResult = "成功导入 \(imported) 条账单，跳过重复 \(skipped) 条"
            } else {
                importResult = "成功导入 \(imported) 条账单"
            }
            showResultAlert = true
        }
    }

    // MARK: - 格式化
    private func formatMoney(_ value: Double) -> String {
        String(format: "¥%.2f", value)
    }

    private func formatDate(_ date: Date) -> String {
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        return dateFormatter.string(from: date)
    }
}

// MARK: - Toggle 风格扩展
private extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .font(AIATheme.Font.title2)
                .foregroundStyle(configuration.isOn ? AIATheme.blue : AIATheme.muted)
        }
        .buttonStyle(.plain)
    }
}
