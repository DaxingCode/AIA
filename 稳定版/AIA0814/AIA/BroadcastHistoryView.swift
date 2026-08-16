// BroadcastHistoryView.swift
// 推送记录：拉云端 aia_broadcast_jobs（按 createdAt 倒序），展示历史群发任务的
// 标题、时间、范围（环境 / 指定账号数）、总数 / 成功 / 失败 / 状态。
// 由 DeveloperCenterView 的「推送记录」入口 présent（开发者口令已写入请求）。
import SwiftUI
import Foundation
import Combine

struct BroadcastJobItem: Identifiable {
    let id: String
    let title: String
    let body: String
    let route: String
    let userIds: [String]
    let envs: [String]
    let status: String        // pending | sending | done
    let sent: Int
    let failed: Int
    let total: Int
    let cursor: Int
    let createdAt: Double
    let finishedAt: Double
}

extension BroadcastJobItem {
    var statusText: String {
        switch status {
        case "pending": return "排队中"
        case "sending": return "发送中"
        case "done": return "已完成"
        default: return status
        }
    }
    var statusColor: Color {
        switch status {
        case "pending": return AIATheme.muted
        case "sending": return AIATheme.warning
        case "done": return AIATheme.green
        default: return AIATheme.muted
        }
    }
    var createdDateText: String {
        guard createdAt > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: createdAt / 1000)
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: d)
    }
    var finishedDateText: String {
        guard finishedAt > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: finishedAt / 1000)
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: d)
    }
    var envText: String {
        guard !envs.isEmpty else { return "全部环境" }
        let map = envs.map { $0 == "production" ? "生产" : ($0 == "sandbox" ? "沙盒" : $0) }
        return map.joined(separator: "/")
    }
    var scopeText: String {
        userIds.isEmpty ? "全部账号" : "\(userIds.count) 个指定账号"
    }
}

@MainActor
final class BroadcastHistoryStore: ObservableObject {
    static let shared = BroadcastHistoryStore()
    @Published private(set) var jobs: [BroadcastJobItem] = []
    @Published private(set) var loading = false
    @Published private(set) var errorText: String?

    func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let resp = try await postAdsJSON([
                "action": "listBroadcastJobs",
                "passcode": DeveloperGate.passcode
            ])
            guard resp["ok"] as? Bool == true else {
                errorText = resp["error"] as? String ?? "云端返回错误"
                return
            }
            let raw = (resp["jobs"] as? [[String: Any]]) ?? []
            jobs = raw.compactMap { dict -> BroadcastJobItem? in
                guard let id = (dict["_id"] as? String) ?? (dict["id"] as? String) else { return nil }
                return BroadcastJobItem(
                    id: id,
                    title: (dict["title"] as? String) ?? "",
                    body: (dict["body"] as? String) ?? "",
                    route: (dict["route"] as? String) ?? "",
                    userIds: (dict["userIds"] as? [String]) ?? [],
                    envs: (dict["envs"] as? [String]) ?? [],
                    status: (dict["status"] as? String) ?? "",
                    sent: (dict["sent"] as? Int) ?? 0,
                    failed: (dict["failed"] as? Int) ?? 0,
                    total: (dict["total"] as? Int) ?? 0,
                    cursor: (dict["cursor"] as? Int) ?? 0,
                    createdAt: (dict["createdAt"] as? Double) ?? 0,
                    finishedAt: (dict["finishedAt"] as? Double) ?? 0
                )
            }
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
    }
}

struct BroadcastHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = BroadcastHistoryStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.loading && store.jobs.isEmpty {
                    ProgressView("加载中…")
                } else if let err = store.errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(AIATheme.over)
                        Text(err).font(AIATheme.Font.callout).foregroundStyle(.primary)
                        Button("重试") { Task { await store.load() } }
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(10).padding(.horizontal, 8)
                            .background(AIATheme.blue)
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                } else if store.jobs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(AIATheme.muted)
                        Text("暂无推送记录").font(AIATheme.Font.callout).foregroundStyle(AIATheme.muted)
                    }
                } else {
                    List {
                        ForEach(store.jobs) { job in
                            jobRow(job)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("推送记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await store.load() } } label: {
                        if store.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .background(AIATheme.fillSoft)
        }
        .task { await store.load() }
    }

    private func jobRow(_ job: BroadcastJobItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title).font(AIATheme.Font.callout.weight(.semibold)).foregroundStyle(.primary)
                    if !job.body.isEmpty {
                        Text(job.body)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Text(job.statusText)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(job.statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(job.statusColor.opacity(0.12))
                    .clipShape(Capsule())
            }
            HStack(spacing: 10) {
                statItem("总数", "\(job.total)")
                statItem("成功", "\(job.sent)", color: AIATheme.green)
                statItem("失败", "\(job.failed)", color: job.failed > 0 ? AIATheme.over : AIATheme.muted)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Label(job.createdDateText, systemImage: "clock")
                if job.status == "done" {
                    Label(job.finishedDateText, systemImage: "checkmark.circle")
                }
                Spacer(minLength: 0)
            }
            .font(AIATheme.Font.micro)
            .foregroundStyle(AIATheme.muted)
            HStack(spacing: 6) {
                Text(job.envText).font(AIATheme.Font.micro).foregroundStyle(AIATheme.blue)
                Text("·").foregroundStyle(AIATheme.muted)
                Text(job.scopeText).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
                if !job.route.isEmpty {
                    Text("·").foregroundStyle(AIATheme.muted)
                    Text("跳转 \(job.route)").font(AIATheme.Font.micro).foregroundStyle(AIATheme.blue)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private func statItem(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(AIATheme.Font.callout.weight(.bold)).foregroundStyle(color)
            Text(label).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
        }
    }
}
