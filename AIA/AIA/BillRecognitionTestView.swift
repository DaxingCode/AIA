// BillRecognitionTestView.swift
// 开发者调试：批量喂「支付截图/」目录的图，跑本地优先识别并打印结果（纯只读，不改主流程、不入库）。
// 注意：路径硬编码为本机工作区绝对路径，仅在你 Mac 上跑有效；打包发布请移除本文件或改为 Bundle 内资源。
import SwiftUI
import Foundation
import SwiftData

struct BillRecognitionTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var running = false
    @State private var rows: [RecRow] = []

    // 本机工作区绝对路径（支付截图/ 在工程根目录，不在 App bundle 内）。
    private let folder = "/Volumes/MacBook/Workbuddy/AI助理/支付截图"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("批量识别测试")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Text("运行")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(AIATheme.blue.opacity(0.08))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                        .onTapGesture(perform: runAll)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(AIATheme.surface)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { r in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(r.name)
                                    .font(AIATheme.Font.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(r.summary)
                                    .font(AIATheme.Font.micro)
                                    .foregroundStyle(AIATheme.muted)
                                    .lineSpacing(2)
                                Divider()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(AIATheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                            .id(r.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: rows.count) { _, _ in
                    if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("批量识别测试")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runAll() {
        guard !running else { return }
        running = true
        rows = []
        Task {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: folder) else {
                await append(name: "（目录读取失败）", summary: "找不到 \(folder)，确认路径或把图片放进 App bundle。")
                await MainActor.run { running = false }
                return
            }
            let imgs = files.filter { $0.lowercased().hasSuffix(".png") || $0.lowercased().hasSuffix(".jpg") }
                           .sorted()
            for f in imgs {
                let path = (folder as NSString).appendingPathComponent(f)
                await recognize(file: f, path: path)
            }
            await MainActor.run { running = false }
            print("===== 批量识别测试结束，共 \(imgs.count) 张 =====")
        }
    }

    private func recognize(file: String, path: String) async {
        guard let img = UIImage(contentsOfFile: path) else {
            await append(name: file, summary: "⚠️ 图片加载失败")
            return
        }
        do {
            let out = try await RecognizeService.recognizeWithLocalPriority(image: img, in: context)
            let r = out.result
            let types = (r.types ?? []).joined(separator: ",")
            var lines: [String] = []
            lines.append("来源: \(out.source == .local ? "本地" : "云端")  类型: \(types.isEmpty ? "none" : types)")
            let raw = out.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                lines.append("OCR: \(String(raw.prefix(80)))")
            }
            let bills = r.billList
            if bills.isEmpty {
                lines.append("账单: 无")
            } else {
                for (i, b) in bills.enumerated() {
                    let amt = b.amount.map { String(format: "%.2f", $0) } ?? "nil"
                    lines.append("账单[\(i)] \(b.merchant ?? "?") | ¥\(amt) | \(b.time ?? "?") | \(b.category ?? "?")")
                }
            }
            let summary = lines.joined(separator: "\n")
            // 控制台完整打印
            print("===== [\(file)] =====\n\(summary)\nOCR全文:\n\(out.rawText)")
            await append(name: file, summary: summary)
        } catch {
            await append(name: file, summary: "❌ 识别失败: \(error.localizedDescription)")
            print("===== [\(file)] 识别失败: \(error) =====")
        }
    }

    private func append(name: String, summary: String) async {
        await MainActor.run {
            rows.append(RecRow(name: name, summary: summary))
        }
    }

    struct RecRow: Identifiable {
        let id = UUID()
        let name: String
        let summary: String
    }
}
