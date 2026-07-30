// PhoneAuthForm.swift
// 手机号（验证码）认证的可复用表单。
// 仅负责「校验手机号 + 验证码」并回调 onAuthorized(phone)，自身不触发 AuthManager.login，
// 因此既可用于正常登录（PhoneLoginView），也可用于「账号关联」场景中拿到 secondary 身份的 userId。
// 真实上线需：① 接入短信服务商；② 点击「获取验证码」调后端发短信；③ 登录时后端校验手机号+验证码。
import SwiftUI

struct PhoneAuthForm: View {
    /// 校验通过并点击登录后回调，参数为手机号（调用方据此拼出 "phone_<phone>" 等 userId）。
    var onAuthorized: (String) -> Void

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

                        Text("手机号验证")
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
            Text("验证并继续")
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
            onAuthorized(phone)
        }
    }

    private func showAlertMessage(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    PhoneAuthForm { _ in }
}
