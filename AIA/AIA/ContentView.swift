// ContentView.swift
// 首页 E宫：顶部标题 + 待处理角标、四模块数据摘要宫格（2 列）、底部 AI 栏。
// 按《UI完整页面流.html》① 重建，数据由本地 SwiftData 驱动。
//
// 导航策略（避坑，重要）：
//   全 App 统一用单个 NavigationStack(path:) + 单个 .navigationDestination(for:)。
//   四宫格卡片、齿轮、快捷操作都走 router.navigate(...) 编程式跳转（经 QuickActionRouter 帧合并，避免同帧多次改 path）。
//   —— 不用 NavigationLink(value:)（iOS 26 首屏会白屏的已知 bug）；
//   —— 不用多个 .navigationDestination(isPresented:)（会互相冲突导致「点了没反应」）。
//   子页面（记录页/详情页）内部继续用闭包式 NavigationLink { Dest() }，与本栈共存无冲突。
import SwiftUI
import SwiftData
import Combine
import UniformTypeIdentifiers

/// 首页可跳转的目的地。统一枚举 → 单个 navigationDestination，规避多 destination 冲突。
enum HomeRoute: Hashable {
    case diet, health, bill, billTools, todo, todoTools, chat, chatVoice, settings, autoSetup, myAccount
    // 详情/编辑页：用 associated value 携带记录引用，让 .navigationDestination(for: HomeRoute.self) 统一处理
    // 所有 push 目标。**严禁**用 SelectableCard 的闭包式 destination 嵌入本路径——会触发
    // SwiftUI.AnyNavigationPath.Error.comparisonTypeMismatch try! 强解崩溃（2026-07-24 踩坑）。
    // 注意：「编辑待办」**不再走 navigationDestination**——2026-07-24 改为 .sheet 弹起（与「编辑账单」一致），
    // 入口在 ReminderListView 内的 @State editTodo + .sheet(item:)。这里只保留 .healthDetail。
    case healthDetail(HealthMetric)
    // 2026-07-29：将所有闭包式 NavigationLink { BillDetailView / BodyDataView / HealthGoalsView /
    // BillDashboardView } 改为 router.navigate 路径推送，消除 NavigationLink 直接写 path 绑定
    // 与 router 异步 flush 同帧触发的 "Update NavigationRequestObserver tried to update multiple times per frame"。
    case billDetail(Bill)
    case bodyData
    case healthGoals
    case billDashboard(BillDashboardMode)
    case recognitionRecords
    // Settings 子页（2026-07-29 从 SettingsView 闭包式 NavigationLink 改造为路由推送）
    case homeLayoutSettings
    case autoSyncSettings
    case imageAutoRecogSettings
    case backgroundSettings
    case defaultReminderSettings
    // 工具页子页（BillToolsView / TodoToolsView / DeveloperCenterView 闭包式 NavigationLink）
    case developerCenter
    case onboarding(writesDone: Bool = false)
    case recurringRuleList
    case billImport
    case importHistory
    case merchantRuleList
    case adManager
    case dataStatsExport
    // 月报 / 月账单 / 触发教程（RecordsViews / AutoRecognitionSetupView 闭包式 NavigationLink）
    case monthlyReport
    case monthlyBillList(year: Int, month: Int)
    case triggerTutorial(TriggerType)
    // 2026-08-19：静息心率每天记录页（点健康管理页静息心率方块跳转，最近90天，支持手动覆盖）
    case restingHeartRateRecords
    // 2026-08-19：近30日能量记录页（点饮食记录页净热量格跳转，顶部三汇总+下方每天三列）
    case energy30DaysRecords
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query({ var d = FetchDescriptor<FoodEntry>(predicate: #Predicate<FoodEntry> { !$0.syncDeleted }, sortBy: [SortDescriptor(\FoodEntry.date, order: .reverse)]); d.fetchLimit = 1000; return d }()) private var foods: [FoodEntry]
    @Query({ var d = FetchDescriptor<Bill>(predicate: #Predicate<Bill> { !$0.syncDeleted }, sortBy: [SortDescriptor(\Bill.time, order: .reverse)]); d.fetchLimit = 1000; return d }()) private var bills: [Bill]
    @Query({ var d = FetchDescriptor<Reminder>(predicate: #Predicate<Reminder> { !$0.syncDeleted }, sortBy: []); d.fetchLimit = 1000; return d }()) private var reminders: [Reminder]
    @Query({ var d = FetchDescriptor<HealthMetric>(predicate: #Predicate<HealthMetric> { !$0.syncDeleted }, sortBy: [SortDescriptor(\HealthMetric.date, order: .reverse)]); d.fetchLimit = 1000; return d }()) private var healths: [HealthMetric]
    // 首页饮食宫格「饮水量」所需：与饮食记录页今日饮水口径一致，仅取手动加水 WaterLog
    @Query({ var d = FetchDescriptor<WaterLog>(predicate: #Predicate<WaterLog> { !$0.syncDeleted }, sortBy: [SortDescriptor(\WaterLog.date, order: .reverse)]); d.fetchLimit = 1000; return d }()) private var waterLogs: [WaterLog]
    // 首页健康管理宫格右上角睡眠状态切换：与健康管理页 SleepToggleButton 共用同一份 SleepSession，状态自动互通。
    @Query({ var d = FetchDescriptor<SleepSession>(predicate: #Predicate<SleepSession> { !$0.syncDeleted }, sortBy: [SortDescriptor(\SleepSession.sleepStart, order: .reverse)]); d.fetchLimit = 200; return d }()) private var sleeps: [SleepSession]

    // 以下单例改用普通 let 强引用而非 @StateObject/@ObservedObject：
    // 这些单例（health/ent/global/sync）会在后台持续改写 @Published 属性（如 HealthKit 回调密集刷新），
    // 若根视图用 @ObservedObject 订阅，任一属性变化都会触发整个首页 body 每秒重算（整页循环抖动）。
    // 改成 let 后根视图不再订阅其 objectWillChange，功能完全保留（属性照读、方法照调、
    // .onReceive(publisher) 照订阅），从架构上切断「单例变化 → 整页重算」链路。
    @ObservedObject private var quickAction = QuickActionRouter.shared
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var layout = HomeLayoutStore.shared
    private let ent = EntitlementManager.shared
    private let global = GlobalConfigStore.shared
    @State private var isEditing = false
    @State private var draggingModule: HomeModule? = nil

    init() {}
    // MARK: 睡眠模式遮罩
    /// 首页宫格点 ☀️ 入睡后盖住整页；点「我醒了」或「先用一下 App」收起。
    @State private var showSleepMask = false
    /// 用户主动点「先用一下 App」收起遮罩的那次会话 syncId（进程内共享，见 SleepSession.swift 的
    /// sharedSleepMaskDismissedSessionID）：记住它 → 同一次睡眠内首页与健康页都不再自动盖回；
    /// 杀 App 重开时进程内共享值天然重置为 nil → 满足「只要没点醒来，每次开 App 都盖着」，无需持久化。
    /// 冷启动恢复窗口：onAppear 打开、3s 后自动关闭。
    /// 冷启动时 coldStartSync 还没把 SleepSession 拉回来，@Query 可能暂时为空，需等数据到位补盖一次。
    /// 窗口关闭后 sleeps 变化不再自动盖——否则在健康页点「入睡」会把遮罩盖到健康页上。
    @State private var sleepMaskRestoreWindowOpen = false
    /// 长按进入编辑态的瞬间时间戳：长按松手会连带触发宫格 Button 的 tap，借此在 0.5s 内吞掉这次跳转，避免"进了编辑又跳页"。
    @State private var longPressEnteredEditAt: Date? = nil
    /// 右上角工具栏是否展开：默认收起，仅露「展开」触发按钮；点开露出「首页编辑」+「设置」。
    @State private var toolbarExpanded = false
    @State private var browserTarget: BrowserTarget?   // App 内打开公告链接（link 模式）
    /// 非 Pro 用户退出首页布局编辑态时弹出的订阅页（已编辑但未落库，回滚）。
    @State private var showPaywall = false
    /// 免费试用期结束后弹出的引导弹窗（带「订阅 Pro 版」按钮，点击跳转到订阅页）。
    @State private var showTrialExpiredPrompt = false
    /// 进入首页布局编辑态瞬间拍下的布局快照；非 Pro 用户退出编辑时回滚到此，
    /// 因为 setHidden/relocate 在编辑操作瞬间就已写入 UserDefaults，必须用进入前的快照才能还原。
    @State private var preEditLayout: HomeLayoutStore.Snapshot? = nil

    @AppStorage("userNickname") private var userNickname = "小记的朋友"

    @State private var showCamera = false
    @State private var showPicker = false
    @State private var animateTiles = false
    /// Siri/快捷指令记完后，首页对应模块卡片高亮（描边+微缩放脉冲），柔和提示「这笔已记在此处」，不跳页。
    @State private var siriHighlightModule: HomeModule? = nil
    /// 高亮自动复位计时器句柄，复位时取消避免内存泄露/误复位。
    @State private var siriHighlightTask: Task<Void, Never>? = nil
    /// 沿边逐渐点亮扫描弧的进度（0→1 走一圈）。
    @State private var siriHighlightProgress: CGFloat = 0
    /// 2026-07-30 新增：首页进入计数器。LazyVGrid 项在导航返回时被复用，
    /// .onAppear 不会再触发；此值每次进入首页 +1，下传给 MiniBar.resetToken，
    /// 强制把 drawn 重置为 0 并重画「从左到右变长」动画。
    @State private var homeEnterToken: Int = 0
    /// >>> CHANGE-[2026-08-18 09:31:07]-[XS Max进度条无生长动画修复-冷启动兜底守卫] 开始
    /// 原因：冷启动首播原本只靠 MiniBar 的 .onAppear 自播（见 405-407 行注释），无 homeEnterToken 兜底；
    /// 而热启动(didBecomeActive)/返回首页(路由下降沿)都有 homeEnterToken &+= 1。XS Max 上 onAppear 自播
    /// 时序不稳被吞 → 冷启动没动画。此处补冷启动递增，与另外两条路径对齐。coldStarted 守卫保证只递增一次。
    /// 回退：删本行 + performOnAppear 内 if !coldStarted 段。
    @State private var coldStarted: Bool = false
    /// >>> CHANGE-[2026-08-18 14:54:59]-[区分冷启动/热启动进度条延迟] 开始
    /// 冷启动首播期间为 true（MiniBar 用 growDelay=1.5s 躲首帧重算风暴）；首次 homeEnterToken 变化后主线程置 false，
    /// 之后热启动/返回首页 MiniBar 走 warmDelay=0.3s 即时播，避免热启动动画出现太晚。
    /// 回退：删本行 + 三处 MiniBar 的 coldStart: 参数 + onChange(homeEnterToken) 内复位段。
    @State private var coldPlayPending: Bool = true
    /// <<< CHANGE-[2026-08-18 14:54:59]-[区分冷启动/热启动进度条延迟] 结束
    /// 好记AI头像呼吸脉冲动画开关
    @State private var abaoPulse = false
    /// 账单宫格隐私遮罩：@AppStorage 自动持久化到 UserDefaults，重启 App 保持
    @AppStorage("billHidden") private var billHidden = false

    /// 启动期「数据恢复中」环境开关（AppDelegate 注入）：容器未就绪占位阶段为 true。
    /// 用于底部显示一行小字"正在恢复数据…"，不挡首页空宫格；容器就绪/首拉完成后隐藏。
    @Environment(\.isRestoringData) private var isRestoringData
    @State private var isRestoring = false

    // 同上：根视图不再用 @StateObject 订阅 CloudSyncManager（它会转发 EntitlementManager.objectWillChange），
    // 改为普通 let 引用；.onReceive(sync.$isSyncing) 订阅的是 publisher，不依赖 @StateObject 身份，逻辑不变。
    private let sync = CloudSyncManager.shared

    // 首次启动引导：未看过引导则 push 出 OnboardingView（走 NavigationRouter，避开 fullScreenCover 弹不出问题）
    @AppStorage("aia.onboardingDone") private var onboardingDone = false
    @State private var showOnboarding = false // 仅作「首装引导激活中」标记，驱动冷启动重活的 onChange，不再绑 fullScreenCover

    // 后台「无感截图识别」的结果：主 App 打开时先自动入库，再弹确认页（确认页只做覆盖修改）。
    @State private var pendingPresent: RecognitionPresent?
    // 触发 pending 流程时是否跳转对话页（点通知进来=跳转；冷启/回前台=不跳，由闭包接管）。
    @State private var pendingNavigate: Bool = false
    // 防止 checkScreenshotPending 被多个通知并发/重复触发时重复 present。
    @State private var isCheckingScreenshotPending = false

    // 冷启动同步指示器：首次同步完成前显示「正在同步数据…」，完成后消失。
    // 用户在「同步完毕 = 全 0 → 真实数据」之间不再茫然。
    @State private var showSyncIndicator = false

    @AppStorage("aia.stepGoal") private var stepGoal: Int = 10000
    /// TDEE 同源键（与健康目标页、饮食记录页一致）。
    @AppStorage("aia.heightCm") private var heightCm: Double = 0
    @AppStorage("aia.weightKg") private var weightKg: Double = 0
    @AppStorage("aia.age") private var age: Int = 30
    @AppStorage("aia.bioSex") private var bioSex: Int = 1   // 1 = 男, 0 = 女
    @AppStorage("aia.activityLevel") private var activityLevel: Int = 1
    // MARK: 健康指标数据来源（逐指标切换，与健康管理页设置联动）
    // 每个指标独立选择「自动记录（HealthKit）/ 手动记录」，key 与健康页 @AppStorage 一致。
    // 仅当「该指标设为 auto」且「HealthKit 真可用」才走 HealthKit，否则回退手动录入。
    // 用户在健康页改数据来源，首页立即跟着变（@AppStorage 响应式广播）。
    @AppStorage(HealthMetricKind.steps.sourceKey)     private var stepsSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.sleep.sourceKey)     private var sleepSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.exercise.sourceKey)  private var exerciseSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.tdee.sourceKey)      private var tdeeSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.heartRate.sourceKey) private var heartRateSource: HealthSourceMode = .auto

    @AppStorage("aia.monthlyBudget") private var monthlyBudget: Double = 5000

    // 外观模式（浅色/深色/跟随系统）已由 AIAApp.WindowGroup 统一驱动，ContentView 不再持有副本。

    // MARK: 顶部工具栏（折叠/展开卷帘式）：编辑·睡眠·设置·💡·✨·触发器
    // 单个 HStack 包一个 ToolbarItem（原始写法）：按钮始终存在，用 frame 宽度 + opacity + scale 做"卷帘"式展开/收起。
    // 不用 if+transition：toolbar 容器对 transition 支持差，会瞬间闪现不走动画。
    private var toolbarTrailingContent: some View {
        HStack(spacing: 0) {
            // 首页编辑 / 完成：图标 + 文字，最直观；编辑态不再旋转（文字配旋转会歪，且铅笔转 90° 像 bug）
            Button {
                // 进入编辑模式时给中等震动反馈；退出不震
                if !isEditing {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    // 拍下进入编辑态前的布局快照：setHidden/relocate 在操作瞬间已写 UserDefaults，
                    // 必须用进入前的快照才能在退出时回滚，仅 reload() 读不回旧值。
                    preEditLayout = layout.snapshot()
                }
                // 非 Pro 用户：允许看/拖/改，但退出编辑态时回滚内存改动 + 弹订阅页，
                // 布局永不被非 Pro 用户落库（首页布局自定义为 Pro 专属）。
                if isEditing && !ent.isFullAccess {
                    _ = rollbackNonProEditIfNeeded(showPaywallWhenRollback: true)
                    return
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isEditing.toggle()
                    draggingModule = nil
                    if !isEditing { preEditLayout = nil }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                        .font(AIATheme.Font.body.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                    Text(isEditing ? "完成" : "编辑")
                        .font(AIATheme.Font.body.weight(.medium))
                }
            }
            .frame(width: toolbarExpanded ? 66 : 0)
            .opacity(toolbarExpanded ? 1 : 0)
            .scaleEffect(toolbarExpanded ? 1 : 0.4, anchor: .trailing)
            .padding(.trailing, toolbarExpanded ? 14 : 0)
            .allowsHitTesting(toolbarExpanded)

            // 入睡 / 醒来：与首页 sleepStatusButton、健康页 SleepToggleButton 共用
            // 同一份 SleepSession（toggleSleepSession），状态在三个入口之间自动互通。
            Button {
                // toggle 返回切换后的真实结果：nil=刚醒来（之前在睡），非 nil=刚入睡（新建会话）。
                // 用返回值而非任何快照/fetch 判「是否醒来」——@Query 闭包快照在 iCloud 同步/
                // 冷启动延迟时可能尚未包含活跃会话，导致误判 wasSleeping=false 而不弹 toast。
                // toggleSleepSession 内部用同一份 sleeps 快照判定，返回值与「真实发生的事」严格一致。
                let activeAfter = toggleSleepSession(in: context, sleeps: sleeps)   // 模型变更不包 withAnimation
                let didWake = (activeAfter == nil)   // 返回 nil = 确实从「在睡」切到「醒来」
                let start = currentActiveSleepSession(in: sleeps)?.sleepStart
                         ?? ContentView.activeSleepSessionStartFallback(context: context)
                if didWake {
                    // 醒来：弹与首页/健康页同款的睡眠时长 toast。
                    // 延后到遮罩淡出后（0.35s）再弹，避免 toast 被遮罩盖住或抢首帧被吞。
                    let toastStart = start
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        ToastCenter.shared.showImportant(
                            ContentView.sleepSummaryText(start: toastStart),
                            icon: "🌙",
                            accent: AIATheme.warning
                        )
                    }
                }
                #if DEBUG
                print("[SleepMask] 顶部按钮 toggle 完成, didWake=\(didWake), activeAfter=\(activeAfter != nil)")
                #endif
                // 直接赋值（不包 withAnimation），避免动画包裹影响 overlay 条件分支的插入时机
                showSleepMask = (activeAfter != nil)   // 刚入睡 → 盖遮罩；刚醒来 → 收遮罩
                #if DEBUG
                print("[SleepMask] 顶部按钮 showSleepMask=\(showSleepMask)")
                #endif
            } label: {
                // 仅靠图标轮廓的厚薄区分在睡/空闲：moon=线稿，moon.fill=实心，一眼可读。
                // .contentTransition(.symbolEffect(.replace)) 让切换有从下往上"升起"的过渡。
                let isSleeping = currentActiveSleepSession(in: sleeps) != nil
                Image(systemName: isSleeping ? "moon.fill" : "moon")
                    .font(AIATheme.Font.body.weight(.medium))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: toolbarExpanded ? 30 : 0)
            .opacity(toolbarExpanded ? 1 : 0)
            .scaleEffect(toolbarExpanded ? 1 : 0.4, anchor: .trailing)
            .padding(.trailing, toolbarExpanded ? 14 : 0)
            .allowsHitTesting(toolbarExpanded)

            // 设置
            Button { router.navigate(.settings) } label: {
                Image(systemName: "gearshape")
                    .font(AIATheme.Font.body.weight(.medium))
                    .rotationEffect(.degrees(toolbarExpanded ? -90 : 0))  // 打开往左滚，关闭往右滚
            }
            .frame(width: toolbarExpanded ? 30 : 0)
            .opacity(toolbarExpanded ? 1 : 0)
            .scaleEffect(toolbarExpanded ? 1 : 0.4, anchor: .trailing)
            .padding(.trailing, toolbarExpanded ? 14 : 0)
            .allowsHitTesting(toolbarExpanded)

            // App 功能介绍（App 内打开微信文章）—— 图标 lightbulb 💡
            Button {
                presentInAppBrowser(AppURLs.featureIntro)
            } label: {
                Image(systemName: "lightbulb")
                    .font(AIATheme.Font.body.weight(.medium))
            }
            .frame(width: toolbarExpanded ? 30 : 0)
            .opacity(toolbarExpanded ? 1 : 0)
            .scaleEffect(toolbarExpanded ? 1 : 0.4, anchor: .trailing)
            .padding(.trailing, toolbarExpanded ? 14 : 0)
            .allowsHitTesting(toolbarExpanded)
            .contentShape(Rectangle())

            // 重新查看新人引导 —— 图标 sparkles ✨（改为 push 跳转，避开 fullScreenCover 弹不出问题）
            Button {
                NavigationRouter.shared.navigate(.onboarding(writesDone: false))
            } label: {
                Image(systemName: "sparkles")
                    .font(AIATheme.Font.body.weight(.medium))
            }
            .frame(width: toolbarExpanded ? 30 : 0)
            .opacity(toolbarExpanded ? 1 : 0)
            .scaleEffect(toolbarExpanded ? 1 : 0.4, anchor: .trailing)
            .padding(.trailing, toolbarExpanded ? 14 : 0)
            .allowsHitTesting(toolbarExpanded)
            .contentShape(Rectangle())

            // 展开 / 收起触发器
            Button {
                // 展开工具栏时给轻微震动反馈；收起不震
                if !toolbarExpanded {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    toolbarExpanded.toggle()
                    // 收起时若在编辑态，一并退出，避免隐藏「完成」按钮后卡在编辑态
                    if !toolbarExpanded && isEditing {
                        // 非 Pro 用户：点 X 取消编辑 = 回滚进入编辑态后的内存改动 + 退出，
                        // 布局绝不被非 Pro 用户落库（与「完成」按钮的回滚语义一致）。
                        _ = rollbackNonProEditIfNeeded()
                    }
                }
            } label: {
                Image(systemName: toolbarExpanded ? "xmark.circle" : "gearshape")
                    .font(AIATheme.Font.body.weight(.medium))
                    .contentTransition(.symbolEffect(.replace))
                    .rotationEffect(.degrees(toolbarExpanded ? 90 : 0))
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .clipped()
    }

    // MARK: 路由目标视图：把 navigationDestination 的 switch 抽出来单独类型检查
    @ViewBuilder
    private func routeDestination(_ route: HomeRoute) -> some View {
        switch route {
        case .diet:         FoodListView()
        case .health:       HealthListView()
        case .bill:         BillListView()
        case .billTools:    BillToolsView()
        case .todo:         ReminderListView()
        case .todoTools:    TodoToolsView()
        case .chat:         ChatView(prefill: router.chatPrefill, entrySource: router.chatEntrySource, autofocusInput: router.chatAutoFocus)
        case .chatVoice:    ChatView(autostartVoice: true, entrySource: "voice")
        case .settings:     SettingsView()
        case .autoSetup:    AutoRecognitionSetupView()
        case .myAccount:    MyAccountView()
        case .healthDetail(let m):
            HealthDetailView(metric: m)
        case .billDetail(let b):
            BillDetailView(bill: b)
        case .bodyData:
            BodyDataView()
        case .healthGoals:
            HealthGoalsView()
        case .billDashboard(let mode):
            BillDashboardView(mode: mode)
        case .recognitionRecords:
            RecognitionRecordsView()
        case .homeLayoutSettings:
            HomeLayoutSettingsView()
        case .autoSyncSettings:
            AutoSyncSettingsView()
        case .imageAutoRecogSettings:
            ImageAutoRecogSettingsView()
        case .backgroundSettings:
            BackgroundSettingsView()
        case .defaultReminderSettings:
            DefaultReminderSettingsView()
        case .developerCenter:
            DeveloperCenterView()
        case .onboarding(let writesDone):
            OnboardingView {
                // 从导航栈移除自身即可返回；首装(writesDone=true)看完标记完成，避免重复弹
                if writesDone {
                    onboardingDone = true
                }
                showOnboarding = false
                NavigationRouter.shared.path.removeAll(where: {
                    if case .onboarding = $0 { return true }
                    return false
                })
            }
        case .recurringRuleList:
            RecurringRuleListView().environment(\.modelContext, context)
        case .billImport:
            BillImportView().environment(\.modelContext, context)
        case .importHistory:
            ImportHistoryView().environment(\.modelContext, context)
        case .merchantRuleList:
            MerchantRuleListView().environment(\.modelContext, context)
        case .adManager:
            AdManagerView()
        case .dataStatsExport:
            DataStatsExportView()
        case .monthlyReport:
            MonthlyReportView().environment(\.modelContext, context)
        case .monthlyBillList(let year, let month):
            MonthlyBillListView(year: year, month: month, bills: [])
                .environment(\.modelContext, context)
        case .triggerTutorial(let trigger):
            TriggerTutorialView(trigger: trigger)
        case .restingHeartRateRecords:
            RestingHeartRateRecordsView()
        case .energy30DaysRecords:
            Energy30DaysRecordsView()
        }
    }

    /// 冷启动一次性逻辑（从 .onAppear 抽出单独类型检查，避免整段闭包卡住编译器）。
    @MainActor
    private func performOnAppear() {
        #if DEBUG
        print("[ContentView] onAppear, pending=\(quickAction.pending?.rawValue ?? "nil")")
        #endif
        // HealthKit 授权：无条件触发，不依赖引导页关闭或 runDeferredStartup。
        // 2026-08-11 把它塞进 runDeferredStartup 后，重装首开若走引导页分支会被推迟，
        // 且引导页关闭的 onChange 偶发不命中 → 授权框不弹。提到此处保证每次进首页都尝试一次
        // （内部有守卫不会重复弹，且仍是 0.6s 延后发系统 modal + 异步查询，不会卡老机型）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            HealthManager.shared.requestAuthorization()
        }
        // >>> CHANGE-[2026-08-18 09:31:07]-[XS Max进度条无生长动画修复-冷启动补homeEnterToken] 开始
        // 原因：原注释主张「冷启动不再补 homeEnterToken，交给 MiniBar 自己 onAppear 自播」。
        // 但 XS Max(A12) 上该自播时序不稳常被吞（首帧 body 多轮重算 + 数据异步）→ 冷启动无生长动画。
        // 现改为冷启动也递增 homeEnterToken，与热启动(didBecomeActive)/返回首页(路由下降沿)完全对齐，
        // 走 MiniBar.resetToken 监听 → drawn 归零重播，双保险（onAppear 自播 + resetToken 重播，视觉连续生长）。
        // 回退：删本段 if !coldStarted 块，并恢复上方「不再补 homeEnterToken」注释。
        if !coldStarted {
            coldStarted = true
            // >>> CHANGE-[2026-08-18 11:50:00]-[冷启动进度条无生长动画-resetToken延迟一帧] 开始
            // 原因：原写法在 performOnAppear(ContentView.onAppear 同步块)里直接 &+= 1，此时 MiniBar 子视图
            // 尚未挂载完，其 onChange(resetToken) 首帧收到的初值已是 1（非变化）→ 不 fire；叠加本项目
            // 首帧 body 多轮重算吞掉 .onAppear/.task 自播 → 冷启动三种触发源全失效（热启动/返回首页走
            // 变化语义必 fire，故它们有、冷启动没有）。改延迟一帧：让 MiniBar 先以 resetToken=0 挂载，
            // 下一帧变 1 → onChange 必然 fire → 重播生长，与热/返回路径语义完全对齐。
            // 回退：删本段 async 包，恢复 `homeEnterToken &+= 1`（同步写法）。
            DispatchQueue.main.async {
                self.homeEnterToken &+= 1
            }
            // <<< CHANGE-[2026-08-18 11:50:00]-[冷启动进度条无生长动画-resetToken延迟一帧] 结束
        }
        // <<< CHANGE-[2026-08-18 09:31:07]-[XS Max进度条无生长动画修复-冷启动补homeEnterToken] 结束
        // 一次性去重：清理重复记录（仅首次启动执行）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            DataDeduplicator.runOnce(context: context)
        }
        if let action = quickAction.pending { consume(action) }
        if let route = AppDelegate.pendingNotificationRoute {
            consumeNotificationRoute(route)
        }
        if !onboardingDone {
            // 首次启动：走 push 路由（与 re-view 同一条已验证稳定的路径），
            // 避免 fullScreenCover 在 .onAppear 同步弹出被系统吞掉导致引导页不出现。
            // 首装标记完成写在 OnboardingView 完成回调里（writesDone=true）。
            showOnboarding = true
            NavigationRouter.shared.navigate(.onboarding(writesDone: true))
            // 等引导页 dismiss 后再跑 runDeferredStartup，避免与引导页抢首帧。
        } else {
            runDeferredStartup()
        }
    }

    /// 睡眠遮罩恢复（独立方法，可被根 .onAppear 与 runDeferredStartup 双保险调用）。
    /// 只要还有没点「醒来」的活跃会话，冷启动/回前台就把遮罩盖回来。
    /// 先立即试一次（本地库已有数据时即刻生效），再开 8s 窗口等本地加载 + 云端同步补数据。
    /// 窗口放宽到 8s：@Query 从本地 SQLite 加载 + coldStartSync(delay:0.5) 拉云端都需时间，
    /// 3s 太短会赌输致遮罩永久不盖（用户杀 App 重开要手动点月亮才出来）。
    @MainActor
    private func restoreSleepMaskOnStartup() {
        sleepMaskRestoreWindowOpen = true
        restoreSleepMaskIfNeeded()
        // 兜底轮询：冷启动时首页 @Query sleeps 快照可能尚未刷新（本地 SQLite 加载 /
        // 云端同步途中），导致首帧调用 restoreSleepMaskIfNeeded 漏盖；而本地已有历史会话时
        // .onChange(of: sleeps) 因数组「未变化」不会 fire，补盖同样落空。
        // 这里每 0.5s 在 8s 窗口内持续重查，确保数据到位后立即盖回遮罩。
        let sleepMaskTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            guard sleepMaskRestoreWindowOpen else {
                timer.invalidate()
                return
            }
            restoreSleepMaskIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            sleepMaskRestoreWindowOpen = false
            sleepMaskTimer.invalidate()
        }
    }

    /// 冷启动重活（与引导页互斥，避免抢首帧导致老机型黑屏卡死）。
    /// 首次启动由 showOnboarding 关闭时的 onChange 触发；非首次启动由 performOnAppear 立即触发。
    /// 2026-08-11：首装老机型（A12/XS Max）"打开就卡"的根因是这些重活全部堆在首帧之后瞬间并发——
    /// HealthKit 授权（一次性发 10+ 个查询密集回刷）+ 周期账单同步写库 + 云拉全量 + 广告/全局配置拉取
    /// 抢同一段 CPU 窗口。这里把重活错峰 + 降优先级，让首帧先稳稳渲染完。
    @MainActor
    private func runDeferredStartup() {
        Task(priority: .background) { await checkScreenshotPending() }
        // 睡眠遮罩恢复：交给 restoreSleepMaskOnStartup()，由根 .onAppear 无条件调用兜底，
        // 这里再调一次双保险（runDeferredStartup 在 .onAppear 之后由引导关闭/非首启触发）。
        // 两次都开 8s 窗口但第二次 isOpen 已被首次置 true，restoreSleepMaskIfNeeded 幂等，无害。
        restoreSleepMaskOnStartup()
        // 周期 / 订阅账单：App 打开时把已到期的账期自动入账（房租、会员费等）。
        // 同步读 RecurringRule + 写 Bill + context.save()，规则多时会阻塞主线程，
        // 延后到首帧渲染稳定后（0.8s）再跑，避免和 HealthKit 授权/云拉全量撞同一窗口。
        // （SwiftData ModelContext 非线程安全，必须留在主线程，故用 asyncAfter 错峰而非丢后台线程）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            RecurringBillManager.generateDue(context: context)
        }
        // HealthKit 授权已提到 performOnAppear 顶层无条件触发（见上），此处不再重复调用，避免非首启重复发起。
        // 冷启动首拉：延到 0.5s 让云端睡眠等数据更早回来，配合 8s 睡眠遮罩恢复窗口更稳。
        // （首帧空态已由 runDeferredStartup 延后调度保证，0.5s 不会与周期账单/HealthKit 撞窗。）
        coldStartSync(delay: 0.5)
        // 首页广告位首拉：本环境 .task 闭包不派发，改由 onAppear（已验证触发）兜底拉取广告。
        // 用最低优先级，不抢首帧体验。
        Task(priority: .background) { await AdStore.shared.fetchIfNeeded() }
        // 全局配置首拉：开发者切换智能问答/AI模型后，所有用户自动跟随（云端权威，本地缓存）。
        // 最低优先级，可在后台慢慢拉。
        Task(priority: .background) { await GlobalConfigStore.shared.fetchConfig() }
        // 冷启动同步指示器：仅当已登录 **且** 云同步真的会跑（开关 + 会员都放行）才亮起。
        // 否则「自动同步已关闭」时根本不会进 sync()、isSyncing 永远是 false，
        // FirstSyncIndicator 永远没机会关条——会看到「正在同步数据」误终身挂着。
        if UserDefaults.standard.bool(forKey: "aia.isLoggedIn"),
           CloudSyncManager.canPerformCloudSync {
            showSyncIndicator = true
        }
        // 数据库降级提示：若 makeContainer 因 schema 版本错位走了「内存存储兜底」，
        // 本次会话写入不会持久化。提示用户重装 App（数据在云端，登录即恢复），
        // 避免「看着能记、实则没存」的困惑。
        if UserDefaults.standard.bool(forKey: "aia.storeDegradedToMemory") {
            ToastCenter.shared.showImportant(
                "数据库版本不兼容（当前代码 v\(AppPersistence.currentSchemaVersion)），旧数据已自动备份。本次记录为临时存储，重启会清空，请重装 App 从云端恢复数据。",
                icon: "⚠️",
                accent: AIATheme.warning
            )
        }
        // Siri/快捷指令记完后：消费共享暂存，让首页对应模块卡片做一次高亮脉冲（柔和提示）。
        consumeSiriHighlightModule()
    }

    /// 读取 TellAIAIntent 写入的「刚记的模块」，驱动首页卡片高亮，消费即删除（防重复触发）。
    private func consumeSiriHighlightModule() {
        guard let raw = UserDefaults.standard.string(forKey: "aia.siriHighlightModule"),
              let m = HomeModule(rawValue: raw) else { return }
        UserDefaults.standard.removeObject(forKey: "aia.siriHighlightModule")
        siriHighlightTask?.cancel()
        siriHighlightModule = m
        siriHighlightProgress = 0
        // 让扫描弧沿宫格外围从起点出发、逐渐点亮走一圈（1.4s）
        withAnimation(.linear(duration: 1.4)) {
            siriHighlightProgress = 1
        }
        // 扫完一圈后留 0.8s 整圈常亮，再复位（共 2.2s）
        siriHighlightTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            siriHighlightModule = nil
            siriHighlightProgress = 0
        }
    }

    var body: some View {
        #if DEBUG
        // 诊断「整页每秒重算」：_printChanges() 会精确打印本次 body 重算由哪个属性触发
        // （如 _observedChanged: layout / _appStorageChanged / _location 等）。
        // 真机跑一次看日志即可定位根因，确认修复后删掉下面两行。
        let _ = Self._printChanges()
        let _ = print("🌀 [验证] ContentView.body 重算 @\(Date().timeIntervalSince1970)")
        #endif
        ZStack {
            NavigationStack(path: $router.path) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 8) {
                        header
                            .padding(.bottom, 8)
                        syncHeaderIndicator
                        AdBannerView()
                        announcementBanner
                        if isEditing {
                            homeModulesEditView
                        } else {
                            homeModulesView
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 0)
                    .padding(.bottom, 12)
                }
                AIBottomBar()
                    .id("homeBottomBar")
            }
            .background(AppBackgroundView())
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HomeRoute.self) { route in
                routeDestination(route)
            }
            // 监听试用期到期信号：弹出自带「订阅 Pro 版」按钮的引导弹窗。
            .onReceive(ent.$presentTrialExpiredPrompt) { shouldShow in
                if shouldShow {
                    showTrialExpiredPrompt = true
                    ent.presentTrialExpiredPrompt = false
                }
            }
            // 去除 NavigationBar 底部分隔线（iOS 系统默认 shadow line）
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                toolbarTrailingContent
            }
        }
        .onAppear {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.shadowColor = .clear
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().compactScrollEdgeAppearance = appearance
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AIA.ShowOnboarding"))) { _ in
            // 中途弹引导（re-view 性质，不写 onboardingDone），走已验证稳定的 push 路径
            showOnboarding = true
            NavigationRouter.shared.navigate(.onboarding(writesDone: false))
        }
        .onChange(of: router.path) { old, new in
            #if DEBUG
            print("[ContentView] path changed from \(old) to \(new)")
            #endif
            // 返回首页（下降沿）：从非空跳到空 = 用户从子页退回首页。
            // 让两个 MiniBar 重播生长动画，与冷启动首播、热启动（didBecomeActive）路径一致。
            // 排除「还没跳进过子页就被重置」的退化：要求 old 非空才算一次真正的返回。
            if !old.isEmpty && new.isEmpty {
                homeEnterToken &+= 1
            }
        }
        // >>> CHANGE-[2026-08-18 14:54:59]-[区分冷启动/热启动进度条延迟] 开始
        // 任意一次 homeEnterToken 变化后（冷启动首播/热启动/返回首页），主线程把 coldPlayPending 置 false，
        // 使后续 MiniBar 重播走 warmDelay(0.3s) 而非冷启动的 1.5s。
        .onChange(of: homeEnterToken) { _, _ in
            DispatchQueue.main.async { coldPlayPending = false }
        }
        // <<< CHANGE-[2026-08-18 14:54:59]-[区分冷启动/热启动进度条延迟] 结束
        // 冷启动兜底：didFinishLaunching 里写入的 pending 在 ContentView 订阅 onReceive 之前就已存在，
        // onReceive 不会回放初始值；通知又在订阅前发出会被直接丢弃。因此这里显式读一次 pending 消费冷启动快捷项。
        .onAppear {
            performOnAppear()
            // 睡眠遮罩恢复：无条件在根视图挂载时启动（与 runDeferredStartup 双保险）。
            // 不依赖 performOnAppear 的 onboardingDone 分支、也不依赖 showOnboarding 的 onChange——
            // 删 App 重装后那条触发链若因任何原因没 fire，睡眠恢复仍能在此兜底跑起来。
            // 引导页遮挡期间启动轮询无害：8s 窗口内数据到位即盖，引导页 dismiss 后用户可见。
            restoreSleepMaskOnStartup()
        }
        // 首次启动：引导页关闭（showOnboarding 由 true→false）后再跑冷启动重活，
        // 避免与引导页抢首帧导致老机型黑屏卡死。
        .onChange(of: showOnboarding) { old, new in
            if old == true && new == false {
                runDeferredStartup()
            }
        }
        // 冷启动时 SleepSession 可能还在云端同步途中，@Query 到位后在恢复窗口内补盖一次。
        // 监听整个 sleeps 数组（而非 sleeps.count）：本地早有历史会话时 count 不变，
        // 但「最新那条翻成未醒来活跃会话」仍应补盖——只盯 count 会漏盖。
        // 窗口外不响应，避免健康页点「入睡」时把遮罩盖到健康页上。
        .onChange(of: sleeps) { _, _ in
            guard sleepMaskRestoreWindowOpen else { return }
            restoreSleepMaskIfNeeded()
        }

        // 热启动（App 后台时长按图标）：performActionFor 改 pending 时 ContentView 已订阅，onReceive 能收到。
        .onReceive(quickAction.$pending) { action in
            #if DEBUG
            print("[ContentView] onReceive pending, action=\(action?.rawValue ?? "nil")")
            #endif
            guard let action else { return }
            consume(action)
        }
        // 通知兜底消费：热启动时 $pending 的 onReceive 可能因 SwiftUI 后台视图订阅的时序竞态而错过本次发射，
        // 导致偶尔不跳转。这里收到通知后主动消费 pending（或通知携带的 action），确保跳转必定发生。
        // consume 内部先清空 pending 且 jump 幂等，即使与 $pending 路径重复触发也不会双跳。
        .onReceive(NotificationCenter.default.publisher(for: .quickActionColdLaunch)) { note in
            #if DEBUG
            let actionRaw = note.userInfo?["action"] as? String
            print("[ContentView] onReceive quickActionColdLaunch, action=\(actionRaw ?? "nil"), pending=\(quickAction.pending?.rawValue ?? "nil")")
            #endif
            if let p = quickAction.pending {
                consume(p)
            } else if let actionRaw = note.userInfo?["action"] as? String,
                      let action = QuickAction(rawValue: actionRaw) {
                consume(action)
            }
        }
        // 极端竞态兜底：万一 $pending 与通知都被 SwiftUI 错过，App 回到前台后延迟一帧主动查 pending 并消费。
        // 系统顺序为 didBecomeActive → performActionFor，故延迟 0.1s 检查以确保 performActionFor 已写好 pending。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            #if DEBUG
            print("[ContentView] didBecomeActive, pending=\(quickAction.pending?.rawValue ?? "nil")")
            #endif
            // 2026-07-30 热启动（方案 C）：App 从后台回前台时，递增 homeEnterToken 让首页两个
            // MiniBar 监听 resetToken 统一走 replayMini()（填充淡出→归零→淡入生长），彻底无「变短」观感。
            // 卡片本身已可见，无需再让 animateTiles 重新淡入（避免回前台整屏闪动）。
            homeEnterToken &+= 1
            // Siri/快捷指令记完后（点 Siri 界面唤醒 App）热启动也走这里：消费高亮暂存。
            // 必须在下方 `guard quickAction.pending != nil` 之前，否则无快捷操作 pending 时提前 return。
            consumeSiriHighlightModule()
            // 截图无感识别：无论是否有快捷操作 pending，只要后台留了识别结果就弹确认页
            Task { await checkScreenshotPending() }
            // 回到前台兜底：编辑态中途切后台/被杀再回来时，非 Pro 用户的改动可能已落库在 UserDefaults，
            // 这里回滚进入编辑前的快照，防止「关 App 再回来布局被改了」。（杀 App 前 didEnterBackground 已先回滚一次）
            _ = rollbackNonProEditIfNeeded()
            // 回到前台时也补生成周期账单（长期未开 App 会补齐中间月份）
            RecurringBillManager.generateDue(context: context)
            // 全局配置回前台拉取：开发者切换智能问答/AI模型后，用户切回 App 即自动跟随云端
            // （低频，生命周期驱动，不再常驻轮询占用云函数额度）
            Task { await GlobalConfigStore.shared.fetchConfig() }
            // 回前台云端同步统一交给 AppDelegate.sceneDidBecomeActive（系统 UISceneDelegate 保证触发，
            // 且受 autoSync + isLoggedIn 双重守卫）。此处删除可避免与 AppDelegate 重复 spawn 同步 Task，
            // 并修正「关掉 autoSync 的用户回前台仍被同步」的语义歧义。
            guard quickAction.pending != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let p = quickAction.pending { consume(p) }
            }
        }
        // 进入后台 / 杀 App 前：非 Pro 用户在编辑态时立即回滚进入编辑前的布局快照。
        // 此时 preEditLayout 仍在内存，是最可靠的回滚时机，避免布局被非 Pro 用户落库。
        // 回前台时再兜底一次（见 didBecomeActive 块），双保险。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            _ = rollbackNonProEditIfNeeded()
        }
        // 冷启动同步指示器：下沉到 FirstSyncIndicator 子视图，避免根视图订阅 sync.$isSyncing
        FirstSyncIndicator(showSyncIndicator: $showSyncIndicator)
        // 点击系统通知：跳转到对应页面（如待办提醒 → 待办页）。
        .onReceive(NotificationCenter.default.publisher(for: .notificationRouteReceived)) { note in
            if let route = note.userInfo?["route"] as? String {
                consumeNotificationRoute(route)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotRecognitionReady)) { _ in
            Task { await checkScreenshotPending(navigateToChat: true) }
        }
        // Siri/快捷指令后台写入独立容器落盘后：前台 @Query 与写容器跨实例不自动合并，
        // 这里尽力而为刷新本地数据。App 在前台时即时刷新靠本监听；App 在后台/锁屏时，
        // 回前台（didBecomeActive）或下次启动打开同一 store 自然读到，无需额外处理。
        .onReceive(NotificationCenter.default.publisher(for: .siriDidSaveData)) { _ in
            #if DEBUG
            print("[ContentView] siriDidSaveData received → 刷新本地数据")
            #endif
            // 补生成周期账单（如 Siri 记的触发跨月）
            RecurringBillManager.generateDue(context: context)
            // 强制主上下文重新读取同一份 store：对关键类型各 fetch 一次，
            // 触发 @Query 内部快照与磁盘对齐（跨容器写入在主 context 上是「新数据」）。
            Task { @MainActor in
                _ = try? context.fetch(FetchDescriptor<Bill>())
                _ = try? context.fetch(FetchDescriptor<FoodEntry>())
                _ = try? context.fetch(FetchDescriptor<Reminder>())
                _ = try? context.fetch(FetchDescriptor<HealthNote>())
            }
        }
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker, navigateToChat: true)
        // 后台「无感截图识别」的结果确认页：App 打开且有 pending 时弹出（正常已入库 / 重复则警告不入库），
        // 关闭即清空，避免重复弹。
        .fullScreenCover(item: $pendingPresent) { present in
            makeResultConfirmView(present,
                onSaveAction: { session in
                    // 「保存」→ 建真实模型实例（applyAndSave 已入库）+ 回插「已保存态」气泡
                    RecognitionSaver.insertSavedBubble(session: session, context: context)
                    if pendingNavigate {
                        DispatchQueue.main.async { NavigationRouter.shared.navigate(.chat) }
                    }
                },
                onCancelAction: {
                    // 「返回 / 不保存」→ 仍生成「待确认态」气泡（syncId=nil 未入库），数据留在对话里
                    if case .pending(let result, _, _, let source, let presavedName, _) = present {
                        RecognitionSaver.insertPendingBubble(result: result, context: context,
                                                             recogSource: RecogSource.raw(from: source),
                                                             imageName: presavedName)
                    }
                    if pendingNavigate {
                        DispatchQueue.main.async { NavigationRouter.shared.navigate(.chat) }
                    }
                }
            )
            .environment(\.modelContext, context)
            .interactiveDismissDisabled(true)
            .onDisappear {
                ScreenshotStore.clearPending()
                pendingPresent = nil
            }
        }
        // 外观模式已由 AIAApp.WindowGroup 最外层统一驱动（@AppStorage 响应式覆盖整窗），此处不再重复。
        // 非 Pro 用户退出首页布局编辑态时弹出订阅页（已编辑但未落库，已回滚）。
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        // 免费试用期结束后的引导弹窗：带锁图标 + 文案 + 「订阅 Pro 版」按钮，
        // 点击按钮关闭弹窗并跳转到上方订阅页。
        .overlay {
            TrialExpiredPromptView(
                isPresented: $showTrialExpiredPrompt,
                onSubscribe: {
                    showTrialExpiredPrompt = false
                    showPaywall = true
                }
            )
        }
        .inAppBrowser(target: $browserTarget)
        // 启动期「数据恢复中」底部小字：容器未就绪占位阶段（isRestoringData=true）显示，
        // 容器就绪/首拉完成后隐藏。不挡首页空宫格，仅页内一行小字提示。
        .task { isRestoring = isRestoringData }
        .onChange(of: isRestoringData) { _, nv in if !nv { isRestoring = false } }
        .onReceive(NotificationCenter.default.publisher(for: .dataRestoreFinished)) { _ in
            isRestoring = false
        }
        .overlay(alignment: .bottom) {
            if isRestoring {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在恢复数据…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.25), value: isRestoring)
            }
        }
        // 睡眠模式遮罩：提到 body 最外层 ZStack，与 NavigationStack 平级、zIndex 最高。
        // 这样无论当前在首页还是被 push 进来的任何页面（含健康管理页），遮罩都盖在整个窗口最上层，
        // 不会被 push 进来的页面盖下去（原挂在 NavigationStack 上的 overlay 会被健康页全屏底色盖住，
        // 导致「首页点月亮没遮罩、健康页才有」的错位现象）。
        if showSleepMask {
            SleepMaskOverlay(
                session: currentActiveSleepSession(in: sleeps),
                show: showSleepMask,
                onWake: {
                    // toggle 返回 nil=确实醒来（之前在睡）；用返回值确保「醒来」判定与真实动作一致，
                    // 不再依赖 currentActiveSleepSession 快照（iCloud/冷启动延迟时可能取不到）。
                    let _ = toggleSleepSession(in: context, sleeps: sleeps)
                    let start = ContentView.activeSleepSessionStartFallback(context: context)
                    DispatchQueue.main.async {
                        sharedSleepMaskDismissedSessionID = nil
                        withAnimation(.easeOut(duration: 0.3)) { showSleepMask = false }
                        // 延后到遮罩淡出后弹 toast，避免被遮罩盖住或抢首帧被吞。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            ToastCenter.shared.showImportant(
                                ContentView.sleepSummaryText(start: start),
                                icon: "🌙",
                                accent: AIATheme.warning
                            )
                        }
                    }
                },
                onDismiss: {
                    sharedSleepMaskDismissedSessionID = currentActiveSleepSession(in: sleeps)?.syncId
                    withAnimation(.easeOut(duration: 0.3)) { showSleepMask = false }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .zIndex(999)
        }
        // 全局轻量 toast：挂在外层 ZStack、且层级高于睡眠遮罩（999），确保醒来提示必可见。
        // 原本挂在 NavigationStack 的 overlay 上，zIndex 100 只作用于 NavigationStack 子树内部，
        // 永远被平级的 SleepMaskOverlay(999) 盖住，导致醒来 toast 被遮罩压在底下看不见。
        GlobalToastOverlay()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(2000)
        }   // ZStack 结束
    }   // body 结束

