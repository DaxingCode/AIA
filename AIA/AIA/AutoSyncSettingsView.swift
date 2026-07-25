// AutoSyncSettingsView.swift
// 自动同步设置二级页：聚合原设置页中红框内的所有云同步相关操作。
import SwiftUI
import SwiftData
import Combine

struct AutoSyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    @StateObject private var sync = CloudSyncManager.shared
    @State private var autoSync: Bool = CloudSyncManager.autoSync

    @State private var showCopied = false
    @State private var toastText = "已复制同步账号"
    @State private var showLogoutConfirm = false
    @State private var showForcePullConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                syncCard
            syncActionCard
            forcePullCard
            syncStatusCard
            accountManageCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(AIATheme.fillSoft)
        .navigationTitle("自动同步设置")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if showCopied {
                copiedToast
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(), value: showCopied)
            }
        }
    }

    // MARK: - 云同步开关/账号卡片
    private var syncCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label("自动同步", systemImage: "arrow.triangle.2.circlepath")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("", isOn: $autoSync)
                    .labelsHidden()
                    .onChange(of: autoSync) { _, v in CloudSyncManager.autoSync = v }
            }
            .padding(.bottom, 12)

            Divider().background(AIATheme.hairline)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("同步账号")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                    Text(syncUserId.isEmpty ? "未设置" : syncUserId)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AIATheme.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = syncUserId
                    showToast("已复制同步账号")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(AIATheme.blue)
                        .frame(width: 32, height: 32)
                        .background(AIATheme.blue.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)

            Group {
                if auth.isLoggedIn {
                    Text("同步账号已绑定当前登录账号。在其它设备用同一登录账号登录，即可自动共享同一份账单/待办/饮食/健康数据。")
                } else {
                    Text("登录后同步账号将自动绑定到登录账号；未登录时使用设备级随机账号，数据仅保存于本机。")
                }
            }
            .font(AIATheme.Font.micro)
            .foregroundStyle(AIATheme.muted)
            .padding(.top, 10)
            .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 立即同步主按钮
    private var syncActionCard: some View {
        Button {
            Task { await sync.sync(context: modelContext) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: sync.isSyncing ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up")
                    .font(AIATheme.Font.title3.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                Text(sync.isSyncing ? "同步中…" : "立即同步")
                    .font(AIATheme.Font.body.weight(.semibold))
                Spacer()
                if sync.isSyncing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(LinearGradient.techAccent)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
        }
        .buttonStyle(.plain)
        .disabled(sync.isSyncing)
    }

    // MARK: - 强制从云端恢复
    private var forcePullCard: some View {
        Button {
            showForcePullConfirm = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(AIATheme.Font.title3.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text("从云端强制恢复")
                        .font(AIATheme.Font.callout.weight(.semibold))
                    Text("重置同步锚点，全量拉取该账号下的所有云端记录")
                        .font(AIATheme.Font.micro)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(AIATheme.sub)
            .padding(14)
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
        }
        .buttonStyle(.plain)
        .disabled(sync.isSyncing)
        .confirmationDialog("从云端强制恢复", isPresented: $showForcePullConfirm, titleVisibility: .visible) {
            Button("确认恢复", role: .none) {
                Task {
                    sync.lastSyncAt = nil
                    UserDefaults.standard.removeObject(forKey: "aia_last_sync")
                    await sync.sync(context: modelContext)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这会忽略本地时间戳，从云端拉取该同步账号下的全部记录。若云端有数据但本地未显示，可尝试此操作。")
        }
    }

    // MARK: - 同步状态卡片
    private var syncStatusCard: some View {
        VStack(spacing: 12) {
            if let last = sync.lastSyncAt {
                HStack {
                    Label("上次同步", systemImage: "clock")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(AppFormat.dateTime.string(from: last))
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.muted)
                }
                Divider().background(AIATheme.hairline)
            }
            HStack {
                Label("状态", systemImage: statusIcon)
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(.primary)
                Spacer()
                Text(sync.status)
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }
            if let stats = sync.lastSyncStats {
                Divider().background(AIATheme.hairline)
                VStack(alignment: .leading, spacing: 7) {
                    Text("同步明细")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(.primary)
                    syncStatRow(label: "本地记录", value: "\(stats.localTotal) 条")
                    syncStatRow(label: "本次上传", value: "\(stats.uploaded) 条", highlight: true)
                    if stats.skipped > 0 {
                        syncStatRow(label: "已跳过（未变更）", value: "\(stats.skipped) 条", dimmed: true)
                    }
                    syncStatRow(label: "云端写入", value: "\(stats.cloudWritten) 条")
                    syncStatRow(label: "拉取更新", value: "\(stats.pulled) 条")
                }
            }
        }
        .padding(14)
        .card()
    }

    private func syncStatRow(label: String, value: String, highlight: Bool = false, dimmed: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(AIATheme.Font.footnote)
                .foregroundStyle(dimmed ? AIATheme.muted : AIATheme.sub)
            Spacer()
            Text(value)
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(highlight ? AIATheme.green : .primary)
        }
    }

    private var statusIcon: String {
        if sync.status.hasPrefix("已同步") { return "checkmark.circle" }
        if sync.status.hasPrefix("同步失败") { return "exclamationmark.circle" }
        if sync.status == "未同步" { return "xmark.circle" }
        return "exclamationmark.circle"
    }

    private var statusColor: Color {
        if sync.status.hasPrefix("已同步") { return AIATheme.green }
        if sync.status.hasPrefix("同步失败") { return AIATheme.warn }
        if sync.status == "未同步" { return AIATheme.muted }
        return AIATheme.sub
    }

    private var syncUserId: String {
        // 优先跟随登录账号；未登录时回退设备级账号
        if auth.isLoggedIn, !auth.userId.isEmpty {
            return auth.userId
        }
        return CloudSyncManager.userId
    }

    // MARK: - 账号绑定说明
    private var accountManageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("账号绑定说明")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("已登录时，云同步账号就是当前登录账号；多台设备登录同一账号即可自动共享数据。退出登录后回退到设备级账号，本地记录不受影响，但不会继续与云端同步。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)

            if auth.isLoggedIn {
                Divider().background(AIATheme.hairline)
                Button {
                    showLogoutConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(AIATheme.Font.subhead)
                        Text("退出登录")
                            .font(AIATheme.Font.subhead.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(AIATheme.muted)
                    }
                    .foregroundStyle(AIATheme.warn)
                }
                .buttonStyle(.plain)
                .confirmationDialog("退出登录", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                    Button("退出", role: .destructive) {
                        auth.logout()
                    }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("退出后将回到登录页，本地记录保留。如需同步到其它账号，请用该账号重新登录。")
                }
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 复制成功提示
    private var copiedToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(toastText)
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
        .clipShape(Capsule())
        .padding(.top, 8)
    }

    private func showToast(_ text: String) {
        toastText = text
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCopied = false }
    }
}
