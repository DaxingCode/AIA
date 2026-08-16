// AppDelegate.swift
// 处理应用级事件：桌面图标 3D Touch / 长按快捷操作（UIApplicationShortcutItem）、
// 推送注册/接收、通知路由。界面由 SwiftUI WindowGroup 直接托管（全屏保证）。
// Scene 级生命周期回调（前后台、URL 路由）改由 AIAApp 的 scenePhase / onOpenURL 接管，
// 这里提供静态方法供其调用（见 handleScenePhase / handleOpenURL）。
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
    /// 启动期 iCloud 自动恢复完成、SwiftData 容器就绪后发出；RootView 据此刷新主界面。
    static let containerReady = Notification.Name("containerReady")
    /// 启动期数据就绪（容器已建好 + 首拉完成）：通知 ContentView 隐藏底部"正在恢复数据"小字条。
    static let dataRestoreFinished = Notification.Name("aia.dataRestoreFinished")
    /// Siri/快捷指令后台写入独立容器落盘后发出；ContentView 监听后刷新前台 @Query（跨容器不自动合并）。
    static let siriDidSaveData = Notification.Name("siriDidSaveData")
    /// 登录态变化（登录成功 / 登出）：通知 RootView 在首页与登录页之间切换。
    static let authStateChanged = Notification.Name("aia.authStateChanged")
}

