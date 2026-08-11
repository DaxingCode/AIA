// AppDelegate.swift
// 处理桌面图标 3D Touch / 长按快捷操作（UIApplicationShortcutItem）。
// iOS 13+ 是 Scene 生命周期，AppDelegate 只负责应用级事件；
// 快捷项的冷/热启动都走 UIWindowSceneDelegate。
import UIKit
import SwiftUI
import SwiftData
import UserNotifications
import WidgetKit
import AIAKit

/// 冷启动快捷项通知名：ContentView 监听此通知作为额外保障（避免 onAppear 时序竞态）。
extension Notification.Name {
    static let quickActionColdLaunch = Notification.Name("quickActionColdLaunch")
    static let screenshotRecognitionReady = Notification.Name("screenshotRecognitionReady")
    /// 用户点击系统通知后，AppDelegate 通过此通知把路由信息广播给 ContentView。
    static let notificationRouteReceived = Notification.Name("notificationRouteReceived")
    /// 启动期 iCloud 自动恢复完成、SwiftData 容器就绪后发出；scene 据此重建主界面。
    static let containerReady = Notification.Name("containerReady")
    /// Siri/快捷指令后台写入独立容器落盘后发出；ContentView 监听后刷新前台 @Query（跨容器不自动合并）。
    static let siriDidSaveData = Notification.Name("siriDidSaveData")
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
    /// 容器就绪通知的观察者（AppDelegate 持有，避免被释放导致收不到重建通知）。
    private var containerReadyObserver: NSObjectProtocol?

