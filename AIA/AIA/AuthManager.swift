// AuthManager.swift
// 登录状态管理：手机号一键登录 / Apple 登录 / 微信登录 统一收口。
// 当前实现为「骨架 + 本地模拟」：Apple 登录走原生 AuthenticationServices；
// 手机号一键登录和微信登录因需要第三方 SDK，先用本地预置/回调占位，真实接入时替换对应 Helper 即可。
import Foundation
import SwiftUI
import Combine

final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    // MARK: - persisted
    @AppStorage("aia.isLoggedIn") var isLoggedIn: Bool = false
    @AppStorage("aia.userId") var userId: String = ""
    @AppStorage("aia.userPhone") var userPhone: String = ""
    @AppStorage("aia.userName") var userName: String = ""
    @AppStorage("aia.loginProvider") var loginProvider: String = "" // apple / phone / wechat / onepass

    private init() {}

    /// 登录成功统一入口
    func login(userId: String,
               phone: String? = nil,
               name: String? = nil,
               provider: LoginProvider) {
        self.userId = userId
        if let phone { self.userPhone = phone }
        if let name, !name.isEmpty { self.userName = name }
        self.loginProvider = provider.rawValue
        self.isLoggedIn = true
        // 持久化身份到 Keychain：删除 App / 重装后仍保留，可在启动时静默恢复登录态。
        KeychainHelper.set(userId, for: KeychainHelper.kUserId)
        KeychainHelper.set(provider.rawValue, for: KeychainHelper.kProvider)
        if let phone { KeychainHelper.set(phone, for: KeychainHelper.kPhone) }
        if let name, !name.isEmpty { KeychainHelper.set(name, for: KeychainHelper.kName) }
        AppDelegate.switchToMainInterface()
    }

    func logout() {
        // Apple 登录无 revoke API；微信可调用 sendAuthReq 的 revoke？这里只做本地状态重置。
        userId = ""
        userPhone = ""
        userName = ""
        loginProvider = ""
        isLoggedIn = false
        // 清空 Keychain 身份，确保下次重装后不会残留旧会话。
        KeychainHelper.clearAll()
        AppDelegate.switchToLoginInterface()
    }

    // MARK: - Keychain 身份恢复（重装后）
    /// 启动时调用：若 Keychain 中存在有效身份，则恢复到内存（UserDefaults 已被重装清空）。
    /// 返回是否成功恢复（用于 AppDelegate 决定首屏：恢复成功 → 直接进主页并拉云端）。
    @discardableResult
    static func restoreFromKeychain() -> Bool {
        guard let savedId = KeychainHelper.get(KeychainHelper.kUserId),
              !savedId.isEmpty,
              let savedProvider = KeychainHelper.get(KeychainHelper.kProvider),
              !savedProvider.isEmpty else {
            return false
        }
        let shared = AuthManager.shared
        shared.userId = savedId
        shared.loginProvider = savedProvider
        shared.userPhone = KeychainHelper.get(KeychainHelper.kPhone) ?? ""
        shared.userName = KeychainHelper.get(KeychainHelper.kName) ?? ""
        shared.isLoggedIn = true
        return true
    }

    /// 微信登录的稳定匿名 id：首次微信登录时生成并写入 Keychain，之后复用。
    /// 避免把一次性 OAuth code 当作 userId 导致每次登录都开一个新云端空间、旧数据孤立。
    /// 真实环境应改为后端返回的 unionid（天然跨设备稳定）。
    static var stableWeChatId: String {
        if let existing = KeychainHelper.get(KeychainHelper.kWxStable), !existing.isEmpty {
            return existing
        }
        let newId = "wx_\(UUID().uuidString)"
        KeychainHelper.set(newId, for: KeychainHelper.kWxStable)
        return newId
    }

    // MARK: - helpers
    var displayPhone: String {
        guard !userPhone.isEmpty else { return "" }
        // 18912349919 -> 189****9919
        let p = userPhone
        if p.count >= 8 {
            let start = p.prefix(3)
            let end = p.suffix(4)
            return "\(start)****\(end)"
        }
        return p
    }

    var providerTitle: String {
        LoginProvider(rawValue: loginProvider)?.title ?? ""
    }
}

enum LoginProvider: String, CaseIterable, Identifiable {
    case onepass = "onepass"   // 运营商一键登录
    case phone   = "phone"     // 验证码手机号登录
    case apple   = "apple"
    case wechat  = "wechat"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onepass: return "本机号码一键登录"
        case .phone:   return "手机号登录"
        case .apple:   return "Apple 登录"
        case .wechat:  return "微信登录"
        }
    }
}
