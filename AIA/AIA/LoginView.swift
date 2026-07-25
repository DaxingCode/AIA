// LoginView.swift
// 登录首页：复刻截图布局，支持一键登录/Apple/微信/其他手机号。
import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var onePassPhone: String = "189****9919"
    @State private var onePassCarrier: String = "中国电信"
    @State private var isLoadingOnePass = false
    @State private var agreedToTerms = false
    @State private var showPhoneLogin = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer().frame(height: 80)

                    // 顶部 Logo + 标语
                    logoSection

                    Spacer().frame(height: 90)

                    // 中间手机号 + 一键登录
                    onePassSection

                    Spacer()

                    // 协议 + 第三方登录
                    bottomSection
                }
                .padding(.horizontal, 32)
            }
            .navigationDestination(isPresented: $showPhoneLogin) {
                PhoneLoginView()
            }
        }
        .alert("提示", isPresented: $showAlert, presenting: alertMessage) { _ in
            Button("好的") {}
        } message: { msg in
            Text(msg)
        }
        .onAppear {
            OnePassAuthHelper.shared.setup()
        }
    }

    // MARK: - 顶部 Logo
    private var logoSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                // 应用图标：可换成 app logo；先用 sparkles 示意
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient.techAccent)
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(AIATheme.Font.title1.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text("阿宝AI管家")
                    .font(AIATheme.Font.display.weight(.black))
                    .foregroundStyle(AIATheme.blue)
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

    // MARK: - 一键登录区
    private var onePassSection: some View {
        VStack(spacing: 24) {
            // 手机号 + 运营商提示
            VStack(spacing: 6) {
                Text(onePassPhone)
                    .font(AIATheme.Font.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(onePassCarrier)提供认证服务")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }

            VStack(spacing: 14) {
                // 一键登录按钮
                Button {
                    performOnePassLogin()
                } label: {
                    HStack {
                        if isLoadingOnePass {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.9)
                        }
                        Text("一键登录")
                            .font(AIATheme.Font.headline.weight(.semibold))
                    }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background {
                    if agreedToTerms {
                        LinearGradient.techAccent
                    } else {
                        AIATheme.muted.opacity(0.35)
                    }
                }
                .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingOnePass)
                .animation(.easeInOut(duration: 0.2), value: agreedToTerms)

                // 其他手机号登录
                Button {
                    showPhoneLogin = true
                } label: {
                    Text("其他手机号登录")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 底部：协议 + 第三方登录
    private var bottomSection: some View {
        VStack(spacing: 28) {
            // 用户协议
            HStack(alignment: .top, spacing: 8) {
                Button {
                    agreedToTerms.toggle()
                } label: {
                    Image(systemName: agreedToTerms ? "checkmark.circle.fill" : "circle")
                        .font(AIATheme.Font.title3.weight(.medium))
                        .foregroundStyle(agreedToTerms ? AIATheme.blue : AIATheme.muted)
                }
                .buttonStyle(.plain)

                agreementText
            }

            // Apple + 微信
            HStack(spacing: 28) {
                socialButton(icon: "apple.logo", bg: .primary, fg: AIATheme.fillSoft) {
                    performAppleLogin()
                }
                socialButton(icon: "bubble.left.fill", bg: Color(red: 0.12, green: 0.74, blue: 0.12), fg: .white) {
                    performWeChatLogin()
                }
            }
        }
        .padding(.bottom, 50)
    }

    private var agreementText: some View {
        let normal = Font.system(size: 12, weight: .regular)
        let highlighted = Font.system(size: 12, weight: .semibold)

        return (
            Text("我已阅读并同意 ")
                .font(normal)
                .foregroundStyle(AIATheme.muted)
            +
            Text("《天翼账号认证服务条款》")
                .font(highlighted)
                .foregroundStyle(AIATheme.blue)
            +
            Text(" 和 ")
                .font(normal)
                .foregroundStyle(AIATheme.muted)
            +
            Text("《用户协议》")
                .font(highlighted)
                .foregroundStyle(AIATheme.blue)
            +
            Text("、")
                .font(normal)
                .foregroundStyle(AIATheme.muted)
            +
            Text("《隐私政策》")
                .font(highlighted)
                .foregroundStyle(AIATheme.blue)
        )
        .onTapGesture {
            // 点击条款可跳转 Safari；这里只做提示
            showAlertMessage("请在项目中配置服务条款/用户协议/隐私政策 URL")
        }
    }

    private func socialButton(icon: String, bg: Color, fg: Color, action: @escaping () -> Void) -> some View {
        Button {
            guard agreedToTerms else {
                showAlertMessage("请先勾选用户协议")
                return
            }
            action()
        } label: {
            Image(systemName: icon)
                .font(AIATheme.Font.largeTitle.weight(.medium))
                .foregroundStyle(fg)
                .frame(width: 54, height: 54)
                .background(bg)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - actions
    private func performOnePassLogin() {
        guard agreedToTerms else {
                showAlertMessage("请先勾选用户协议")
            return
        }
        isLoadingOnePass = true
        Task {
            let result = await OnePassAuthHelper.shared.requestToken()
            await MainActor.run {
                isLoadingOnePass = false
                switch result {
                case .success(let info):
                    auth.login(userId: "phone_\(info.phone)",
                               phone: info.phone,
                               provider: .onepass)
                case .failure(let err):
                    showAlertMessage(err.localizedDescription)
                }
            }
        }
    }

    private func performAppleLogin() {
        Task {
            let result = await AppleAuthHelper.shared.signIn()
            await MainActor.run {
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

    private func performWeChatLogin() {
        Task {
            let result = await WeChatAuthHelper.shared.requestLogin()
            await MainActor.run {
                switch result {
                case .success(let info):
                    // 真实环境：把 code 发给后端，后端换取 unionid/openid 后再登录。
                    // 当前用 Keychain 内稳定的匿名 id（跨重装一致），避免一次性 code 当 userId
                    // 导致每次登录都开一个新云端空间、旧数据孤立。
                    let wxId = AuthManager.stableWeChatId
                    auth.login(userId: wxId,
                               name: "微信用户",
                               provider: .wechat)
                case .failure(let err):
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
