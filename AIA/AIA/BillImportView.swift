// BillImportView.swift
// 账单导入：支持 CSV 文件 / 粘贴文本导入，提供模板、预览、去重。
// 入口：账单管理页（BillListView）顶部「账单导入」。
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 一条待导入的账单
private struct ImportableBill: Identifiable, Hashable {
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
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // TODO: 导航到导入记录页
                } label: {
                    Text("导入记录")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.sub)
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert(importResult ?? "", isPresented: $showResultAlert) {
            Button("知道了") {
                if importResult?.hasPrefix("成功") == true { dismiss() }
            }
        }
    }

    // MARK: - 请选择账单来源
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请选择账单来源")
                .font(AIATheme.Font.headline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                sourceRow(iconName: "alipay", title: "支付宝", iconColor: Color(hex: 0x1677ff), iconBg: Color(hex: 0x1677ff).opacity(0.12), isOtherSource: false)

                Divider().padding(.leading, 48)

                sourceRow(iconName: "wechat", title: "微信", iconColor: Color(hex: 0x07c160), iconBg: Color(hex: 0x07c160).opacity(0.12), isOtherSource: false)

                Divider().padding(.leading, 48)

                sourceRow(iconName: "doc.on.doc", title: "其他来源", iconColor: AIATheme.blue, iconBg: AIATheme.blue.opacity(0.12), isOtherSource: true)
            }
        }
        .padding(14)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }

    private func sourceRow(iconName: String, title: String, iconColor: Color, iconBg: Color, isOtherSource: Bool) -> some View {
        Button {
            showFileImporter = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(iconBg)
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(AIATheme.Font.body.weight(.medium))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isOtherSource {
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.footnote.weight(.medium))
                        .foregroundStyle(AIATheme.iconInactive)
                }
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 说明文案
    private var hintSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("支持导入银行、钱包和财务类 App 的账单。\n如果 AIA 无法识别你的文件，请下载并填写")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.sub)
                    .lineSpacing(2)
                Text("标准模板")
                    .font(AIATheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AIATheme.blue)
                    .underline(color: AIATheme.blue)
            }
        }
        .padding(.horizontal, 2)
        .onTapGesture {
            UIPasteboard.general.string = templateCSV
            importResult = "模板已复制到剪贴板"
            showResultAlert = true
        }
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
                    Text("共 \(parsedBills.count) 条，有效 \(parsedBills.filter(\.isValid).count) 条")
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
        _ = selected.filter { isDuplicate($0) }
        return Button {
            performImport()
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                }
                Image(systemName: "arrow.down.doc")
                Text(selected.isEmpty ? "无可导入账单" : "导入 \(selected.count) 条账单")
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
            var text = ""
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                importResult = "读取文件失败：\(error.localizedDescription)"
                showResultAlert = true
                return
            }
            csvText = text
            parseCSV(text)
        case .failure(let error):
            importResult = "选择文件失败：\(error.localizedDescription)"
            showResultAlert = true
        }
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
            if let d = dateFormatter.date(from: string) { return d }
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

        // 批量插入到 SwiftData，依赖 autosave 自动持久化
        for bill in selected {
            let new = Bill(
                merchant: bill.merchant.isEmpty ? "未命名" : bill.merchant,
                amount: bill.amount,
                currency: "CNY",
                category: bill.category.isEmpty ? "其他" : bill.category,
                time: bill.time,
                note: bill.note,
                confirmed: true,
                isIncome: bill.isIncome
            )
            context.insert(new)
        }

        // 延迟一帧关闭加载态并提示
        DispatchQueue.main.async {
            isLoading = false
            importResult = "成功导入 \(selected.count) 条账单"
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
