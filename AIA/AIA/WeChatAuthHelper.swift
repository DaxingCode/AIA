// WeChatAuthHelper.swift
// 微信登录封装。当前为「本地占位实现」，真机使用前必须集成微信 SDK。
//
// 接入步骤：
// 1. 在微信开放平台 (https://open.weixin.qq.com) 注册移动应用，获取 appID 和 universal link。
// 2. Xcode → 项目 Info → URL Types 添加：identifier=com.wechat, URL Schemes=wx你的appID。
// 3. 在 Info.plist 添加 LSApplicationQueriesSchemes 数组：weixin、weixinULAPI、weixinURLParamsAPI。
// 4. 通过 Swift Package Manager / CocoaPods 集成 WeChatOpenSDK。
// 5. AppDelegate 中实现 onReq / onResp 回调，把 auth code 发后端换取 openid/unionid。
import Foundation

final class WeChatAuthHelper {
    static let shared = WeChatAuthHelper()
    private init() {}

    struct WeChatLoginInfo {
        let code: String
        let state: String
    }

    /// 当前占位：直接模拟一个 code 成功返回。
    /// 真实环境：调用 WXApi.send(SendAuthReq()) 唤起微信，在 AppDelegate onResp 中接收 code。
    func requestLogin() async -> Result<WeChatLoginInfo, WeChatAuthError> {
        // 模拟唤起微信、用户授权后返回
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return .success(WeChatLoginInfo(code: "mock-wx-code-\(UUID().uuidString)", state: "aia"))
    }

    /// 真实接入时：AppDelegate.application(_:open:options:) 中调用此方法来分发回调。
    static func handleOpenURL(_ url: URL) -> Bool {
        // 真实环境：return WXApi.handleOpen(url, delegate: WXApiManager.shared)
        #if DEBUG
        print("[WeChat] handleOpenURL \(url) (mock)")
        #endif
        return true
    }
}

enum WeChatAuthError: LocalizedError {
    case notInstalled
    case canceled
    case denied
    case backendError(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "未安装微信"
        case .canceled:     return "已取消微信登录"
        case .denied:       return "微信授权被拒绝"
        case .backendError(let msg): return msg
        }
    }
}
