// RecognitionRecordsView.swift
// 识别记录页：列出所有识别历史，文字本地+云端同步，照片仅本地。
import SwiftUI
import SwiftData

struct RecognitionRecordsView: View {
    @Query(sort: \RecognitionRecord.recognizedAt, order: .reverse) private var records: [RecognitionRecord]
    @State private var selectedRecord: RecognitionRecord?
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            ForEach(records) { record in
                Button {
                    selectedRecord = record
                } label: {
                    RecognitionRecordRow(record: record)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteRecords)
        }
        .listStyle(.plain)
        .navigationTitle("识别记录")
        .navigationDestination(item: $selectedRecord) { record in
            RecognitionRecordDetailView(record: record)
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("暂无识别记录", systemImage: "doc.text.magnifyingglass",
                                       description: Text("拍摄或选择照片识别后，记录会出现在这里"))
            }
        }
    }

    private func deleteRecords(offsets: IndexSet) {
        let toDelete = offsets.map { records[$0] }
        for record in toDelete {
            LocalImageStore.delete(record.imageName)
            context.delete(record)
        }
        try? context.save()
    }
}

private struct RecognitionRecordRow: View {
    let record: RecognitionRecord

    private var typeLabel: String {
        let labels: [String: String] = [
            "bill": "账单", "todo": "待办", "food": "饮食", "health": "健康", "none": "未识别"
        ]
        return record.typesArray.compactMap { labels[$0] }.joined(separator: " / ")
    }

    var body: some View {
        HStack(spacing: 12) {
            if let thumb = LocalImageStore.load(record.imageName) {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AIATheme.surfaceSecondary)
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "doc.text").foregroundStyle(AIATheme.muted))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(AppFormat.dateTime.string(from: record.recognizedAt))
                    .font(AIATheme.Font.subhead.weight(.medium))
                if !typeLabel.isEmpty {
                    Text(typeLabel)
                        .font(AIATheme.Font.micro)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(AIATheme.fillSoft)
                        .foregroundStyle(AIATheme.sub)
                        .clipShape(Capsule())
                }
            }

            Spacer()
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
        }
        .padding(.vertical, 4)
    }
}
