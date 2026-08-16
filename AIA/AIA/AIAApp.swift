// AIAApp.swift
// App 入口。创建 SwiftData 容器，并由 SwiftUI WindowGroup 直接托管主界面（保证全屏）。
//
// 启动性能关键修复（2026-08-05）：
//  - 旧实现：`init()` 同步调用 `ICloudBackupManager.restore()`（最多阻塞 20+ 秒），主线程冻住。
//  - 新实现：启动先异步判断是否需要恢复，需要则后台 restore 完再建容器并注入 `sharedContainer`，
//    期间 RootView 显示 loading 占位，容器就绪后发 `containerReady` 通知刷新界面，主线程全程不阻塞。
//
// 全屏黑边根治（2026-08-13，方案 A）：
//  - 旧实现：AppDelegate 同时当 UISceneDelegate，手动 `UIWindow(windowScene:)` 建窗口，
//    与 SwiftUI `WindowGroup { EmptyView() }` 在 scene 配置上打架，导致模拟器某些机型非全屏。
//  - 新实现：SwiftUI `WindowGroup` 直接渲染真实界面（单一全屏 window），AppDelegate 仅保留
//    UIApplicationDelegate 职责（推送/通知/快捷项冷启动捕获），scene 级回调改用
//    `@Environment(\.scenePhase)` 与 `.onOpenURL` 接管。
import SwiftUI
import SwiftData
@_exported import AIAKit

@main
struct AIAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// 容器。为「启动期可能需先 iCloud 恢复」改造为可选：
    /// 不需要恢复 → 后台建好再注入 sharedContainer 并发 containerReady；期间 RootView 显示占位。
    let container: ModelContainer?

    init() {
        // iCloud 自动备份默认关闭：默认值与一次性迁移统一在 AppDelegate 注册/处理，
        // 此处不再 register(true)，避免与 AppDelegate 的 false 默认值冲突。

        // 是否需要启动期 iCloud 恢复：本地全新空库 + iCloud 有可用备份（重装/换机场景）。
        if ICloudBackupManager.shouldAutoRestore() {
            container = nil
            Task.detached(priority: .userInitiated) {
                let r = ICloudBackupManager.restore()
                #if DEBUG
                print("[AIAApp] iCloud 自动恢复完成 → \(r.summary)")
                #endif
                let c = AppPersistence.makeContainer()
                await MainActor.run {
                    AppDelegate.sharedContainer = c
                    AppDelegate.sharedMainContext = ModelContext(c)
                    NotificationCenter.default.post(name: .containerReady, object: nil)
                }
            }
        } else {
            container = nil
            Task.detached(priority: .userInitiated) {
                let c = AppPersistence.makeContainer()
                #if DEBUG
                print("[AIAApp] container initialized (background), store URL: \(AppPersistence.storeURL)")
                #endif
                await MainActor.run {
                    AppDelegate.sharedContainer = c
                    AppDelegate.sharedMainContext = ModelContext(c)
                    NotificationCenter.default.post(name: .containerReady, object: nil)
                }
            }
        }

        // 付费墙：启动即记录试用起点（跨重装保留）并拉取服务端权益快照（plan / 剩余额度）。
        Task { await EntitlementManager.shared.refresh() }
        // 订阅（¥88/年 + ¥8.8/月）：加载商品、校验当前权益、监听交易更新（回写 aia.isPaid）。
        Task { @MainActor in SubscriptionManager.shared.start() }
    }

    @AppStorage("aia.appearance") private var appearanceRaw = "system"

    var body: some Scene {
        // SwiftUI 直接托管界面：单一全屏 window，根除手动 UIWindow 非全屏黑边。
        // 外观模式提到 WindowGroup 最外层：@AppStorage 响应式，任一页面改写后整窗立即重渲染，
        // 根治「设置页切换浅/深/跟随系统无反应」（旧写法挂在 static 计算属性上 SwiftUI 不重算）。
        // 外观模式提到根视图最外层：@AppStorage 响应式，任一页面改写后整窗立即重渲染，
        // 根治「设置页切换浅/深/跟随系统无反应」（旧写法挂在 static 计算属性上 SwiftUI 不重算）。
        // 注意：.preferredColorScheme 是 View 修饰符，必须挂在 RootView() 上而非 WindowGroup 上。
        WindowGroup {
            SplashWrapperView()
                .preferredColorScheme(AppearanceMode(raw: appearanceRaw).colorScheme)
                .onOpenURL { url in
                    AppDelegate.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    AppDelegate.handleScenePhase(newPhase)
                }
        }
    }
}

