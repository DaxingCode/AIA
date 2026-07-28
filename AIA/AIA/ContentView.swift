// ContentView.swift
// 首页 E宫：顶部标题 + 待处理角标、四模块数据摘要宫格（2 列）、底部 AI 栏。
// 按《UI完整页面流.html》① 重建，数据由本地 SwiftData 驱动。
//
// 导航策略（避坑，重要）：
//   全 App 统一用单个 NavigationStack(path:) + 单个 .navigationDestination(for:)。
//   四宫格卡片、齿轮、快捷操作都走 path 编程式跳转（Button { path.append(...) }）。
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
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \FoodEntry.date, order: .reverse) private var foods: [FoodEntry]
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \Bill.time, order: .reverse) private var bills: [Bill]
    @Query(filter: #Predicate<Reminder> { !$0.syncDeleted }) private var reminders: [Reminder]
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \HealthMetric.date, order: .reverse) private var healths: [HealthMetric]

    @StateObject private var health = HealthManager.shared
    @ObservedObject private var quickAction = QuickActionRouter.shared
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var layout = HomeLayoutStore.shared
    @State private var isEditing = false
    @State private var draggingModule: HomeModule? = nil
    /// 长按进入编辑态的瞬间时间戳：长按松手会连带触发宫格 Button 的 tap，借此在 0.5s 内吞掉这次跳转，避免"进了编辑又跳页"。
    @State private var longPressEnteredEditAt: Date? = nil
    /// 右上角工具栏是否展开：默认收起，仅露「展开」触发按钮；点开露出「首页编辑」+「设置」。
    @State private var toolbarExpanded = false

    @AppStorage("userNickname") private var userNickname = "阿宝的朋友"
    @AppStorage("aia.calorieGoalOverride") private var calorieGoalOverride: Double = 0
    @AppStorage("aia.calorieGoalIsCustom") private var calorieGoalIsCustom: Bool = false

    @State private var showCamera = false
    @State private var showPicker = false
    @State private var animateTiles = false
    /// 阿宝头像呼吸脉冲动画开关
    @State private var abaoPulse = false
    /// 账单宫格隐私遮罩：@AppStorage 自动持久化到 UserDefaults，重启 App 保持
    @AppStorage("billHidden") private var billHidden = false

    // 气泡转轴滚动调度：每 2 秒只让「当前轮到的那一条」滚动，四条依次轮流。
    @State private var rollSlot = 0
    @State private var rollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    // 定时同步：已登录且前台时，每 60 秒自动推一次本地数据到云端，降低删除 App 前未同步的概率。
    @State private var syncTimer: Timer?
    @StateObject private var sync = CloudSyncManager.shared

    // 首次启动引导：未看过引导则弹出 OnboardingView
    @AppStorage("aia.onboardingDone") private var onboardingDone = false
    @State private var showOnboarding = false

    // 后台「无感截图识别」的结果：主 App 打开时先自动入库，再弹确认页（确认页只做覆盖修改）。
    @State private var pendingPresent: RecognitionPresent?
    // 防止 checkScreenshotPending 被多个通知并发/重复触发时重复 present。
    @State private var isCheckingScreenshotPending = false

    // 冷启动同步指示器：首次同步完成前显示「正在同步数据…」，完成后消失。
    // 用户在「同步完毕 = 全 0 → 真实数据」之间不再茫然。
    @State private var showSyncIndicator = false
    @State private var hasFirstSyncStarted = false

    // 目标常量（与记录页保持一致）
    private var calorieGoal: Double { calorieGoalIsCustom ? calorieGoalOverride : tdee }
    @AppStorage("aia.stepGoal") private var stepGoal: Int = 10000
    /// TDEE 同源键（与健康目标页、饮食记录页一致）。
    @AppStorage("aia.heightCm") private var heightCm: Double = 0
    @AppStorage("aia.weightKg") private var weightKg: Double = 0
    @AppStorage("aia.age") private var age: Int = 30
    @AppStorage("aia.bioSex") private var bioSex: Int = 1   // 1 = 男, 0 = 女
    @AppStorage("aia.activityLevel") private var activityLevel: Int = 1
    /// 与健康管理页一致：已接入 HealthKit 且真正读到过非零数据时才用真实数据，
    /// 否则回退到本地手动录入（防止授权弹窗被点拒绝/无 entitlement 时显示全 0）。
    private var usesHealthKit: Bool { health.authorized && health.isAvailable && health.hasHealthKitData }
    private var homeSteps: Int { usesHealthKit ? Int(health.stepsToday) : ManualHealthStore.shared.steps(for: Date()) }
    private var homeExerciseMin: Double {
        usesHealthKit ? health.exerciseTimeToday : health.exerciseTimeToday + Double(ManualHealthStore.shared.exerciseMinutes(for: Date()))
    }
    /// 与健康管理页 TDEE 圆环同源：已接入 HealthKit 且读到数据 → 静息+活动能量；
    /// 未接入 → 手动补录的活动热量。保证首页健康卡片/今日预览/管理页圆环三处一致。
    private var homeEnergyBurned: Double {
        usesHealthKit ? health.restingEnergyToday + health.activeEnergyToday : Double(ManualHealthStore.shared.activeCalories(for: Date()))
    }
    /// 健康气泡消息：与首页健康卡片 / 健康管理页「今日概览」完全同源——
    /// 步数走 homeSteps（含手动回落）、目标走 @AppStorage stepGoal、运动时长走 homeExerciseMin（含手动回落）、
    /// 能量消耗走 homeEnergyBurned（与 TDEE 圆环同源）、静息心率 key 与页面 StatCard 一致（"心率"）。
    /// 不再直读 raw health.stepsToday/exerciseTimeToday，也不再硬编码 10000 目标。
    private var healthBubbleMessages: [String] {
        let stat = { (key: String) -> String in
            healths.first(where: { $0.metric.contains(key) }).map { "\($0.value)\($0.unit)" } ?? "—"
        }
        let energyText = homeEnergyBurned > 0 ? "\(Int(homeEnergyBurned)) kcal" : "—"
        return [
            "健康管理 · 今日步数 \(homeSteps)，距目标还差 \(max(0, stepGoal - homeSteps))",
            "健康管理 · 运动时长 \(Int(homeExerciseMin)) min",
            "健康管理 · 能量消耗 \(energyText)",
            "健康管理 · 静息心率 \(stat("心率"))"
        ]
    }
    @AppStorage("aia.monthlyBudget") private var monthlyBudget: Double = 5000

    // 外观模式：浅色 / 深色 / 跟随系统（设置页可改；与系统浅深自适应主题联动）
    @AppStorage("aia.appearance") private var appearanceRaw = "system"
    private var appearanceColorScheme: ColorScheme? {
        AppearanceMode(raw: appearanceRaw).colorScheme
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 8) {
                        header
                            .padding(.bottom, 8)
                        syncHeaderIndicator
                        AdBannerView()
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
            }
            .background(AppBackgroundView())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 按钮始终存在，用 frame 宽度 + opacity + scale 做"卷帘"式展开/收起。
                    // 不用 if+transition：toolbar 容器对 transition 支持差，会瞬间闪现不走动画。
                    HStack(spacing: 0) {
                        // 首页编辑 / 完成：图标 + 文字，最直观；编辑态不再旋转（文字配旋转会歪，且铅笔转 90° 像 bug）
                        Button {
                            // 进入编辑模式时给中等震动反馈；退出不震
                            if !isEditing {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                isEditing.toggle()
                                draggingModule = nil
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

                        // 设置
                        Button { router.path.append(.settings) } label: {
                            Image(systemName: "gearshape")
                                .font(AIATheme.Font.body.weight(.medium))
                                .rotationEffect(.degrees(toolbarExpanded ? -90 : 0))  // 打开往左滚，关闭往右滚
                        }
                        .frame(width: toolbarExpanded ? 30 : 0)
                        .opacity(toolbarExpanded ? 1 : 0)
                        .scaleEffect(toolbarExpanded ? 1 : 0.4, anchor: .trailing)
                        .padding(.trailing, toolbarExpanded ? 14 : 0)
                        .allowsHitTesting(toolbarExpanded)

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
                                    isEditing = false
                                    draggingModule = nil
                                }
                            }
                        } label: {
                            Image(systemName: toolbarExpanded ? "xmark.circle" : "ellipsis.circle")
                                .font(AIATheme.Font.body.weight(.medium))
                                .contentTransition(.symbolEffect(.replace))
                                .rotationEffect(.degrees(toolbarExpanded ? 90 : 0))
                        }
                    }
                    .clipped()
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                Group {
                    switch route {
                    case .diet:         FoodListView()
                    case .health:       HealthListView()
                    case .bill:         BillListView()
                    case .billTools:    BillToolsView()
                    case .todo:         ReminderListView()
                    case .todoTools:    TodoToolsView()
                    case .chat:         ChatView(prefill: router.chatPrefill, entrySource: router.chatEntrySource)
                    case .chatVoice:    ChatView(autostartVoice: true, entrySource: "voice")
                    case .settings:     SettingsView()
                    case .autoSetup:    AutoRecognitionSetupView()
                    case .myAccount:    MyAccountView()
                    case .healthDetail(let m):
                        HealthDetailView(metric: m)
                    }
                }
            }
        }
        .onChange(of: router.path) { old, new in
            #if DEBUG
            print("[ContentView] path changed from \(old) to \(new)")
            #endif
        }
        // 冷启动兜底：didFinishLaunching 里写入的 pending 在 ContentView 订阅 onReceive 之前就已存在，
        // onReceive 不会回放初始值；通知又在订阅前发出会被直接丢弃。因此这里显式读一次 pending 消费冷启动快捷项。
        .onAppear {
            #if DEBUG
            print("[ContentView] onAppear, pending=\(quickAction.pending?.rawValue ?? "nil")")
            #endif
            // 一次性去重：清理重复记录（仅首次启动执行）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                DataDeduplicator.runOnce(context: context)
            }
            if let action = quickAction.pending { consume(action) }
            if let route = AppDelegate.pendingNotificationRoute {
                consumeNotificationRoute(route)
            }
            if !onboardingDone { showOnboarding = true }
            checkScreenshotPending()
            // 周期 / 订阅账单：App 打开时把已到期的账期自动入账（房租、会员费等）。
            RecurringBillManager.generateDue(context: context)
            // 打通 HealthKit：进入首页即尝试授权。autoAuthEnabled=false（免费账号默认）时内部自动跳过，不会崩。
            health.requestAuthorization()
            // 启动定时同步器
            startPeriodicSync()
            // 冷启动同步指示器：仅当已登录才亮起（本地无数据才真正可见）
            if UserDefaults.standard.bool(forKey: "aia.isLoggedIn") {
                showSyncIndicator = true
                hasFirstSyncStarted = false
            }
        }
        .onDisappear {
            syncTimer?.invalidate()
            syncTimer = nil
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
            // 截图无感识别：无论是否有快捷操作 pending，只要后台留了识别结果就弹确认页
            checkScreenshotPending()
            // 回到前台时也补生成周期账单（长期未开 App 会补齐中间月份）
            RecurringBillManager.generateDue(context: context)
            // 回到前台立即同步一次云端 → 4 宫格立刻显示最新数据，不再等 60s
            if UserDefaults.standard.bool(forKey: "aia.isLoggedIn") {
                sync.autoSyncIfEnabled(context: context)
            }
            guard quickAction.pending != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let p = quickAction.pending { consume(p) }
            }
        }
        // 冷启动同步指示器消失：检测到第一次 isSyncing 从 true → false
        // （即 0.3s 后首次同步完成，云端数据写入本地，@Query 自动刷新）
        .onReceive(sync.$isSyncing) { syncing in
            if syncing {
                hasFirstSyncStarted = true
            }
            if hasFirstSyncStarted && !syncing {
                showSyncIndicator = false
            }
        }
        // 点击系统通知：跳转到对应页面（如待办提醒 → 待办页）。
        .onReceive(NotificationCenter.default.publisher(for: .notificationRouteReceived)) { note in
            if let route = note.userInfo?["route"] as? String {
                consumeNotificationRoute(route)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotRecognitionReady)) { _ in
            checkScreenshotPending()
        }
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker)
        // 后台「无感截图识别」的结果确认页：App 打开且有 pending 时弹出（正常已入库 / 重复则警告不入库），
        // 关闭即清空，避免重复弹。
        .fullScreenCover(item: $pendingPresent) { present in
            makeResultConfirmView(present)
                .environment(\.modelContext, context)
                .interactiveDismissDisabled(true)
                .onDisappear {
                    ScreenshotStore.clearPending()
                    pendingPresent = nil
                }
        }
        // 首次启动引导：看完即标记完成，避免重复弹
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
                onboardingDone = true
            }
        }
        // 全局轻量 toast（静默保存提示等）：挂在 NavigationStack 上，push 进来的页面也能看到。
        // 静默路径不弹 fullScreenCover，不会被 cover 遮挡。
        .overlay(alignment: .top) { GlobalToastOverlay() }
        // 外观模式开关：system → 不覆盖（跟随系统）；light/dark → 强制浅/深。
        // 挂在 NavigationStack 上即可覆盖整个窗口（含 push 进来的设置页、sheet、fullScreenCover）。
        .preferredColorScheme(appearanceColorScheme)
    }

    /// 检查后台识别留下的待确认结果（截图无感识别链路）：
    /// 走 processRecognition —— 按「图片自动识别」设置（按类别 自动保存/自动弹出）分流：
    /// - .present：弹确认页（预存类别可覆盖修改，未预存类别点「存入」才写库）；
    /// - .silentlySaved：已静默入库 → 清 pending + 顶部 toast 引导去对应页面修改（原生「识别完成」通知不受影响）；
    /// - .nothing：按设置丢弃 → 仅清 pending。
    @MainActor
    private func checkScreenshotPending() {
        guard !isCheckingScreenshotPending, pendingPresent == nil else { return }
        guard let p = ScreenshotStore.loadPending() else { return }
        isCheckingScreenshotPending = true
        let img = ScreenshotStore.loadPendingImage()
        let outcome = RecognitionSaver.processRecognition(result: p.result, rawText: p.rawText,
                                                          image: img, context: context,
                                                          source: p.source ?? .cloud)
        isCheckingScreenshotPending = false
        switch outcome {
        case .present(let present):
            // 推迟到下一个 runloop 呈现 cover，避免 SwiftUI 环境（NavigationStack/ModelContext）未完全就绪时
            // 全屏 cover 闪烁/自动关闭再弹出。同一 runloop 中的后续 checkScreenshotPending 会被 isCheckingScreenshotPending 拦截。
            DispatchQueue.main.async { [present] in
                guard pendingPresent == nil else { return }
                pendingPresent = present
            }
        case .silentlySaved(let savedTypes):
            // 数据已入库：立即清 pending，避免点通知回 App 时再弹确认页
            ScreenshotStore.clearPending()
            ToastCenter.shared.show(ImageAutoRecogSettings.silentSaveToast(savedTypes: savedTypes))
        case .nothing:
            ScreenshotStore.clearPending()
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

    /// 阿宝头像：app icon (AIAvatar) 圆形裁剪 + 呼吸脉冲动画（2.5s 循环胀缩）
    private var abaoAvatar: some View {
        Button {
            router.path.append(.myAccount)
        } label: {
            Image("AIAvatar")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .scaleEffect(abaoPulse ? 1.12 : 1.0)
        }
        .frame(width: 44, height: 44)
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
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
    private func tileView(for m: HomeModule) -> some View {
        switch m {
        case .diet:      dietTile
        case .health:    healthTile
        case .bill:      billTile
        case .todo:      todoTile
        case .aiSummary: EmptyView()
        }
    }

    @ViewBuilder
    private func fullRowView(for m: HomeModule) -> some View {
        switch m {
        case .aiSummary: aiSummarySection
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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isEditing = true
                    toolbarExpanded = true   // 展开工具栏，让「完成」按钮可见，用户能退出编辑态
                    draggingModule = nil
                }
            }
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
                                    animatedTile(gi, tile: tileView(for: m))
                                        .simultaneousGesture(longPressToEnterEdit)
                                }
                            }
                            .task { animateTiles = true }
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
        .onDisappear { animateTiles = false }
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
            // 编辑态吞掉原卡片的点击跳转（原 tile 是 Button），但 − 按钮盖在上方仍可点
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
                .allowsHitTesting(true)
            minusButton(for: m)
        }
        .frame(maxWidth: .infinity)
        .modifier(ShakeModifier(active: true))
    }

    @ViewBuilder
    private func tileOrRowContent(for m: HomeModule) -> some View {
        switch m {
        case .aiSummary: aiSummarySection
        default:         tileView(for: m)
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
                .spring(response: 0.55, dampingFraction: 0.72)
                    .delay(Double(idx) * 0.06),
                value: animateTiles
            )
    }

    // MARK: 饮食
    private var dietTile: some View {
        tile(bg: AIATheme.dietBG, accent: AIATheme.food, icon: "fork.knife", route: .diet,
             title: "饮食记录",
             badge: TileBadge(text: "今日 \(todayFoods.count) 条", warn: false),
             number: "\(Int(todayCalories))", unit: "kcal",
             isEmpty: foods.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                MiniBar(value: todayCalories / calorieGoal, color: AIATheme.food, height: 5)
                VStack(alignment: .leading, spacing: 5) {
                    calSummaryRow("目标", "\(Int(calorieGoal)) kcal", AIATheme.sub)
                    calSummaryRow(todayCalories > calorieGoal ? "已超" : "待摄入",
                                  "\(max(0, Int(abs(calorieGoal - todayCalories)))) kcal",
                                  todayCalories > calorieGoal ? AIATheme.over : AIATheme.sub)
                    calSummaryRow("净热量",
                                  "\(netCalories >= 0 ? "+" : "")\(Int(netCalories)) kcal",
                                  netCalories >= 0 ? AIATheme.food : AIATheme.over)
                }
            }
        }
    }

    private func calSummaryRow(_ label: String, _ value: String, _ valueColor: Color) -> some View {
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

    // MARK: 昨晚睡眠（替代原宫格的「静息心率」项）
    @AppStorage("aia.sleepGoalHours") private var sleepGoalHours: Double = 8
    /// 昨晚睡眠 = 最近一条睡眠记录（HealthKit 同步）+ 未接入时的手动增量，与记录页同源。
    private var sleepLastNight: Double {
        let stored = healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0
        return usesHealthKit ? stored : stored + ManualHealthStore.shared.sleepHours(for: Date())
    }
    private var sleepRowText: String {
        guard sleepLastNight > 0 else { return "—" }
        let met = sleepGoalHours > 0 && sleepLastNight >= sleepGoalHours
        return String(format: "%.1fh%@", sleepLastNight, met ? " · 达标" : "")
    }
    private var sleepRowColor: Color {
        guard sleepLastNight > 0, sleepGoalHours > 0 else { return AIATheme.sub }
        return sleepLastNight >= sleepGoalHours ? AIATheme.health : AIATheme.warning
    }

    // MARK: 健康
    private var healthTile: some View {
        tile(bg: AIATheme.healthBG, accent: AIATheme.health, icon: "heart.fill", route: .health,
             title: "健康管理",
             badge: TileBadge(text: homeSteps >= stepGoal ? "达标" : "今日", warn: false),
             number: "\(homeSteps)", unit: "步",
             isEmpty: healths.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                sparkBars
                VStack(alignment: .leading, spacing: 5) {
                    healthSummaryRow("运动时长", exerciseTimeText, AIATheme.sub)
                    healthSummaryRow("能量消耗", homeEnergyBurned > 0 ? "\(Int(homeEnergyBurned)) kcal" : "—", AIATheme.sub)
                    healthSummaryRow("昨晚睡眠", sleepRowText, sleepRowColor)
                }
            }
        }
    }

    private func healthSummaryRow(_ label: String, _ value: String, _ valueColor: Color) -> some View {
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
        "\(Int(homeExerciseMin)) min"
    }

    // MARK: 账单
    private var billTile: some View {
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

        return tile(bg: AIATheme.billBG, accent: AIATheme.bill, icon: "creditcard.fill", route: .bill,
             title: "账单管理",
             badge: TileBadge(text: "", warn: false),
             number: numberTxt, unit: "今日支出",
             isEmpty: bills.isEmpty,
             headerMode: .titleLine,
             titleTrailing: privacyEyeButton) {
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        )
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 待办
    private var todoTile: some View {
        tile(bg: AIATheme.todoBG, accent: AIATheme.todo, icon: "checklist", route: .todo,
             title: "待办提醒",
             badge: TileBadge(text: "今日 \(todayTodos.count) 项", warn: false),
             number: "\(todayTodos.count)", unit: "今日待办",
             isEmpty: reminders.isEmpty,
             headerMode: .none) {
            VStack(alignment: .leading, spacing: 6) {
                if recentTodos.isEmpty {
                    Text("暂无待办 👍")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                } else {
                    ForEach(recentTodos, id: \.persistentModelID) { r in
                        HStack(spacing: 4) {
                            Text("· \(r.title)").lineLimit(1)
                            Spacer(minLength: 0)
                            Text(todoTimeSuffix(r)).foregroundStyle(AIATheme.muted)
                        }
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                    }
                }
            }
        }
    }

    // MARK: - 今日事项预览气泡（四条气泡固定展示，每条内部轮播各自内容）
    private var aiSummarySection: some View {
        let dietMsgs = AISummary.dietMessages(foods: foods)
        let billMsgs = AISummary.billMessages(bills: bills)
        let todoMsgs = AISummary.todoMessages(reminders: reminders)

        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "今日事项预览", trailing: "阿宝AI提醒")
            VStack(spacing: 8) {
                rollingBubble(messages: dietMsgs, accent: AIATheme.food, active: rollSlot == 0, route: .diet)
                rollingBubble(messages: healthBubbleMessages, accent: AIATheme.health, active: rollSlot == 1, route: .health)
                rollingBubble(messages: billMsgs, accent: AIATheme.bill, active: rollSlot == 2, route: .bill)
                rollingBubble(messages: todoMsgs, accent: AIATheme.todo, active: rollSlot == 3, route: .todo)
            }
            .onReceive(rollTimer) { _ in
                rollSlot = (rollSlot + 1) % 4
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 单条气泡：当 `active` 为真（由外层调度器轮流指派）且候选 >1 时，像转轴一样向上滚动切换到下一条；气泡框本身不动。
    private func rollingBubble(messages: [String], accent: Color, active: Bool, route: HomeRoute) -> some View {
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
                NavigationRouter.shared.path.append(route)
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
    private struct TileBadge { let text: String; let warn: Bool }
    private enum TileHeaderMode { case bigNumber, titleLine, none }

    private func tile<Content: View>(
        bg: Color, accent: Color, icon: String, route: HomeRoute, title: String, badge: TileBadge,
        number: String, unit: String, isEmpty: Bool,
        headerMode: TileHeaderMode = .bigNumber,
        titleTrailing: AnyView? = nil,
        @ViewBuilder details: () -> Content
    ) -> some View {
        Button {
            // 长按进入编辑后松手会连带触发本 tap：0.5s 内的跳转吞掉，只进编辑不跳页
            if let t = longPressEnteredEditAt, Date().timeIntervalSince(t) < 0.5 {
                longPressEnteredEditAt = nil
                return
            }
            router.path.append(route)
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
                    if let titleTrailing { titleTrailing }
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
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
            .contentShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
            .frame(maxWidth: .infinity, minHeight: 165, maxHeight: 165)
            .clipped()
        }
        // 按压反馈：整张宫格在按下时轻微缩放下沉 + 阴影抬升，松手 spring 回弹。
        // 用 ButtonStyle 实现，与 Button 点击共存，不吞点击，且自动遵守「减弱动态效果」。
        .buttonStyle(PressableCardStyle())
        .overlay(alignment: .center) {
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
            }
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
        MiniBar(value: Double(homeSteps) / Double(stepGoal),
                color: AIATheme.health,
                height: 5)
    }

    // MARK: - 定时同步器（首次 0.3s 触发让首页先渲染，之后 60s 一次）
    private func startPeriodicSync() {
        syncTimer?.invalidate()
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return }
        // 首次同步：延迟 0.3s 让首页 @Query 先把本地空态渲染一帧，避免和首帧渲染抢资源；
        // 然后立即从云端拉真实数据写回本地，4 宫格会随后自动刷新。
        // 关键：之前 60s 干等的版本会让用户在 60s 内看到「全 0」的假数据，体验非常糟。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak sync] in
            print("[ContentView] 首次同步触发（0.3s 延迟后）")
            sync?.autoSyncIfEnabled(context: context)
        }
        // 之后每 60s 增量同步一次
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak sync] _ in
            print("[ContentView] 定时同步触发")
            MainActor.assumeIsolated {
                sync?.autoSyncIfEnabled(context: context)
            }
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
            if self.router.path != [route] {
                router.path = [route]
            }
        }
    }

    /// 把通知点击携带的路由字符串映射到 HomeRoute，并清空 AppDelegate 的冷启动暂存。
    private func consumeNotificationRoute(_ route: String) {
        AppDelegate.pendingNotificationRoute = nil
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
    private func mealCal(_ meal: String) -> Int {
        let v = todayFoods.filter { $0.meal == meal }.reduce(0) { $0 + $1.calories }
        return Int(v)
    }
    /// 与饮食记录页同步：TDEE = 静息能量 + 活动能量（HealthKit 真实数据）；
    /// 无真实数据时回落到 TDEE 目标值 BMR × 活动系数（与健康目标页同源）。
    private var tdeeGoalFallback: Double {
        (mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: age, isMale: bioSex == 1) ?? 0)
            * activityMultiplier(activityLevel)
    }
    private var tdee: Double {
        let actual = health.restingEnergyToday + health.activeEnergyToday
        return actual > 0 ? actual : tdeeGoalFallback
    }
    private var netCalories: Double { todayCalories - tdee }

    // MARK: - 数据计算：健康
    private var weekStepValues: [Double] {
        // 仅今日步数可从 HealthKit 拿到；其余占位为 0（免费账号无 HealthKit 时全 0，柱子为最小高度）
        let today = Double(health.stepsToday)
        return [0, 0, 0, 0, 0, 0, today]
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
        let time = AppFormat.time.string(from: due)
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
