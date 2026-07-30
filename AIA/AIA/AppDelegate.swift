// AppDelegate.swift
// 处理桌面图标 3D Touch / 长按快捷操作（UIApplicationShortcutItem）。
// iOS 13+ 是 Scene 生命周期，AppDelegate 只负责应用级事件；
// 快捷项的冷/热启动都走 UIWindowSceneDelegate。
import UIKit
import SwiftUI
import SwiftData
import UserNotifications

/// 冷启动快捷项通知名：ContentView 监听此通知作为额外保障（避免 onAppear 时序竞态）。
extension Notification.Name {
    static let quickActionColdLaunch = Notification.Name("quickActionColdLaunch")
    static let screenshotRecognitionReady = Notification.Name("screenshotRecognitionReady")
    /// 用户点击系统通知后，AppDelegate 通过此通知把路由信息广播给 ContentView。
    static let notificationRouteReceived = Notification.Name("notificationRouteReceived")
}

class AppDelegate: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate, UNUserNotificationCenterDelegate {

    /// 全局共享容器：application delegate 与 scene delegate 是 AppDelegate 的两个不同实例，
    /// 靠实例属性注入无法跨实例传递。静态变量让两者都能取到 AIAApp 创建的容器。
    static var sharedContainer: ModelContainer?
    /// 与 SwiftUI 注入界面（ContentView/LoginView）绑定的主上下文同一实例；
    /// 已开启 automaticallyMergesChangesFromParent，使后台同步落盘后首页 @Query 自动刷新。
    static var sharedMainContext: ModelContext?
    /// 冷启动时用户点击通知，ContentView 尚未创建，先把路由存在这里，onAppear 时消费。
    static var pendingNotificationRoute: String?

    /// 由 AIAApp 注入的 SwiftData 容器；实际存到 `sharedContainer`。
    var container: ModelContainer? {
        get { Self.sharedContainer }
        set { Self.sharedContainer = newValue }
    }
    var window: UIWindow?

    /// 应用级：注册快捷项，并接收 iOS 可能从 didFinishLaunching 直接交付的 shortcutItem。
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.shortcutItems = [
            UIApplicationShortcutItem(type: "com.aia.shortcut.voice", localizedTitle: "语音记录", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "mic.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: "com.aia.shortcut.camera", localizedTitle: "拍照记录", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "camera.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: "com.aia.shortcut.chat", localizedTitle: "问阿宝AI", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "bubble.left.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: "com.aia.shortcut.todo", localizedTitle: "查待办", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "checklist"), userInfo: nil),
        ]

        #if DEBUG
        print("[QuickAction] didFinishLaunching, hasShortcut=\(launchOptions?[.shortcutItem] != nil)")
        #endif

        // 通知：设置代理（让 App 在前台时也能弹横幅）并申请授权。
        // 本地通知（UNUserNotificationCenter）不需要付费开发者账号，免费账号真机即可测试。
        UNUserNotificationCenter.current().delegate = self
        ReminderNotificationManager.requestAuthorization()

        // 防御性：iOS 某些版本/场景下会把 shortcutItem 放在 didFinishLaunchingWithOptions 里。
        // 如果 configurationForConnecting 后续也收到，guard pending==nil 会防止二次覆盖。
        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem,
           let action = QuickAction(rawValue: item.type),
           QuickActionRouter.shared.pending == nil {
            #if DEBUG
            print("[QuickAction] cold-launch from didFinishLaunching, action=\(action)")
            #endif
            QuickActionRouter.shared.pending = action
            NotificationCenter.default.post(name: .quickActionColdLaunch, object: nil, userInfo: ["action": action.rawValue])
        }

        // 注意：SwiftUI @main App 下必须 return true，否则场景创建失败 → 白屏。
        return true
    }

    /// Scene 级：返回 SceneDelegate 配置；同时从 options.shortcutItem 捕获冷启动快捷项。
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        #if DEBUG
        print("[QuickAction] configurationForConnecting, hasShortcut=\(options.shortcutItem != nil)")
        #endif
        if let item = options.shortcutItem,
           let action = QuickAction(rawValue: item.type),
           QuickActionRouter.shared.pending == nil {  // 防止连续点多个快捷项互相覆盖
            #if DEBUG
            print("[QuickAction] cold-launch from scene options, action=\(action)")
            #endif
            QuickActionRouter.shared.pending = action
            // 额外发通知，作为 ContentView 消费的第三重保险（onReceive/$pending + onAppear 之外）。
            // userInfo 带上 action，让 ChatView 在「已在对话页」时也能可靠启动语音，而不依赖自身 autostartVoice 标记。
            NotificationCenter.default.post(name: .quickActionColdLaunch, object: nil, userInfo: ["action": action.rawValue])
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = AppDelegate.self
        return config
    }

