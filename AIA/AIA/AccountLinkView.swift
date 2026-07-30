// AccountLinkView.swift
// 「账号关联」页：把其他登录方式（首版支持手机号、Apple 账号）关联到当前账号，
// 合并各自云端数据。关联成功后触发一次全量重同步（syncAfterLogin 已重置同步游标），
// 把合并进主账号分区的数据拉回当前设备。
import SwiftUI

struct AccountLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    @State private var stage: LinkStage = .options
    @State private var isLinking = false
    @State private var resultMessage: String?
    @State private var showResult = false
    @State private var linkSucceeded = false
    @State private var linkedMethods: [String] = []
    @State private var pendingUnlink: String? = nil

    private enum LinkStage { case options, phone }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .options: optionsView
                case .phone: phoneLinkView
                }
            }
            .navigationTitle("账号关联")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if stage == .phone {
                        Button("返回") { stage = .options }
                    } else {
                        Button("关闭") { dismiss() }
                    }
                }
            }
            .alert("提示", isPresented: $showResult, presenting: resultMessage) { _ in
                Button("好的") {
                    if linkSucceeded { dismiss() }
                }
            } message: { msg in
                Text(msg)
            }
            .alert("解除关联", isPresented: Binding(
                get: { pendingUnlink != nil },
                set: { if !$0 { pendingUnlink = nil } }
            )) {
                Button("取消", role: .cancel) { pendingUnlink = nil }
                Button("解除关联", role: .destructive) {
                    if let method = pendingUnlink {
                        pendingUnlink = nil
                        Task { await unlink(method) }
                    }
                }
            } message: {
                if let method = pendingUnlink {
                    Text("确定解除「\(methodInfo(method).title)」与当前账号的关联吗？已合并的数据不会自动退回。")
                }
            }
            .overlay {
                if isLinking {
                    ProgressView("处理中…")
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    // MARK: - 选项页
    private var optionsView: some View {
        ScrollView {
            VStack(spacing: 16) {
                infoCard
                linkRow(title: "关联手机号",
                        subtitle: "用另一个手机号登录，把该手机号下的数据合并到当前账号",
                        icon: "phone.fill") {
                    stage = .phone
                }
                linkRow(title: "关联 Apple 账号",
                        subtitle: "用同一 Apple ID 的另一设备账号，合并其下的数据",
                        icon: "apple.logo") {
                    linkWithApple()
                }
                if !linkedMethods.isEmpty {
                    linkedSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .disabled(isLinking)
        .onAppear { Task { await loadLinkedMethods() } }
    }

    // MARK: - 已关联的方式
    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已关联的方式")
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.muted)
                .padding(.horizontal, 4)
            ForEach(linkedMethods, id: \.self) { method in
                linkedRow(method)
            }
        }
    }

    private func linkedRow(_ method: String) -> some View {
        HStack(spacing: 12) {
            let info = methodInfo(method)
            ZStack {
                Circle()
                    .fill(AIATheme.blue.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: info.icon)
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(AIATheme.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Text("已关联，可合并数据")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                pendingUnlink = method
            } label: {
                Text("解除")
                    .font(AIATheme.Font.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .card()
    }

    private func methodInfo(_ userId: String) -> (title: String, icon: String) {
        if userId.hasPrefix("phone_") {
            return ("手机号 \(maskPhone(String(userId.dropFirst("phone_".count))))", "phone.fill")
        } else if userId.hasPrefix("apple_") {
            return ("Apple 账号", "apple.logo")
        } else if userId.hasPrefix("wx_") {
            return ("微信同步码", "bubble.left.fill")
        }
        return (userId, "link")
    }

    private func maskPhone(_ phone: String) -> String {
        guard phone.count >= 7 else { return phone }
        return "\(phone.prefix(3))****\(phone.suffix(4))"
    }

    @MainActor
    private func loadLinkedMethods() async {
        let list = await CloudSyncManager.listLinkedAccounts(primary: auth.userId)
        self.linkedMethods = list
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(AIATheme.blue)
                Text("当前账号：\(auth.providerTitle)\(auth.displayPhone.isEmpty ? "" : " · \(auth.displayPhone)")")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
            }
            Text("关联后，用任意一种已关联的方式登录，都能看到合并后的全部数据。关联不改变当前登录状态。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    private var phoneLinkView: some View {
        PhoneAuthForm { phone in
            Task { await link(secondary: "phone_\(phone)") }
        }
        .navigationTitle("关联手机号")
    }

    // MARK: - 行
    private func linkRow(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AIATheme.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(14)
            .card()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 关联动作
    private func linkWithApple() {
        isLinking = true
        Task { @MainActor in
            let res = await AppleAuthHelper.shared.signIn()
            switch res {
            case .success(let info):
                await link(secondary: "apple_\(info.userID)")
            case .failure(let err):
                isLinking = false
                resultMessage = "Apple 登录失败：\(err.localizedDescription)"
                showResult = true
            }
        }
    }

    /// 把 secondary 身份关联到当前账号（primary = auth.userId）。成功后全量重同步。
    @MainActor
    private func link(secondary: String) async {
        let primary = auth.userId
        guard secondary != primary else {
            isLinking = false
            resultMessage = "该登录方式即当前账号，无需关联"
            showResult = true
            return
        }
        isLinking = true
        let result = await CloudSyncManager.linkAccounts(primary: primary, secondary: secondary)
        isLinking = false
        if let returned = result {
            // 云函数保证返回主账号；若与当前不同（异常），统一切到主账号分区
            if returned != primary {
                auth.userId = returned
                KeychainHelper.set(returned, for: KeychainHelper.kUserId)
            }
            // 关联成功后全量重同步，把合并数据拉回当前设备（syncAfterLogin 已重置游标）
            if let ctx = AppDelegate.sharedMainContext {
                CloudSyncManager.shared.syncAfterLogin(context: ctx)
            }
            linkSucceeded = true
            resultMessage = "关联成功，该账号下的数据已合并到当前账号"
        } else {
            resultMessage = "关联失败，请稍后重试"
        }
        showResult = true
    }

    /// 解除关联：仅删映射（已并入主账号的数据不会自动回退），成功后更新本地列表。
    @MainActor
    private func unlink(_ secondary: String) async {
        isLinking = true
        let ok = await CloudSyncManager.unlinkAccount(secondary: secondary)
        isLinking = false
        if ok {
            linkedMethods.removeAll { $0 == secondary }
            linkSucceeded = false
            resultMessage = "已解除关联「\(methodInfo(secondary).title)」"
        } else {
            resultMessage = "解除关联失败，请稍后重试"
        }
        showResult = true
    }
}

#Preview {
    AccountLinkView()
        .environmentObject(AuthManager.shared)
}
