// MyAccountView.swift
// 「我的账号」详情页：聚合昵称编辑、账号信息（登录方式 + 手机号）与退出登录。
// 由 SettingsView 的「我的账号」入口 NavigationLink push 进入，
// 因此本页不能再自带 NavigationStack（避免栈中栈）。
import SwiftUI

struct MyAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: AuthManager

    @AppStorage("userNickname") private var userNickname = "阿宝的朋友"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                profileHeader
                nicknameEditCard
                accountInfoCard
                logoutCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .onTapGesture { hideKeyboard() }
        .background(AIATheme.fillSoft)
        .navigationTitle("我的账号")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: userNickname) { _, _ in
            // 记录修改时间并触发增量同步：昵称随后经 aia_records(type:"profile") 上云，
            // 下次登录 pull 会自动回写。未登录时不推送（CloudSyncManager 内部已守卫）。
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "userNicknameUpdatedAt")
            CloudSyncManager.shared.syncAfterLocalChange(context: modelContext)
        }
    }

    // MARK: - 顶部头像 + 昵称
    private var profileHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient.techAccent.opacity(0.15))
                    .frame(width: 72, height: 72)
                Text(String(userNickname.prefix(1)))
                    .font(AIATheme.Font.display.weight(.semibold))
                    .foregroundStyle(AIATheme.blue)
            }
            Text(userNickname.isEmpty ? "阿宝的朋友" : userNickname)
                .font(AIATheme.Font.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - 昵称编辑
    private var nicknameEditCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("昵称")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            TextField("输入昵称", text: $userNickname)
                .font(AIATheme.Font.body.weight(.medium))
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(AIATheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            Text("昵称会显示在首页招呼与识别记录等位置，修改后会同步到云端，换设备登录沿用。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 账号信息
    private var accountInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("账号信息")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AIATheme.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: authProviderIcon)
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.providerTitle)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                    if !auth.displayPhone.isEmpty {
                        Text(auth.displayPhone)
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }

            Divider().background(AIATheme.hairline)

            HStack {
                Text("登录方式")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.sub)
                Spacer()
                Text(auth.providerTitle)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
            }
            if !auth.displayPhone.isEmpty {
                HStack {
                    Text("绑定手机号")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(AIATheme.sub)
                    Spacer()
                    Text(auth.displayPhone)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 退出登录
    private var logoutCard: some View {
        VStack(spacing: 0) {
            Button {
                auth.logout()
            } label: {
                Text("退出登录")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.warn)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(AIATheme.warn.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
            Text("退出后下次打开 App 将回到登录页，本地记录不受影响。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
                .padding(.top, 10)
        }
        .padding(14)
        .card()
    }

    private var authProviderIcon: String {
        switch LoginProvider(rawValue: auth.loginProvider) {
        case .apple:  return "apple.logo"
        case .wechat: return "bubble.left.fill"
        case .phone, .onepass, .none: return "phone.fill"
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
