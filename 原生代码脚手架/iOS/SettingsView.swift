// SettingsView.swift
// 云同步设置：同步账号、自动同步开关、立即同步、上次同步时间。
import SwiftUI
import SwiftData
import Combine

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @StateObject private var sync = CloudSyncManager.shared
    @State private var userId: String = CloudSyncManager.userId
    @State private var autoSync: Bool = CloudSyncManager.autoSync

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("云同步") {
                    Toggle("自动同步（启动 App 时）", isOn: $autoSync)
                        .onChange(of: autoSync) { _, v in CloudSyncManager.autoSync = v }

                    TextField("同步账号", text: $userId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: userId) { _, v in CloudSyncManager.userId = v }

                    Text("多台设备填**同一个**同步账号，即可共享同一份账单/待办/饮食/健康数据。留空会自动生成一个随机值（仅本机）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await sync.sync(context: modelContext) }
                    } label: {
                        if sync.isSyncing {
                            Label("同步中…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("立即同步", systemImage: "icloud.and.arrow.up")
                        }
                    }
                    .disabled(sync.isSyncing)

                    if let last = sync.lastSyncAt {
                        HStack {
                            Text("上次同步")
                            Spacer()
                            Text(Self.dateFmt.string(from: last))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(sync.status)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("同步账号管理") {
                    Button("重新生成同步账号", role: .destructive) {
                        userId = UUID().uuidString
                        CloudSyncManager.userId = userId
                    }
                    Text("重新生成后，本机将只同步「新账号」下的数据；旧账号数据仍保留在云端，可在其它设备用旧账号访问。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("关于") {
                    LabeledContent("版本", value: "MVP · M5 云同步")
                    Link("CloudBase 文档", destination: URL(string: "https://www.cloudbase.net/")!)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