    /// 检查后台识别留下的待确认结果（截图无感识别链路）：
    /// 走 processRecognition —— 按「来源 × 类别」二维设置分流，结果统一组装成一条对话气泡消息插入对话流：
    /// - .inserted：已在对话流插入结果气泡（已保存态 / 待确认态卡片随设置而定）→ 清 pending；
    ///   若用户是点系统通知进来的（navigateToChat=true），跳到对话页查看结果。
    /// - .nothing：按设置丢弃、或未识别出任何类别 → 仅清 pending。
    @MainActor
    private func checkScreenshotPending(navigateToChat: Bool = false, forceSave: Bool = false) async {
        guard !isCheckingScreenshotPending, pendingPresent == nil else { return }
        guard let p = ScreenshotStore.loadPending() else { return }
        isCheckingScreenshotPending = true
        let img = ScreenshotStore.loadPendingImage()
        // 招呼气泡定位锚点：必须打在插入「你发的图」气泡之前，
        // 否则 ChatView.onAppear 会把这张截屏算成历史，招呼气泡排到图片后面。
        NavigationRouter.shared.beginChatSession()
        // 像微信一样：这张截屏先作为「你发的图」进对话流，好记AI随后在同一段对话里回识别卡片。
        // 返回的文件名给识别结果复用，同一张图不落盘两次。
        let presavedName = appendUserImageMessage(image: img, context: context)

        // 付费墙拦截分支：后台识别被免费版权益拦截（无云端视觉 + 本地覆盖不到），
        // 不当作普通识别结果处理，而是回插「升级 Pro」引导气泡——与对话页付费墙做法一致。
        if p.isPaywallBlocked {
            ScreenshotStore.clearPending()
            // 已开通 Pro/试用/白名单的用户本不该走这条分支；若因权益状态抖动误入，
            // 不要再提示「升级 Pro」（会造成「已开通还让升级」的困惑），改提示重试/网络问题。
            let text: String
            if EntitlementManager.shared.isPro {
                text = "这张图片的云端识别暂时没成功，可能是网络波动。你可以稍后重试，或手动记录～"
            } else {
                text = UPGRADE_PRO_PREFIX + "这张图用免费版AI识别失败了，如果你想体验更好，可升级 Pro版会员后，使用云端大模型AI进行识别。"
            }
            context.insert(ChatMessage(role: .ai, text: text))
            isCheckingScreenshotPending = false
            if navigateToChat {
                DispatchQueue.main.async { NavigationRouter.shared.navigate(.chat) }
            }
            return
        }

        // 普通识别失败分支（非权益类错误：本地解析/网络/云端异常）。
        // 绝提示「升级 Pro」，避免已开通会员用户被误导；给友好提示即可。
        if p.isRecognizeFailed {
            ScreenshotStore.clearPending()
            context.insert(ChatMessage(role: .ai, text: "这张图片暂时没能识别成功，可能是网络或图片问题。你可以稍后重试，或手动记录～"))
            isCheckingScreenshotPending = false
            if navigateToChat {
                DispatchQueue.main.async { NavigationRouter.shared.navigate(.chat) }
            }
            return
        }

        // 分流依据：若识别出的已知类别里任一设为「待确认」，整张图先弹确认页——
        // 确认页只是待确认气泡的前置编辑入口，关掉后数据照样留在对话气泡里，之后在气泡点保存才入库。
        // forceSave=true（来自通知「保存」Action）：即使用户设置是「确认后再保存」，本次也直接入库，
        // 实现「锁屏点一下就记上」的无感体验，且仍走 processRecognition 同一套逻辑不绕弯。
        let types = p.result.types ?? []
        let known = ImageAutoRecogSettings.knownTypes.filter { types.contains($0) }
        let hasPending = !forceSave && known.contains { ImageAutoRecogSettings.mode(for: $0, source: "image") == .pending }

        if hasPending {
            pendingNavigate = navigateToChat
            pendingPresent = .pending(p.result, rawText: p.rawText,
                                      image: img, source: p.source ?? .cloud,
                                      presavedImageName: presavedName,
                                      screenshotShortcut: true)
            isCheckingScreenshotPending = false
        } else {
            let outcome = await RecognitionSaver.processRecognition(result: p.result, rawText: p.rawText,
                                                              image: img, context: context,
                                                              source: p.source ?? .cloud,
                                                              entryOrigin: "image",
                                                              screenshotShortcut: true,
                                                              presavedImageName: presavedName)
            isCheckingScreenshotPending = false
            switch outcome {
            case .inserted:
                // 结果已进对话气泡：立即清 pending，避免点通知回 App 时重复处理
                ScreenshotStore.clearPending()
            case .nothing:
                // 按设置丢弃或未识别：仅清 pending，不弹不存。
                // 但图已经「发」出去了，好记AI必须有回应，否则对话里只剩一张没人理的图。
                ScreenshotStore.clearPending()
                if presavedName != nil {
                    context.insert(ChatMessage(role: .ai, text: "这张图我没识别到可记录的内容～可以在「设置 → 识别结果保存方式设置」里调整保存策略。"))
                }
            }
            if navigateToChat {
                DispatchQueue.main.async {
                    NavigationRouter.shared.navigate(.chat)
                }
            }
        }
    }