/// 启动期「数据仍在恢复/加载中」环境开关：由 AppDelegate 在容器未就绪时注入 true，
/// 容器就绪后改为 false。ContentView 据此在底部显示一行"正在恢复数据…"小字，不挡首页内容。
private struct IsRestoringDataKey: EnvironmentKey {
    static let defaultValue: Bool = false
}
extension EnvironmentValues {
    var isRestoringData: Bool {
        get { self[IsRestoringDataKey.self] }
        set { self[IsRestoringDataKey.self] = newValue }
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// 全局共享容器：由 AIAApp 在后台建好后注入（容器就绪前为 nil）。
    static var sharedContainer: ModelContainer?
    /// 与 SwiftUI 注入界面（ContentView/LoginView）绑定的主上下文同一实例；
    /// 已开启 automaticallyMergesChangesFromParent，使后台同步落盘后首页 @Query 自动刷新。
    static var sharedMainContext: ModelContext?
    /// 冷启动时用户点击通知，ContentView 尚未创建，先把路由存在这里，onAppear 时消费。
    static var pendingNotificationRoute: String?

    /// 启动期占位容器：用内存存储（isStoredInMemoryOnly）+ 与真实容器同一 schema，
    /// 让 RootView 在真实磁盘库后台建好前就能渲染占位（空 @Query）。不碰磁盘 store，避免与后台 makeContainer 抢文件。
    static func makeStubContainer() -> ModelContainer {
        let mem = ModelConfiguration(schema: AppPersistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        // 内存 schema 建不出来理论不会发生；兜底空 schema 防崩。
        return (try? ModelContainer(for: AppPersistence.schema, configurations: [mem]))
            ?? (try? ModelContainer())!
    }

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

        // >>> CHANGE-[2026-08-16 21:30:00]-健康目标提醒默认值 开始
        // 原因: 用户要求「步数/饮水目标提醒」默认打开且默认时间 19:00；
        //       原代码 register(defaults:) 未注册 healthGoal 三个 key，新装 App 默认关、显示 00:00。
        // 回退: 删除本段三行 healthGoal* 注册即可恢复「默认关」。
        // 每天使用提醒：注册默认开关/时间 + 带 4 个操作按钮的 category
        UserDefaults.standard.register(defaults: [
            ReminderNotificationManager.dailyEnabledKey: true,
            ReminderNotificationManager.dailyHourKey: 22,
            ReminderNotificationManager.dailyMinuteKey: 0,
            // 健康目标提醒：默认开启，默认 19:00（用户可手动关闭/改时间，register 不覆盖已设值）
            ReminderNotificationManager.healthGoalEnabledKey: true,
            ReminderNotificationManager.healthGoalHourKey: 19,
            ReminderNotificationManager.healthGoalMinuteKey: 0,
            ICloudBackupManager.enabledKey: false,
        ])
        // <<< CHANGE-[2026-08-16 21:30:00]-健康目标提醒默认值 结束

        // 一次性迁移：强制 iCloud 自动备份默认关闭。
        // 只清一次（用版本标记守卫），确保老用户/测试机已存的 true 被重置为关；
        // 迁移后用户若手动打开，则保留其选择，不再被覆盖。
        let icloudDefaultOffMigratedKey = "aia.migratedICloudDefaultOff"
        if !UserDefaults.standard.bool(forKey: icloudDefaultOffMigratedKey) {
            UserDefaults.standard.set(false, forKey: ICloudBackupManager.enabledKey)
            UserDefaults.standard.set(true, forKey: icloudDefaultOffMigratedKey)
        }

        // 一次性迁移：强制自动同步默认关闭。
        // 逻辑同上：只清一次（用版本标记守卫），重置老用户/测试机已存的 true；
        // 迁移后用户若手动打开，则保留其选择，不再被覆盖。
        let autoSyncDefaultOffMigratedKey = "aia.migratedAutoSyncDefaultOff"
        if !UserDefaults.standard.bool(forKey: autoSyncDefaultOffMigratedKey) {
            UserDefaults.standard.set(false, forKey: "aia_auto_sync")
            UserDefaults.standard.set(true, forKey: autoSyncDefaultOffMigratedKey)
        }
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

    /// Scene 级：仅从 options.shortcutItem 捕获冷启动快捷项。
    /// 注意：在 SwiftUI App 生命周期下，界面由 WindowGroup 直接托管（系统自动生成
    /// 名为 "Default Configuration" 的全屏 scene 配置，delegate 指向 SwiftUI 内部实现），
    /// 这里**不**设置 config.delegateClass，避免 AppDelegate 再次当 scene delegate 与
    /// SwiftUI 抢夺 window 导致模拟器非全屏黑边。
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
        // 返回 SwiftUI 默认的全屏 scene 配置（不设 delegateClass，由 SwiftUI 托管）。
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// 读取当前持久化的外观模式，映射为 SwiftUI ColorScheme（system → nil，跟随系统）。
    /// 供 AIAApp 的 MainOrLoginView 通过 `.preferredColorScheme` 使用（SwiftUI 托管下直接生效）。
    static var currentColorScheme: ColorScheme? {
        AppearanceMode(raw: UserDefaults.standard.string(forKey: "aia.appearance") ?? "system").colorScheme
    }

    /// App 每次回到前台：先拉最新健康数据（异步，几秒后回来），再预写四宫格共享摘要（Widget 跨进程读不到 HealthKit/ManualHealthStore），最后刷新桌面小组件。
    /// 注意：writeShared 此刻写入的可能是 0（HealthKit 还没回来），HealthManager.refreshAll() 完成后的延迟补偿会再补写一次真实值。
    func applicationDidBecomeActive(_ application: UIApplication) {
        HealthManager.shared.refreshAll()
        MainActor.assumeIsolated {
            WidgetSnapshot.writeShared()
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    /// URL scheme 打开（如微信登录返回、桌面组件跳转）：由 SwiftUI 的 `.onOpenURL` 调用。
    /// 静态方法，便于 AIAApp 的 WindowGroup 直接接入。
    static func handleOpenURL(_ url: URL) {
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

    // MARK: - 登录/主界面切换（AuthManager 调用）

    /// 登录成功：发 `authStateChanged` 通知，由 AIAApp 的 RootView（MainOrLoginView）响应式切到首页。
    /// 不再手动换 rootViewController（方案 A 下界面由 SwiftUI WindowGroup 托管）。
    static func switchToMainInterface() {
        guard sharedContainer != nil else {
            #if DEBUG
            print("[Auth] switchToMainInterface failed: sharedContainer is nil")
            #endif
            return
        }
        // 通知 RootView 刷新登录态 → 切到 ContentView。
        NotificationCenter.default.post(name: .authStateChanged, object: nil)

        // 登录成功后：从云端全量拉取数据到本地（满足「登录后自动同步到本地」），
        // 同时把本机已有数据推到云端；仅已登录时触发。
        Task { @MainActor in
            guard let container = sharedContainer else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            CloudSyncManager.shared.syncAfterLogin(context: ModelContext(container))
        }
    }

    /// 登出：发 `authStateChanged` 通知，由 RootView 响应式切到登录页。
    static func switchToLoginInterface() {
        NotificationCenter.default.post(name: .authStateChanged, object: nil)
    }

    // MARK: - 自动同步：前后台触发（由 AIAApp 的 scenePhase onChange 调用）

    /// Scene 生命周期桥接：由 AIAApp 的 `@Environment(\.scenePhase)` 变化时调用。
    /// 集中处理前后台自动同步、角标清理、埋点、iCloud 备份等。
    static func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            #if DEBUG
            print("[Auth] scenePhase .active → 触发自动同步")
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
        case .background:
            #if DEBUG
            print("[Auth] scenePhase .background → 触发自动同步（上传本地数据）")
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
        default:
            break
        }
    }
}
