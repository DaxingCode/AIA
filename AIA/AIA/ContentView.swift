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

/// 首页可跳转的目的地。统一枚举 → 单个 navigationDestination，规避多 destination 冲突。
enum HomeRoute: Hashable {
    case diet, health, bill, todo, todoTools, chat, chatVoice, settings, autoSetup
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

    @AppStorage("userNickname") private var userNickname = "阿宝的朋友"
    @AppStorage("aia.calorieGoalOverride") private var calorieGoalOverride: Double = 0
    @AppStorage("aia.calorieGoalIsCustom") private var calorieGoalIsCustom: Bool = false

    @State private var showCamera = false
    @State private var showPicker = false
    @State private var animateTiles = false

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

    // 目标常量（与记录页保持一致）
    private var calorieGoal: Double { calorieGoalIsCustom ? calorieGoalOverride : tdee }
    private let stepGoal: Int = 10000
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
                        tilesGrid
                        aiSummarySection
                    }
                    .padding()
                }
                AIBottomBar()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.path.append(.settings) } label: {
                        Image(systemName: "gearshape")
                            .font(AIATheme.Font.body.weight(.medium))
                    }
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                #if DEBUG
                print("[ContentView] navigationDestination for \(route)")
                #endif
                return Group {
                    switch route {
                    case .diet:      FoodListView()
                    case .health:    HealthListView()
                    case .bill:      BillListView()
                    case .todo:      ReminderListView()
                    case .todoTools: TodoToolsView()
                    case .chat:      ChatView(prefill: router.chatPrefill)
                    case .chatVoice: ChatView(autostartVoice: true)
                    case .settings:  SettingsView()
                    case .autoSetup: AutoRecognitionSetupView()
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
            guard quickAction.pending != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let p = quickAction.pending { consume(p) }
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
        // 外观模式开关：system → 不覆盖（跟随系统）；light/dark → 强制浅/深。
        // 挂在 NavigationStack 上即可覆盖整个窗口（含 push 进来的设置页、sheet、fullScreenCover）。
        .preferredColorScheme(appearanceColorScheme)
    }

    /// 检查后台识别留下的待确认结果（截图无感识别链路）：
    /// 走 saveOrCheckDuplicate —— 命中历史重复指纹也会**自动入库**，仅顶部弹「似乎已记录过」警告，
    /// 由用户决定编辑/保留/删除；未命中指纹则正常入库。两者都弹确认页供覆盖修改。
    @MainActor
    private func checkScreenshotPending() {
        guard pendingPresent == nil else { return }
        if let p = ScreenshotStore.loadPending() {
            let img = ScreenshotStore.loadPendingImage()
            let decision = RecognitionSaver.saveOrCheckDuplicate(result: p.result, rawText: p.rawText,
                                                                image: img, context: context, source: p.source ?? .cloud)
            pendingPresent = decision.present
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
        HStack(alignment: .firstTextBaseline) {
            Text("\(greeting)，\(userNickname)")
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
    }

    // MARK: - 四宫格（2 列）
    private var tilesGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            animatedTile(0, tile: dietTile)
            animatedTile(1, tile: healthTile)
            animatedTile(2, tile: billTile)
            animatedTile(3, tile: todoTile)
        }
        .task {
            // 延迟一帧，确保 LazyVGrid 首帧以隐藏态渲染，再过渡到可见触发入场动画
            try? await Task.sleep(nanoseconds: 60_000_000)
            animateTiles = true
        }
        .onDisappear {
            animateTiles = false
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
             badge: TileBadge(text: "已记 \(todayFoods.count) 餐", warn: false),
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

    // MARK: 健康
    private var healthTile: some View {
        tile(bg: AIATheme.healthBG, accent: AIATheme.health, icon: "heart.fill", route: .health,
             title: "健康管理",
             badge: TileBadge(text: health.stepsToday >= stepGoal ? "达标" : "今日", warn: false),
             number: "\(health.stepsToday)", unit: "步",
             isEmpty: healths.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                sparkBars
                VStack(alignment: .leading, spacing: 5) {
                    healthSummaryRow("运动时长", exerciseTimeText, AIATheme.sub)
                    healthSummaryRow("能量消耗", "\(healthStat("静息能量")) kcal", AIATheme.sub)
                    healthSummaryRow("静息心率", "\(healthStat("静息心率")) bpm", AIATheme.sub)
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
        "\(Int(health.exerciseTimeToday)) min"
    }

    // MARK: 账单
    private var billTile: some View {
        tile(bg: AIATheme.billBG, accent: AIATheme.bill, icon: "creditcard.fill", route: .bill,
             title: "账单管理",
             badge: TileBadge(text: "", warn: false),
             number: "¥\(Int(todayExpense))", unit: "今日支出",
             isEmpty: bills.isEmpty,
             headerMode: .titleLine) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    billMetric("本月收入", "¥\(Int(monthIncome))", AIATheme.income)
                    billMetric("本月支出", "¥\(Int(monthExpense))", AIATheme.expense)
                }
                HStack(spacing: 8) {
                    billMetric("本月预算", "¥\(Int(monthlyBudget))", AIATheme.sub)
                    billMetric("本月结余", "¥\(Int(monthBalance))",
                               monthBalance >= 0 ? AIATheme.income : AIATheme.expense)
                }
            }
            .padding(.top, 4)
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
        let healthMsgs = AISummary.healthMessages(health: health, healths: healths)
        let billMsgs = AISummary.billMessages(bills: bills)
        let todoMsgs = AISummary.todoMessages(reminders: reminders)

        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "今日事项预览", trailing: "阿宝AI提醒")
            VStack(spacing: 8) {
                rollingBubble(messages: dietMsgs, accent: AIATheme.food, active: rollSlot == 0)
                rollingBubble(messages: healthMsgs, accent: AIATheme.health, active: rollSlot == 1)
                rollingBubble(messages: billMsgs, accent: AIATheme.bill, active: rollSlot == 2)
                rollingBubble(messages: todoMsgs, accent: AIATheme.todo, active: rollSlot == 3)
            }
            .onReceive(rollTimer) { _ in
                rollSlot = (rollSlot + 1) % 4
            }
        }
    }

    /// 单条气泡：当 `active` 为真（由外层调度器轮流指派）且候选 >1 时，像转轴一样向上滚动切换到下一条；气泡框本身不动。
    private func rollingBubble(messages: [String], accent: Color, active: Bool) -> some View {
        RollingBubbleView(messages: messages, accent: accent, active: active)
    }

    private struct RollingBubbleView: View {
        let messages: [String]
        let accent: Color
        let active: Bool
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
        @ViewBuilder details: () -> Content
    ) -> some View {
        Button { router.path.append(route) } label: {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部类型色细色条：顶部两角与卡片圆角贴合，靠颜色秒认模块类型
                UnevenRoundedRectangle(
                    topLeadingRadius: AIATheme.rLG,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: AIATheme.rLG
                )
                .fill(accent)
                .frame(height: 4)

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
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
            .contentShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
            .frame(maxWidth: .infinity, minHeight: 165, maxHeight: 165)
            .clipped()
        }
        .buttonStyle(.plain)
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
        MiniBar(value: Double(health.stepsToday) / Double(stepGoal),
                color: AIATheme.health,
                height: 5)
    }

    // MARK: - 定时同步器（60 秒一次，作为前后台同步的补充）
    private func startPeriodicSync() {
        syncTimer?.invalidate()
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak sync] _ in
            print("[ContentView] 定时同步触发")
            sync?.autoSyncIfEnabled(context: context)
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
            jump(to: .chat)
        case .voice:
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
    private var tdee: Double { 1730 + health.activeEnergyToday }
    private var netCalories: Double { todayCalories - tdee }

    // MARK: - 数据计算：健康
    private func healthStat(_ key: String) -> String {
        healths.first(where: { $0.metric.contains(key) }).map { "\($0.value)\($0.unit)" } ?? "—"
    }
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
        let now = Date()
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