    // MARK: - 顶部标题 + 待处理角标
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11:  return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<23: return "晚上好"
        default:      return "你好"
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            abaoAvatar

            Text("\(greeting)，\(userNickname) \(Self.greetingEmoji)")
                .font(AIATheme.Font.title2.weight(.semibold))
            Spacer()
            if pendingCount > 0 {
                Text("\(pendingCount) 项待处理")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.warn)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(AIATheme.warn.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.leading, 2)
    }

    /// 问候语随机 emoji（每次启动从池中随机选一个，不随界面刷新变化）
    private static let greetingEmoji: String = {
        ["👋", "😊", "🌟", "☀️", "✨", "🎉", "💪", "🫡", "👍", "🔥", "🌸", "🍀", "🥳", "😎"].randomElement() ?? "👋"
    }()

    /// 好记AI头像：app icon (AIAvatar) 圆形裁剪 + 呼吸脉冲动画（2.5s 循环胀缩）
    private var abaoAvatar: some View {
        Button {
            router.navigate(.myAccount)
        } label: {
            Image("AIAvatar")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .scaleEffect(abaoPulse ? 1.12 : 1.0)
        }
        .proAvatarBadge(isPro: ent.isPro, badgeDiameter: 14)
        .frame(width: 44, height: 44)
        .buttonStyle(.plain)
        .onAppear {
            // 收敛动画：老芯片(A12/XS Max)上自定义 repeatForever 缩放会持续触发 IOSurface 合成，
            // 导致整页渲染抖动。改为仅入场时呼吸 2 次（约 5s）后静止；reduceMotion 开启时不播。
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            withAnimation(.easeInOut(duration: 2.5).repeatCount(2, autoreverses: true)) {
                abaoPulse = true
            }
        }
    }

    /// 冷启动同步指示器：仅当本地无数据且首次同步尚未完成时显示。
    /// 告诉用户「数据正在路上，请稍等片刻」，避免看到空数据时感到疑惑。
    private var syncHeaderIndicator: some View {
        // 核心逻辑：showSyncIndicator 在同步完成后变为 false；
        // @Query 结果（foods/bills/reminders）有任一类数据说明本地不全空 → 无需提示
        let shouldShow = showSyncIndicator
            && foods.isEmpty
            && bills.isEmpty
            && reminders.isEmpty
        return Group {
            if shouldShow {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("正在同步数据，请稍等…")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.sub)
                    Spacer()
                }
                .padding(8)
                .foregroundStyle(AIATheme.sub)
            }
        }
    }

    /// 应用内公告横条（方案 B 群发通知）：云端配置生效后，所有用户打开 App 在首页顶部看到。
    /// 已读去重：用 lastSeenAnnouncementID 记已展示过的公告 id，避免每次回前台重复弹。
    private var announcementBanner: some View {
        let lastSeen = UserDefaults.standard.string(forKey: "aia.lastSeenAnnouncementID")
        // 仅当：有公告 + 生效中 + id 未读
        let ann = global.announcement
        let showable = (ann != nil) && ann!.isEffective && (ann!.id != lastSeen)
        return Group {
            if showable, let a = ann {
                ZStack(alignment: .leading) {
                    HStack(spacing: 10) {
                        Image(systemName: "megaphone.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AIATheme.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title)
                                .font(AIATheme.Font.subhead.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(a.body)
                                .font(AIATheme.Font.caption)
                                .foregroundStyle(AIATheme.sub)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        if a.link?.nonEmpty != nil || a.route?.nonEmpty != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AIATheme.muted)
                        }
                    }
                    .padding(12)
                }
                .background(AIATheme.purple.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .stroke(AIATheme.purple.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                .contentShape(Rectangle())   // ZStack 几何撑满整条，空白区也能响应点击
                // 本环境自定义 Button(action:) 闭包不派发，改用 .onTapGesture 触发跳转
                .onTapGesture {
                    // 标记已读，避免重复弹；写后本子视图会从视图树移除
                    UserDefaults.standard.set(a.id, forKey: "aia.lastSeenAnnouncementID")
                    let link = a.link?.nonEmpty
                    let route = a.route?.nonEmpty
                    let openMode = a.openMode ?? "inApp"
                    if let l = link, let url = URL(string: l), UIApplication.shared.canOpenURL(url) {
                        if openMode == "browser" {
                            UIApplication.shared.open(url)          // 跳系统浏览器
                        } else {
                            presentInAppBrowser(url)               // App 内打开（默认，UIKit 直弹）
                        }
                    } else if let r = route {
                        consumeNotificationRoute(r)
                    }
                }
            }
        }
    }

    // MARK: - 可配置首页渲染（分段渲染器 + 编辑态）
    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    /// 把模块序列按 layout 切成连续段：连续 gridCard 合一段、fullRow 自成一段。
    private func chunkModules(_ modules: [HomeModule]) -> [(HomeModuleLayout, [HomeModule])] {
        var result: [(HomeModuleLayout, [HomeModule])] = []
        var i = 0
        while i < modules.count {
            let layout = modules[i].layout
            var seg: [HomeModule] = [modules[i]]
            var j = i + 1
            while j < modules.count && modules[j].layout == layout {
                seg.append(modules[j]); j += 1
            }
            result.append((layout, seg))
            i = j
        }
        return result
    }

    @ViewBuilder
    private func tileView(for m: HomeModule, gridIndex: Int) -> some View {
        switch m {
        case .diet:
            DietTileView(gridIndex: gridIndex,
                         todayCalories: todayCalories,
                         todayWater: todayWater,
                         homeEnterToken: homeEnterToken,
                         foods: foods,
                         context: context,
                         onTap: { [self] in
                             if let t = longPressEnteredEditAt, Date().timeIntervalSince(t) < 0.5 {
                                 longPressEnteredEditAt = nil
                                 return
                             }
                             router.navigate(.diet)
                         },
                         coldPlayPending: coldPlayPending)
        case .health:
            HealthTileView(gridIndex: gridIndex,
                           stepGoal: stepGoal,
                           sleepGoalHours: sleepGoalHours,
                           healths: healths,
                           sleeps: sleeps,
                           homeEnterToken: homeEnterToken,
                           context: context,
                           onTap: { [self] in
                               if let t = longPressEnteredEditAt, Date().timeIntervalSince(t) < 0.5 {
                                   longPressEnteredEditAt = nil
                                   return
                               }
                               router.navigate(.health)
                           },
                           coldPlayPending: coldPlayPending,
                           showSleepMask: $showSleepMask)
        case .bill:      billTile(gridIndex: gridIndex)
        case .todo:      todoTile(gridIndex: gridIndex)
        case .aiSummary: AISummarySectionView(foods: foods, bills: bills, reminders: reminders,
                                            stepGoal: stepGoal,
                                            healths: healths)
        }
    }

    @ViewBuilder
    private func fullRowView(for m: HomeModule) -> some View {
        switch m {
        case .aiSummary: AISummarySectionView(foods: foods, bills: bills, reminders: reminders,
                                            stepGoal: stepGoal,
                                            healths: healths)
        default:         EmptyView()
        }
    }

    /// 长按任意模块进入编辑态。maximumDistance:10 限制位移，避免滚动时误触（与 SelectableRow 一致的成熟做法）。
    private var longPressToEnterEdit: some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
            .onEnded { _ in
                guard !isEditing else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                // 记下此刻：松手时宫格 Button 的 tap 会随之触发，0.5s 内的这次跳转需吞掉
                longPressEnteredEditAt = Date()
                // 拍下进入编辑态前的布局快照，供退出时回滚（见编辑/完成按钮与 X 按钮逻辑）
                preEditLayout = layout.snapshot()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isEditing = true
                    toolbarExpanded = true   // 展开工具栏，让「完成」按钮可见，用户能退出编辑态
                    draggingModule = nil
                }
            }

    }

    /// 非 Pro 用户在编辑态退出（点完成 / 点 X / 关闭 App）时，回滚进入编辑前的布局快照。
    /// setHidden/relocate 在编辑操作瞬间已写 UserDefaults，必须用进入前的快照才能还原。
    /// 返回是否发生了回滚（用于决定是否需要弹订阅页 / 退出编辑态）。
    @discardableResult
    private func rollbackNonProEditIfNeeded(showPaywallWhenRollback: Bool = false) -> Bool {
        guard isEditing, !ent.isFullAccess else { return false }
        if let snap = preEditLayout { layout.restore(snap) }
        preEditLayout = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isEditing = false
            draggingModule = nil
        }
        if showPaywallWhenRollback { showPaywall = true }
        return true
    }

    /// 正常态：按 order 分段渲染，连续 gridCard 合进一个 LazyVGrid，遇 fullRow 先渲网格再渲整行。
    private var homeModulesView: some View {
        let visible = layout.visibleModules()
        let chunks = chunkModules(visible)
        return Group {
            if visible.isEmpty {
                emptyModulesPlaceholder
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        if chunk.0 == .gridCard {
                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(Array(chunk.1.enumerated()), id: \.element) { gi, m in
                                    siriHighlighted(m, animatedTile(gi, tile: tileView(for: m, gridIndex: gi)))
                                        .simultaneousGesture(longPressToEnterEdit)
                                }
                            }
                            // 极短延迟（≈1 帧）：确保首帧以「隐藏态」(opacity0/下移/微缩) 渲染，
                            // 给入场动画一个起点。否则 .task 在同事务内立即置 true，SwiftUI 会把它
                            // 当作初始布局而非状态变化 → 弹簧动画被吞掉（即「之前有动画现在没有了」的根因）。
                            // 早期用 60ms + 0.55s 弹簧 + 索引延迟≈0.8s，用户嫌「加载那么久才显示」，
                            // 故这里只留 1 帧级延迟，配合下方更快的弹簧，既恢复动画又几乎无等待感。
                            // 2026-07-30 同步递增 homeEnterToken：让两个 MiniBar.resetToken 监听后
                            // 把 drawn 强制归 0 并重新播放生长动画，覆盖「从其他页面返回首页」场景。
                            // 修复：iOS 18 上 .task 会在父 body 重算导致子视图身份变化时反复重启，
                            // 旧的 .onDisappear{animateTiles=false} 会让入场弹簧被反复重置 → 整页跳动循环。
                            // 这里加幂等守卫（已播过就不再重启），且入场动画只播一次、不依赖 onDisappear 重置。
                            // 修复（2026-08-11）：homeEnterToken 不再放在 ScrollView 内部子视图的 .onAppear 里递增，
                            // 因为 iOS 18 上父 body 重算导致 ScrollView 内子视图布局变化时，.onAppear 会被反复触发，
                            // 形成「homeEnterToken 自增 → 根 body 重算 → 子视图 onAppear 再触发 → 再自增」死循环，
                            // 在 XS Max(A12) 上表现为整页自动上下滑往复。
                            // 现改为只在根视图 performOnAppear（首次挂载）+ didBecomeActive（回前台）+ 路由下降沿（返回首页）
                            // 各递增一次，彻底断掉循环。
                            .id("homeModulesGrid")
                            .task {
                                guard !animateTiles else { return }
                                try? await Task.sleep(nanoseconds: 16_000_000)
                                animateTiles = true
                            }
                        } else {
                            ForEach(chunk.1, id: \.self) { m in
                                fullRowView(for: m)
                                    .simultaneousGesture(longPressToEnterEdit)
                            }
                        }
                    }
                }
            }
        }
        // 注意：入场动画只播一次，不再用 .onDisappear 重置 animateTiles，
        // 否则 iOS 18 上子视图因布局抖动被判消失→重建会反复重播弹簧，整页跳动。
    }

    /// 编辑态：按与正常态相同的分段逻辑渲染——连续 gridCard 进一个 2 列 LazyVGrid，fullRow（事项预览）直接在 VStack 里全宽渲染（不进 grid、不依赖 gridCellColumns，规避与 .onDrag/.onDrop 手势容器冲突），支持拖拽重排 + 隐藏 + 添加。
    private var homeModulesEditView: some View {
        let visible = layout.visibleModules()
        let chunks = chunkModules(visible)
        return Group {
            if visible.isEmpty {
                emptyModulesPlaceholder
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        if chunk.0 == .gridCard {
                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(chunk.1, id: \.self) { m in
                                    moduleEditCard(for: m)
                                        .onDrag {
                                            draggingModule = m
                                            return NSItemProvider(item: nil, typeIdentifier: UTType.item.identifier)
                                        }
                                        .onDrop(of: [UTType.item.identifier],
                                                delegate: ModuleDropDelegate(item: m,
                                                                             dragging: $draggingModule,
                                                                             layout: layout))
                                }
                            }
                        } else {
                            ForEach(chunk.1, id: \.self) { m in
                                moduleEditCard(for: m)
                                    .onDrag {
                                        draggingModule = m
                                        return NSItemProvider(item: nil, typeIdentifier: UTType.item.identifier)
                                    }
                                    .onDrop(of: [UTType.item.identifier],
                                            delegate: ModuleDropDelegate(item: m,
                                                                         dragging: $draggingModule,
                                                                         layout: layout))
                            }
                        }
                    }
                    addModuleBar
                }
            }
        }
    }

    /// 编辑态拖拽：进入目标模块区域即实时重排（B 平滑让位），松手仅清状态。
    private struct ModuleDropDelegate: DropDelegate {
        let item: HomeModule
        @Binding var dragging: HomeModule?
        let layout: HomeLayoutStore

        /// 进入目标格子即实时重排，并加弹簧动画 → B 平滑让位
        func dropEntered(info: DropInfo) {
            guard let dragged = dragging, dragged != item else { return }
            // 每次换位给一次 selection 轻点反馈，贴合系统重排手感
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                layout.relocate(dragged, relativeTo: item)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        /// 松手：清空拖拽态（此时顺序已被 dropEntered 定好）
        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            return true
        }
    }

    @ViewBuilder
    private func moduleEditCard(for m: HomeModule) -> some View {
        ZStack(alignment: .topLeading) {
            tileOrRowContent(for: m)
            // 编辑态吞掉原卡片的点击跳转（原 tile 是 Button），但 − 按钮盖在上方仍可点。
            // 玻璃只盖卡片主体，右上角留出 ~56×56 通道给睡眠/饮水/隐私眼小按钮，避免被玻璃吞掉点不动。
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .allowsHitTesting(true)
                    Color.clear
                        .frame(width: 56, height: 56)
                        .allowsHitTesting(false)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .allowsHitTesting(true)
            }
            minusButton(for: m)
        }
        .frame(maxWidth: .infinity)
        .modifier(ShakeModifier(active: true))
    }

    @ViewBuilder
    private func tileOrRowContent(for m: HomeModule, gridIndex: Int = 0) -> some View {
        switch m {
        case .aiSummary: AISummarySectionView(foods: foods, bills: bills, reminders: reminders,
                                            stepGoal: stepGoal,
                                            healths: healths)
        default:         tileView(for: m, gridIndex: gridIndex)
        }
    }



    private func minusButton(for m: HomeModule) -> some View {
        Button {
            // 移除模块时给轻震动反馈
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                layout.setHidden(m, true)
            }
        } label: {
            Image(systemName: "minus.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, AIATheme.expense)
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .padding(6)
        .offset(x: -6, y: -6)
    }

    private var emptyModulesPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.largeTitle)
                .foregroundStyle(AIATheme.muted)
            Text("暂无可显示模块")
                .font(AIATheme.Font.callout.weight(.medium))
                .foregroundStyle(AIATheme.sub)
            Text("点下方「添加模块」恢复，或在设置 → 首页布局中恢复默认。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            addModuleBar
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(AIATheme.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
    }

    private var addModuleBar: some View {
        let hiddenOnes = HomeModule.allCases.filter { layout.isHidden($0) }
        return VStack(alignment: .leading, spacing: 8) {
            if hiddenOnes.isEmpty {
                Text("所有模块均已显示")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            } else {
                Text("已隐藏模块（点按恢复）")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(hiddenOnes) { m in
                        Button {
                            // 新增（恢复）模块时给轻震动反馈
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                layout.setHidden(m, false)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(m.accent)
                                Text(m.title)
                            }
                            .font(AIATheme.Font.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(m.accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 编辑态抖动效果
    private struct ShakeModifier: ViewModifier {
        var active: Bool
        @State private var on = false
        func body(content: Content) -> some View {
            content
                .rotationEffect(.degrees(active ? (on ? 0.8 : -0.8) : 0))
                .animation(active ? .easeInOut(duration: 0.16).repeatForever(autoreverses: true) : .default, value: on)
                .onAppear { if active { on = true } }
                .onChange(of: active) { _, v in on = v }
        }
    }

    /// 给单个宫格卡片加进入动画：先透明、下方偏移、微缩，再按索引延迟展开。
    private func animatedTile(_ idx: Int, tile: some View) -> some View {
        tile
            .opacity(animateTiles ? 1 : 0)
            .offset(y: animateTiles ? 0 : 20)
            .scaleEffect(animateTiles ? 1 : 0.96)
            .animation(
                .spring(response: 0.4, dampingFraction: 0.8)
                    .delay(Double(idx) * 0.04),
                value: animateTiles
            )
    }

    /// Siri 记完后首页卡片高亮：被点亮的模块描边 + 轻微放大脉冲 +
    /// 外沿「逐渐点亮绕一圈」扫描效果（亮弧沿圆角矩形周长行进一圈），2.2s 后复位。
    private func siriHighlighted(_ m: HomeModule, _ content: some View) -> some View {
        let active = siriHighlightModule == m
        return content
            .scaleEffect(active ? 1.04 : 1.0)
            // ① 静态实色描边（锚定卡片轮廓）
            .overlay(
                RoundedRectangle(cornerRadius: AIATheme.rLG)
                    .stroke(m.accent, lineWidth: active ? 3 : 0)
            )
            // ② 沿边逐渐点亮的扫描弧：trim 的 to 从 0→1，亮弧扫过整圈
            .overlay(
                RoundedRectangle(cornerRadius: AIATheme.rLG)
                    .trim(from: 0, to: active ? siriHighlightProgress : 0)
                    .stroke(
                        m.accent,
                        style: StrokeStyle(lineWidth: active ? 4 : 0, lineCap: .round)
                    )
                    .animation(
                        active
                            ? .linear(duration: 1.4)
                            : .default,
                        value: siriHighlightProgress
                    )
            )
            // ③ 扫描头拖尾：一小段更亮的弧跟着进度走，做出"点亮余辉"
            .overlay(
                RoundedRectangle(cornerRadius: AIATheme.rLG)
                    .trim(from: max(0, siriHighlightProgress - 0.12), to: siriHighlightProgress)
                    .stroke(
                        m.accent.opacity(0.55),
                        style: StrokeStyle(lineWidth: active ? 4 : 0, lineCap: .round)
                    )
                    .animation(
                        active
                            ? .linear(duration: 1.4)
                            : .default,
                        value: siriHighlightProgress
                    )
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: siriHighlightModule)
    }

    // MARK: 饮食
    /// 抽成独立 View 结构体并局部 @ObservedObject HomeHealthData.shared：让「卡路里目标(来自 HealthKit
    /// TDEE)」随 HealthKit 回刷实时更新进度条/建议，而不把整页 ContentView 订阅到健康发布器。
    /// 与 HealthTileView 同理，仅本子视图随健康数据重算。
    fileprivate struct DietTileView: View {
        let gridIndex: Int
        let todayCalories: Double
        let todayWater: Double
        let homeEnterToken: Int
        let foods: [FoodEntry]
        let context: ModelContext
        let onTap: () -> Void
        // >>> CHANGE-[2026-08-18 15:04:36]-[coldPlayPending透传进嵌套TileView] 开始
        // 原因: coldPlayPending 是 ContentView 的 @State 实例成员，嵌套子结构体访问不到，
        //       改为通过构造参数值透传(与 homeEnterToken 同套路)；值来源/改写时机/刷新链不变，
        //       冷启动(true→1.5s)与热启动(false→0.3s)生长动画行为完全保持。
        // 回退: 删本行 + 调用处 coldPlayPending: coldPlayPending + 1551行改回 coldStart: coldPlayPending 引用外层(不可行)。
        let coldPlayPending: Bool
        // <<< CHANGE-[2026-08-18 15:04:36]-[coldPlayPending透传进嵌套TileView] 结束

        @ObservedObject private var hd = HomeHealthData.shared

        var body: some View {
            ContentView.tile(bg: AIATheme.dietBG, accent: AIATheme.food, icon: "fork.knife",
                 title: "饮食记录",
                 badge: TileBadge(text: "", warn: false),
                 number: "\(Int(todayCalories))", unit: "kcal",
                 isEmpty: foods.isEmpty,
                 gridIndex: gridIndex,
                 onTap: onTap,
                 topTrailingAccessory: {
                    ContentView.makeWaterCupButton(context: context)
                 }) {
                VStack(alignment: .leading, spacing: 8) {
                    MiniBar(value: hd.calorieGoal > 0 ? todayCalories / hd.calorieGoal : 0, color: AIATheme.food, height: 5, delay: 0, resetToken: homeEnterToken, coldStart: coldPlayPending)
                    VStack(alignment: .leading, spacing: 5) {
                        ContentView.calSummaryRow(NSLocalizedString("home.diet.calorieSuggestion", comment: ""), "\(Int(hd.calorieGoal)) kcal", AIATheme.sub)
                        ContentView.calSummaryRow(todayCalories > hd.calorieGoal ? "已超" : "还可摄入",
                                      "\(max(0, Int(abs(hd.calorieGoal - todayCalories)))) kcal",
                                      todayCalories > hd.calorieGoal ? AIATheme.over : AIATheme.sub)
                        ContentView.calSummaryRow("饮水量",
                                      "\(Int(todayWater)) ml",
                                      AIATheme.food)
                    }
                }
            }
        }
    }

    fileprivate static func calSummaryRow(_ label: String, _ value: String, _ valueColor: Color) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AIATheme.sub)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor)
        }
        .font(AIATheme.Font.micro)
        .lineLimit(1)
    }

    /// 饮食宫格右上角「小水杯」按钮：呼吸光环 + 点击 +100ml。
    /// 写入 WaterLog(date:.now, amount:100)，与饮食记录页 addWaterTap 同模型、同 @Query，数据自动互通。
    /// 抽成 fileprivate 自由函数：DietTileView（独立子视图）也要复用，但拿不到根视图的 context，
    /// 故通过参数传入。
    fileprivate static func makeWaterCupButton(context: ModelContext) -> AnyView {
        AnyView(
            WaterCupButton {
                let log = WaterLog(date: .now, amount: 100)
                context.insert(log)
                // 解耦后 context 经参数传入独立子视图，纯 insert 在 iOS 17 上不一定即时触发
                // 根视图 @Query 刷新；显式 save 强制提交并广播变更，宫格饮水量立即 +100ml。
                try? context.save()
                #if DEBUG
                print("💧 [水杯] +100ml 已入库 syncId=\(log.syncId)")
                #endif
                CloudSyncManager.shared.syncAfterLocalChange(context: context)
            }
        )
    }

    /// 饮食宫格右上角水杯按钮：呼吸光环提示可点，点击弹跳 + 震动 + +100ml 飞出动画。
    private struct WaterCupButton: View {
        let onTap: () -> Void

        @State private var bounceTick = 0
        @State private var flyOffset: CGFloat = 0
        @State private var flyOpacity: Double = 0

        private let accent = AIATheme.food   // 琥珀色，与饮食模块同色

        var body: some View {
            Button {
                bounceTick += 1
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                flyOffset = 0
                flyOpacity = 1
                withAnimation(.easeOut(duration: 0.9)) {
                    flyOffset = -34
                    flyOpacity = 0
                }
                onTap()
            } label: {
                ZStack {
                    // ① 底圈：浅色圆底（保留，作为图标衬底）
                    Circle()
                        .fill(accent.opacity(0.16))
                        .frame(width: 26, height: 26)

                    // ② 玻璃杯图标（mug.fill 在 iOS 17.0 即存在）
                    // 用系统 symbolEffect(.pulse) 替代自定义 repeatForever 呼吸光环：
                    // 老芯片(A12/XS Max)上自定义无限动画会触发 IOSurface 合成失败导致整页渲染抖动，
                    // 系统符号脉冲不挂自定义合成层，对老芯片友好，且同样暗示"可点击"。
                    // reduceMotion 开启时跳过脉冲，避免眩晕。
                    Image(systemName: "mug.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .symbolEffect(.bounce, value: bounceTick)
                        .if(!UIAccessibility.isReduceMotionEnabled) { $0.symbolEffect(.pulse) }

                    // ③ +100ml 飞出动画：点击后向上飘移并淡出
                    Text("+100ml")
                        .font(AIATheme.Font.micro.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(y: flyOffset)
                        .opacity(flyOpacity)
                }
                .frame(width: 30, height: 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("喝水 +100ml")
            .accessibilityHint("轻点两下记录 100 毫升饮水")
        }
    }

    // MARK: 睡眠时长（替代原宫格的「静息心率」项）
    @AppStorage("aia.sleepGoalHours") private var sleepGoalHours: Double = 8
    /// 睡眠时长（小时）：与健康管理页睡眠圆环保持同源——
    /// 自动模式 → HealthKit 数据（healths「睡眠」值，由 HealthKit 同步写入）；
    /// 手动模式 → 睡眠圆环「总数值」（manualSleepTotalHours：历史残留 + 圆环点击累加 + 当天已醒 SleepSession 累计）。
    /// 用户在健康页改睡眠数据来源会即时反映到此处。
    private var sleepLastNightHours: Double {
        if HomeHealthData.shared.isAuto(.sleep) {
            return healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0
        }
        return manualSleepTotalHours(sleeps: sleeps, healths: healths, on: Date())
    }
    private var sleepRowText: String {
        guard sleepLastNightHours > 0 else { return "—" }
        let totalMin = Int(sleepLastNightHours * 60)
        let h = totalMin / 60
        let m = totalMin % 60
        let met = sleepGoalHours > 0 && sleepLastNightHours >= sleepGoalHours
        return String(format: "%dh%dm%@", h, m, met ? " · 达标" : "")
    }
    private var sleepRowColor: Color {
        guard sleepLastNightHours > 0, sleepGoalHours > 0 else { return AIATheme.sub }
        return sleepLastNightHours >= sleepGoalHours ? AIATheme.health : AIATheme.warning
    }

    // MARK: 健康
    /// 健康宫格是否为空：手动 HealthMetric 表为空，且宫格展示的四项指标（步数/运动时长/
    /// 能量消耗/睡眠时长，自动模式下均来自 HealthKit）全为 0，才算真正无数据。
    private var isHealthTileEmpty: Bool {
        guard healths.isEmpty else { return false }
        if HomeHealthData.shared.homeSteps > 0 { return false }
        if HomeHealthData.shared.homeExerciseMin > 0 { return false }
        if HomeHealthData.shared.homeEnergyBurned > 0 { return false }
        if sleepLastNightHours > 0 { return false }
        return true
    }

    // MARK: 健康管理宫格（独立子视图）
    /// 抽成独立 View 结构体并局部 @ObservedObject HomeHealthData.shared：HealthKit 授权/后台回刷
    /// 改写步数/运动/能量/睡眠时，只重算本子视图（不波及整页 ContentView.body），彻底切断
    /// 原来「healthTile 是 ContentView 的 private func + 内部 .onReceive(HealthManager…)」把整页
    /// 根视图订阅到 HealthManager 每秒发布器、导致整页每 1~2 秒循环重算的死循环。
    /// HomeHealthData 已转发 HealthManager.objectWillChange，故本子视图自动随 HealthKit 刷新。
    fileprivate struct HealthTileView: View {
        let gridIndex: Int
        let stepGoal: Int
        let sleepGoalHours: Double
        let healths: [HealthMetric]
        let sleeps: [SleepSession]
        let homeEnterToken: Int
        let context: ModelContext
        let onTap: () -> Void
        // >>> CHANGE-[2026-08-18 15:04:36]-[coldPlayPending透传进嵌套TileView] 开始
        // 原因: 同 DietTileView，coldPlayPending 需从 ContentView 透传进本嵌套子结构体。
        // 回退: 删本行 + 调用处 coldPlayPending: coldPlayPending。
        let coldPlayPending: Bool
        // <<< CHANGE-[2026-08-18 15:04:36]-[coldPlayPending透传进嵌套TileView] 结束
        @Binding var showSleepMask: Bool

        @ObservedObject private var hd = HomeHealthData.shared

        private var isHealthTileEmpty: Bool {
            guard healths.isEmpty else { return false }
            if hd.homeSteps > 0 { return false }
            if hd.homeExerciseMin > 0 { return false }
            if hd.homeEnergyBurned > 0 { return false }
            if sleepLastNightHours > 0 { return false }
            return true
        }
        private var sleepLastNightHours: Double {
            if hd.isAuto(.sleep) {
                return healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0
            }
            return manualSleepTotalHours(sleeps: sleeps, healths: healths, on: Date())
        }
        private var exerciseTimeText: String {
            "\(Int(hd.homeExerciseMin)) min"
        }
        private var sleepRowText: String {
            guard sleepLastNightHours > 0 else { return "—" }
            let totalMin = Int(sleepLastNightHours * 60)
            let h = totalMin / 60
            let m = totalMin % 60
            let met = sleepGoalHours > 0 && sleepLastNightHours >= sleepGoalHours
            return String(format: "%dh%dm%@", h, m, met ? " · 达标" : "")
        }
        private var sleepRowColor: Color {
            guard sleepLastNightHours > 0, sleepGoalHours > 0 else { return AIATheme.sub }
            return sleepLastNightHours >= sleepGoalHours ? AIATheme.health : AIATheme.warning
        }
        private var sparkBars: some View {
            MiniBar(value: stepGoal > 0 ? Double(hd.homeSteps) / Double(stepGoal) : 0,
                    color: AIATheme.health,
                    height: 5,
                    delay: 0.08,
                    resetToken: homeEnterToken,
                    coldStart: coldPlayPending)
        }

        var body: some View {
            ContentView.tile(bg: AIATheme.healthBG, accent: AIATheme.health, icon: "heart.fill",
                 title: "健康管理",
                 badge: TileBadge(text: hd.homeSteps >= stepGoal ? "达标" : "", warn: false),
                 number: "\(hd.homeSteps)", unit: "步",
                 isEmpty: isHealthTileEmpty,
                 gridIndex: gridIndex,
                 onTap: onTap,
                 topTrailingAccessory: {
                    ContentView.makeSleepStatusButton(sleeps: sleeps, showSleepMask: $showSleepMask,
                                          context: context)
                 }) {
                VStack(alignment: .leading, spacing: 8) {
                    sparkBars
                    VStack(alignment: .leading, spacing: 5) {
                        ContentView.healthSummaryRow("能量消耗", hd.homeEnergyBurned > 0 ? "\(Int(hd.homeEnergyBurned)) kcal" : "—", AIATheme.sub)
                        ContentView.healthSummaryRow("运动时长", exerciseTimeText, AIATheme.sub)
                        ContentView.healthSummaryRow("睡眠时长", sleepRowText, sleepRowColor)
                    }
                }
            }
        }
    }


    fileprivate static func healthSummaryRow(_ label: String, _ value: String, _ valueColor: Color) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AIATheme.sub)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor)
        }
        .font(AIATheme.Font.micro)
        .lineLimit(1)
    }

    private var exerciseTimeText: String {
        "\(Int(HomeHealthData.shared.homeExerciseMin)) min"
    }

    // MARK: 账单
    private func billTile(gridIndex: Int) -> some View {
        // 隐私遮罩：隐藏时所有金额显示 ¥•••，颜色降级为 muted（避免被猜出正负/位数）
        let hiddenText = "¥•••"
        let numberTxt = billHidden ? hiddenText : "¥\(Int(todayExpense))"
        let incomeTxt = billHidden ? hiddenText : "¥\(Int(monthIncome))"
        let expenseTxt = billHidden ? hiddenText : "¥\(Int(monthExpense))"
        let budgetTxt = billHidden ? hiddenText : "¥\(Int(monthlyBudget))"
        let balanceTxt = billHidden ? hiddenText : "¥\(Int(monthBalance))"
        let balanceColor: Color = billHidden
            ? AIATheme.muted
            : (monthBalance >= 0 ? AIATheme.income : AIATheme.expense)

        return ContentView.tile(bg: AIATheme.billBG, accent: AIATheme.bill, icon: "creditcard.fill",
             title: "账单管理",
             badge: TileBadge(text: "", warn: false),
             number: numberTxt, unit: "今日支出",
             isEmpty: bills.isEmpty,
             gridIndex: gridIndex,
             headerMode: .titleLine,
             onTap: { [self] in
                if let t = longPressEnteredEditAt, Date().timeIntervalSince(t) < 0.5 {
                    longPressEnteredEditAt = nil
                    return
                }
                router.navigate(.bill)
             },
             topTrailingAccessory: {
                privacyEyeButton
             }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    billMetric("本月收入", incomeTxt, billHidden ? AIATheme.muted : AIATheme.income)
                    billMetric("本月支出", expenseTxt, billHidden ? AIATheme.muted : AIATheme.expense)
                }
                HStack(spacing: 8) {
                    billMetric("本月预算", budgetTxt, AIATheme.sub)
                    billMetric("本月结余", balanceTxt, balanceColor)
                }
            }
            .padding(.top, 4)
        }
    }

    /// 账单宫格右上角隐私按钮：眼睛/闭眼切换，30×30 hit area 不吞父卡片点击
    private var privacyEyeButton: AnyView {
        AnyView(
            Button { billHidden.toggle() } label: {
                Image(systemName: billHidden ? "eye.slash" : "eye")
                    .font(AIATheme.Font.micro.weight(.semibold))
                    .foregroundStyle(billHidden ? AIATheme.bill : AIATheme.muted)
                    .frame(width: 30, height: 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        )
    }

    /// 自动恢复睡眠遮罩：仅当「有进行中的睡眠会话」且「本次会话用户没主动收起过」时盖上。
    /// 超过 maxAutoRestoreHours 的会话视为「忘了点醒来的孤儿数据」，不再盖遮罩打扰用户
    /// （宫格图标仍是 🌙，用户可自行点它结束会话）。
    private func restoreSleepMaskIfNeeded() {
        guard !showSleepMask else {
            #if DEBUG
            print("[SleepMask] 恢复检查跳过：遮罩已显示")
            #endif
            return
        }
        guard let active = currentActiveSleepSession(in: sleeps) else {
            #if DEBUG
            print("[SleepMask] 恢复检查跳过：无活跃会话（sleeps 可能尚未刷新）")
            #endif
            return
        }
        guard sharedSleepMaskDismissedSessionID != active.syncId else {
            #if DEBUG
            print("[SleepMask] 恢复检查跳过：本次会话用户已主动收起")
            #endif
            return
        }
        let maxAutoRestoreHours: Double = 14
        guard Date().timeIntervalSince(active.sleepStart) < maxAutoRestoreHours * 3600 else {
            #if DEBUG
            print("[SleepMask] 恢复检查跳过：会话超 \(maxAutoRestoreHours)h 视为孤儿")
            #endif
            return
        }
        #if DEBUG
        print("[SleepMask] ✅ 恢复遮罩，session=\(active.syncId)")
        #endif
        withAnimation(.easeOut(duration: 0.35)) { showSleepMask = true }
    }

    /// 醒来后 @Query 快照里活跃会话可能已被 toggle 写成 wakeAt!=nil，
    /// 此时 currentActiveSleepSession 取不到 sleepStart。用实时 fetch 兜底取最新一条会话的入睡时刻。
    static func activeSleepSessionStartFallback(context: ModelContext) -> Date {
        (try? context.fetch(FetchDescriptor<SleepSession>(
            predicate: #Predicate { !$0.syncDeleted },
            sortBy: [SortDescriptor(\SleepSession.sleepStart, order: .reverse)]
        )).first)?.sleepStart ?? Date()
    }

    /// 睡眠时长中文摘要（入睡时刻 → 现在），用于醒来后页面 toast 提示。
    /// 直接基于 sleepStart 计算，避免依赖 @Query 此刻是否已刷新（toggle 后数组可能仍是旧引用）。
    fileprivate static func sleepSummaryText(start: Date) -> String {
        let totalMin = Int(max(0, Date().timeIntervalSince(start)) / 60)
        return totalMin >= 60
            ? "本次睡眠 \(totalMin / 60) 小时 \(totalMin % 60) 分钟"
            : "本次睡眠 \(totalMin) 分钟"
    }

    /// 健康管理宫格右上角睡眠状态切换按钮：在睡=moon（琥珀），空闲=sun（紫）。
    /// 与 HealthListView 的 SleepToggleButton 共用 SleepSession 同一份数据，状态自动互通。
    /// 仿照 privacyEyeButton：内层 Button + .buttonStyle(.plain) 吞掉 tap 不冒泡到外层"跳健康页"。
    /// 抽成 fileprivate 自由函数：HealthTileView（独立子视图）也要复用，但拿不到根视图的
    /// @State(showSleepMask / sleepMaskDismissedSessionID)，故通过 Binding 传入。
    fileprivate static func makeSleepStatusButton(
        sleeps: [SleepSession],
        showSleepMask: Binding<Bool>,
        context: ModelContext
    ) -> AnyView {
        let isSleeping = currentActiveSleepSession(in: sleeps) != nil
        return AnyView(
            SleepStatusToggleIcon(isSleeping: isSleeping) {
                // toggle 返回切换后的真实结果：nil=刚醒来（之前在睡），非 nil=刚入睡（新建会话）。
                // 用返回值而非 wasSleeping 快照判断：@Query 闭包快照在 iCloud 同步/冷启动延迟时
                // 可能尚未包含活跃会话，导致误判 wasSleeping=false 而不弹 toast。
                let activeAfter = toggleSleepSession(in: context, sleeps: sleeps)   // 模型变更不包 withAnimation（项目铁律）
                let didWake = (activeAfter == nil)
                let start = currentActiveSleepSession(in: sleeps)?.sleepStart
                         ?? ContentView.activeSleepSessionStartFallback(context: context)
                // 醒来时页面提示本次睡眠时长（与遮罩「我醒了」同口径）。延后到遮罩淡出后弹，避免被盖住。
                if didWake {
                    let toastStart = start
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        ToastCenter.shared.showImportant(
                            ContentView.sleepSummaryText(start: toastStart),
                            icon: "🌙",
                            accent: AIATheme.warning
                        )
                    }
                }
                #if DEBUG
                print("[SleepMask] 宫格按钮 toggle 完成, didWake=\(didWake), activeAfter=\(activeAfter != nil)")
                #endif
                // 同步立刻设置遮罩：activeAfter != nil 说明现在在睡。不再 async 延迟，
                // 避免与 @Query 刷新竞争导致遮罩开关被吞。
                showSleepMask.wrappedValue = (activeAfter != nil)
                #if DEBUG
                print("[SleepMask] 宫格按钮 showSleepMask=\(showSleepMask.wrappedValue)")
                #endif
            }
        )
    }

    /// 首页「健康管理」宫格右上角的睡眠切换图标。
    /// 设计目标：既表达「当前是什么状态」，又持续暗示「这里可以点」。三层动效：
    /// ① 常驻呼吸光环——2s 循环向外扩散并淡出（雷达波），最直观的"可交互"信号；
    /// ② 每 4s 闪现一次对侧图标（☀︎ ⇄ ☾）停 0.9s 复位，预览态半透明 → 告诉用户"点我会切到那边"；
    /// ③ 点击瞬间 symbolEffect(.bounce) + .replace.downUp 过渡，反馈干脆。
    /// 颜色始终跟真实状态走（紫=醒着 / 琥珀=睡着），所以预览闪现不会让用户误判当前状态。
    ///
    /// 注意两点：
    /// - 不用 TimelineView 驱动（每秒重建视图会打断 repeatForever 动画），改 Timer.publish + onReceive；
    ///   .autoconnect() 的订阅在视图消失时自动取消，离开首页不会空转。
    /// - 符号切换用 .animation(value:) 而非 withAnimation 包裹，
    ///   这样点击导致的 isSleeping 变化（来自 SwiftData）也能有过渡，且不违反「不用 withAnimation 包模型变更」铁律。
    private struct SleepStatusToggleIcon: View {
        let isSleeping: Bool
        let onToggle: () -> Void

        /// 状态色：在睡=琥珀，空闲=紫（与健康页 SleepToggleButton 同源口径）
        private var accent: Color { isSleeping ? AIATheme.warning : AIATheme.health }
        /// 当前真实状态对应的符号
        private var stateSymbol: String { isSleeping ? "moon.fill" : "sun.max.fill" }
        /// 对侧符号（点一下会变成的样子）
        private var peerSymbol: String { isSleeping ? "sun.max.fill" : "moon.fill" }
        /// 此刻实际渲染的符号：预览期显示对侧，其余时间显示当前状态
        private var shownSymbol: String { previewing ? peerSymbol : stateSymbol }

        @State private var previewing = false  // 是否正在闪现对侧图标
        @State private var bounceTick = 0      // 点击弹跳触发器（值一变就 bounce 一次）

        /// 预览闪现的节拍：4s 一轮（仅做"图标瞬切对侧"提示可点击，不挂自定义渲染层，
        /// 不会像自定义 repeatForever 光环那样在老芯片上触发 IOSurface 合成失败）。
        /// reduceMotion 开启时不闪现，避免眩晕。
        private var peek: Publishers.Autoconnect<Timer.TimerPublisher>? {
            UIAccessibility.isReduceMotionEnabled ? nil : Timer.publish(every: 4, on: .main, in: .common).autoconnect()
        }

        /// 图标本体：用系统 symbolEffect(.pulse) 替代自定义 repeatForever 呼吸光环。
        /// reduceMotion 由系统 symbolEffect 自动降级（不会持续动效），故无需 `.if` 分支，
        /// 既符合无障碍语义也避免「.if 返回 some View + 长修饰符链」触发编译器
        /// "Failed to produce diagnostic" 类型推断崩溃（XS Max 实测整页抖动的元凶之一）。
        private var iconImage: some View {
            Image(systemName: shownSymbol)
                .font(AIATheme.Font.micro.weight(.semibold))
                .foregroundStyle(accent)
                .opacity(previewing ? 0.55 : 1)
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, value: bounceTick)
                .symbolEffect(.pulse)
                .animation(.easeInOut(duration: 0.3), value: shownSymbol)
                .animation(.easeInOut(duration: 0.3), value: previewing)
        }

        var body: some View {
            sleepToggleButton
        }

        /// 整个 Button 闭包 + .onReceive 抽成独立属性，避免主体 `var body` 表达式过长
        /// 触发编译器 "Failed to produce diagnostic" 类型推断崩溃。
        private var sleepToggleButton: some View {
            Button {
                previewing = false     // 立刻收起预览，避免和真实状态切换撞在一起
                bounceTick += 1
                onToggle()
            } label: {
                ZStack {
                    // ① 底圈：与原设计一致的浅色圆底
                    Circle()
                        .fill(accent.opacity(0.16))
                        .frame(width: 26, height: 26)

                    // ② 图标本体
                    // 用系统 symbolEffect(.pulse) 替代自定义 repeatForever 呼吸光环（老芯片整页抖动的元凶）：
                    // 同样暗示"可点击"，但系统符号脉冲不挂自定义 IOSurface 合成层，对 A12/XS Max 友好。
                    // reduceMotion 开启时系统自动降级为静态，无需手动分支。
                    iconImage
                }
                // 保持 30×30，与 privacyEyeButton 对齐；scaleEffect 不参与布局，光环溢出不会撑高标题行
                .frame(width: 30, height: 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSleeping ? "结束睡眠" : "开始睡眠")
            .accessibilityHint("轻点两下切换睡眠状态")
            .onReceive(peekPublisher) { _ in
                previewing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    previewing = false
                }
            }
        }

        /// peek 可能为 nil（reduceMotion 开启），统一擦除为 AnyPublisher 供 .onReceive 订阅，
        /// 避免 `peek ?? Empty(...)` 直接写在 body 链里加剧类型推断负担。
        private var peekPublisher: AnyPublisher<Date, Never> {
            let fallback = Empty<Date, Never>().eraseToAnyPublisher()
            guard let p = peek else { return fallback }
            return p.eraseToAnyPublisher()
        }
    }

    private func billMetric(_ label: String, _ value: String, _ valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            Text(value)
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 待办
    private func todoTile(gridIndex: Int) -> some View {
        ContentView.tile(bg: AIATheme.todoBG, accent: AIATheme.todo, icon: "checklist",
             title: "待办提醒",
             badge: TileBadge(text: "今日 \(todayTodos.count) 项", warn: false),
             number: "\(todayTodos.count)", unit: "今日待办",
             isEmpty: reminders.isEmpty,
             gridIndex: gridIndex,
             headerMode: .none,
             onTap: { [self] in
                 if let t = longPressEnteredEditAt, Date().timeIntervalSince(t) < 0.5 {
                     longPressEnteredEditAt = nil
                     return
                 }
                 router.navigate(.todo)
             }) {
            VStack(alignment: .leading, spacing: 6) {
                if recentTodos.isEmpty {
                    Text("暂无待办 👍")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                } else {
                    ForEach(recentTodos, id: \.persistentModelID) { r in
                        HStack(spacing: 4) {
                            Text("· \(r.title)").lineLimit(1).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            Text(todoTimeSuffix(r)).foregroundStyle(AIATheme.muted)
                        }
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 今日事项预览气泡（四条气泡固定展示，每条内部轮播各自内容）
    // 独立子视图持有 rollTimer/rollSlot：Timer 只驱动本区块重算，不再波及整个 ContentView（避免整页每 2 秒循环刷新）。
    private struct AISummarySectionView: View {
        let foods: [FoodEntry]
        let bills: [Bill]
        let reminders: [Reminder]
        // 步数目标（@AppStorage，非 HealthKit，由根传入快照即可）。
        let stepGoal: Int
        let healths: [HealthMetric]

        // 健康气泡所需的今日健康数据：局部订阅 HomeHealthData（转发 HealthManager），
        // HealthKit 回刷只重算本子视图的健康气泡，不波及整页 body（根视图已不再订阅 health）。
        // 仅订阅 HomeHealthData（转发 HealthManager）这一个对象：HealthKit 回刷只重算本子视图，
        // 且只经 hd 触发一次（不再额外直接订阅原始 HealthManager，避免重复订阅触发两次刷新）。
        @ObservedObject private var hd = HomeHealthData.shared
        @State private var rollSlot = 0
        // 气泡轮播：用 rollActive 控制是否推进槽位。首启后延后 0.5s 才置 true，
        // 避免首屏前 0.5s 抢 CPU（老机型首启卡顿来源之一）。定时器本身始终 autoconnect，
        // 但仅在 rollActive 为真时才切槽，避免在 rollActive 之前无谓触发 body 副作用。
        @State private var rollActive = false
        private let rollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
        // 文案计算缓存：diet/bill/todo 三条气泡的候选文案每次 body 重算都会对 1000 条数组
        // filter+sorted+reduce 重算，纯计算浪费大。改为 @State 缓存，仅在对应 @Query 数据真正
        // 变化时（.onChange）才重算，首屏/首拉期间不再每次 body 重算都重跑。
        @State private var cachedDiet: [String] = []
        @State private var cachedBill: [String] = []
        @State private var cachedTodo: [String] = []

        private var healthBubbleMessages: [String] {
            let stat = { (key: String) -> String in
                if key == "心率" {
                    if hd.isAuto(.heartRate), hd.restingHeartRate > 0 {
                        return "\(Int(hd.restingHeartRate))bpm"
                    }
                    let manual = ManualHealthStore.shared.restingHeartRate(for: Date())
                    if manual > 0 { return "\(manual)bpm" }
                }
                return healths.first(where: { $0.metric.contains(key) }).map { "\($0.value)\($0.unit)" } ?? "—"
            }
            let energyText = hd.homeEnergyBurned > 0 ? "\(Int(hd.homeEnergyBurned)) kcal" : "—"
            return [
                "健康管理 · 今日步数 \(hd.homeSteps)，距目标还差 \(max(0, stepGoal - hd.homeSteps))",
                "健康管理 · 运动时长 \(Int(hd.homeExerciseMin)) min",
                "健康管理 · 能量消耗 \(energyText)",
                "健康管理 · 静息心率 \(stat("心率"))"
            ]
        }

        var body: some View {
            // 优先用缓存；首次 onAppear 计算一次（缓存空时 fallback 当场算，保证首屏有内容）。
            let dietMsgs = cachedDiet.isEmpty ? AISummary.dietMessages(foods: foods) : cachedDiet
            let billMsgs = cachedBill.isEmpty ? AISummary.billMessages(bills: bills) : cachedBill
            let todoMsgs = cachedTodo.isEmpty ? AISummary.todoMessages(reminders: reminders) : cachedTodo
            let healthMsgs = healthBubbleMessages

            return VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "今日事项预览", trailing: "小记提醒")
                VStack(spacing: 8) {
                    ContentView.rollingBubble(messages: dietMsgs, accent: AIATheme.food, active: rollSlot == 0, route: .diet)
                    ContentView.rollingBubble(messages: healthMsgs, accent: AIATheme.health, active: rollSlot == 1, route: .health)
                    ContentView.rollingBubble(messages: billMsgs, accent: AIATheme.bill, active: rollSlot == 2, route: .bill)
                    ContentView.rollingBubble(messages: todoMsgs, accent: AIATheme.todo, active: rollSlot == 3, route: .todo)
                }
                .onReceive(rollTimer) { _ in
                    guard rollActive else { return }
                    rollSlot = (rollSlot + 1) % 4
                }
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                // 首屏首次计算，写入缓存；并延后 0.5s 启动轮播定时器，让首帧先稳住。
                #if DEBUG
                print("🔤 [调试] AISummary 初次计算文案 @\(Date().timeIntervalSince1970)")
                #endif
                cachedDiet = AISummary.dietMessages(foods: foods)
                cachedBill = AISummary.billMessages(bills: bills)
                cachedTodo = AISummary.todoMessages(reminders: reminders)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    rollActive = true
                }
            }
            .onChange(of: foods) { _, _ in
                #if DEBUG
                print("🔤 [调试] AISummary.foods 变化→重算 diet @\(Date().timeIntervalSince1970)")
                #endif
                cachedDiet = AISummary.dietMessages(foods: foods)
            }
            .onChange(of: bills) { _, _ in
                #if DEBUG
                print("🔤 [调试] AISummary.bills 变化→重算 bill @\(Date().timeIntervalSince1970)")
                #endif
                cachedBill = AISummary.billMessages(bills: bills)
            }
            .onChange(of: reminders) { _, _ in
                #if DEBUG
                print("🔤 [调试] AISummary.reminders 变化→重算 todo @\(Date().timeIntervalSince1970)")
                #endif
                cachedTodo = AISummary.todoMessages(reminders: reminders)
            }
        }
    }

    /// 单条气泡：当 `active` 为真（由外层调度器轮流指派）且候选 >1 时，像转轴一样向上滚动切换到下一条；气泡框本身不动。
    private static func rollingBubble(messages: [String], accent: Color, active: Bool, route: HomeRoute) -> some View {
        RollingBubbleView(messages: messages, accent: accent, active: active, route: route)
    }

    private struct RollingBubbleView: View {
        let messages: [String]
        let accent: Color
        let active: Bool
        let route: HomeRoute
        private let rowH: CGFloat = 18
        @State private var display = 0
        @State private var incoming = 0
        @State private var rolling = false

        private var count: Int { messages.count }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ZStack(alignment: .leading) {
                    bubbleText(text(at: display))
                        .offset(y: rolling ? -rowH : 0)
                    bubbleText(text(at: incoming))
                        .offset(y: rolling ? 0 : rowH)
                }
                .frame(height: rowH)
                .clipped()
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(AIATheme.surface)
            .overlay(alignment: .leading) {
                // 左侧类型色条（与首页圆点、各列表类型色一致）
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .onTapGesture {
                NavigationRouter.shared.navigate(route)
            }
            .onAppear { if active { roll() } }
            .onChange(of: active) { _, isActive in
                if isActive { roll() }
            }
        }

        private func text(at i: Int) -> String {
            guard !messages.isEmpty else { return "" }
            return messages[((i % count) + count) % count]
        }

        private func bubbleText(_ text: String) -> some View {
            Text(text)
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.sub)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: false)
        }

        private func roll() {
            guard count > 1 else { return }
            incoming = (display + 1) % count
            withAnimation(.easeInOut(duration: 0.5)) {
                rolling = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                display = incoming
                rolling = false
            }
        }
    }

    // MARK: - 单个宫格构造器

    /// 首页 2×2 宫格专用填充形状：外侧两角大圆角，朝网格中心的两角直角，
    /// 并向中心方向各伸出 6pt 凸条，把 12pt 间距的十字缝用卡片自身颜色填满
    /// （消除红框里那种「背景从圆角内侧透出的小三角缺口」）。
    /// gridIndex：0=左上 1=右上 2=左下 3=右下。
    private struct GridFillShape: Shape {
        var cornerRadius: CGFloat
        var gridIndex: Int
        var extend: CGFloat = 6   // 与 gridColumns 的 spacing(12) 的一半对应

        func path(in rect: CGRect) -> Path {
            let col = gridIndex % 2
            let row = gridIndex / 2
            let r = cornerRadius
            let w = rect.width
            let h = rect.height

            // 四角半径：仅「朝外」的两个角为 r，朝中心的两个角为 0（直角拼合无缝）
            let tl: CGFloat = (col == 0 && row == 0) ? r : 0
            let tr: CGFloat = (col == 1 && row == 0) ? r : 0
            let bl: CGFloat = (col == 0 && row == 1) ? r : 0
            let br: CGFloat = (col == 1 && row == 1) ? r : 0

            var p = Path()
            p.addPath(unevenRoundedRect(in: rect, tl: tl, tr: tr, bl: bl, br: br))
            // 朝中心方向伸凸条（填满相邻间距缝）
            if col == 0 {
                p.addPath(Rectangle().path(in: CGRect(x: w, y: 0, width: extend, height: h)))      // 左列→右凸
            } else {
                p.addPath(Rectangle().path(in: CGRect(x: -extend, y: 0, width: extend, height: h))) // 右列→左凸
            }
            if row == 0 {
                p.addPath(Rectangle().path(in: CGRect(x: 0, y: h, width: w, height: extend)))       // 上行→下凸
            } else {
                p.addPath(Rectangle().path(in: CGRect(x: 0, y: -extend, width: w, height: extend)))  // 下行→上凸
            }
            return p
        }

        /// 四角可分别指定半径的圆角矩形路径（半径为 0 时退化为直角）。
        private func unevenRoundedRect(in rect: CGRect, tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat) -> Path {
            let x = rect.origin.x, y = rect.origin.y
            let w = rect.width, h = rect.height
            func pt(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
            var p = Path()
            p.move(to: pt(tl, 0))
            p.addLine(to: pt(w - tr, 0))
            if tr > 0 { p.addArc(center: pt(w - tr, tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
            else { p.addLine(to: pt(w, tr)) }
            p.addLine(to: pt(w, h - br))
            if br > 0 { p.addArc(center: pt(w - br, h - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
            else { p.addLine(to: pt(w - br, h)) }
            p.addLine(to: pt(bl, h))
            if bl > 0 { p.addArc(center: pt(bl, h - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) }
            else { p.addLine(to: pt(0, h - bl)) }
            p.addLine(to: pt(0, tl))
            if tl > 0 { p.addArc(center: pt(tl, tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
            else { p.addLine(to: pt(tl, 0)) }
            p.closeSubpath()
            return p
        }
    }

    fileprivate struct TileBadge { let text: String; let warn: Bool }
    fileprivate enum TileHeaderMode { case bigNumber, titleLine, none }

    /// 宫格通用卡片。抽成 fileprivate 自由函数，方便子视图（HealthTileView/DietTileView）
    /// 也能复用同一套卡片布局；跳转逻辑由调用方通过 onTap 闭包传入（子视图拿不到根视图的
    /// longPressEnteredEditAt / router，由调用方在闭包里包好长按吞跳 + 跳转）。
    fileprivate static func tile<Content: View, Accessory: View>(
        bg: Color, accent: Color, icon: String, title: String, badge: TileBadge,
        number: String, unit: String, isEmpty: Bool,
        gridIndex: Int,
        headerMode: TileHeaderMode = .bigNumber,
        onTap: @escaping () -> Void,
        @ViewBuilder topTrailingAccessory: () -> Accessory = { EmptyView() },
        @ViewBuilder details: () -> Content
    ) -> some View {
        // 关键：用 ZStack 拆成两层，避免「大 Button 包小 Button」导致右上角小按钮被外层吞掉点不动。
        // 底层 Button 只负责整张卡片点击跳转 + 按压反馈；右上角小按钮独立放最上层，点击命中独立。
        ZStack {
            Button {
                onTap()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        // 标题 + 角标
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(AIATheme.Font.micro.weight(.semibold))
                            .foregroundStyle(accent)
                            .frame(width: 22, height: 22)
                            .background(accent.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text(title)
                            .font(AIATheme.Font.caption.weight(.medium))
                            .foregroundStyle(AIATheme.sub)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .layoutPriority(1)
                        if !badge.text.isEmpty {
                            Text(badge.text)
                                .font(AIATheme.Font.micro)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(badge.warn ? AIATheme.warn.opacity(0.14) : Color.black.opacity(0.06))
                                .foregroundStyle(badge.warn ? AIATheme.warn : AIATheme.sub)
                                .clipShape(Capsule())
                                .lineLimit(1)
                                // badge 数字优先完整显示，title 让步
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Spacer(minLength: 0)
                    }
                    // 主标题：大数字模式 / 标题行模式
                    switch headerMode {
                    case .bigNumber:
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(number)
                                .font(AIATheme.Font.title2.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(unit)
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.muted)
                        }
                    case .titleLine:
                        HStack(alignment: .lastTextBaseline, spacing: 4) {
                            Text(unit)
                                .font(AIATheme.Font.caption)
                                .foregroundStyle(AIATheme.sub)
                            Text(number)
                                .font(AIATheme.Font.title3.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    case .none:
                        EmptyView()
                    }
                    // 详情
                    details()
                    Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 135, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                }
                .background(bg)
                .clipShape(GridFillShape(cornerRadius: AIATheme.rLG, gridIndex: gridIndex))
                .contentShape(GridFillShape(cornerRadius: AIATheme.rLG, gridIndex: gridIndex))
                .frame(maxWidth: .infinity, minHeight: 165, maxHeight: 165)
            }
            // 按压反馈：整张宫格在按下时轻微缩放下沉 + 阴影抬升，松手 spring 回弹。
            // 用 ButtonStyle 实现，与 Button 点击共存，不吞点击，且自动遵守「减弱动态效果」。
            .buttonStyle(PressableCardStyle())

            // 空状态提示（点击记录）
            if isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap")
                        .font(AIATheme.Font.micro.weight(.semibold))
                    Text("点击记录")
                        .font(AIATheme.Font.micro.weight(.medium))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(accent.opacity(0.12))
                .clipShape(Capsule())
                .allowsHitTesting(false)
            }

            // 右上角小按钮（睡眠/饮水/隐私眼等）：用 .overlay(alignment:.topTrailing) 盖在父卡片之上，
            // 点击命中必然独立，不会被大卡片的 contentShape 吞掉。
            // 关键修复（2026-08-12）：浮层只占据 54×54 那一小块，绝不能用 frame(maxWidth/maxHeight:.infinity) 把
            // 几何 frame 撑满整张卡片——否则老芯片(A12/XS Max) UIKit 把圆内点击也判为"圆外"→ 穿透给父卡片 → 点不动。
            // 浮层整体用 .overlay 挂在上层，contentShape 收紧成 54×54，命中天然隔离。
        }
        .overlay(alignment: .topTrailing) {
            topTrailingAccessory()
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
                .padding(.top, 12)
                .padding(.trailing, 12)
        }
    }

    // MARK: - 迷你标签流
    private func miniTags(_ items: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(items, id: \.self) { t in
                Text(t)
                    .font(AIATheme.Font.micro)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.black.opacity(0.05))
                    .foregroundStyle(AIATheme.sub)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 健康步数进度条（今日步数 / 目标步数，与饮食 MiniBar 同高）
    private var sparkBars: some View {
        MiniBar(value: stepGoal > 0 ? Double(HomeHealthData.shared.homeSteps) / Double(stepGoal) : 0,
                color: AIATheme.health,
                height: 5,
                resetToken: homeEnterToken,
                coldStart: coldPlayPending)
    }

    // MARK: - 定时同步器（首次 0.3s 触发让首页先渲染，之后 60s 一次）
    /// 冷启动首拉：延迟 0.3s 让首页 @Query 先把本地空态渲染一帧，再立即从云端拉真实数据写回本地，4 宫格随后自动刷新。
    /// 之后**不再周期轮询**——同步完全由「本地改动 3s 防抖推送（syncAfterLocalChange，已在各写入口接好）」
    /// +「回前台拉取（didBecomeActive → autoSyncIfEnabled）」驱动，避免每 60s 空转调一次云函数
    /// 浪费 CloudBase 调用/数据库读配额。小程序/其他设备写入的数据会在用户下次打开 App（冷启动）
    /// 或从后台切回（didBecomeActive）时拉到，双端交叉使用体感等同自动同步。
    private func coldStartSync(delay: TimeInterval = 0.3) {
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            print("[ContentView] 冷启动首拉（\(delay)s 延迟后）")
            sync.autoSyncIfEnabled(context: context)
        }
    }

    // MARK: - 快捷操作消费
    private func consume(_ action: QuickAction) {
        #if DEBUG
        print("[ContentView] consume action=\(action)")
        #endif
        quickAction.pending = nil   // 立刻清空，避免重复消费（置 nil 会再次触发 onReceive，但 guard 会拦掉）
        switch action {
        case .camera:
            // 拉起相机（识别流程由 cameraRecognitionFlow 处理）；延迟到视图就绪后再弹，规避冷启动时序竞态。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showCamera = true }
        case .chat:
            router.chatEntrySource = "home"
            jump(to: .chat)
        case .voice:
            router.chatEntrySource = "voice"
            jump(to: .chatVoice)
        case .todo:
            jump(to: .todo)
        }
    }

    /// 延迟跳转：等 NavigationStack 就绪后再改 path，规避冷启动时序竞态。
    /// 幂等：若 path 已是目标，不再重复赋值（避免快捷操作被系统重复投递时连续重置 path）。
    private func jump(to route: HomeRoute) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            #if DEBUG
            print("[ContentView] jump to \(route), path was: \(self.router.path)")
            #endif
            // 走 NavigationRouter 的帧合并，避免冷启动多入口同帧重置 path 触发
            // "Update NavigationRequestObserver tried to update multiple times per frame"
            NavigationRouter.shared.replaceWith(route)
        }
    }

    /// 把通知点击携带的路由字符串映射到 HomeRoute，并清空 AppDelegate 的冷启动暂存。
    /// 若 route 本身是 http(s) URL，则按 App 内浏览器打开（browser:// 前缀则跳系统浏览器）。
    private func consumeNotificationRoute(_ route: String) {
        AppDelegate.pendingNotificationRoute = nil
        // 外部链接：直接打开
        if route.hasPrefix("http://") || route.hasPrefix("https://") || route.hasPrefix("browser://") {
            let urlString = route.hasPrefix("browser://") ? String(route.dropFirst("browser://".count)) : route
            guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else { return }
            if route.hasPrefix("browser://") {
                UIApplication.shared.open(url)
            } else {
                browserTarget = BrowserTarget(url: url)
            }
            return
        }
        // 截屏无感识别通知：点通知 = 按「来源×类别」设置分流，
        // 自动保存类跳对话页查看气泡；确认类弹结果确认（编辑）弹窗。
        if route == "screenshotRecognition" {
            Task { await checkScreenshotPending(navigateToChat: true) }
            return
        }
        // 点通知上的「保存」Action：本次强制自动入库（即便设置是「确认后再保存」），
        // 用户锁屏点一下即记上，无需进 App 二次确认。
        if route == "screenshotRecognition:save" {
            Task { await checkScreenshotPending(navigateToChat: true, forceSave: true) }
            return
        }
        // 点 widget / 通知带 aia://home：强制弹回首页根（清空整条导航栈），
        // 无论当前停在哪个深层页都回到首页宫格主界面。
        if route == "home" {
            NavigationRouter.shared.popToRoot()
            return
        }
        // >>> CHANGE-[2026-08-18 18:28:46]-[睡眠提醒通知路由] 开始
        // 原因: 睡觉提醒通知点按 → 进首页 + 自动开始一次睡眠记录 + 弹遮罩。
        // 守卫: 已在睡时不重复 toggle（避免误"醒来"），仅回首页。
        // 回退: 删除本段即可。
        if route == "sleepReminder" {
            NavigationRouter.shared.popToRoot()              // 回首页宫格主界面
            if currentActiveSleepSession(in: sleeps) == nil { // 仅在"未入睡"时自动开始记录
                let activeAfter = toggleSleepSession(in: context, sleeps: sleeps)
                showSleepMask = (activeAfter != nil)         // 刚入睡 → 盖遮罩；刚醒来 → 收遮罩
            }
            return
        }
        // <<< CHANGE-[2026-08-18 18:28:46]-[睡眠提醒通知路由] 结束
        // 桌面「快捷操作」组件（4×2）点击：WidgetKit 的 Link 触发 aia://voice|camera|chat|todo，
        // 直接映射到长按图标快捷操作的落地逻辑 consume(_:)，行为 100% 一致
        //（语音→自动开麦 / 拍照→弹相机 / 问好记→对话页 / 查待办→待办列表）。
        if let action = quickActionFromWidgetRoute(route) {
            consume(action)
            return
        }
        // 桌面「快捷操作」组件（4×2）点击：标记是 QuickAction 的完整 rawValue
        //（如 "com.aia.shortcut.voice"），复用长按图标快捷操作的落地逻辑 consume(_:)，
        // 行为 100% 一致（语音→自动开麦 / 拍照→弹相机 / 问好记→对话页 / 查待办→待办列表）。
        if route.hasPrefix("com.aia.shortcut."), let action = QuickAction(rawValue: route) {
            consume(action)
            return
        }
        let target: HomeRoute?
        switch route {
        case "todo", "reminder": target = .todo
        case "bill":             target = .bill
        case "diet", "food":     target = .diet
        case "health":           target = .health
        case "chat":             target = .chat
        default:                 target = nil
        }
        guard let target else { return }
        #if DEBUG
        print("[ContentView] consumeNotificationRoute route=\(route) -> \(target)")
        #endif
        jump(to: target)
    }

    // MARK: - 数据计算：饮食
    private var todayFoods: [FoodEntry] { foods.filter { Calendar.current.isDateInToday($0.date) } }
    private var todayCalories: Double { todayFoods.reduce(0) { $0 + $1.calories } }
    /// 今日饮水（ml）：与饮食记录页「今日饮水」口径一致——仅统计手动加水 WaterLog（不含食物自带水分）。
    private var todayWater: Double {
        waterLogs.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.amount }
    }
    private func mealCal(_ meal: String) -> Int {
        let v = todayFoods.filter { $0.meal == meal }.reduce(0) { $0 + $1.calories }
        return Int(v)
    }
    // MARK: - 首页健康派生数据（已下沉，根视图不再订阅 HealthManager）
    // 抽到独立 ObservableObject 单例：各子视图（健康宫格 / AI 气泡 / 饮食宫格）局部 @ObservedObject 订阅，
    // HealthKit 回刷只重算对应子视图，不再触发整页 body 重算（切断耦合，消除老芯片首装头两秒整页抖动）。
    final class HomeHealthData: ObservableObject {
        static let shared = HomeHealthData()
        private var cancellables = Set<AnyCancellable>()

        // 数据来源开关（与首页/健康页 @AppStorage 同 key，确保实时跟随用户在健康页的切换）
        @AppStorage(HealthMetricKind.steps.sourceKey)     private var stepsSource: HealthSourceMode = .auto
        @AppStorage(HealthMetricKind.sleep.sourceKey)     private var sleepSource: HealthSourceMode = .auto
        @AppStorage(HealthMetricKind.exercise.sourceKey)  private var exerciseSource: HealthSourceMode = .auto
        @AppStorage(HealthMetricKind.tdee.sourceKey)      private var tdeeSource: HealthSourceMode = .auto
        @AppStorage(HealthMetricKind.heartRate.sourceKey) private var heartRateSource: HealthSourceMode = .auto

        // 身体数据（用于 TDEE 目标值计算）
        @AppStorage("aia.calorieGoalOverride") private var calorieGoalOverride: Double = 0
        @AppStorage("aia.calorieGoalIsCustom") private var calorieGoalIsCustom: Bool = false
        @AppStorage("aia.weightKg")  private var weightKg: Double = 0
        @AppStorage("aia.heightCm")  private var heightCm: Double = 0
        @AppStorage("aia.age")       private var age: Int = 30
        @AppStorage("aia.bioSex")    private var bioSex: Int = 1
        @AppStorage("aia.activityLevel") private var activityLevel: Int = 1

        private init() {
            // 转发 HealthManager 的「去抖后」变化通知（debouncedChange，合并 300ms 内多次 @Published 改写），
            // 而非原始 objectWillChange。否则 HealthKit 授权后 refreshAll() 并发发起 10+ 查询，
            // 每个回调改写 @Published 都会密集发 objectWillChange → 本单例直接转发 →
            // HealthTileView / DietTileView / AISummarySectionView 三个子视图每秒级重算，
            // 在老机型（A12/XS Max）上表现为「整页循环抖动」。
            // debouncedChange 已在 HealthManager 内对 objectWillChange 做 300ms 去抖，与之配合即可。
            HealthManager.shared.debouncedChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        private var hkUsable: Bool {
            HealthManager.shared.authorized && HealthManager.shared.isAvailable
        }
        func isAuto(_ kind: HealthMetricKind) -> Bool {
            let mode: HealthSourceMode = {
                switch kind {
                case .steps:     return stepsSource
                case .sleep:     return sleepSource
                case .exercise:  return exerciseSource
                case .tdee:      return tdeeSource
                case .heartRate: return heartRateSource
                default:         return .auto
                }
            }()
            return mode == .auto && hkUsable
        }

        var homeSteps: Int {
            isAuto(.steps) ? Int(HealthManager.shared.stepsToday) : ManualHealthStore.shared.steps(for: Date())
        }
        var homeExerciseMin: Double {
            isAuto(.exercise)
                ? HealthManager.shared.exerciseTimeToday
                : HealthManager.shared.exerciseTimeToday + Double(ManualHealthStore.shared.exerciseMinutes(for: Date()))
        }
        // >>> CHANGE-[2026-08-19 12:55:00]-对齐全App今日消耗口径 开始
        // 原因: 与饮食页/管理页同源, 按 Date() 查 activeEnergyForDay/restingEnergyForDay 字典, 避免实时 fetch 与字典口径差几十卡
        // 回退: 恢复原判(HealthManager.shared.restingEnergyToday + activeEnergyToday) 即可
        var homeEnergyBurned: Double {
            let day = Calendar.current.startOfDay(for: Date())
            if isAuto(.tdee) && HealthManager.shared.isAvailable && HealthManager.shared.hasHealthKitData {
                let active = HealthManager.shared.activeEnergyForDay[day]
                    ?? ManualHealthStore.shared.healthKitValue("activeCalories", for: day)
                let resting = HealthManager.shared.restingEnergyForDay[day]
                    ?? ManualHealthStore.shared.healthKitValue("restingCalories", for: day)
                return active + resting
            }
            return Double(ManualHealthStore.shared.activeCalories(for: day))
        }
        // <<< CHANGE-[2026-08-19 12:55:00]-对齐全App今日消耗口径 结束
        /// 静息心率（自动模式才取 HealthKit；手动模式走 ManualHealthStore）。
        var restingHeartRate: Double {
            isAuto(.heartRate) ? HealthManager.shared.restingHeartRate : 0
        }

        private var tdeeGoalFallback: Double {
            // 2026-08-13 修复：冷启动时云端 profile 未拉到（或用户未填体重身高）→ mifflinBMR 返回 nil → 结果为 0。
            // 首页进度条 value = todayCalories / calorieGoal，calorieGoal 一旦=0 会被兜底成 0 → 进度条一直空/先长再空。
            // 缺身体数据时给一个通用成人 TDEE 保底（非 0 分母），避免进度条空；填了身体数据仍按 Mifflin 精确算。
            let bmr = mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: age, isMale: bioSex == 1)
            if let bmr {
                let mult = activityMultiplier(activityLevel)
                return bmr * (mult > 0 ? mult : 1.375)
            }
            return 2000   // 通用成人 TDEE 估算保底（kg/cm 缺失时）
        }
        // >>> CHANGE-[2026-08-19 12:55:00]-对齐全App今日消耗口径 开始
        // 原因: 与 homeEnergyBurned/饮食页/管理页同源, 按 Date() 查字典当日值
        // 回退: 恢复原判(HealthManager.shared.restingEnergyToday + activeEnergyToday) 即可
        var tdee: Double {
            let day = Calendar.current.startOfDay(for: Date())
            let actual: Double
            if isAuto(.tdee) && HealthManager.shared.isAvailable && HealthManager.shared.hasHealthKitData {
                let active = HealthManager.shared.activeEnergyForDay[day]
                    ?? ManualHealthStore.shared.healthKitValue("activeCalories", for: day)
                let resting = HealthManager.shared.restingEnergyForDay[day]
                    ?? ManualHealthStore.shared.healthKitValue("restingCalories", for: day)
                actual = active + resting
            } else {
                actual = Double(ManualHealthStore.shared.activeCalories(for: day))
            }
            return actual > 0 ? actual : tdeeGoalFallback
        }
        // <<< CHANGE-[2026-08-19 12:55:00]-对齐全App今日消耗口径 结束
        var calorieGoal: Double {
            if calorieGoalIsCustom, calorieGoalOverride > 0 { return calorieGoalOverride }
            return tdeeGoalFallback
        }
    }

    // MARK: - 数据计算：账单
    private var monthBills: [Bill] {
        bills.filter { Calendar.current.isDate($0.time, equalTo: Date(), toGranularity: .month) }
    }
    private var todayExpense: Double {
        bills.filter { Calendar.current.isDateInToday($0.time) && !$0.isIncome }
             .reduce(0) { $0 + $1.amount }
    }
    private var monthIncome: Double { monthBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount } }
    private var monthExpense: Double { monthBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount } }
    private var monthBalance: Double { monthIncome - monthExpense }

    // MARK: - 数据计算：待办
    private var todayTodos: [Reminder] {
        reminders.filter { r in
            guard let due = r.due, !r.done else { return false }
            return Calendar.current.isDateInToday(due)
        }
        .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
    }
    private var recentTodos: [Reminder] {
        Array(reminders.filter { !$0.done }
              .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
              .prefix(5))
    }
    private func todoTimeSuffix(_ r: Reminder) -> String {
        guard let due = r.due else { return "" }
        let cal = Calendar.current
        let time = AppFormat.hourMinute.string(from: due)
        let datePrefix: String
        if cal.isDateInToday(due) {
            datePrefix = "今天"
        } else if cal.isDateInTomorrow(due) {
            datePrefix = "明天"
        } else {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "zh_Hans_CN")
            fmt.dateFormat = "M/d"
            datePrefix = fmt.string(from: due)
        }
        return " · \(datePrefix) \(time)"
    }
    // MARK: - 顶部待处理总数（今日待办）
    private var pendingCount: Int { todayTodos.count }
}

// MARK: - 首同步指示器子视图（局部订阅 CloudSyncManager，避免根视图订阅）
private struct FirstSyncIndicator: View {
    @Binding var showSyncIndicator: Bool
    @State private var hasFirstSyncStarted = false
    private let sync = CloudSyncManager.shared
    
    var body: some View {
        EmptyView()
            .onReceive(sync.$isSyncing) { syncing in
                if syncing {
                    hasFirstSyncStarted = true
                }
                if hasFirstSyncStarted && !syncing {
                    showSyncIndicator = false
                }
            }
            // 兜底：当同步根本不会发生（autoSync 已关 / 会员到期 / 体验模式），
            // sync() 第一行 guard canPerformCloudSync 直接 return、isSyncing 永不变 true，
            // 上面的 onReceive 永远没机会关条。监听 rawStatus：一旦出现「已确定不会再同步」的
            // 终态文案，立即关掉误导性「正在同步」提示。
            .onReceive(sync.$rawStatus) { status in
                guard showSyncIndicator else { return }
                let terminalNonSyncing: Set<String> = [
                    "自动同步已关闭",
                    "会员已过期，云同步不可用",
                    "免费版体验模式：云同步已禁用",
                    "未同步",
                ]
                if terminalNonSyncing.contains(status) {
                    showSyncIndicator = false
                }
            }
    }
}
