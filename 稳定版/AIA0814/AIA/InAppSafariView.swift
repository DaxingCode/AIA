// InAppSafariView.swift
// App 内打开网页的封装：用 SFSafariViewController 以 sheet 模态呈现，
// 带系统顶部地址栏 + 左上角「完成」关闭按钮，用户不离开 App 即可查看协议。
import SwiftUI
import SafariServices

/// 包裹 SFSafariViewController 的 UIViewControllerRepresentable
struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done   // 左上角「完成」关闭
        vc.preferredControlTintColor = UIColor(AIATheme.blue)
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// sheet(item:) 需要的 Identifiable 包装
struct BrowserTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// 便捷修饰：给任意 View 挂一个可选的 App 内网页 sheet
extension View {
    func inAppBrowser(target: Binding<BrowserTarget?>) -> some View {
        self.sheet(item: target) { t in
            InAppSafariView(url: t.url)
                .ignoresSafeArea()   // SFSafariViewController 自行管理安全区
        }
    }
}

/// 直接用 UIKit present SFSafariViewController，绕开 SwiftUI 首页 body 高频重算 +
/// 多模态叠加导致 sheet(item:) 被吞的问题。设置页等静态页仍可走 .inAppBrowser。
func presentInAppBrowser(_ url: URL) {
    let safari = SFSafariViewController(url: url)
    safari.dismissButtonStyle = .done
    safari.preferredControlTintColor = UIColor(AIATheme.blue)
    guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
          let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
    else { return }
    // 找到最上层可 present 的 VC（跳过已 present 的层级）
    var top = root
    while let presented = top.presentedViewController,
          !(presented is UIAlertController) {
        top = presented
    }
    top.present(safari, animated: true)
}
