// RecognitionRecordDetailView.swift
// 识别记录详情：展示识别时间、命中类型、完整识别文字，以及本地原图。
import SwiftUI
import SwiftData

struct RecognitionRecordDetailView: View {
    let record: RecognitionRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    private var typeLabel: String {
        let labels: [String: String] = [
            "bill": "账单", "todo": "待办", "food": "饮食", "health": "健康", "none": "未识别"
        ]
        return record.typesArray.compactMap { labels[$0] }.joined(separator: " / ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 头部信息
                VStack(alignment: .leading, spacing: 6) {
                    Text("识别于 \(AppFormat.dateTime.string(from: record.recognizedAt))")
                        .font(AIATheme.Font.callout.weight(.semibold))
                    if !typeLabel.isEmpty {
                        Text("命中类型：\(typeLabel)")
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 本地原图
                if record.imageName != nil {
                    SectionTitle(text: "识别原图")
                    AttachmentSection(imageName: record.imageName)
                }

                // 识别文字
                SectionTitle(text: "识别文字")
                Text(record.rawText)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AIATheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle("识别详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    // 先标记删除意图并 pop，等 onDisappear（pop 动画结束后）再真正删除。
                    // 关键：只保存 persistentModelID，不捕获 record 对象——
                    // 若先 context.delete 再 dismiss，详情页 pop 动画期间 SwiftUI 仍会读
                    // record.xxx 已 fault 的属性，触发闪退（与待办/账单详情页同因）。
                    pendingDeleteID = record.persistentModelID
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .onDisappear {
            if let id = pendingDeleteID {
                pendingDeleteID = nil
                // 延迟到父列表彻底稳定后再删除，避免 @Query 重 fetch 与 pop 动画竞争。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let rec = context.model(for: id) as? RecognitionRecord else { return }
                    LocalImageStore.delete(rec.imageName)
                    // 软删除（标记 syncDeleted=true），由 CloudSyncManager 在 push 成功后清理。
                    rec.syncDeleted = true
                    rec.syncUpdatedAt = Date()
                }
            }
        }
    }
}
