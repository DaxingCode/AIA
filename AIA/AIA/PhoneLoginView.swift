// PhoneLoginView.swift
// 其他手机号登录（验证码方式）。当前为本地模拟：输入任意 6 位验证码即可登录。
// 真实上线需：
//   1. 接入短信服务商（阿里云短信、腾讯云短信、Twilio 等）。
//   2. 点击「获取验证码」时调后端发送短信。
//   3. 登录时把手机号 + 验证码发后端校验。
import SwiftUI

struct PhoneLoginView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var phone = ""
    @State private var code = ""
    @State private var isCountingDown = false
    @State private var countdown = 60
    @State private var timer: Timer?
    @State private var isLoading = false
    @State private var agreedToTerms = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    private var isPhoneValid: Bool {
        // 简单校验 11 位手机号
        phone.count == 11 && phone.allSatisfy { $0.isNumber }
    }

    private var isCodeValid: Bool {
        code.count == 6 && code.allSatisfy { $0.isNumber }
    }

    var body: some View {
        ZStack {
            AIATheme.fillSoft.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer().frame(height: 30)

                        Text("手机号登录")
                            .font(AIATheme.Font.title1.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        phoneField

                        codeField

                        loginButton

                        agreementRow

                        Spacer(minLength: 40)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
                    .foregroundStyle(AIATheme.sub)
            }
        }
        .alert("提示", isPresented: $showAlert, presenting: alertMessage) { _ in
            Button("好的") {}
        } message: { msg in
            Text(msg)
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    // MARK: - 手机号输入
    private var phoneField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手机号")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(AIATheme.sub)
            HStack(spacing: 12) {
                Text("+86")
                    .font(AIATheme.Font.body.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                TextField("请输入手机号", text: $phone)
                    .keyboardType(.numberPad)
                    .font(AIATheme.Font.headline)
                    .textContentType(.telephoneNumber)
            }
            .padding(14)
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
    }

    // MARK: - 验证码输入
    private var codeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("验证码")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(AIATheme.sub)
            HStack(spacing: 12) {
                TextField("请输入验证码", text: $code)
                    .keyboardType(.numberPad)
                    .font(AIATheme.Font.headline)
                Button {
                    sendCode()
                } label: {
                    Text(isCountingDown ? "\(countdown)s 后重发" : "获取验证码")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(isCountingDown || !isPhoneValid ? AIATheme.muted : AIATheme.blue)
                        .frame(width: 90, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .disabled(isCountingDown || !isPhoneValid)
            }
            .padding(14)
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
    }

    // MARK: - 登录按钮
    private var loginButton: some View {
        Button {
            performLogin()
        } label: {
            Text("登录")
                .font(AIATheme.Font.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background {
                    if canLogin {
                        LinearGradient.techAccent
                    } else {
                        AIATheme.muted.opacity(0.35)
                    }
                }
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private var canLogin: Bool {
        isPhoneValid && isCodeValid && agreedToTerms
    }

    // MARK: - 协议勾选
    private var agreementRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                agreedToTerms.toggle()
            } label: {
                Image(systemName: agreedToTerms ? "checkmark.circle.fill" : "circle")
                    .font(AIATheme.Font.title3.weight(.medium))
                    .foregroundStyle(agreedToTerms ? AIATheme.blue : AIATheme.muted)
            }
            .buttonStyle(.plain)

            Text("我已阅读并同意《用户协议》和《隐私政策》")
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.muted)
                .onTapGesture {
                    showAlertMessage("请在项目中配置用户协议和隐私政策 URL")
                }
        }
    }

    // MARK: - actions
    private func sendCode() {
        guard isPhoneValid else { return }
        // TODO: 真实环境调用后端发送短信
        startCountdown()
        showAlertMessage("验证码已发送（模拟：请输入 123456）")
    }

    private func startCountdown() {
        isCountingDown = true
        countdown = 60
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            countdown -= 1
            if countdown <= 0 {
                isCountingDown = false
                timer?.invalidate()
            }
        }
    }

    private func performLogin() {
        guard isPhoneValid && isCodeValid else {
            showAlertMessage("请输入正确的手机号和 6 位验证码")
            return
        }
        guard agreedToTerms else {
            showAlertMessage("请先勾选用户协议")
            return
        }
        isLoading = true
        // TODO: 真实环境：调后端校验手机号+验证码，成功后返回 userId/token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isLoading = false
            auth.login(userId: "phone_\(phone)",
                       phone: phone,
                       provider: .phone)
        }
    }

    private func showAlertMessage(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    NavigationStack {
        PhoneLoginView()
            .environmentObject(AuthManager.shared)
    }
}
