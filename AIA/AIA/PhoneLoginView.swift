// PhoneLoginView.swift
// 其他手机号登录（验证码方式）。复用 PhoneAuthForm，验证成功后走正常登录流程。
import SwiftUI

struct PhoneLoginView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PhoneAuthForm { phone in
            auth.login(userId: "phone_\(phone)",
                       phone: phone,
                       provider: .phone)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
                    .foregroundStyle(AIATheme.sub)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PhoneLoginView()
            .environmentObject(AuthManager.shared)
    }
}