    /// Scene 级：创建窗口并显示 ContentView；这里注入 SwiftData 容器。
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        #if DEBUG
        print("[Scene] willConnectTo, self instance: \(Unmanaged.passUnretained(self).toOpaque())")
        print("[Scene] sharedContainer isNil: \(Self.sharedContainer == nil)")
        #endif

        // 通过静态变量取容器，避免 application delegate / scene delegate 实例不一致问题。
        let container = Self.sharedContainer

        // 主上下文：与 SwiftUI 注入的 @Query 绑定同一实例。
        // 新版 SwiftData（iOS 26）中 ModelContext 为具体类，上下文间写入自动同步/合并，
        // 无需（也不存在）automaticallyMergesChangesFromParent 开关——后台 ModelContext 落盘后，
        // 首页 @Query 会自动刷新，主线程无需参与写库。
        // 必须在首次使用 .modelContext(Self.sharedMainContext!) 之前完成赋值，否则强制解包崩溃 → 白屏。
        if let container = container {
            Self.sharedMainContext = ModelContext(container)
        }

        // 手动健康数据（步数/睡眠/运动/活动热量）录入后触发防抖增量同步，
        // 以便重装重登后能从小程序同分区拉回并恢复展示。未登录时不触发（syncAfterLocalChange 内部已守卫）。
        ManualHealthStore.shared.syncTrigger = {
            guard let ctx = AppDelegate.sharedMainContext else { return }
            Task { @MainActor in
                CloudSyncManager.shared.syncAfterLocalChange(context: ctx)
            }
        }

        // 首启一次性把内置营养表灌进 FoodMetaStore（source:"builtin"），实现单库单查询路径。
        // 已存在（含 cloud 沉淀）则跳过，不覆盖用户数据；UserDefaults 守卫保证仅执行一次。
        if !UserDefaults.standard.bool(forKey: "foodMetaSeeded"), let container = container {
            let ctx = ModelContext(container)
            for e in NutritionLibrary.shared.builtinEntries {
                FoodMetaStore.seedIfAbsent(name: e.name, kcal: e.kcal, protein: e.protein,
                    carbs: e.carbs, fat: e.fat, fiber: e.fiber, sugar: e.sugar, sodium: e.sodium, in: ctx)
            }
            try? ctx.save()
            UserDefaults.standard.set(true, forKey: "foodMetaSeeded")
        }

        // 登录状态决定首屏：未登录显示 LoginView，已登录显示 ContentView。
        // 重装后 UserDefaults 已被清空，先尝试从 Keychain 静默恢复登录态；
        // 恢复成功则可直接进入主页并从云端拉回历史数据（实现「删除 App 重装后数据还在」）。
        let restored = AuthManager.restoreFromKeychain()
        let isLoggedIn = restored || UserDefaults.standard.bool(forKey: "aia.isLoggedIn")

        let window = UIWindow(windowScene: windowScene)
        if isLoggedIn, let container = container {
            window.rootViewController = UIHostingController(
                rootView: ContentView()
                    .modelContext(Self.sharedMainContext!)
                    .accentColor(AIATheme.blue)
                    .environmentObject(AuthManager.shared)
            )
        } else if let container = container {
            // 未登录：展示登录页；容器同时注入，便于登录成功后无缝切换。
            window.rootViewController = UIHostingController(
                rootView: LoginView()
                    .modelContext(Self.sharedMainContext!)
                    .environmentObject(AuthManager.shared)
            )
        } else {
            // 极端兜底：容器不存在时至少显示错误，避免白屏。
            window.rootViewController = UIHostingController(
                rootView: Text("容器初始化失败，请重启 App")
                    .foregroundColor(.red)
                    .padding()
            )
        }
        self.window = window
        window.makeKeyAndVisible()

