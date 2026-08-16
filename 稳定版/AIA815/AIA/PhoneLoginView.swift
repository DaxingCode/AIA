// PhoneLoginView.swift
// 其他手机号登录（验证码方式）。复用 PhoneAuthForm，验证成功后走正常登录流程。
import SwiftUI

struct PhoneLoginView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        PhoneAuthForm { phone in
            auth.login(userId: "phone_\(phone)",
                       phone: phone,
                       provider: .phone)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PhoneLoginView()
            .environmentObject(AuthManager.shared)
    }
}
