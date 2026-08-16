// LoginView.swift
// 登录首页：复刻截图布局，支持一键登录/Apple/微信/其他手机号。
import SwiftUI
import AuthenticationServices
import Combine

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var isLoadingApple = false
    @State private var agreedToTerms = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var browserTarget: BrowserTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer().frame(height: 80)

                    // 顶部 Logo + 标语
                    logoSection

                    // 上方 2 份弹性空间
                    Spacer()
                    Spacer()

                    // 中间手机号 + 一键登录
                    onePassSection

                    // 底部 3 份弹性空间（登录区更靠上）
                    Spacer()
                    Spacer()
                    Spacer()
                }
                .padding(.horizontal, 32)
            }
        }
        .centeredAlert(item: $alertMessage, title: "", dismissTitle: "好的")
        .inAppBrowser(target: $browserTarget)
        // 方案 B：订阅云端配置变化，开发者改了协议链接后登录页的《用户协议》《隐私政策》立即重读新链接。
        .onReceive(GlobalConfigStore.shared.objectWillChange) { _ in }
        // 补充：进登录页也拉一次最新配置，补上「当前在登录页时云端被改」的刷新缺口（与首页同套路）。
        .task {
            await GlobalConfigStore.shared.fetchConfig()
        }
    }

    // MARK: - 顶部 Logo
    private var logoSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                // 应用图标
                Image("AppLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text("好记AI")
                    .font(AIATheme.Font.display.weight(.black))
                    .foregroundStyle(Color(red: 0.204, green: 0.780, blue: 0.349))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("自动记账、记待办、记饮食")
                Text("运动、睡眠、健康管理")
                Text("一个App全搞定")
            }
            .font(AIATheme.Font.title1.weight(.light))
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 主登录区（默认 Apple 一键登录）
    private var onePassSection: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                // Apple 一键登录主按钮
                Button {
                    performAppleLogin()
                } label: {
                    HStack(spacing: 10) {
                        if isLoadingApple {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.9)
                        } else {
                            Image(systemName: "apple.logo")
                                .font(AIATheme.Font.title2.weight(.medium))
                        }
                        Text("使用 Apple 一键登录")
                            .font(AIATheme.Font.headline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.black.opacity(agreedToTerms ? 1 : 0.35))
                    .clipShape(Capsule())
                    .shadow(
                        color: agreedToTerms ? Color.black.opacity(0.15) : .clear,
                        radius: 8, x: 0, y: 4
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoadingApple)
                .animation(.easeInOut(duration: 0.2), value: agreedToTerms)
            }

            // 用户协议（位于 Apple 按钮下方）
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    agreedToTerms.toggle()
                } label: {
                    Image(systemName: agreedToTerms ? "checkmark.circle.fill" : "circle")
                        .font(AIATheme.Font.title3.weight(.medium))
                        .foregroundStyle(agreedToTerms ? AIATheme.blue : AIATheme.muted)
                        // 把图标视觉中心对齐到文本首行基线，避免圆圈偏低
                        .alignmentGuide(.firstTextBaseline) { d in
                            d[.firstTextBaseline] - 1
                        }
                }
                .buttonStyle(.plain)

                agreementText
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var agreementText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("我已阅读并同意 ")
                .font(Font.system(size: 12, weight: .regular))
                .foregroundStyle(AIATheme.muted)
            Button {
                browserTarget = BrowserTarget(url: AppURLs.userAgreement)
            } label: {
                Text("《用户协议》")
                    .font(Font.system(size: 12, weight: .semibold))
                    .foregroundStyle(AIATheme.blue)
            }
            .buttonStyle(.plain)
            Text("、")
                .font(Font.system(size: 12, weight: .regular))
                .foregroundStyle(AIATheme.muted)
            Button {
                browserTarget = BrowserTarget(url: AppURLs.privacyPolicy)
            } label: {
                Text("《隐私政策》")
                    .font(Font.system(size: 12, weight: .semibold))
                    .foregroundStyle(AIATheme.blue)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - actions
    private func performAppleLogin() {
        guard agreedToTerms else {
            showAlertMessage("请先勾选用户协议和隐私政策")
            return
        }
        isLoadingApple = true
        Task {
            let result = await AppleAuthHelper.shared.signIn()
            await MainActor.run {
                isLoadingApple = false
                switch result {
                case .success(let info):
                    // 用 Apple userID 做唯一标识；邮箱/姓名仅首次有，需后端保存
                    let displayName = info.fullName ?? "Apple 用户"
                    auth.login(userId: "apple_\(info.userID)",
                               name: displayName,
                               provider: .apple)
                case .failure(let err):
                    if let authErr = err as? ASAuthorizationError, authErr.code == .canceled {
                        return
                    }
                    showAlertMessage(err.localizedDescription)
                }
            }
        }
    }

    private func showAlertMessage(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

// MARK: - Preview
#Preview {
    LoginView()
        .environmentObject(AuthManager.shared)
}