        // 重装后从 Keychain 恢复了登录态：立即做一次云端全量拉取，
        // 把历史数据（账单/饮食/待办/健康/聊天等）拉回本地，实现「数据还在」。
        if restored, let container = container {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                CloudSyncManager.shared.syncAfterLogin(context: ModelContext(container))
            }
        }

        // 处理通过 universal link / URL scheme 冷启动传入的 URL（如微信登录回调）。
        if let url = connectionOptions.urlContexts.first?.url {
            _ = WeChatAuthHelper.handleOpenURL(url)
        }
    }

    /// Scene 级：处理 universal link / URL scheme 打开（如微信登录返回）。
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        _ = WeChatAuthHelper.handleOpenURL(url)
    }

    /// App 在前台时收到通知：默认 iOS 不会弹横幅，这里让它照常弹出横幅+声音+角标。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 截图无感识别：App 在前台时收到「识别完成」通知，主动提醒 ContentView 弹确认页
        // （此时不会触发 didBecomeActive，必须由这里桥接）。
        if notification.request.content.title == "识别完成" {
            NotificationCenter.default.post(name: .screenshotRecognitionReady, object: nil)
        }
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// 用户点击系统通知（横幅/锁屏/通知中心）：解析 userInfo 中的 route 并通知首页跳转。
    /// 冷启动时 ContentView 尚未创建，先存到 pendingNotificationRoute，onAppear 再消费。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = response.notification.request.content.userInfo["route"] as? String
        #if DEBUG
        print("[Notification] didReceive, route=\(route ?? "nil")")
        #endif
        if let route = route {
            Self.pendingNotificationRoute = route
            NotificationCenter.default.post(
                name: .notificationRouteReceived,
                object: nil,
                userInfo: ["route": route]
            )
        }
        // 用户已处理通知，立即清除桌面角标
        Self.resetBadgeCount()
        completionHandler()
    }

    // MARK: - Badge 清零
    /// 用户点击通知或进入 App 后，应清除桌面图标角标。
    static func resetBadgeCount() {
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().setBadgeCount(0)
            // 同时清空通知中心里已 delivered 的通知，避免角标残留
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
    }

    /// Scene 级：热启动（App 在后台/前台时长按图标）处理快捷项。
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        #if DEBUG
        print("[QuickAction] windowScene performActionFor type=\(shortcutItem.type)")
        #endif
        // 防止连续点多个快捷项互相覆盖；第一个为准。
        if QuickActionRouter.shared.pending == nil {
            QuickActionRouter.shared.pending = QuickAction(rawValue: shortcutItem.type)
            NotificationCenter.default.post(name: .quickActionColdLaunch, object: nil, userInfo: ["action": shortcutItem.type])
        }
        completionHandler(true)
    }

    // MARK: - 登录/主界面切换（AuthManager 调用）

    /// 最鲁棒地取得当前 keyWindow：遍历 connectedScenes 找 UIWindowScene 的 keyWindow，
    /// 找不到再退化到该 scene 的第一个 window；都没有则退化到 UIApplication.shared.windows（iOS 14 兜底）。
    private static func currentWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let key = ws.windows.first(where: { $0.isKeyWindow }) { return key }
            if let first = ws.windows.first { return first }
        }
        #if DEBUG
        print("[Auth] currentWindow: fallback to UIApplication.shared.windows")
        #endif
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first }
            .first
    }

    static func switchToMainInterface() {
        guard let container = sharedContainer else {
            #if DEBUG
            print("[Auth] switchToMainInterface failed: sharedContainer is nil")
            #endif
            return
        }
        guard let window = currentWindow() else {
            #if DEBUG
            print("[Auth] switchToMainInterface failed: no window")
            #endif
            // 极端兜底：用首个 scene 直接重建 window
            if let ws = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let w = UIWindow(windowScene: ws)
                w.rootViewController = UIHostingController(
                    rootView: ContentView().modelContext(Self.sharedMainContext!).environmentObject(AuthManager.shared)
                )
                w.makeKeyAndVisible()
            }
            return
        }
        window.rootViewController = UIHostingController(
            rootView: ContentView()
                .modelContext(Self.sharedMainContext!)
                .accentColor(AIATheme.blue)
                .environmentObject(AuthManager.shared)
        )

        // 登录成功后：从云端全量拉取数据到本地（满足「登录后自动同步到本地」），
        // 同时把本机已有数据推到云端；仅已登录时触发。
        Task { @MainActor in
            guard let container = sharedContainer else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            CloudSyncManager.shared.syncAfterLogin(context: ModelContext(container))
        }
    }

    static func switchToLoginInterface() {
        guard let window = currentWindow() else {
            #if DEBUG
            print("[Auth] switchToLoginInterface failed: no window")
            #endif
            return
        }
        window.rootViewController = UIHostingController(
            rootView: LoginView()
                .environmentObject(AuthManager.shared)
        )
    }

    // MARK: - 自动同步：前后台触发
    /// 进入前台（含冷启动）：已开启自动同步且已登录时，推本地 + 拉云端，保持多端一致。
    func sceneDidBecomeActive(_ scene: UIScene) {
        #if DEBUG
        print("[Auth] sceneDidBecomeActive → 触发自动同步")
        #endif
        // 每次回到前台都清理角标（用户已打开 App，通知已被消费）
        Self.resetBadgeCount()
        Task { @MainActor in
            guard let container = AppDelegate.sharedContainer else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            CloudSyncManager.shared.autoSyncIfEnabled(context: ModelContext(container))
        }
    }

    /// 进入后台：把本机最新数据推到云端（免费账号无后台推送能力，离开 App 是上传的关键时机）。
    func sceneDidEnterBackground(_ scene: UIScene) {
        #if DEBUG
        print("[Auth] sceneDidEnterBackground → 触发自动同步（上传本地数据）")
        #endif
        Task { @MainActor in
            guard let container = AppDelegate.sharedContainer else { return }
            CloudSyncManager.shared.autoSyncIfEnabled(context: ModelContext(container))
        }
    }
}