    /// 应用级：注册快捷项，并接收 iOS 可能从 didFinishLaunching 直接交付的 shortcutItem。
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.shortcutItems = [
            UIApplicationShortcutItem(type: "com.aia.shortcut.voice", localizedTitle: "语音记录", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "mic.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: "com.aia.shortcut.camera", localizedTitle: "拍照记录", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "camera.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: "com.aia.shortcut.chat", localizedTitle: "问小记", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "bubble.left.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: "com.aia.shortcut.todo", localizedTitle: "查待办", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "checklist"), userInfo: nil),
        ]

        #if DEBUG
        print("[QuickAction] didFinishLaunching, hasShortcut=\(launchOptions?[.shortcutItem] != nil)")
        #endif

        // 通知：设置代理（让 App 在前台时也能弹横幅）并申请授权。
        // 本地通知（UNUserNotificationCenter）不需要付费开发者账号，免费账号真机即可测试。
        UNUserNotificationCenter.current().delegate = self
        ReminderNotificationManager.requestAuthorization()

        // 远程推送（APNs）：注册设备 token（方案 A 群发通知）。
        // 模拟器无 APNs 能力，守卫避免报错；真机/TestFlight 才真正注册。
        #if !targetEnvironment(simulator)
        application.registerForRemoteNotifications()
        #endif

        // 每天使用提醒：注册默认开关/时间 + 带 4 个操作按钮的 category
        UserDefaults.standard.register(defaults: [
            ReminderNotificationManager.dailyEnabledKey: true,
            ReminderNotificationManager.dailyHourKey: 22,
            ReminderNotificationManager.dailyMinuteKey: 0,
        ])
        ReminderNotificationManager.registerDailyCheckinCategory()

        // 截图无感识别通知的 category：注册「保存 / 查看」两个 Action 按钮。
        // 「保存」= 本次强制自动入库（即便设置是「确认后再保存」，也顺手存）；
        // 「查看」= 按现有设置分流（待确认则弹确认页，自动保存则直接进气泡）。
        // 点横幅/锁屏本体 = UNNotificationDefaultActionIdentifier → 也走「查看」语义。
        let saveAction = UNNotificationAction(
            identifier: "SCREENSHOT_SAVE",
            title: "保存",
            options: [.authenticationRequired]   // 需解锁设备才执行，避免误触
        )
        let viewAction = UNNotificationAction(
            identifier: "SCREENSHOT_VIEW",
            title: "查看",
            options: []
        )
        let screenshotCategory = UNNotificationCategory(
            identifier: "SCREENSHOT_RECOGNITION",
            actions: [saveAction, viewAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        // 累加注册：读取已有的 categories 再插入，避免覆盖掉「每日提醒」等其它 category。
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var set = existing
            set.insert(screenshotCategory)
            UNUserNotificationCenter.current().setNotificationCategories(set)
        }

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

        // 使用统计：冷启动计一次（缓冲队列上报，不阻塞启动）
        UsageAnalytics.log("app_launch")

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
    /// 启动性能修复（2026-08-05）：容器可能因「需先 iCloud 自动恢复」尚未就绪（后台线程恢复中），
    /// 此时先显示 loading 占位；容器就绪后由 `.containerReady` 通知触发重建主界面。
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        #if DEBUG
        print("[Scene] willConnectTo, self instance: \(Unmanaged.passUnretained(self).toOpaque())")
        print("[Scene] sharedContainer isNil: \(Self.sharedContainer == nil)")
        #endif

        // 通过静态变量取容器，避免 application delegate / scene delegate 实例不一致问题。
        let container = Self.sharedContainer

        let window = UIWindow(windowScene: windowScene)
        if let container = container {
            Self.buildRootInterface(in: window, container: container)
        } else {
            // 容器未就绪（后台 iCloud 恢复中）：显示 loading 占位，避免白屏/冻结。
            window.rootViewController = UIHostingController(rootView: StartupLoadingView())
            // 容器就绪后重建主界面。观察者由 AppDelegate 持有，重复通知时
            // buildRootInterface 幂等（sharedContainer 是同一容器），无需额外保护。
            containerReadyObserver = NotificationCenter.default.addObserver(
                forName: .containerReady,
                object: nil,
                queue: .main
            ) { _ in
                guard let c = Self.sharedContainer else { return }
                Self.buildRootInterface(in: window, container: c)
            }
        }
        self.window = window
        window.makeKeyAndVisible()

        // 处理通过 universal link / URL scheme 冷启动传入的 URL（如微信登录回调、桌面组件跳转）。
        if let url = connectionOptions.urlContexts.first?.url {
            if url.scheme == "aia", let host = url.host {
                // 桌面组件四宫格冷启动跳转：存待消费路由，ContentView.onAppear 的
                // performOnAppear 会读 pendingNotificationRoute 兜底跳到对应页。
                Self.pendingNotificationRoute = host
            } else {
                _ = WeChatAuthHelper.handleOpenURL(url)
            }
        }
    }

    /// 容器就绪后统一构建主界面（登录页 / 首页）。
    /// 从 `scene(_:willConnectTo:)` 与 `.containerReady` 通知两处复用，保证一致。
    private static func buildRootInterface(in window: UIWindow, container: ModelContainer) {
        Self.sharedContainer = container
        Self.sharedMainContext = ModelContext(container)

        // 手动健康数据（步数/睡眠/运动/活动热量）录入后触发防抖增量同步，
        // 以便重装重登后能从小程序同分区拉回并恢复展示。未登录时不触发（syncAfterLocalChange 内部已守卫）。
        ManualHealthStore.shared.syncTrigger = {
            guard let ctx = AppDelegate.sharedMainContext else { return }
            Task { @MainActor in
                CloudSyncManager.shared.syncAfterLocalChange(context: ctx)
            }
        }

        // 首启把内置营养表灌进 FoodMetaStore（source:"builtin"），实现单库单查询路径。
        // 版本化：SEED_VERSION 升级时（扩充/修正权威表）自动重 seed，覆盖老用户被 LLM 估算污染的旧 cloud 值。
        // 额外做样本键完整性检查：防止 save 失败但版本号已写导致"有版本号无数据"。
        let foodMetaSeedV = UserDefaults.standard.integer(forKey: "foodMetaSeedVersion")
        let seedCtx = ModelContext(container)
        // 样本键完整性检查：用一组关键词条（而非单个），任一缺失即强制重 seed，
        // 防止老用户在 v6 等扩充批次中只漏掉部分新增词（如只补了燕麦粥却漏了皮蛋瘦肉粥）。
        let seedSampleKeys = ["燕麦粥", "皮蛋瘦肉粥", "海鲜粥", "南瓜粥"]
        let sampleMissing = seedSampleKeys.contains { !FoodMetaStore.hasBuiltinKey($0, in: seedCtx) }
        let needsSeed = foodMetaSeedV < NutritionLibrary.SEED_VERSION
            || sampleMissing
        if needsSeed {
            FoodMetaStore.seedBuiltin(NutritionLibrary.shared.builtinEntries, in: seedCtx)
            do {
                try seedCtx.save()
                if !seedSampleKeys.contains(where: { !FoodMetaStore.hasBuiltinKey($0, in: seedCtx) }) {
                    UserDefaults.standard.set(NutritionLibrary.SEED_VERSION, forKey: "foodMetaSeedVersion")
                    print("[FoodMeta] seed 完成，版本 \(NutritionLibrary.SEED_VERSION)")
                } else {
                    print("[FoodMeta] seed save 后样本键仍有缺失: \(seedSampleKeys.filter { !FoodMetaStore.hasBuiltinKey($0, in: seedCtx) })")
                }
            } catch {
                print("[FoodMeta] seed save 失败: \(error)")
            }
        }

        // 登录状态决定首屏：未登录显示 LoginView，已登录显示 ContentView。
        // 重装后 UserDefaults 已被清空，先尝试从 Keychain 静默恢复登录态；
        // 恢复成功则可直接进入主页并从云端拉回历史数据（实现「删除 App 重装后数据还在」）。
        let restored = AuthManager.restoreFromKeychain()
        let isLoggedIn = restored || UserDefaults.standard.bool(forKey: "aia.isLoggedIn")

        let root: UIViewController
        if isLoggedIn {
            root = UIHostingController(
                rootView: ContentView()
                    .modelContext(Self.sharedMainContext!)
                    .accentColor(AIATheme.blue)
                    .environmentObject(AuthManager.shared)
            )
        } else {
            // 未登录：展示登录页；容器同时注入，便于登录成功后无缝切换。
            root = UIHostingController(
                rootView: LoginView()
                    .modelContext(Self.sharedMainContext!)
                    .environmentObject(AuthManager.shared)
            )
        }
        window.rootViewController = root

        // 重装后从 Keychain 恢复了登录态：立即做一次云端全量拉取，
        // 把历史数据（账单/饮食/待办/健康/聊天等）拉回本地，实现「数据还在」。
        if restored {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                CloudSyncManager.shared.syncAfterLogin(context: ModelContext(container))
            }
        }
    }

