// OnePassAuthHelper.swift
// 手机号「一键登录」（运营商本机号码认证）封装。
//
// 当前是「本地占位实现」：会显示一个预置手机号，点击后模拟成功。
// 真实上线必须接入第三方聚合 SDK（同时支持移动/联通/电信），推荐：
//   - 极光认证 (https://www.jiguang.cn/identify)
//   - 创蓝闪验 / MobTech秒验
//   - 电信天翼账号、移动和通行证、联通统一认证（分别集成较繁琐，不推荐）
//
// 接入后把 requestToken() 中的模拟逻辑替换为 SDK 调用：
//   1. 初始化（appKey / 密钥）
//   2. 预取号（获取运营商类型）
//   3. 拉起授权页 / 获取 token
//   4. 把 token 发自己的后端，后端调运营商接口换取真实手机号。
import Foundation

final class OnePassAuthHelper {
    static let shared = OnePassAuthHelper()
    private init() {}

    struct OnePassResult {
        let phone: String
        let token: String
    }

    /// 模拟：一键登录预取号成功，返回示例手机号。
    /// 真实环境：应调用 SDK 预取号，成功后再展示授权页/一键登录按钮。
    func requestToken() async -> Result<OnePassResult, OnePassError> {
        // 模拟网络/SDK 耗时
        try? await Task.sleep(nanoseconds: 800_000_000)
        // 模拟成功。真实 SDK 返回的是 token，手机号由后端换取。
        return .success(OnePassResult(phone: "18912349919", token: "mock-token-\(UUID().uuidString)"))
    }

    /// 真实接入时，把这里改成 SDK 初始化方法。
    func setup() {
        // TODO: 替换为真实 SDK 初始化，例如 JVerificationInterface.setup(with: config)
        #if DEBUG
        print("[OnePass] setup() called (mock)")
        #endif
    }
}

enum OnePassError: LocalizedError {
    case notSupported      // 当前网络/运营商不支持一键登录
    case tokenFailed       // 取 token 失败
    case userCanceled      // 用户关闭授权页
    case backendError(String)

    var errorDescription: String? {
        switch self {
        case .notSupported:     return "当前网络不支持一键登录，请使用其他登录方式"
        case .tokenFailed:      return "一键登录失败，请重试"
        case .userCanceled:     return "已取消一键登录"
        case .backendError(let msg): return msg
        }
    }
}