/// 品牌启动页（仿微信/支付宝冷启动体验）。
/// 纯白底 + 居中 App 图标 + 下方「好记 AI」标题 + 底部灰色 Slogan，展示固定时长后淡出。
struct SplashView: View {
    var body: some View {
        ZStack {
            // >>> CHANGE-[2026-08-16 22:40:00]-[启动页深色模式] 开始
            // 原因: 原写死 Color.white 导致深色模式下启动页仍为刺眼白底，与随后深色主界面切换产生闪烁。
            // 回退: 改回 Color.white.ignoresSafeArea() 即可。
            Color(UIColor.systemBackground).ignoresSafeArea()
            // <<< CHANGE-[2026-08-16 22:40:00]-[启动页深色模式] 结束

            VStack(spacing: 10) {
                Spacer()

                // 居中 App 图标（复用 Assets 里已存在的 AppLogo）。
                Image("AppLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    // >>> CHANGE-[2026-08-16 22:40:00]-[启动页深色模式] 开始
                    // 原因: 深色底上 black.opacity(0.08) 阴影几乎不可见，改用 primary 自适应阴影增强浮起感。
                    // 回退: 改回 .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                    .shadow(color: Color.primary.opacity(0.12), radius: 12, x: 0, y: 4)
                    // <<< CHANGE-[2026-08-16 22:40:00]-[启动页深色模式] 结束

                // 标题：好记AI
                Text("好记AI")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                // 底部 Slogan（整体上移）
                // >>> CHANGE-[2026-08-16 23:10:00]-[启动页Slogan] 开始
                // 原因: 用户要求底部 Slogan 改为「自动记账记待办，管理饮食和健康」。
                // 回退: 改回 Text("自动记账待办，管理饮食和健康")
                Text("自动记账记待办，管理饮食和健康")
                // <<< CHANGE-[2026-08-16 23:10:00]-[启动页Slogan] 结束
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 68)
            }
        }
    }
}

/// 启动页包装器：先展示 SplashView，倒计时结束后淡出并切换到底层 RootView（首页/登录页）。
struct SplashWrapperView: View {
    /// 启动页是否已消失（淡出完成后才真正卸载 SplashView，露出下面界面）。
    @State private var splashGone = false
    /// 控制淡出动画的透明度。
    @State private var opacity: Double = 1

    var body: some View {
        ZStack {
            // 底层永远是真正的界面（RootView），即使启动页盖在上面也在后台准备就绪。
            RootView()

            // 启动页覆盖层：opacity=0 后从层级移除。
            if !splashGone {
                SplashView()
                    .opacity(opacity)
                    .ignoresSafeArea()
                    .onAppear {
                        // 1.5 秒后触发淡出（类似微信节奏）。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                opacity = 0
                            }
                            // 动画结束后彻底移除覆盖层，避免拦截首页面交互。
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                splashGone = true
                            }
                        }
                    }
            }
        }
    }
}

/// 启动期 iCloud 自动恢复完成前显示的轻量 loading 占位。
/// 避免容器未就绪时白屏/冻结，给用户「正在恢复数据」的明确反馈。
struct StartupLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("正在恢复数据…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }
}

/// 根视图：容器就绪前显示占位，就绪后切换为真实首页/登录页。
/// 容器就绪通过 `containerReady` 通知刷新，登录态切换通过 `authStateChanged` 通知刷新，
/// 均走 SwiftUI 响应式刷新（不再手动换 rootViewController）。
struct RootView: View {
    @State private var container: ModelContainer? = AppDelegate.sharedContainer

    var body: some View {
        Group {
            if let container = container {
                MainOrLoginView()
                    .modelContainer(container)
            } else {
                // 容器未就绪：内存占位容器 + 启动占位视图，待 containerReady 刷新。
                StartupLoadingView()
                    .modelContainer(AppDelegate.makeStubContainer())
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .containerReady)) { _ in
            self.container = AppDelegate.sharedContainer
        }
    }
}

/// 根据登录态返回首页（ContentView）或登录页（LoginView）。
/// 登录态变化（AuthManager 登录/登出）通过 `authStateChanged` 通知驱动刷新。
struct MainOrLoginView: View {
    @State private var isLoggedIn: Bool = {
        // 重装后 UserDefaults 被清空，先尝试从 Keychain 静默恢复登录态，
        // 恢复成功可直接进主页并从云端拉回历史数据（实现「删除 App 重装后数据还在」）。
        let restored = AuthManager.restoreFromKeychain()
        return restored || UserDefaults.standard.bool(forKey: "aia.isLoggedIn")
    }()

    var body: some View {
        Group {
            if isLoggedIn {
                ContentView()
                    .accentColor(AIATheme.blue)
                    .environmentObject(AuthManager.shared)
                    .environment(\.isRestoringData, false)
            } else {
                LoginView()
                    .environmentObject(AuthManager.shared)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .authStateChanged)) { _ in
            isLoggedIn = UserDefaults.standard.bool(forKey: "aia.isLoggedIn")
        }
    }
}
