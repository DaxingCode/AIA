// AppleAuthHelper.swift
// 原生 Sign in with Apple 封装（iOS 13+）。
// 真机测试前需：
// 1. 有 Apple Developer 账号（免费账号无法在真机启用 Sign in with Apple，需付费会员）。
// 2. 在 Certificates, Identifiers & Profiles → App ID → Sign in with Apple 中开启能力。
// 3. Xcode → Signing & Capabilities → + Capability → Sign in with Apple。
import Foundation
import AuthenticationServices

final class AppleAuthHelper: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    static let shared = AppleAuthHelper()

    private var continuation: CheckedContinuation<Result<AppleLoginInfo, Error>, Never>?

    private override init() {}

    struct AppleLoginInfo {
        let userID: String
        let email: String?
        let fullName: String?
        let identityToken: String?
        let authorizationCode: String?
    }

    /// 发起 Apple 登录。返回用户 ID、邮箱、姓名、identityToken、authorizationCode。
    /// 首次登录会返回 email/fullName；后续仅返回 userID，需服务端自行绑定。
    @MainActor
    func signIn() async -> Result<AppleLoginInfo, Error> {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            resume(.failure(AppleAuthError.invalidCredential))
            return
        }

        let info = AppleLoginInfo(
            userID: credential.user,
            email: credential.email,
            fullName: credential.fullName?.givenName,
            identityToken: credential.identityToken.flatMap { String(data: $0, encoding: .utf8) },
            authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        )
        resume(.success(info))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        // ASAuthorizationError.canceled 表示用户取消，通常不弹强提示
        resume(.failure(error))
    }

    private func resume(_ result: Result<AppleLoginInfo, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let delegate = scene.delegate as? AppDelegate,
              let window = delegate.window else {
            // 兜底：新建一个看不见的窗口（极少触发）
            return UIWindow()
        }
        return window
    }
}

enum AppleAuthError: LocalizedError {
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Apple 登录返回的凭证无效"
        }
    }
}