    /// App 每次回到前台：先拉最新健康数据（异步，几秒后回来），再预写四宫格共享摘要（Widget 跨进程读不到 HealthKit/ManualHealthStore），最后刷新桌面小组件。
    /// 注意：writeShared 此刻写入的可能是 0（HealthKit 还没回来），HealthManager.refreshAll() 完成后的延迟补偿会再补写一次真实值。
    func applicationDidBecomeActive(_ application: UIApplication) {
        HealthManager.shared.refreshAll()
        MainActor.assumeIsolated {
            WidgetSnapshot.writeShared()
        }

        // 桌面组件四宫格跳转：读 widget 写入 App Group 的待处理导航标记，转交已有的
        // 「通知路由」通道（consumeNotificationRoute → jump 0.35s 可靠延迟），冷启动/前台都覆盖。
        // 不再直接 navigate：早期直接跳转会因冷启动时 NavigationStack 未就绪被吞（表现为只闪不跳）。
        if let ud = UserDefaults(suiteName: "group.com.daxing.aia"),
           let host = ud.string(forKey: "aia.widget.pendingNav") {
            ud.removeObject(forKey: "aia.widget.pendingNav")
            ud.synchronize()
            // 冷启动：ContentView.onAppear 会读 pendingNotificationRoute 兜底消费。
            Self.pendingNotificationRoute = host
            // 前台/热启动：发通知让 ContentView 的 .notificationRouteReceived 监听立即跳。
            NotificationCenter.default.post(
                name: .notificationRouteReceived,
                object: nil,
                userInfo: ["route": host]
            )
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Scene 级：处理 universal link / URL scheme 打开（如微信登录返回、桌面组件跳转）。
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        // 桌面小组件四宫格跳转：aia://bill | todo | food | health
        // 不直接 navigate：冷启动时 NavigationStack 尚未就绪会被吞（只闪不跳）。
        // 改走与通知点击一致的可靠通道：存 pendingNotificationRoute + 发 .notificationRouteReceived，
        // 冷启动由 ContentView.onAppear 的 performOnAppear 兜底消费，前台由监听即时跳。
        if url.scheme == "aia", let host = url.host {
            Self.pendingNotificationRoute = host
            NotificationCenter.default.post(
                name: .notificationRouteReceived,
                object: nil,
                userInfo: ["route": host]
            )
            return
        }
        _ = WeChatAuthHelper.handleOpenURL(url)
    }

    /// App 在前台时收到通知：默认 iOS 不会弹横幅，这里让它照常弹出横幅+声音+角标。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 截图无感识别：App 在前台时收到「识别完成」通知，主动提醒 ContentView 弹确认页
        // （此时不会触发 didBecomeActive，必须由这里桥接）。
        // 「识别遇到限制」也走同一条路由：让前台收到付费墙拦截通知时主动刷对话页，
        // 由 checkScreenshotPending 识别到付费墙标记并回插「升级 Pro」引导气泡。
        let title = notification.request.content.title
        if title == "识别完成" || title == "识别遇到限制" {
            NotificationCenter.default.post(name: .screenshotRecognitionReady, object: nil)
        }
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// 用户点击系统通知（横幅/锁屏/通知中心）：解析 userInfo 中的 route 并通知首页跳转。
    /// 冷启动时 ContentView 尚未创建，先存到 pendingNotificationRoute，onAppear 再消费。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionID = response.actionIdentifier
        var routeToJump: String?
        if actionID == "SCREENSHOT_SAVE" {
            // 点通知上的「保存」：本次强制自动入库（绕过「确认后再保存」设置），
            // 主 App 唤醒后由 checkScreenshotPending(forceSave:) 接管直接入库并跳对话页。
            routeToJump = "screenshotRecognition:save"
        } else if actionID == "SCREENSHOT_VIEW" {
            // 点「查看」：按现有设置分流。
            routeToJump = response.notification.request.content.userInfo["route"] as? String
        } else if actionID.hasPrefix("route:"), !actionID.dropFirst("route:".count).isEmpty {
            routeToJump = String(actionID.dropFirst("route:".count))   // 点操作按钮：route:bill/diet/health/todo
        } else if actionID == UNNotificationDefaultActionIdentifier {
            routeToJump = response.notification.request.content.userInfo["route"] as? String
        }
        #if DEBUG
        print("[Notification] didReceive, route=\(routeToJump ?? "nil")")
        #endif
        if let route = routeToJump {
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

    // MARK: - 远程推送（APNs）设备 token 上报
    /// 成功拿到 deviceToken：上报到云函数 aia_devices，供开发者中心 broadcast 群发。
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        print("[APNs] deviceToken 已获取（\(token.count) 位），上报云端")
        #endif
        // 仅已登录时上报（未登录不上云，与云同步守则一致）
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else {
            #if DEBUG
            NSLog("[APNs] 未登录，跳过 deviceToken 上报（aia_devices 不会有此设备）")
            #endif
            return
        }
        let userId = KeychainHelper.get(KeychainHelper.kUserId) ?? ""
        guard !userId.isEmpty else {
            #if DEBUG
            NSLog("[APNs] 已登录但 userId 为空，跳过 deviceToken 上报")
            #endif
            return
        }
        let deviceId = KeychainHelper.deviceId
        // 生产环境（App Store / TestFlight）走 production，开发/调试走 sandbox。
        let apnsEnv: String = {
            #if DEBUG
            return "sandbox"
            #else
            return "production"
            #endif
        }()
        // 本地缓存 hex token 与 apnsEnv，供广播推送时作为 submitterDeviceId/submitterEnv 带上去（完成回执推回自己）。
        UserDefaults.standard.set(token, forKey: "aia.deviceTokenHex")
        UserDefaults.standard.set(apnsEnv, forKey: "aia.apnsEnv")
        Task {
            do {
                let resp = try await postAdsJSON([
                    "action": "registerDevice",
                    "userId": userId,
                    "deviceId": deviceId,
                    "token": token,
                    "apnsEnv": apnsEnv
                ])
                if resp["ok"] as? Bool != true {
                    NSLog("[APNs] registerDevice 云端返回失败: \(resp)")
                } else {
                    #if DEBUG
                    NSLog("[APNs] registerDevice 上报成功（userId=\(userId) deviceId=\(deviceId) env=\(apnsEnv)）→ aia_devices 已写入")
                    #endif
                }
            } catch {
                NSLog("[APNs] registerDevice 上报失败: \(error)")
            }
        }
    }

    /// 注册失败（模拟器/无网络/未授权）：静默降级，不影响本地功能。
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[APNs] 注册失败（可忽略，模拟器/无网络）: \(error.localizedDescription)")
        #endif
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
        guard sharedContainer != nil else {
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
        // 使用统计：距上次前台超过 30 分钟才算一次新会话（衡量真实打开频次）
        UsageAnalytics.logSessionStart()
        Task { @MainActor in
            guard let container = AppDelegate.sharedContainer else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            CloudSyncManager.shared.autoSyncIfEnabled(context: ModelContext(container))
            // 每天使用提醒：开关开启时用最新时间 + 当天数据重排程（幂等覆盖，不会累积多条）
            ReminderNotificationManager.rescheduleFromStoredDefaults()
            // 回前台刷新 HealthKit：App 在前台停留期间不自动更新，切回即拉最新（2026-08-01）
            HealthManager.shared.refreshAll()
        }
    }

    /// 进入后台：把本机最新数据推到云端（免费账号无后台推送能力，离开 App 是上传的关键时机）。
    func sceneDidEnterBackground(_ scene: UIScene) {
        #if DEBUG
        print("[Auth] sceneDidEnterBackground → 触发自动同步（上传本地数据）")
        #endif
        // 离开 App 是上报埋点缓冲的关键时机，与数据同步同理
        UsageAnalytics.flush()
        // iCloud 自动备份（仅当用户在设置开启「iCloud 同步」）：把本地库+图片备份到 iCloud，
        // 与腾讯云跨端同步并存互补（一个管本机重装恢复，一个管多端共享）。
        ICloudBackupManager.autoBackupIfEnabled()
        Task { @MainActor in
            guard let container = AppDelegate.sharedContainer else { return }
            CloudSyncManager.shared.autoSyncIfEnabled(context: ModelContext(container))
        }
    }
}
