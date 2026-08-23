// ChatView.swift
// ② 对话页 D话：按《UI完整页面流.html》屏幕 2 重做。
// 当前为 UI 壳：示例 AI 气泡 + 快捷意图 chips（跳转到各模块页）+ 输入栏（发送后追加用户气泡与占位回复）。
// 真 LLM 对话未接入（API Key 走云端代理的后续迭代）。
import SwiftUI
import SwiftData
import CoreData
import UniformTypeIdentifiers

/// 本地确认消息的统一开场白池；生成确认消息时随机取一个，避免每条都"记好啦"开头。
/// 同时被下方"过滤 AI 确认消息不进上下文"的逻辑复用，务必与那个过滤集合保持一致。
/// 自动保存类卡片前附的简短文字开场白（文字/语音/图片三条入口共用）。
let chatConfirmOpeners = ["记好啦", "收到～", "好嘞", "搞定", "记下啦", "OK，记上了"]

/// 本地创建函数走 processRecognition 水槽、已插入识别卡片后返回的哨兵值。
/// 调用方据此判定「已处理」，不再插入纯文本回复。
private let kHandledCard = "__CARD_INSERTED__"

/// 聊天内待确认饮食记录（内嵌在 AI 消息文本中，避免改 ChatMessage schema）。
private struct PendingFoodConfirm: Codable {
    let meal: String
    let name: String
    let portion: String
    let weight: Double
    let cal: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double            // 膳食纤维（克）
    let sugar: Double            // 糖（克）
    let sodium: Double           // 钠（毫克）
    let amount: Double?
    let originalText: String
}

struct ChatView: View {
    // >>> CHANGE-[2026-08-17 23:20:47]-[对话页8个LLM上下文@Query改按需fetch] 开始
    // 原因：这 8 个 @Query（foods/bills/reminders/healths/merchantMetas/recognitions/waters/recurringRules）
    // 只给打招呼/智能问答/本地兜底/agent 工具提供 LLM 上下文，列表渲染根本不用，
    // 但一进对话页就全表 materialize（无时间窗/无 fetchLimit），历史数据越多进页面越卡。
    // 修复：删除下方 8 行 @Query，改为 fetchLlmContextData() 在真正使用时才 context.fetch（首屏只查 ChatMessage 消息表）。
    // 回退：删除本标记段至下方「<<< ... 结束」标记之间所有改动（含 fetchLlmContextData() 定义及各调用处 data. 前缀引用）即可恢复。
    // <<< CHANGE-[2026-08-17 23:20:47]-[对话页8个LLM上下文@Query改按需fetch] 结束
    // >>> CHANGE-[2026-08-17 22:10:00]-[对话页首屏时间窗分页] 开始
    // 原因：原 @Query 全量 materialize 所有 ChatMessage，进对话页瞬间 CPU 接近 200%（全表扫 + O(N²) displayedMessages 放大）。
    // 修复：@Query 改用 FetchDescriptor 形态，加 fetchLimit:60 + 最近 7 天时间窗 predicate，
    // 首屏只 materialize 最近 7 天最多 60 条，进页面 I/O 降一个量级，零跳动不变（首帧即满、钉底）。
    // 更老消息由 loadEarlierMessages() 手动 fetch(createdAt < 首屏最老) 拼进 earlierMessages。
    // 回退：恢复 @Query(filter: #Predicate<ChatMessage> { !$0.syncDeleted }, sort: \.createdAt, order: .reverse) 全量写法。
    @Query({
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
        var d = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { !$0.syncDeleted && $0.createdAt >= start },
            sortBy: [SortDescriptor(\ChatMessage.createdAt, order: .reverse)]
        )
        d.fetchLimit = 60
        return d
    }()) private var recentMessages: [ChatMessage]
    /// 下拉加载的更早消息段（倒序，与 @Query 同源），拼在最近消息之前。
    @State private var earlierMessages: [ChatMessage] = []
    /// 视图使用正序序列：更早段（正序）+ 最近 60 条（reversed 转正序）。
    private var orderedMessages: [ChatMessage] {
        earlierMessages.reversed() + recentMessages.reversed()
    }
    /// 是否还有更早的消息未加载（由 fetchCount 决定，驱动「加载更早」入口显隐，避免无限加载）。
    @State private var hasMoreMessages = false
    /// 防止下拉自动加载时因视图反复进入视口而重复触发的锁。
    @State private var isLoadingEarlier = false
    @StateObject private var health = HealthManager.shared
    // 健康指标数据来源（逐指标切换），与首页 / 健康管理页设置联动。
    @AppStorage(HealthMetricKind.steps.sourceKey) private var stepsSource: HealthSourceMode = .auto
    @AppStorage(HealthMetricKind.tdee.sourceKey)  private var tdeeSource: HealthSourceMode = .auto
    private var hkUsable: Bool { health.authorized && health.isAvailable && health.hasHealthKitData }
    private func isAuto(_ kind: HealthMetricKind) -> Bool {
        let mode: HealthSourceMode = (kind == .steps) ? stepsSource : tdeeSource
        return mode == .auto && hkUsable
    }
    private var effectiveStepsToday: Double {
        isAuto(.steps) ? Double(health.stepsToday) : Double(ManualHealthStore.shared.steps(for: Date()))
    }
    private var effectiveActiveEnergy: Double {
        isAuto(.tdee) ? health.activeEnergyToday : Double(ManualHealthStore.shared.activeCalories(for: Date()))
    }
    // 消息多选（contextMenu 「选择」进入；底部条改为「取消 / 删除」）
    @State private var messageMultiSelectMode = false
    @State private var selectedMessageIDs = Set<PersistentIdentifier>()
    @State private var showMessageDeleteConfirm = false
    @State private var showPaywall = false
    @Environment(\.modelContext) private var context

    @State private var input = ""
    /// 语音录音中、识别到说话前的输入框占位文案；识别到说话后由 transcript 覆盖。
    private let voicePlaceholder = "请开口说话，我帮你记～"
    /// 首屏示例气泡随机轮播：用户点过任意一条后暂停，避免文案在用户阅读时跳走。
    @State private var examplePaused = false

    // 智能问答 Agent 总开关：云端全局配置（开发者中心切换，所有用户自动跟随）。
    // 用 @ObservedObject 观察 GlobalConfigStore，开发者改完云端后正在看对话页的用户也会即时响应。
    @ObservedObject private var globalConfig = GlobalConfigStore.shared
    @AppStorage("aia.greetingLLM") private var greetingLLM: Bool = true
    /// 招呼变体轮换索引（周一至周日自然循环，避免同一天相同变体）
    @AppStorage("aia.greetingVariant") private var greetingVariant = 0
    /// 早餐提醒每日限次：记录当天日期字符串，每天只提醒一次
    @AppStorage("aia.lastBreakfastReminderDate") private var lastBreakfastReminderDate = ""
    @FocusState private var isInputFocused: Bool
    @State private var isParsing = false
    /// 图片识别进行中信号：runImageRecognition 置位，驱动输入栏上方「小记正在识别...」提示。
    @StateObject private var recognitionActivity = RecognitionActivity.shared
    @State private var hasAutoFocused = false
    /// 首屏是否已执行初始落位（无动画多段校正），避免重复滚动与「两跳」。
    @State private var didInitialScroll = false
    @State private var pendingQueue: [ChatMessage] = []

    /// processNext 内若识别结果已通过 processRecognition 插入对话气泡，则不再重复插入纯文本回复。
    @State private var chatBubbleInserted = false

    // 语音输入
    @StateObject private var recognizer = SpeechRecognizer()
    /// 从首页底部栏的语音按钮进入时，自动开始语音输入（内联，不跳页面）
    var autostartVoice = false
    /// 从空态 CTA 进入时，自动填入输入框并延迟发送的文本。
    var prefill: String?
    /// 进入聊天页的来源：home / voice / todoReminder
    var entrySource: String = "home"
    /// 进入时是否自动聚焦输入框（仅首页文字输入框进入为 true，其余场景不弹键盘）
    var autofocusInput = false

    // 输入栏扩展功能（拍照/相册/文件）
    @State private var showInputActions = false
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var showFileImporter = false
    @State private var fileImportErrorMessage: String?

    init(prefill: String? = nil, autostartVoice: Bool = false, entrySource: String = "home", autofocusInput: Bool = false) {
        self.prefill = prefill
        self.autostartVoice = autostartVoice
        self.entrySource = entrySource
        self.autofocusInput = autofocusInput
        #if DEBUG
        print("[ChatView] init prefill=\(prefill ?? "nil") autostartVoice=\(autostartVoice) entrySource=\(entrySource) autofocusInput=\(autofocusInput)")
        #endif
    }

    /// 构造聊天记录查询：倒序取 `createdAt < before`（不含 before 当天）的未软删消息段，
    /// 带 fetchLimit 分页，避免 1000+ 历史时全量 materialize。
    /// before=nil 时退化为全量未软删（兜底）。
    private static func makeMessageDescriptor(limit: Int, before: Date? = nil) -> FetchDescriptor<ChatMessage> {
        let predicate: Predicate<ChatMessage>
        if let before {
            predicate = #Predicate<ChatMessage> { !$0.syncDeleted && $0.createdAt < before }
        } else {
            predicate = #Predicate<ChatMessage> { !$0.syncDeleted }
        }
        var d = FetchDescriptor<ChatMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\ChatMessage.createdAt, order: .reverse)]
        )
        d.fetchLimit = limit
        return d
    }

    /// 判断是否有比 earliest 更早的消息（局部 fetchCount，避免进页面全表扫造成额外 I/O / CPU 尖峰）。
    /// earliest=nil 时回退到全量 count。
    private func refreshHasMoreMessages(earliest: Date? = nil) {
        let hasEarlier: Bool
        if let earliest {
            let desc = ChatView.makeMessageDescriptor(limit: 1, before: earliest)
            hasEarlier = (try? context.fetchCount(desc)) ?? 0 > 0
        } else {
            let total = (try? context.fetchCount(FetchDescriptor<ChatMessage>(
                predicate: #Predicate<ChatMessage> { !$0.syncDeleted }))) ?? 0
            hasEarlier = total > 60
        }
        hasMoreMessages = hasEarlier
    }

    /// 加载更早的消息段（倒序），拼进 earlierMessages 前端。
    /// 时间窗分页下：@Query 只含最近 7 天，这里手动 fetch「比当前已加载最老消息更早」的段（createdAt < oldest）。
    private func loadEarlierMessages() {
        let loaded = recentMessages + earlierMessages
        guard let oldest = loaded.min(by: { $0.createdAt < $1.createdAt }) else { return }
        let older = (try? context.fetch(ChatView.makeMessageDescriptor(limit: 60, before: oldest.createdAt))) ?? []
        earlierMessages = older + earlierMessages
        refreshHasMoreMessages(earliest: oldest.createdAt)
        recomputeDisplayed()   // 更早段拼入后重算缓存
    }

    // 当前页面动态生成的小记招呼（不持久化），时间戳两种锚定：
    // ① 有历史（进入前 1s 窗口外存在历史消息）：钉在「最新一条历史」之后 0.5s → 旧历史在上、招呼居中、刚发的图在下。
    // ② 无历史（首页首次发图等，@Query 里只有本次会话新增）：钉在「会话最旧一条」之前 0.5s，确保招呼位于刚发的图上方。
    @State private var greetingMessage: ChatMessage?
    /// 进入页面时启动的 LLM 招呼生成任务，离开页面 / 重新进入时取消旧任务避免回灌。
    @State private var greetingTask: Task<Void, Never>?

    /// 用户说了食物但没给重量时，暂存食物名、餐次、原始日期与是否含具体时刻，等用户回复重量。
    /// 非 nil 时 app 先问「你大概吃了多少重量呀？」，收到重量回复后再结合入库。
    /// 注意：必须连同 date/hasTime 一起暂存——用户分两次说（如「昨天 下午3点 喝了咖啡」→「一杯」）时，
    /// 第二次组句不含「昨天/下午3点」，若不暂存日期/时刻，会回退成「今天 + 默认餐次时间」导致记错天。
    @State private var pendingWeightFood: (name: String, meal: String, date: Date, hasTime: Bool)?

    /// 识别协议解码结果缓存（文本不变即复用，避免 1000+ 条时每次 body 重复 decode 大 JSON）。
    private static var recognitionCache: [String: RecognitionResultPayload?] = [:]

    /// displayedMessages 计算结果缓存：body 每次重算都读它，避免 O(N²)+JSON 解码被反复放大（进页面 CPU 高主因之一）。
    /// 仅在 orderedMessages / greetingMessage / earlierMessages 变化时才重算。
    @State private var cachedDisplayed: [ChatMessage] = []
    // >>> CHANGE-[2026-08-22 11:45:00]-[缓存填充标志防删空回退补回] 开始
    // 原因：删除使 cachedDisplayed 变空时，原回退 `cachedDisplayed.isEmpty ? displayedMessages`
    //       会暴露尚未被 @Query 刷新过滤的软删消息（displayedMessages 实时算、可能仍含）→ 消息又显示，
    //       表现为"少部分情况点两次才删掉"。需区分"首帧未填充"与"删除后变空"：仅首帧回退。
    // 回退：删除 cacheEverFilled 及下方对回退逻辑的改写。
    @State private var cacheEverFilled = false
    // <<< CHANGE-[2026-08-22 11:45:00]-[缓存填充标志防删空回退补回] 结束
    // >>> CHANGE-[2026-08-17 21:36:03]-[缓存非空守卫防空白与循环] 开始
    // 原因：原 recomputeDisplayed 无条件 cachedDisplayed = displayedMessages；
    // 当 @Query 异步间隙 displayedMessages 为空时，会把缓存清成 []，
    // 触发首帧回退逻辑（cachedDisplayed.isEmpty ? 实时算）反复跑 O(N²)+JSON 解码 → 发烫；
    // 同时缓存被清空后首帧钉底/scrollToBottom 读 cachedDisplayed.last 为 nil → 不滚 → 偶发空白停顶。
    // 修复：仅当算出新数据（非空）才覆盖缓存；空结果保留旧缓存不清空。
    // 回退：恢复 cachedDisplayed = displayedMessages。
    private func recomputeDisplayed() {
        let fresh = displayedMessages
        guard !fresh.isEmpty else { return }
        cachedDisplayed = fresh
        // >>> CHANGE-[2026-08-22 11:45:00]-[缓存填充标志防删空回退补回] 开始
        cacheEverFilled = true
        // <<< CHANGE-[2026-08-22 11:45:00]-[缓存填充标志防删空回退补回] 结束
    }
    // <<< CHANGE-[2026-08-17 21:36:03]-[缓存非空守卫防空白与循环] 结束

    private var displayedMessages: [ChatMessage] {
        // 方式A：先标记空壳开场白（识别开场白 + 之后已无配对识别卡片气泡），渲染层直接隐藏，
        // 避免卡片被删而开场白残留时退化成「小圆点」。空壳判定基于已加载的 orderedMessages，
        // 不额外查库，保持 O(N)。
        let ordered = orderedMessages
        let shellOpeners = Set(ordered.enumerated().compactMap { idx, m -> ChatMessage? in
            guard m.role == .ai,
                  RecognitionSaver.isRecognitionOpener(m.text),
                  !m.text.hasPrefix(RECOGNITION_RESULT_PREFIX) else { return nil }
            let later = ordered[(idx + 1)...]
            let hasCard = later.contains { $0.text.hasPrefix(RECOGNITION_RESULT_PREFIX) }
            return hasCard ? nil : m
        }.map { $0.persistentModelID })

        // 兜底：历史遗留的「空 items 识别协议消息」不再展示（否则渲染成「（无识别结果）」空壳）
        let filtered = ordered.filter { m in
            if shellOpeners.contains(m.persistentModelID) { return false }
            guard m.text.hasPrefix(RECOGNITION_RESULT_PREFIX) else { return true }
            if let cached = Self.recognitionCache[m.text] { return cached?.items.isEmpty == false }
            let payload = decodeRecognitionPayload(m.text)
            Self.recognitionCache[m.text] = payload
            return payload.map { !$0.items.isEmpty } ?? false
        }
        // @Query 已带 fetchLimit:60 取最近消息，earlierMessages 为更早段，二者合并后 orderedMessages 即已加载全集，
        // 无需再 suffix 截断（旧 fetchMessages 用 suffix 是因为分页在 @State 里手动维护）。
        let limited = filtered
        // 【D】兜底过滤：理论上 fetchMessages 已按 !syncDeleted 取数，这里再防一层
        // （如 greetingMessage 拼接、状态竞态边界），确保任何软删消息绝不进入渲染列表。
        let safe = limited.filter { !$0.syncDeleted }
        if let g = greetingMessage {
            return (safe + [g]).sorted { $0.createdAt < $1.createdAt }
        }
        return limited
    }

    /// 时间分隔行插入间隔阈值（秒）。微信为 5 分钟，这里保持一致。
    /// 语义即「隔了这么久再说话 = 新发起一段对话」，因此不需要额外的会话标记。
    private static let timeDividerGap: TimeInterval = 5 * 60

    /// 一次性算出每个 index 是否显示时间分隔行，避免逐行重复访问 `displayedMessages`
    /// （该属性每次访问都要 filter + JSON decode + sorted，逐行调用会变成 O(N²)）。
    /// 判断一条消息是否会产生可见内容（用于时间戳守门）。
    /// 软删消息、空壳识别开场白、空 items 识别卡都不应单独带时间戳，
    /// 否则删除这类消息后会残留「没有消息的时间戳」。
    private static func messageProducesVisibleContent(_ m: ChatMessage) -> Bool {
        if m.syncDeleted { return false }
        // 空壳识别开场白（后面已无配对识别卡）不展示内容，时间戳应随之下沉到真正的卡片。
        if m.role == .ai,
           RecognitionSaver.isRecognitionOpener(m.text),
           !m.text.hasPrefix(RECOGNITION_RESULT_PREFIX) {
            return false
        }
        // 空 items 识别协议消息不展示内容。
        if m.text.hasPrefix(RECOGNITION_RESULT_PREFIX) {
            let cached = Self.recognitionCache[m.text]
            let payload = cached ?? decodeRecognitionPayload(m.text)
            Self.recognitionCache[m.text] = payload
            return payload.map { !$0.items.isEmpty } ?? false
        }
        return true
    }

    private static func dividerFlags(for list: [ChatMessage]) -> [Bool] {
        guard !list.isEmpty else { return [] }
        var flags = [Bool](repeating: false, count: list.count)
        // 找到第一条「会产生可见内容」的消息作为首锚点。若整段都不可见则全 false。
        // 不能直接用 list[0]：若首条是空壳开场白/空 items 卡，渲染层守门会把它剔除，
        // 此刻强行 flags[0]=true 会让时间戳无处落地。
        var firstAnchor: Int?
        for i in 0..<list.count where messageProducesVisibleContent(list[i]) {
            firstAnchor = i
            break
        }
        guard let first = firstAnchor else { return flags }
        flags[first] = true
        // 分段时间锚点应"只减不增"：以「上一条已显示时间戳的时间」为基准，
        // 而非「相邻消息的时间」。否则删除中间消息会让原本间隔 < timeDividerGap
        // 的两条消息变成间隔 > timeDividerGap，触发新增时间戳（表现为"删了消息
        // 时间戳还在/反而多了"）。
        // 关键：分段基准只纳入「可见消息」，与渲染层守门口径（showDivider[idx] &&
        // messageProducesVisibleContent）严格对齐。若把不可见消息（如空壳开场白）
        // 也纳入，它会偷走时间锚点，导致其后紧邻的真实可见消息被迫多出一个时间戳。
        var lastShowedAt = list[first].createdAt
        for i in (first + 1)..<list.count {
            if !messageProducesVisibleContent(list[i]) { continue }
            if list[i].createdAt.timeIntervalSince(lastShowedAt) > timeDividerGap {
                flags[i] = true
                lastShowedAt = list[i].createdAt
            }
        }
        return flags
    }

    var body: some View {
        // >>> CHANGE-[2026-08-22 11:51:07]-[键盘修复：bottomBar 改回 safeAreaInset 让位] 开始
        // 原因：之前把 bottomBar 从 safeAreaInset 抽到 VStack，并给 messageList 加 .frame(maxHeight:.infinity)，
        //       键盘升起时 safeArea 首帧突变导致 messageList 整片白屏；且 VStack 自压缩让位不可靠，气泡被键盘/输入栏遮挡。
        // 修复：bottomBar 回到 messageList.safeAreaInset(edge:.bottom)，由系统确定性把 ScrollView 视口底压到输入栏顶，
        //       配合删除 .frame(maxHeight:.infinity)，白屏与遮挡一并解决。
        // <<< CHANGE-[2026-08-22 11:51:07]-[键盘修复：bottomBar 改回 safeAreaInset 让位] 结束
        messageList
            .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("小记")
        .task { UsageAnalytics.logOpen("chat") }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
                    // 中间标题：圆形头像 + "我是小记" + 副标（与首条气泡同款内容）
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image("AIAvatar")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AIATheme.hairline, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("我是小记")
                            .font(AIATheme.Font.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("你的私人专属AI助理")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isInputFocused {
                    Button {
                        isInputFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .foregroundStyle(AIATheme.sub)
                    }
                }
            }
        }
        .background(AppBackgroundView())
        .onAppear {
            // 语音自动启动与键盘聚焦解耦：不依赖 hasAutoFocused，否则会被上方 ScrollView 的 onAppear 抢先消费标记而跳过。
            // 从语音快捷操作/语音按钮进入：不弹键盘，自动开启内联语音输入。
            // 延迟到视图与音频会话稳定后再 start，规避冷启动跳转时的音频会话竞态。
            if autostartVoice {
                #if DEBUG
                print("[ChatView] onAppear autostartVoice, will start recognizer after 0.3s (isRecording=\(recognizer.isRecording))")
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    #if DEBUG
                    print("[ChatView] onAppear calling recognizer.start()")
                    #endif
                    if !recognizer.isRecording {
                        let gen = UIImpactFeedbackGenerator(style: .medium)
                        gen.prepare()
                        gen.impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            recognizer.start()
                        }
                    }
                }
            }

            // 从空态 CTA 进入：自动填入预置文本，2 秒后自动发送，并清空全局 prefill 避免重复触发。
            if let p = prefill, !p.isEmpty, !autostartVoice {
                #if DEBUG
                print("[ChatView] onAppear prefill=\(p), will fill and send after 2s")
                #endif
                input = p
                NavigationRouter.shared.chatPrefill = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    send()
                }
            }
        }
        // 语音输入：录音态切换时控制占位文案（transcript 在录音初期不变化，不能只靠它）
        // 开始录音且尚无转写 → 显示占位；停止录音 → 清掉占位（避免残留）。
        .onReceive(recognizer.$isRecording) { recording in
            if recording {
                if input.isEmpty || input == voicePlaceholder {
                    input = voicePlaceholder
                }
            } else {
                if input == voicePlaceholder { input = "" }
            }
        }
        // 语音输入：录音中实时把转写文字写入输入框（内联，不跳页面）
        // 识别到说话前（transcript 为空）显示占位文案；一旦有转写即覆盖占位。
        .onReceive(recognizer.$transcript) { text in
            if recognizer.isRecording {
                input = text.isEmpty ? voicePlaceholder : text
            }
        }
        // 兜底：当用户已经在对话页（任何 ChatView 实例）时，从快捷操作再次进入不会触发 onAppear，
        // 但会收到 .quickActionColdLaunch 通知。这里只要通知里的 action 是语音，就直接启动语音，
        // 不依赖本实例的 autostartVoice 标记（因为底部栏进来的 ChatView 默认 autostartVoice=false）。
        .onReceive(NotificationCenter.default.publisher(for: .quickActionColdLaunch)) { note in
            let actionRaw = note.userInfo?["action"] as? String
            #if DEBUG
            print("[ChatView] received quickActionColdLaunch, action=\(actionRaw ?? "nil"), autostartVoice=\(autostartVoice), isRecording=\(recognizer.isRecording)")
            #endif
            if actionRaw == QuickAction.voice.rawValue, !recognizer.isRecording {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    #if DEBUG
                    print("[ChatView] (notification) calling recognizer.start()")
                    #endif
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    recognizer.start()
                }
            }
        }
        .onDisappear {
            recognizer.stop()
            // 离开页面时取消正在飞的招呼 LLM 任务，避免重新进入页面时旧任务回灌到新气泡。
            greetingTask?.cancel()
        }
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .alert("提示", isPresented: Binding(
            get: { fileImportErrorMessage != nil },
            set: { if !$0 { fileImportErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(fileImportErrorMessage ?? "")
        }
        // 消息多选模式：底部出现「取消 / 全选 / 删除(N)」操作条
        .overlay(alignment: .bottom) {
            if messageMultiSelectMode {
                MultiSelectBottomBar(
                    count: selectedMessageIDs.count,
                    totalCount: orderedMessages.count,
                    onCancel: {
                        messageMultiSelectMode = false
                        selectedMessageIDs.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allIDs = Set(orderedMessages.map(\.persistentModelID))
                        if selectedMessageIDs.isSuperset(of: allIDs) {
                            selectedMessageIDs.subtract(allIDs)
                        } else {
                            selectedMessageIDs.formUnion(allIDs)
                        }
                    },
                    onDelete: {
                        guard !selectedMessageIDs.isEmpty else { return }
                        showMessageDeleteConfirm = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: messageMultiSelectMode)
        .alert(NSLocalizedString("common.confirmDelete", comment: ""), isPresented: $showMessageDeleteConfirm) {
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { }
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                deleteSelectedMessages()
            }
        } message: {
            Text(String(format: NSLocalizedString("common.deleteCount", comment: ""), selectedMessageIDs.count))
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    /// 小记招呼：每次进入页面时根据本地数据与用户习惯实时生成（不持久化，避免重复堆积）。
    private var greeting: String { buildGreeting() }

    /// 把一次「新鲜识别结果」转成一条 AI 消息插入对话流（进气泡，不弹确认页）。
    private func insertRecognitionBubble(result: RecognitionResult, imageName: String? = nil) {
        let items = buildPendingItems(from: result, source: "image", imageName: imageName)
        guard !items.isEmpty else { return }
        let payload = RecognitionResultPayload(
            types: result.types ?? items.map { $0.type.rawValue },
            source: "image",
            autoSaved: false,
            items: items
        )
        let msg = ChatMessage(role: .ai, text: encodeRecognitionPayload(payload), createdAt: Date())
        context.insert(msg)
        // @Query 自动响应式刷新，无需手动 fetchMessages
    }

    /// 底部输入区（tips + chips + 输入栏 + 提示），作为 messageList 的 .safeAreaInset(edge: .bottom)。
    /// 键盘升起时 safeAreaInset 确定性把 ScrollView 视口底压到本栏顶之上，气泡滚到底即不被键盘/输入栏遮挡。
    private var bottomBar: some View {
        VStack(spacing: 0) {
            // 处理中提示（放在 chips 上方，避免遮挡输入）：文字问答=思考中，图片识别=识别中
            if isParsing || recognitionActivity.isRecognizing {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(recognitionActivity.isRecognizing ? "小记正在识别..." : "小记正在思考...")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 6)
                .background(Color(.systemBackground))
            }

            // 快捷意图 chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("记饮食", route: .diet)
                    chip("看健康", route: .health)
                    chip("查账单", route: .bill)
                    chip("加待办", route: .todo)
                    chip("识别记录", route: .recognitionRecords)
                    feedbackChip
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 6)
            .background(Color(.systemBackground))

            // 语音错误提示（自动启动失败时显示，帮助定位权限/音频问题）
            if let error = recognizer.errorMessage {
                Text(error)
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.warn)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            // 扩展功能按钮（拍照/相册/文件）
            if showInputActions {
                HStack(spacing: 0) {
                    inputActionButton(icon: "camera.fill", title: NSLocalizedString("chat.action.camera", comment: "")) {
                        showInputActions = false
                        showCamera = true
                    }
                    inputActionButton(icon: "photo.fill", title: NSLocalizedString("chat.action.album", comment: "")) {
                        showInputActions = false
                        showPicker = true
                    }
                    inputActionButton(icon: "folder.fill", title: NSLocalizedString("chat.action.file", comment: "")) {
                        showInputActions = false
                        showFileImporter = true
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
            }

            // 输入栏
            HStack(spacing: 9) {
                Button {
                    if recognizer.isRecording {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        recognizer.stop()
                        if input == voicePlaceholder { input = "" } // 仅清占位，保留已识别的转写文字
                    } else {
                        isInputFocused = false
                        // 先立即同步触发触觉（与关麦同款时机），再把录音会话激活推迟 100ms，
                        // 避免 setActive(true) 的同步音频初始化把 Taptic Engine 渲染挤掉。
                        let gen = UIImpactFeedbackGenerator(style: .medium)
                        gen.prepare()
                        gen.impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            recognizer.start()
                        }
                    }
                } label: {
                    // >>> CHANGE-[2026-08-23 09:59:50]-[语音录音态脉冲可视化] 开始
                    // 原因：麦克风录音时只有图标变红 + 文字实时进框，没有"正在听"的明确指示，用户不确定录音是否生效。
                    //       录音态在图标外套一圈脉冲光圈（scale + opacity 循环），给清晰的"正在录音"反馈；非录音态无动画。
                    // 回退：删除 overlay 脉冲块，恢复原 Image 单标签即可。
                    Image(systemName: recognizer.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(AIATheme.Font.title2.weight(.medium))
                        .foregroundStyle(recognizer.isRecording ? AIATheme.warn : AIATheme.sub)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Circle()
                                .stroke(AIATheme.warn, lineWidth: 2)
                                .opacity(recognizer.isRecording ? 0.6 : 0)
                                .scaleEffect(recognizer.isRecording ? 1.6 : 1.0)
                                .animation(
                                    recognizer.isRecording
                                        ? Animation.easeOut(duration: 1.1).repeatForever(autoreverses: false)
                                        : .default,
                                    value: recognizer.isRecording
                                )
                        )
                    // <<< CHANGE-[2026-08-23 09:59:50]-[语音录音态脉冲可视化] 结束
                }
                TextField("请输入文字，或点麦克风说话", text: $input, axis: .vertical)
                    .font(.system(size: 15.5))
                    .lineLimit(1...5)
                    .padding(.vertical, 15).padding(.horizontal, 14)
                    .background(AIATheme.surfaceSecondary)
                    .clipShape(Capsule())
                    .focused($isInputFocused)
                if input.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showInputActions.toggle()
                        }
                        isInputFocused = false
                    } label: {
                        Image(systemName: showInputActions ? "xmark" : "plus")
                            .font(AIATheme.Font.title2.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(AIATheme.blue)
                            .clipShape(Circle())
                    }
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up")
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(AIATheme.blue)
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(.systemBackground))
            .overlay(alignment: .top) { Divider() }

            // 底部小字提示：免费版 AI 识别结果仅供参考，引导升级 Pro。
            Text("免费版AI识别结果仅供参考，如需体验更好可升级Pro版")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .background(Color(.systemBackground))
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            // 微信式确定性钉底：持有 proxy，所有「滚到底」走一次 proxy.scrollTo（等价于 UIScrollView.setContentOffset），
            // 不依赖 .scrollPosition 声明式跟随——声明式会在内容/安全区(键盘)过渡态重算 offset，导致「弹起又落下/被挡」。
            // 远端 item 未渲染的可靠性由「onAppear 让帧后 scrollTo」保证（LazyVStack 已完成首屏布局）。
            // >>> CHANGE-[2026-08-17 21:31:57]-[首帧缓存空回退保零跳动] 开始
            // 原因：上一轮把列表改读 cachedDisplayed 缓存，但缓存首帧填充在 .onAppear（晚于首帧 body 渲染半拍），
            // 导致首帧 cachedDisplayed 仍为空 → 列表先空帧后暴涨 → 进页面又跳。
            // 修复：首帧缓存未就绪时回退读 displayedMessages 实时计算（首帧即满、钉底、不跳）；
            // .onAppear 填好缓存后后续帧统一走缓存，CPU 优化保留。
            // 回退：恢复 let list = cachedDisplayed.isEmpty ? displayedMessages : cachedDisplayed
            // >>> CHANGE-[2026-08-22 11:45:00]-[缓存填充标志防删空回退补回] 开始
            // 首帧缓存未填充（cacheEverFilled==false）才回退读 displayedMessages 保不空白/不跳；
            // 一旦填充过，删除导致缓存变空也走空缓存（渲染空），不再回退暴露未刷新的软删消息。
            // 回退：恢复 let list = cachedDisplayed.isEmpty ? displayedMessages : cachedDisplayed
            let list = cacheEverFilled ? cachedDisplayed : displayedMessages
            // <<< CHANGE-[2026-08-22 11:45:00]-[缓存填充标志防删空回退补回] 结束
            // <<< CHANGE-[2026-08-17 21:31:57]-[首帧缓存空回退保零跳动] 结束
            let showDivider = ChatView.dividerFlags(for: list)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if hasMoreMessages {
                        earlierLoader(proxy: proxy)
                    }
                    ForEach(Array(list.enumerated()),
                            id: \.element.persistentModelID) { idx, m in
                        // 【A】渲染层守门：仅当该消息未被软删且确实会产生可见内容时，
                        // 才显示其时间戳分隔行，杜绝「删了消息却残留孤立时间戳」。
                        if showDivider[idx],
                           !m.syncDeleted,
                           Self.messageProducesVisibleContent(m) {
                            ChatTimeDivider(date: m.createdAt)
                        }
                        messageRow(m)
                    }
                    // >>> CHANGE-[2026-08-22 14:57:57]-[底部占位锚点防末条被输入栏吞] 开始
                    // 原因：XS Max 老机型一进对话页，招呼/最新消息被底部输入栏(safeAreaInset)盖住。
                    //       根因：scrollToLatest/scrollToBottom 用 anchor:.bottom 锚定「末条气泡 item 底」，
                    //       吞掉底部 padding，老芯片首帧 safeAreaInset 让位与滚动落位不同步 → 末条被输入栏盖。
                    // 修复：追加透明占位锚点作为「真·内容底」，滚动一律锚定它，保证底部 padding 一并滚入可视区。
                    // 回退：删除本段占位锚点 + padding(.bottom,24) 恢复 12。
                    // <<< CHANGE-[2026-08-22 14:57:57]-[底部占位锚点防末条被输入栏吞] 结束
                    Color.clear.frame(height: 0).id("chat-bottom-anchor")
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .contentShape(Rectangle())
                .animation(didInitialScroll ? scrollAnimation : nil, value: list.count)
                .onTapGesture {
                    isInputFocused = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // 微信式自动贴底：ScrollView 内容布局后默认保持底部对齐（进页直接显示最新历史），
            // 气泡追加时自动吸底（新消息式）。不依赖任何 scrollTo/scrollPosition——
            // 手动 scrollTo 在 LazyVStack 远端 item 未渲染时失效（这是之前停在周三的根因）。
            // 此前该修饰符配合 .frame(maxHeight:.infinity)+VStack 布局导致白屏，现已无此干扰。
            .defaultScrollAnchor(.bottom)
            // >>> CHANGE-[2026-08-22 11:51:07]-[键盘修复：回退 .frame(maxHeight:.infinity) 消除首帧白屏] 开始
            // 原因：.frame(maxHeight:.infinity) 在 VStack 里让 ScrollView 撑满，配合 .defaultScrollAnchor(.bottom)
            //       与第三方键盘(wetype)的 safeArea 首帧突变，把 messageList 渲染成空白。
            // 修复：删除该行，恢复 ScrollView 按内容分配高度，白屏消失。
            // <<< CHANGE-[2026-08-22 11:51:07]-[键盘修复：回退 .frame(maxHeight:.infinity) 消除首帧白屏] 结束
            .onAppear {
                // 首屏由 @Query(recentMessages) 自动同步填充，首帧即满、零跳动，无需手动 fetch。
                // 先算一次缓存，保证列表（读 cachedDisplayed）首帧即有数据。
                recomputeDisplayed()
                // >>> CHANGE-[2026-08-17 22:21:08]-[首帧同步生成招呼防白屏] 开始
                // 原因：原招呼气泡在 onAppear 末尾的 DispatchQueue.main.async 里生成，晚于首帧 body 渲染半拍；
                // 首帧 @Query 未就绪时列表既无历史也无招呼 → 中间纯黑(白屏)。
                // 修复：在 onAppear 开头同步生成招呼气泡（greetingDate 已在本闭包下方算出，此处先用兜底 Date.now）；
                // 真正精确锚点后仍由下方 main.async 块兜底（greetingMessage 已非 nil 则跳过）。
                // 回退：删除本段（回到仅下方 async 生成）。
                // 注意：greetingDate 精确值依赖下方 anchor 计算，但同步生成只需占位锚点即可避免空白，
                // 下方 main.async 块会在 greetingMessage 仍 nil 时用精确 greetingDate 重建（实际本帧已生成则不重建）。
                // <<< CHANGE-[2026-08-17 22:21:08]-[首帧同步生成招呼防白屏] 结束
                // 仅判定是否还有更早消息以显隐「加载更早」入口（局部 fetchCount，不扫全表）。
                let oldest = recentMessages.min(by: { $0.createdAt < $1.createdAt })?.createdAt
                refreshHasMoreMessages(earliest: oldest)
                // 消费「本次会话锚点」：无论是否首次滚动都读走并清零，
                // 避免上一次遗留的陈旧锚点把下次进入的招呼气泡钉到对话中间。
                let sessionAnchor = NavigationRouter.shared.chatSessionAnchor
                NavigationRouter.shared.chatSessionAnchor = nil
                if !hasAutoFocused {
                    hasAutoFocused = true
                    if autofocusInput {
                        isInputFocused = true
                    }
                }
                if autofocusInput {
                    // 消费后清零，避免后续其他 .chat 进入误弹；延到下一 runloop 避开 view update 期改状态
                    DispatchQueue.main.async { NavigationRouter.shared.chatAutoFocus = false }
                }
                // >>> CHANGE-[2026-08-17 15:05:00]-[对话页首屏干净落位] 开始
                // 原因：原 for d in [0.0,...] 里 d:0.0 虽同步执行，但排在 didInitialScroll 置位之前，
                // 且依赖 defaultScrollAnchor(.bottom) 在 LazyVStack 首帧高度未定时的不可靠落位，
                // 快芯片(15 Pro Max)首帧先渲染顶部历史一帧 → 显出「先见历史再跳最新」卡顿感。
                // 修复：进入即同步 disablesAnimations 钉底（proxy 在 onAppear 闭包内已就绪），
                // 首帧直接是最新屏，消除顶部闪历史；异步校正仅补高度、不再反向跳。
                // 回退：恢复 defaultScrollAnchor 依赖 + 原 for 循环首拍延迟写法。
                // 招呼气泡锚点：用户要求招呼时间 = 当前进入时刻（今天），且气泡位置与文案一致地落在最底部。
                // 因此 greetingDate 直接取 Date.now，不再钉在历史末条之后 —— 有/无历史场景统一为“进页此刻”。
                // （旧实现：有历史钉在最新历史之后 0.5s，无历史钉在本次会话起点之前 0.5s；现弃用以符合“显示当前进入时间”诉求。）
                // sessionAnchor 仍仅用于下方「消费锚点防陈旧」逻辑，与 greetingDate 不再耦合。
                // orderedMessages 是正序（最旧在前、最新在后，见 47 行）。
                // sessionAnchor 已在上方消费并清零（717-718 行），此处无需再持有。
                let greetingDate = Date.now
                // >>> CHANGE-[2026-08-17 22:36:13]-[首帧钉底改到列表首次非空] 开始
                // 原因：原首帧钉底读 initialList（cachedDisplayed/displayedMessages）仍依赖 @Query 在 onAppear 此刻已就绪，
                // 但 SwiftData @Query 首帧常晚于 onAppear 异步 materialize → 读到的列表为空 → 钉底被跳过/钉错位置 → 偶发白屏。
                // 修复：删掉此刻钉底，改由下方 .onChange(of: cachedDisplayed.count) 在「列表首次真正非空」时精准钉底，
                // 无论 @Query/招呼晚到多少帧，只要首次有内容就钉底一次，绝不白屏。
                // 回退：恢复上一版 initialList 钉底 + scrollToBottom(delay:0.4) 两段。
                // <<< CHANGE-[2026-08-17 22:36:13]-[首帧钉底改到列表首次非空] 结束
                // 招呼气泡与首屏同帧生成：@Query 首帧即满 → 历史由下方首次非空守卫钉底 → 此处插入招呼只是底部追加一行，
                // defaultScrollAnchor(.bottom) 已贴底，无反向跳。didInitialScroll 置位已移至首次非空守卫内
                // （历史无动画、招呼有动画：守卫钉底时置位，后续招呼插入即走 scrollAnimation 从下滚出）。
                // >>> CHANGE-[2026-08-17 22:48:59]-[招呼延迟0.4s滑出-两阶段解耦] 开始
                // 原因：原招呼在 onAppear 同步生成（首帧即入列表）→ 招呼跟历史同帧渲染，看不到「先历史、后招呼从底部滑出」的微信式层次。
                // 修复：删除同步生成，改为延迟 0.4s 注入——历史由下方首次非空守卫无动画钉底（阶段A），
                // 招呼注入走 .onChange(of: greetingMessage) 的带动画滚动从底部滚出（阶段B）。
                // 回退：恢复下方 if greetingMessage == nil { ... } 同步生成块。
                if greetingMessage == nil {
                    let initial = buildGreeting()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                        guard self.greetingMessage == nil else { return }
                        self.greetingMessage = ChatMessage(role: .ai, text: initial, createdAt: greetingDate)
                        self.startGreetingLLMTask(initial: initial)
                    }
                }
                // <<< CHANGE-[2026-08-17 22:48:59]-[招呼延迟0.4s滑出-两阶段解耦] 结束
                // >>> CHANGE-[2026-08-17 22:36:13]-[首帧钉底改到列表首次非空] 开始
                // 原因：原 scrollToBottom(delay:0.4) 依赖 @Query 在 onAppear 首帧已就绪，晚到时钉在空/不完整列表。
                // 修复：删除此刻钉底，仅由下方 .onChange(of: cachedDisplayed.count) 首次非空守卫精准钉底。
                // 回退：恢复 scrollToBottom(proxy: proxy, delay: 0.4, animated: false)。
                // <<< CHANGE-[2026-08-17 22:36:13]-[首帧钉底改到列表首次非空] 结束
                // <<< CHANGE-[2026-08-17 15:05:00]-[对话页首屏干净落位] 结束
                // >>> CHANGE-[2026-08-22 14:57:57]-[首帧延迟确定性落位防被输入栏吞] 开始
                // 原因：XS Max 老芯片首帧 @Query/招呼/safeAreaInset 让位不同步，defaultScrollAnchor 落位不可靠，
                //       末条气泡被输入栏盖。延迟到首帧重算风暴后（0.6s），用确定性 scrollTo 占位锚点再钉底一次。
                // 回退：删除本段。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { proxy.scrollTo("chat-bottom-anchor", anchor: .bottom) }
                }
                // <<< CHANGE-[2026-08-22 14:57:57]-[首帧延迟确定性落位防被输入栏吞] 结束
            }
            // >>> CHANGE-[2026-08-17 21:36:03]-[去掉全局存库监听治发烫] 开始
            // 原因：原 .onReceive(NSManagedObjectContextDidSaveNotification) 监听【全局每一次 modelContext 保存】
            // （健康/账单/云同步心跳/其它模块），在对话页反复 recomputeDisplayed()+scrollToBottom()，
            // 与首帧回退实时算叠加形成持续重算 → 手机发烫。@Query 本身已响应式，
            // .onChange(of: orderedMessages.count) 已足够兜底，此全局监听纯属多余且危险。
            // 修复：整段删除，滚动校正仅靠 @Query 响应式 + .onChange(of: orderedMessages.count)。
            // 回退：恢复 .onReceive(NSManagedObjectContextDidSaveNotification) 整段。
            // @Query(recentMessages) 已自动响应式刷新（任何 modelContext 保存后下一帧 body 即反映），
            // 无需手动 fetch；下方 .onChange(of: orderedMessages.count) 负责滚动校正。
            // <<< CHANGE-[2026-08-17 21:36:03]-[去掉全局存库监听治发烫] 结束
            // >>> CHANGE-[2026-08-17 23:05:00]-[首次非空守卫改监听displayedMessages] 开始
            // 原因：原守卫监听 cachedDisplayed.count，但渲染层回退逻辑读的是 displayedMessages——
            // 首帧缓存空时列表照常渲染 displayedMessages，可 cachedDisplayed 恒为 0 → 守卫永不触发
            // → didInitialScroll 永远 false → defaultScrollAnchor(.bottom) 不工作 + 动画走 nil + 不钉底
            // → 列表停在初始位置，配合缓存/招呼时序问题表现成整页白屏。
            // 修复：守卫改监听 displayedMessages.count（反映「列表真有内容」而非缓存是否被填），
            // @Query 到或 greetingMessage 注入任一路径首次非空都精准钉底一次并置位 didInitialScroll；
            // 不破坏 recomputeDisplayed 的非空守卫 CPU 优化（缓存仍受其保护）。
            // 回退：恢复监听 cachedDisplayed.count + 读 cachedDisplayed.last。
            // >>> CHANGE-[2026-08-22 12:01:29]-[首次非空守卫改读渲染真实末条] 开始
            // 原因：原守卫读 displayedMessages.last 钉底，但渲染列表实际读 list = cacheEverFilled ? cachedDisplayed : displayedMessages；
            //       当气泡(greetingMessage)延迟 0.4s 注入、cachedDisplayed 已填充时，displayedMessages.last 未必是气泡，
            //       守卫钉到非末条 → 气泡（在更底）被挡、仅其上方时间戳可见。
            // 修复：改读 cachedDisplayed.last（渲染真实最后一条，含气泡），钉底对象正确。
            // <<< CHANGE-[2026-08-22 12:01:29]-[首次非空守卫改读渲染真实末条] 结束
            // 首屏钉底已移入 ScrollView 内层 .onChange(of: list.count)（见 681 行附近），此处不再冗余守卫，
            // 避免两套滚动逻辑抢 didInitialScroll。
            // <<< CHANGE-[2026-08-17 23:05:00]-[首次非空守卫改监听displayedMessages] 结束
            // >>> CHANGE-[2026-08-17 23:41:25]-[新消息不自动显示修复-监听集合而非数量] 开始
            // 原因：渲染列表绝大多数读 cachedDisplayed 缓存（见 list = cachedDisplayed.isEmpty ? displayedMessages : cachedDisplayed），
            // 缓存只在 recomputeDisplayed() 更新；原 .onChange(of: orderedMessages.count) 只监听消息【数量】。
            // 当历史消息 ≥ 60 条（@Query fetchLimit:60）时，发新消息 → recentMessages 挤掉最旧一条 → count 不变
            // → onChange 不触发 → recomputeDisplayed 不执行 → 新消息已入库但渲染读旧缓存 → 必须退出重进才显示。
            // 修复：改监听 recentMessages 集合本身（@Model 引用数组，Equatable 逐元素比较 persistentModelID），
            // 只要 @Query 刷新产生的内容不同的新数组（新增/挤掉均触发，count 不变也触发）就重算缓存+滚动校正。
            // 回退：恢复 .onChange(of: orderedMessages.count)。
            // >>> CHANGE-[2026-08-22 08:33:31]-[删除消息不强制滚底] 开始
            // 原因：原写法 recentMessages 一变（无论新增还是删除）都 scrollToBottom，
            //       删除历史消息时屏幕被错误拽到底。仅当 new.count >= old.count（新增/更新）
            //       才补偿滚动，删除（count 变小）时保持原滚动位置。
            // 回退：恢复无条件 for d in [...] scrollToBottom(proxy:...)。
            .onChange(of: recentMessages) { old, new in
                guard !isLoadingEarlier else { return }
                recomputeDisplayed()   // 数据集合变化，重算缓存（切断 body 重算放大）
                // 仅新增/更新（count 不减）时钉到底；删除历史消息保持原滚动位置，不被错误拽到底。
                if new.count >= old.count {
                    scrollToLatest(proxy: proxy)
                }
            }
            // <<< CHANGE-[2026-08-22 08:33:31]-[删除消息不强制滚底] 结束
            // <<< CHANGE-[2026-08-17 23:41:25]-[新消息不自动显示修复-监听集合而非数量] 结束
            .onChange(of: greetingMessage) { old, new in
                // 招呼气泡插入/替换 → 重算缓存（displayedMessages 含 greetingMessage）
                recomputeDisplayed()
                // >>> CHANGE-[2026-08-17 23:09:26]-[招呼注入带动画滚出-专属弹性] 开始
                // 原因：招呼延迟 0.4s 注入后，仅靠 defaultScrollAnchor(.bottom) 不保证带动画从底部滑出。
                // 修复：区分「注入（old==nil→new 非 nil）」与「替换（LLM 刷新文案，old 非 nil）」，
                // 注入时 withAnimation(招呼专属弹性 spring) 滚动到底 → 招呼从底部滚出（微信式阶段B）；
                // 替换不动滚动（气泡原地换文案）。
                // 气泡注入（微信新消息式）：列表已钉到历史末条（周六）贴底，气泡作为更底下的新消息，
                // 用专属弹性动画滚到底 → 周六被往上推、气泡从底部弹出浮现。这是用户确认的「弹入」效果。
                // greetingBubble 自身 offset(y:56) transition 与滚入协同，营造从底部滑出。
                // 回退：恢复 .onChange(of: greetingMessage) { _, _ in recomputeDisplayed() }。
                if old == nil {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
                        scrollToLatest(proxy: proxy, immediate: false)   // 气泡弹入：带动画，不被 disablesAnimations 压制
                    }
                }
                // <<< CHANGE-[2026-08-17 23:09:26]-[招呼注入带动画滚出-专属弹性] 结束
            }
            // 识别落地（拍照/相册/截屏/ShareExtension/语音等）主动广播的滚动信号：
            // 刷新列表 + 钉到底，保证结果气泡出现后页面自动滚到底、最新卡片完整可见。
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AIA.chatScrollToBottom"))) { _ in
                guard !isLoadingEarlier else { return }
                scrollToLatest(proxy: proxy)
            }
            // 键盘升降：完全交给 defaultScrollAnchor(.bottom)——ScrollView 内容保持贴底，
            // 键盘升起时 safeAreaInset(edge:.bottom) 把输入栏顶到键盘上方、视口底自动压缩到输入栏顶，
            // 气泡随之贴顶，无需滚动。
            // 不再手动 scrollTo：scrollTo(末条,.bottom) 锚定的是「末条 item 底」而非「内容底」，
            // 会吞掉底部 padding，在键盘 safeArea 过渡态与 defaultScrollAnchor 竞争 →「气泡上升又回落被挡」。
        }
    }

    /// 顶部「下拉自动加载更早的消息」：指示器滚入视口即自动扩大分页上限并重建查询，
    /// 加载后锚定此前的首条保持可视位置；加载期间显示 spinner 并用 `isLoadingEarlier` 锁防重复触发。
    private func earlierLoader(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            if isLoadingEarlier {
                ProgressView()
                    .controlSize(.small)
                Text("加载中…")
                    .font(AIATheme.Font.subhead)
            } else {
                Image(systemName: "arrow.up.circle.dotted")
                Text("下拉加载更早的消息")
                    .font(AIATheme.Font.subhead)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
        .onAppear { loadEarlier(proxy: proxy) }
    }

    /// 自动加载更早的消息：仅在未处于加载态、且仍有更早记录时触发，加载后锚定原首条。
    private func loadEarlier(proxy: ScrollViewProxy) {
        guard !isLoadingEarlier, hasMoreMessages else { return }
        isLoadingEarlier = true
        let firstID = cachedDisplayed.first?.persistentModelID
        // 时间窗分页：取「比当前已加载最老消息更早」的段，拼进 earlierMessages
        let loaded = recentMessages + earlierMessages
        let oldest = loaded.min(by: { $0.createdAt < $1.createdAt })?.createdAt
        loadEarlierMessages()
        refreshHasMoreMessages(earliest: oldest)
        if let firstID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { proxy.scrollTo(firstID, anchor: .top) }
            }
        }
        // 锁在滚动校正完成后释放，无论滚动是否成功都解锁，避免死锁。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isLoadingEarlier = false
        }
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        if let greeting = greetingMessage, m === greeting {
            greetingBubble(m)
        } else if let imgName = decodeUserImageName(m.text) {
            // 用户发出的图片（拍照/相册/文件/截屏）：像微信一样先出现你发的图，小记随后回识别卡片
            UserImageBubble(
                imageName: imgName,
                isSelected: selectedMessageIDs.contains(m.persistentModelID),
                showSelection: messageMultiSelectMode,
                onToggleSelection: { toggleMessageSelection(m.persistentModelID) },
                onDelete: {
                    // >>> CHANGE-[2026-08-22 11:20:00]-[长按删除消除竞态] 开始
                    // 同长按删除：当帧即时移除缓存（立即少一行、不跳底），软删落库延后下一帧，
                    // 顺序隔离避免 recompute 用旧 fresh 把消息补回。回退：恢复同步 removeMessageFromCache + SafeDelete.chatMessageByID。
                    cachedDisplayed.removeAll { $0.persistentModelID == m.persistentModelID }
                    DispatchQueue.main.async {
                        SafeDelete.chatMessageByID(m.persistentModelID, in: context)
                    }
                    // <<< CHANGE-[2026-08-22 11:20:00]-[长按删除消除竞态] 结束
                },
                onEnterMultiSelect: { enterMessageMultiSelect(m.persistentModelID) }
            )
        } else if m.text.hasPrefix(RECOGNITION_RESULT_PREFIX) {
            // 识别结果卡片宽度由内部气泡钉死到（屏宽 − 60），与文字气泡同宽；
            // 外层不再加 Spacer，避免二次扣减导致比文字气泡窄。
            ChatRecognitionBubble(message: m)
        } else if m.text.hasPrefix(UPGRADE_PRO_PREFIX) {
            // 付费墙拦截（免费版无云端视觉）时给的升级 Pro 引导气泡。
            upgradeProBubble(message: m)
        } else {
            bubble(m)
        }
    }

    /// 付费墙拦截引导气泡：免费版用户发「视觉专属场景」（如饭菜照片）本地识别失败时，
    /// 给一条可读文案 + 升级 Pro 入口，点击弹出订阅页。
    @ViewBuilder
    private func upgradeProBubble(message: ChatMessage) -> some View {
        let body = String(message.text.dropFirst(UPGRADE_PRO_PREFIX.count))
        VStack(alignment: .leading, spacing: 12) {
            Text(body)
                .font(AIATheme.Font.chatBody)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showPaywall = true
            } label: {
                Label("升级 Pro 版会员", systemImage: "crown.fill")
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(AIATheme.amber)
        }
        .padding(14)
        .background(Color.adaptive(light: 0xffffff, dark: 0x2c2c2e))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        // 兼容历史消息：旧版 __FOOD_CONFIRM__ 协议仍按确认卡片渲染，新记录统一走识别卡片水槽。
        if let pending = parseFoodConfirm(m.text) {
            foodConfirmBubble(pending, message: m)
        } else {
            messageBubble(message: m)
        }
    }

    /// 解析消息文本中内嵌的待确认饮食标记。
    private func parseFoodConfirm(_ text: String) -> PendingFoodConfirm? {
        let marker = "__FOOD_CONFIRM__"
        guard text.hasPrefix(marker),
              let data = text.dropFirst(marker.count).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PendingFoodConfirm.self, from: data) else {
            return nil
        }
        return decoded
    }

    /// 聊天气泡里的饮食确认卡片：用户点确认才写库，避免静默入库。
    private func foodConfirmBubble(_ pending: PendingFoodConfirm, message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .foregroundStyle(AIATheme.food)
                Text("待确认的饮食记录")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            FoodInfoCard(pending: pending)
            if let amount = pending.amount {
                Text("支出 ¥\(String(format: "%.2f", amount)) 已保留")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
            }
            HStack(spacing: 10) {
                Button {
                    confirmPendingFood(pending, message: message)
                } label: {
                    Text("确认记录")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AIATheme.food)

                Button {
                    cancelPendingFood(pending, message: message)
                } label: {
                    Text("算了")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(AIATheme.muted)
            }
        }
        .padding(12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .contextMenu {
            // 多选模式时不再弹菜单
            if !messageMultiSelectMode {
                Button {
                    UIPasteboard.general.string = "\(pending.meal) · \(pending.name) · \(pending.portion) · \(Int(pending.cal)) kcal"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    // >>> CHANGE-[2026-08-17 11:33:30]-[临时对象失效崩溃] 开始
                    // 原因：message 来自消息数组，删除后紧接 fetchMessages 重 fetch 可能释放引用。回退：改回 SafeDelete.chatMessage(message, in: context)
                    SafeDelete.chatMessageByID(message.persistentModelID, in: context)
                    // <<< CHANGE-[2026-08-17 11:33:30]-[临时对象失效崩溃] 结束
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    enterMessageMultiSelect(message.persistentModelID)
                } label: {
                    Label("选择", systemImage: "checkmark.circle")
                }
            }
        }
    }

    /// 聊天气泡里的「食物信息卡」（B 方案）：顶部 hero（食物名 + 餐次·份量 + 热量大数字），下方 6 列营养明细。
    private struct FoodInfoCard: View {
        let pending: PendingFoodConfirm

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                // hero：左食物名 + 餐次·份量；右热量大数字
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(AIATheme.food)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.name)
                            .font(AIATheme.Font.subhead.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(pending.meal) · \(pending.portion)")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(pending.cal))")
                            .font(AIATheme.Font.title3.weight(.bold))
                            .foregroundStyle(AIATheme.food)
                            .contentTransition(.numericText())
                        Text("kcal")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.sub)
                    }
                }

                Divider()
                    .background(AIATheme.hairline)

                // 6 列营养明细：碳水 / 蛋白 / 脂肪 / 纤维 / 糖 / 钠
                HStack(spacing: 4) {
                    macroCell("碳水", pending.carbs, "g")
                    macroCell("蛋白", pending.protein, "g")
                    macroCell("脂肪", pending.fat, "g")
                    macroCell("纤维", pending.fiber, "g")
                    macroCell("糖", pending.sugar, "g")
                    macroCell("钠", pending.sodium, "mg")
                }
            }
        }

        private func macroCell(_ title: String, _ value: Double, _ unit: String) -> some View {
            VStack(spacing: 4) {
                Text(title)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(formatValue(value))
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(unit)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(AIATheme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rXS))
        }

        /// 数值格式化：整数显示整数，否则保留 1 位小数（0 显示 0）。
        private func formatValue(_ v: Double) -> String {
            if v == 0 { return "0" }
            if v.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(v))"
            }
            return String(format: "%.1f", v)
        }
    }

    /// 用户确认：创建 FoodEntry 并入饮食库，把确认卡片消息替换为普通确认文案。
    private func confirmPendingFood(_ pending: PendingFoodConfirm, message: ChatMessage) {
        let ratio = pending.weight / 100.0
        let baseCalories = ratio > 0 ? pending.cal / ratio : pending.cal
        let baseProtein  = ratio > 0 ? pending.protein / ratio : pending.protein
        let baseCarbs    = ratio > 0 ? pending.carbs / ratio : pending.carbs
        let baseFat      = ratio > 0 ? pending.fat / ratio : pending.fat
        let baseFiber    = ratio > 0 ? pending.fiber / ratio : pending.fiber
        let baseSugar    = ratio > 0 ? pending.sugar / ratio : pending.sugar
        let baseSodium   = ratio > 0 ? pending.sodium / ratio : pending.sodium

        let entry = FoodEntry(
            name: pending.name,
            calories: pending.cal,
            protein: pending.protein,
            carbs: pending.carbs,
            fat: pending.fat,
            fiber: pending.fiber,
            sugar: pending.sugar,
            sodium: pending.sodium,
            portion: pending.portion,
            meal: pending.meal,
            weightGram: pending.weight,
            baseCalories: baseCalories,
            baseProtein: baseProtein,
            baseCarbs: baseCarbs,
            baseFat: baseFat,
            baseFiber: baseFiber,
            baseSugar: baseSugar,
            baseSodium: baseSodium,
            imageName: nil
        )
        context.insert(entry)
        CloudSyncManager.shared.syncAfterLocalChange(context: context)

        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        let foodIcon = ["🍽", "🍜", "🍚", "🥗", "😋", "🍱"].randomElement() ?? "🍽"
        message.text = "\(opener)：\(foodIcon) \(pending.meal)「\(pending.name)」\(Int(pending.cal)) kcal（\(pending.portion)）"
        try? context.save()
    }

    /// 用户取消：保留账单，仅把确认卡片替换为取消提示。
    private func cancelPendingFood(_ pending: PendingFoodConfirm, message: ChatMessage) {
        message.text = "🍽 已取消记录「\(pending.name)」的饮食，支出仍保留。"
        try? context.save()
    }

    /// 顶部小记招呼气泡（带小头像，区别于普通聊天记录）
    @ViewBuilder
    private func greetingBubble(_ m: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 注：原「招呼气泡显示时间」Text 块已删除。原因：ForEach 里 messageRow(m) 之前会按 showDivider 渲染一个
            //     ChatTimeDivider(date: m.createdAt)，招呼消息同样会触发，于是招呼上方已有一个水平居中的胶囊时间戳，
            //     再在招呼气泡内加一个完全一样的就会重复显示。招呼时间直接复用 ChatTimeDivider，无需自己再画一遍。
            // >>> CHANGE-[2026-08-22 00:00:00]-[招呼头像贴气泡左侧中间] 开始
            // 原因：原 HStack 把头像和「气泡+按钮」整列居中，气泡多行+按钮拉高后头像被顶到总高中点，相对气泡显得偏下。
            // 修复：头像只与气泡同处一个 HStack(alignment:.center)，头像垂直中心恒等于气泡垂直中心（多行也稳），不再受下方按钮影响；
            //       头像 .padding(.top,2) 略上提补偿气泡 10pt 内边距带来的文字中心偏低观感。按钮拆到外层 VStack 第二行并左缩进对齐气泡。
            // 回退：删掉本 HStack + 外层 VStack，恢复原「头像 + (气泡+按钮)VStack」平铺结构即可。
            HStack(alignment: .center, spacing: 8) {
                Image("AIAvatar")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AIATheme.hairline, lineWidth: 0.5))
                    .padding(.top, 2)
                messageBubble(message: nil, text: m.text, isUser: false)
            }
            // >>> CHANGE-[2026-08-22 00:00:00]-[招呼下加使用攻略按钮] 开始
            // 原因：用户要求在招呼气泡下方加「好记AI使用攻略」小按钮（带 > 箭头），点开 App 内网页 https://mp.weixin.qq.com/s/ekSczrt_yItd6UH4_n1PhA。
            // 按钮与气泡平级（外层 VStack 兄弟层），遵守"禁止嵌套 Button"铁律；用 UIKit present 版 SFSafariViewController 绕开首页 body 重算吞 sheet。
            // 回退：删掉 Button 块或整体回退到上一 CHANGE 前的结构。
            Button {
                if let url = URL(string: "https://mp.weixin.qq.com/s/ekSczrt_yItd6UH4_n1PhA") {
                    presentInAppBrowser(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 12))
                    Text("好记AI使用攻略")
                        .font(AIATheme.Font.micro)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(AIATheme.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AIATheme.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.leading, 40)   // 头像 32 + spacing 8，与气泡左边缘对齐
            // <<< CHANGE-[2026-08-22 00:00:00]-[招呼下加使用攻略按钮] 结束

            // >>> CHANGE-[2026-08-23 09:59:50]-[首屏示例提问降低冷启动门槛] 开始
            // >>> CHANGE-[2026-08-23 10:30:00]-[示例文案动态化A+B组合] 开始
            // 原因：新用户首屏只有招呼 + 使用攻略，不知道能发图识别/语音记账。在攻略下方加 3 个可点示例气泡，
            //       点一下把示例文本填入输入框并聚焦，降低"不知道说啥"的门槛（微信/钉钉同类做法）。
            //       文案动态化：按 entrySource 选池（B）+ 池内随机抽一组（A），且全部为可直接发送自动记录的指令。
            // 回退：把下面三行 examplePrompt(prompts[...]) 改回固定三句字符串即可。
            // >>> CHANGE-[2026-08-23 14:30:00]-[首屏示例随机轮播 5秒] 开始
            // 原因：原示例气泡只 randomElement 抽一组静态不动，用户停留首页看不到其他示例。
            //       改为 TimelineView 每 5 秒随机切一组（不重复上一次），淡入淡出；点任意条暂停轮播。
            // 回退：把本块改回 `let prompts = ChatView.examplePrompts(for: entrySource)` + 静态 HStack 即可。
            let pool = ChatView.examplePool(for: entrySource)
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                // 用时间 + 池长推导出当前组索引，保证每次刷新换组且不重复上一次
                let tick = Int(ctx.date.timeIntervalSince1970) / 3
                let n = pool.count
                let idx = n > 1 ? ((tick % (n - 1)) + ((tick / (n - 1)) % 2 == 0 ? 1 : 0)) % n : 0
                let prompts = pool[idx]
                HStack(spacing: 6) {
                    examplePrompt(prompts[0])
                    examplePrompt(prompts[1])
                }
                .id(idx) // 触发 transition 动画
                .opacity(examplePaused ? 1 : 1) // 暂停仅停切换，不隐藏
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .animation(.easeInOut(duration: 0.4), value: idx)
            }
            .padding(.leading, 40)
            .padding(.top, 4)
            // <<< CHANGE-[2026-08-23 14:30:00]-[首屏示例随机轮播 5秒] 结束
            // <<< CHANGE-[2026-08-23 10:30:00]-[示例文案动态化A+B组合] 结束
            // <<< CHANGE-[2026-08-23 09:59:50]-[首屏示例提问降低冷启动门槛] 结束
            // <<< CHANGE-[2026-08-22 00:00:00]-[招呼头像贴气泡左侧中间] 结束
        }
        Spacer(minLength: 28)
        // >>> CHANGE-[2026-08-17 23:09:26]-[招呼从下往上顶出] 开始
        // 原因：用户要求招呼气泡"从下往上顶出来、把历史往上顶、吸引眼球"。
        // 原 CHANGE-[2026-08-17 20:58:00]-[招呼浮出] 用 offset(y:8) 8pt 轻浮出，太"温柔"。
        // 修复：insertion 改为从底部 offset(y:56) 滑到 0 + opacity 淡入——招呼从视口下方明显顶上来；
        // 配合 .onChange(of: greetingMessage) 注入时专属弹性 spring 滚到底，整个列表被顶上，
        // 视觉上是"从下往上把历史顶开、自己顶出来"。
        // 回退：恢复 .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
        //       或原 CHANGE-[2026-08-17 20:58:00]-[招呼浮出] 的 .move(edge: .bottom)。
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 56)),
                                 removal: .opacity))
        // <<< CHANGE-[2026-08-17 23:09:26]-[招呼从下往上顶出] 结束
    }

    /// 普通消息气泡。`message == nil` 时用于顶部招呼（无长按菜单/不进多选）。
    @ViewBuilder
    private func messageBubble(message: ChatMessage? = nil, text: String = "", isUser: Bool = false) -> some View {
        let displayText = message?.text ?? text
        let userSide = message.map { $0.role == .user } ?? isUser
        let isSelected = message.map { selectedMessageIDs.contains($0.persistentModelID) } ?? false
        let showSelection = messageMultiSelectMode && message != nil

        HStack {
            if userSide { Spacer(minLength: 28) }

            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Text(displayText)
                        .font(AIATheme.Font.chatBody)
                        .foregroundStyle(userSide ? .white : .primary)
                        // >>> CHANGE-[2026-08-23 09:59:50]-[复制菜单统一去掉重复textSelection] 开始
                        // 原因：气泡已自定义 .contextMenu（含"复制/删除/选择"），再开 .textSelection(.enabled) 会让系统原生
                        //       选择态与自定义菜单并存，出现"两套复制"且长按易触发系统选择而非菜单，交互不一致。
                        //       统一关闭 textSelection，复制/选择全部走自定义长按菜单（用户/AI 气泡一致）。
                        // 回退：恢复 .textSelection(.enabled) 即可。
                        .padding(10)
                        // <<< CHANGE-[2026-08-23 09:59:50]-[复制菜单统一去掉重复textSelection] 结束
                        .background(userSide ? AIATheme.blue : Color.adaptive(light: 0xffffff, dark: 0x2c2c2e))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .opacity(showSelection && !isSelected ? 0.4 : 1.0)

                    if showSelection {
                        // 深色模式适配：未选中圆圈禁写死黑色（深色下黑圈落在黑底/深灰气泡上隐形）。
                        // 浅色=半透明黑、深色=半透明白，另加自适应细描边保证任意气泡底色上可见。
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                isSelected ? Color.green : Color.adaptive(light: 0x000000, dark: 0xffffff).opacity(0.5),
                                Color.white
                            )
                            .font(.system(size: 18))
                            .overlay(
                                Circle()
                                    .stroke(Color.adaptive(light: 0xffffff, dark: 0x8e8e93), lineWidth: 1)
                                    .opacity(isSelected ? 0 : 1)
                            )
                            .offset(x: 8, y: -8)
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    // 多选模式不再弹出菜单；非多选且有 message 时才显示 复制/删除/选择
                    if let m = message, !messageMultiSelectMode {
                        Button {
                            UIPasteboard.general.string = displayText
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            // >>> CHANGE-[2026-08-22 11:20:00]-[长按删除消除竞态] 开始
                            // 根因：原 action 同时做"手动 removeAll 缓存"和"SafeDelete.save() 软删"。
                            //       save() 触发 @Query 刷新 → onChange → recomputeDisplayed → cachedDisplayed = fresh。
                            //       若 recompute 比 removeAll 晚到（@Query 刷新异步、非确定性），会用"还含该消息的旧 fresh"
                            //       把缓存补回 → 表现为"有时点一次不消失、要点两次"（竞态，非确定性）。
                            // 修复：1) 当帧只从渲染缓存即时移除（列表立即少一行、不触发 scrollToBottom，故不跳底）；
                            //       2) 软删落库延后到下一帧（contextMenu 已关闭、body 已重绘后），再 save() 触发
                            //          @Query 刷新 → recompute 时 fresh 已不含该消息 → 缓存与数据一致，绝不再补回。
                            //       两帧隔离彻底消除"手动移除"与"recompute 覆盖"的竞态，每次点一次都消失。
                            // 回退：恢复同步调用 removeMessageFromCache + SafeDelete.chatMessageByID。
                            cachedDisplayed.removeAll { $0.persistentModelID == m.persistentModelID }
                            DispatchQueue.main.async {
                                SafeDelete.chatMessageByID(m.persistentModelID, in: context)
                            }
                            // <<< CHANGE-[2026-08-22 11:20:00]-[长按删除消除竞态] 结束
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            enterMessageMultiSelect(m.persistentModelID)
                        } label: {
                            Label("选择", systemImage: "checkmark.circle")
                        }
                    }
                }
                .onTapGesture {
                    if showSelection {
                        toggleMessageSelection(message!.persistentModelID)
                    }
                }

                // >>> CHANGE-[2026-08-20 15:30:00]-[小记查询跳转按钮] 开始
                // 原因：数据查询类 AI 气泡下方渲染一个平级跳转按钮，点直达对应页面。
                //       按钮放在气泡下方（VStack 兄弟层，与气泡 ZStack 平级），遵守项目"禁止嵌套 Button"铁律；不包 withAnimation。
                // 回退：删除本 if 块即可。
                if !userSide, let m = message, let routeKey = m.actionRouteRaw, let route = HomeRoute(routeKey: routeKey) {
                    Button {
                        NavigationRouter.shared.navigate(route)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 12))
                            Text("查看详情")
                                .font(AIATheme.Font.micro)
                        }
                        .foregroundStyle(AIATheme.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AIATheme.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                // <<< CHANGE-[2026-08-20 15:30:00]-[小记查询跳转按钮] 结束
            }

            if !userSide { Spacer(minLength: 28) }
        }
        // >>> CHANGE-[2026-08-17 23:34:41]-[去掉消息淡入位移过渡] 开始
        // 原因：用户要求去掉"历史消息出现时的淡入/位移过渡"。已删除原 .transition(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity)，消息现在直接显示、不再闪现。
        // 回退：在 messageBubble 闭包结束 } 前恢复 .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity)) 即可
        // <<< CHANGE-[2026-08-17 23:34:41]-[去掉消息淡入位移过渡] 结束
    }

    // MARK: - 消息多选三连
    private func enterMessageMultiSelect(_ id: PersistentIdentifier) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        messageMultiSelectMode = true
        selectedMessageIDs.insert(id)
    }

    private func toggleMessageSelection(_ id: PersistentIdentifier) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedMessageIDs.contains(id) {
            selectedMessageIDs.remove(id)
            if selectedMessageIDs.isEmpty { messageMultiSelectMode = false }
        } else {
            selectedMessageIDs.insert(id)
        }
    }

    private func deleteSelectedMessages() {
        let ids = selectedMessageIDs
        messageMultiSelectMode = false
        selectedMessageIDs.removeAll()
        // >>> CHANGE-[2026-08-22 11:20:00]-[长按删除消除竞态] 开始
        // 当帧即时从渲染缓存批量移除（立即少多行、不跳底）；软删落库在下方 async 延后执行。
        // 顺序隔离同单条长按删除，避免 recompute 用旧 fresh 把消息补回。
        // 回退：恢复 for id in ids { removeMessageFromCache(id) }。
        cachedDisplayed.removeAll { ids.contains($0.persistentModelID) }
        // <<< CHANGE-[2026-08-22 11:20:00]-[长按删除消除竞态] 结束
        DispatchQueue.main.async {
            for id in ids {
                SafeDelete.chatMessageByID(id, in: context)
            }
        }
    }

    /// 生成小记打招呼文案。
    /// 格式：时段开头 + 固定自我介绍 + 入口感知专属内容。
    /// 入口感知内容根据 entrySource 决定（food/health/bill/todo/home/兜底）。
    private func buildGreeting() -> String {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)

        // 1. 时段开头
        let opening: String
        switch hour {
        case 5..<11:  opening = "早上好呀"
        case 11..<14: opening = "中午好"
        case 14..<18: opening = "下午好"
        case 18..<23: opening = "晚上好"
        default:      opening = "这么晚还没休息呀"
        }

        // 2. 固定自我介绍
        let intro = "我是小记～你的私人AI助理。"
        let ending = "文字、语音跟我说都行。"

        // 3. 入口感知专属内容
        let personalContent: String
        switch entrySource {
        case "food":
            personalContent = entryGreeting_food(hour: hour) + ending
        case "health":
            personalContent = entryGreeting_health() + ending
        case "bill":
            personalContent = entryGreeting_bill() + ending
        case "todo":
            personalContent = entryGreeting_todo() + ending
        case "home":
            let idx = Int.random(in: 0..<4)
            switch idx {
            case 0: personalContent = entryGreeting_food(hour: hour) + ending
            case 1: personalContent = entryGreeting_health() + ending
            case 2: personalContent = entryGreeting_bill() + ending
            default: personalContent = entryGreeting_todo() + ending
            }
        default:
            // voice / todoReminder / 其他 → 兜底
            personalContent = "\n我目前最擅长帮你记饮食、账单、待办和看健康数据，比如：\n· 「早餐吃了50克鸡蛋」\n· 「记一笔星巴克35」\n· 「晚上8点提醒我开会」\n语音、文字跟我说都行，剩下的我帮你做。"
        }

        return "\(opening)。\(intro)\(personalContent)"
    }

    // MARK: - 入口感知模板

    /// 饮食入口模板（根据时间推荐餐次）
    private func entryGreeting_food(hour: Int) -> String {
        let mealHint: String
        switch hour {
        case 5..<10:  mealHint = "早餐"
        case 10..<14: mealHint = "午餐"
        case 14..<17: mealHint = "下午"
        default:      mealHint = "晚餐"
        }
        let pool = [
            "最近吃了什么好吃的？跟我说说，我帮你记录。比如：「\(mealHint)吃了2个鸡蛋」。",
            "今天有吃东西吗？告诉我，我来帮你记。比如：「\(mealHint)吃了一份鸡胸肉沙拉」。",
            "来记一下今天的美食吧？直接跟我说就行。比如：「\(mealHint)吃了一条清蒸鲈鱼」。",
            "有吃什么好东西吗？告诉我，我帮你记下来。比如：「\(mealHint)喝了一杯拿铁咖啡」。",
            "要不要记一记今天的饮食？跟我说说。比如：「\(mealHint)吃了一碗牛肉面」。",
            "今天吃了啥？直接说给我，我帮你记录营养。比如：「\(mealHint)吃了一个苹果」。",
        ]
        return pool.randomElement() ?? pool[0]
    }

    /// 健康入口模板
    private func entryGreeting_health() -> String {
        let pool = [
            "想知道今天的运动量吗？可以直接问我「今天走了多少步」。查历史数据也行，比如「这周消耗了多少卡路里」。",
            "想看看你的健康趋势吗？试试跟我说「查一下最近7天的步数」。",
            "运动数据我来帮你查，你可以跟我说「今天消耗了多少能量」，或者「看看我的身体指标」。",
            "健康数据随时可查，问问我就行。比如：「我最近的心率怎么样」「这周的活动量如何」。",
            "想要了解你的身体指标吗？直接跟我说，比如「今天走了多少步」「本周的运动数据」。",
            "健康信息一键查，跟我说「我的步数」「今天消耗多少」就行。",
        ]
        return pool.randomElement() ?? pool[0]
    }

    /// 账单入口模板
    private func entryGreeting_bill() -> String {
        let pool = [
            "今天有记账吗？告诉我，我帮你记。比如：「记一笔星巴克35」。",
            "有花钱吗？说给我听，我帮你归类记录。比如：「晚饭吃了85元」。",
            "要记账的话直接告诉我，我按类别自动归类。比如：「买一本书花了50」。",
            "最近有消费吗？说给我就行。比如：「工资发了5000元」。",
            "记账很简单，直接说。比如：「买了件衣服花了299」「中午吃饭花了35」。",
            "今天花了多少钱？跟我说说，我帮你记下来。比如：「打车花了25块」。",
        ]
        return pool.randomElement() ?? pool[0]
    }

    /// 待办入口模板
    private func entryGreeting_todo() -> String {
        let pool = [
            "有什么需要提醒的吗？直接说，我帮你记并到点提醒。比如：「晚上8点提醒我开会」。",
            "有新的待办吗？跟我说说，我设置好截止时间。比如：「明天早上10点提醒我交报告」。",
            "想新增提醒吗？直接告诉我任务和时间。比如：「1小时后提醒我吃药」。",
            "要设个待办提醒吗？告诉我时间和内容就行。比如：「后天下午3点提醒我去健身房」。",
            "有什么事情怕忘记的吗？交给我记住。比如：「下午2点提醒我打电话给客户」。",
            "新建待办很方便，跟我说就行。比如：「周五提醒我提交周报」。",
        ]
        return pool.randomElement() ?? pool[0]
    }

    /// 按需拉取 LLM 上下文所需的各表数据（仅在使用时查库，避免进页面全表加载拖慢首屏）。
    /// 调用方均为异步/按需时机：打招呼(0.4s后)、智能问答、本地兜底回复、agent 工具目标查找。
    /// 排序保持与旧 @Query 一致（healths/recognitions/waters 倒序），确保 healths.first 等语义不变。
    // <<< CHANGE-[2026-08-17 23:20:47]-[对话页8个LLM上下文@Query改按需fetch] 结束
    private func fetchLlmContextData() -> (
        foods: [FoodEntry], bills: [Bill], reminders: [Reminder],
        healths: [HealthMetric], merchantMetas: [MerchantMeta],
        recognitions: [RecognitionRecord], waters: [WaterLog], recurringRules: [RecurringRule]
    ) {
        let reminderPred = #Predicate<Reminder> { !$0.syncDeleted }
        let waterPred = #Predicate<WaterLog> { !$0.syncDeleted }
        let rulePred = #Predicate<RecurringRule> { !$0.syncDeleted }
        let foods = (try? context.fetch(FetchDescriptor<FoodEntry>())) ?? []
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        let reminders = (try? context.fetch(FetchDescriptor<Reminder>(predicate: reminderPred))) ?? []
        let healths = (try? context.fetch(FetchDescriptor<HealthMetric>(sortBy: [SortDescriptor(\HealthMetric.date, order: .reverse)]))) ?? []
        let merchantMetas = (try? context.fetch(FetchDescriptor<MerchantMeta>())) ?? []
        let recognitions = (try? context.fetch(FetchDescriptor<RecognitionRecord>(sortBy: [SortDescriptor(\RecognitionRecord.recognizedAt, order: .reverse)]))) ?? []
        let waters = (try? context.fetch(FetchDescriptor<WaterLog>(predicate: waterPred, sortBy: [SortDescriptor(\WaterLog.date, order: .reverse)]))) ?? []
        let recurringRules = (try? context.fetch(FetchDescriptor<RecurringRule>(predicate: rulePred))) ?? []
        return (foods, bills, reminders, healths, merchantMetas, recognitions, waters, recurringRules)
    }

    /// 招呼专用上下文：比 buildContext() 精简得多（只喂给 LLM 与招呼相关的字段，省 token 也避免模型分心）。
    /// 字段命名兼容中文（便于模型直接读懂）：时间 / 今日饮食 / 今日账单 / 今日待办 / 步数 / 最新健康指标等。
    private func buildGreetingContext() -> [String: Any] {
        let data = fetchLlmContextData()
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)

        // 今日已记饮食（精简字段）
        let todayFoods = data.foods.filter { cal.isDateInToday($0.date) }
        let todayFoodsCompact: [[String: Any]] = todayFoods.map { f in
            [
                "meal": f.meal,
                "name": f.name,
                "calories": f.calories,
                "portion": f.portion,
            ]
        }

        // 近 14 天早餐时段众数（用于「你平时差不多 X 点就吃早餐」式开场）
        let since = cal.date(byAdding: .day, value: -14, to: now) ?? now
        let bfHours = data.foods.filter { $0.date >= since && $0.meal == "早餐" }.map { cal.component(.hour, from: $0.date) }
        let commonBF: Int? = bfHours.isEmpty ? nil : Int(round(Double(bfHours.reduce(0, +)) / Double(bfHours.count)))

        // 今日待办（仅 today + 未完成 + 未过期）
        let upcomingToday = data.reminders.filter { r in
            guard let due = r.due else { return false }
            return cal.isDateInToday(due) && !r.done && due >= now
        }
        // 重要：所有传给云端 LLM 的时间戳必须用本地时区（带 +HH:MM 偏移），
        // 否则默认 ISO8601DateFormatter() 是 UTC（Z），本地 11:45 会变成 03:45Z 被 LLM 误读为「凌晨 3 点」。
        let fmt = AppFormat.isoLocal
        let upcomingCompact: [[String: Any]] = upcomingToday.prefix(3).map { r in
            [
                "title": r.title,
                "priority": r.priority,
                "due": fmt.string(from: r.due ?? now),
            ]
        }

        // 【D】今日账单概况
        let todayBills = data.bills.filter { cal.isDateInToday($0.time) && !$0.syncDeleted }
        var todayBillSummary: [String: Any]?
        if todayBills.count > 0 {
            let expense = todayBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
            let income = todayBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
            let top = todayBills.filter { !$0.isIncome }.sorted { $0.amount > $1.amount }.prefix(3)
            todayBillSummary = [
                "count": todayBills.count,
                "totalExpense": expense,
                "totalIncome": income,
                "topExpenses": top.map { ["merchant": $0.merchant, "amount": $0.amount, "category": $0.category] },
            ]
        }

        // 【D】最新健康指标
        var latestMetric: [String: Any]?
        if let lh = data.healths.first {
            latestMetric = ["metric": lh.metric, "value": lh.value, "unit": lh.unit]
        }

        var ctx: [String: Any] = [
            "currentHour": hour,
            "currentTime": DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short),
            "todayFoods": todayFoodsCompact,
            "commonBreakfastHour": commonBF as Any,
            "upcomingTodayCount": upcomingToday.count,
            "upcomingToday": upcomingCompact,
            "totalFoods": data.foods.count,
            "totalReminders": data.reminders.count,
            "entrySource": entrySource,                  // 🆕 入口来源
        ]
        if let bs = todayBillSummary { ctx["todayBillSummary"] = bs }  // 🆕
        if let lm = latestMetric { ctx["latestHealthMetric"] = lm }    // 🆕
        if effectiveStepsToday > 0 {
            ctx["stepsToday"] = effectiveStepsToday
        }
        return ctx
    }

    /// 后台调云端 LLM 重写招呼：成功且非空 → 替换气泡；失败/空/超时 → 保留本地版本。
    /// - 用 Task 而非 fire-and-forget Task.detached，便于 .onDisappear 时取消。
    /// - 用户已开启 greetingLLM + 已登录（让云端能用真实 userId）。
    private func startGreetingLLMTask(initial: String) {
        greetingTask?.cancel()
        guard greetingLLM, UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return }
        let userId = UserDefaults.standard.string(forKey: "aia.userId") ?? ""
        let ctx = buildGreetingContext()
        greetingTask = Task { @MainActor in
            let result = try? await RecognizeService.agentChatGreeting(context: ctx, userId: userId)
            // 任务被取消或返回空 → 保留本地招呼（initial）
            if Task.isCancelled { return }
            guard let r = result, !r.isEmpty, r != initial else { return }
            // 长度防御：LLM 可能输出过长，截断避免气泡过高
            let trimmed = r.count > 120 ? String(r.prefix(120)) + "…" : r
            if let g = greetingMessage {
                greetingMessage = ChatMessage(role: g.role, text: trimmed, createdAt: g.createdAt)
            }
        }
    }

    // >>> CHANGE-[2026-08-23 09:59:50]-[对话页chips按压反馈] 开始
    // 原因：原 chip/feedbackChip 用 .buttonStyle(.plain)，点下去无任何视觉反馈，用户"没反应感"。
    //       改用项目统一样式 PressableCardStyle()，按下有缩放+阴影反馈，与全 App 卡片交互一致。
    // 回退：把两处 .buttonStyle(PressableCardStyle()) 改回 .buttonStyle(.plain) 即可。
    private func chip(_ title: String, route: HomeRoute) -> some View {
        Button {
            isInputFocused = false
            NavigationRouter.shared.navigate(route)
        } label: {
            Text(title)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.sub)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(AIATheme.surfaceSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(PressableCardStyle())
    }

    private var feedbackChip: some View {
        Button {
            isInputFocused = false
            postContactMessage()
        } label: {
            Text(NSLocalizedString("chat.feedback", comment: ""))
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.sub)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(AIATheme.surfaceSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(PressableCardStyle())
    }
    // <<< CHANGE-[2026-08-23 09:59:50]-[对话页chips按压反馈] 结束

    // >>> CHANGE-[2026-08-23 09:59:50]-[首屏示例提问降低冷启动门槛] 开始
    // >>> CHANGE-[2026-08-23 10:30:00]-[示例文案动态化A+B组合] 开始
    // A+B 组合：B=按 entrySource 选不同示例池（贴合入口），A=池内 randomElement 随机抽一组（每次不重样）。
    // 铁律：所有示例必须是"点了直接发送就能自动记录"的指令（饮食/账单/待办），不含查询/闲聊句——
    //       本功能是帮用户养成记录习惯，开放式提问（如"今天吃了什么"）不符合场景，已剔除。
    // 回退：把 greetingBubble 里的 examplePrompts(for:) 调用改回固定三句 examplePrompt(...) 即可。
    // >>> CHANGE-[2026-08-23 11:03:38]-[示例文案池扩充+health复用home+识别核对修正] 开始
    // 原因：原每入口仅 3 组，随机抽易重复；扩充到 8 组（home）/ 8 组（其余），全部口语化、带数字、
    //       每组 [饮食,账单,待办] 三类齐全且均可被 resolveLocally 识别（已逐句核对 createTodoLocally/
    //       createBillLocally/isFoodLike 规则）。health 入口不再单独成池，复用 home 池（用户要求）。
    // 修正（核对代码发现）：① home 第8组第3句原"后天中午12点还书"无"提醒"关键词→待办分支 hasObject
    //       不满足→不会建待办，补"提醒"；② bill 第4组第3句"月底提醒我还房贷"→"28号提醒我还房贷"（更具体）。
    // 回退：删除本 CHANGE 块，恢复旧 examplePools（5 池）即可。
    /// 各入口对应的示例组池：每组 [饮食, 账单, 待办] 均为可直接发送自动记录的指令（已核对识别规则）。
    private static let examplePools: [String: [[String]]] = [
        // home / 兜底：均衡三类（口语化记录指令）；health 入口也复用本池。
        // 12 组 × 2 条，D 混合轮替（饮+账 / 饮+待 / 账+待 各 4 组），靠 randomElement 每次随机抽一组。
        "home": [
            ["喝了1杯牛奶", "买早餐花了8元"],
            ["吃了100克牛肉", "打车花了18元"],
            ["吃了1份沙拉", "外卖花了32元"],
            ["吃了一个苹果", "买饮料花了6元"],
            ["吃了一碗米饭", "晚上8点提醒我健身"],
            ["喝了1碗粥", "明早7点提醒我跑步"],
            ["喝了1杯酸奶", "后天12点提醒我还书"],
            ["吃了2个鸡蛋", "15点提醒我取快递"],
            ["买菜花了12元", "每天10点提醒我服药"],
            ["午餐花了25元", "下午3点提醒我交报表"],
            ["便利店花了15元", "每天9点提醒我写日记"],
            ["买水果花了10元", "周五11点提醒我开会"],
        ],
        // food 入口：饮食句更具体，仍配账单/待办凑齐三类；12 组 × 2 条 D 混合轮替
        "food": [
            ["吃了150克鸡胸肉", "午餐花了25元"],
            ["喝了一杯豆浆", "买水果花了12元"],
            ["吃了半碗面条", "晚饭外卖花了42元"],
            ["吃了2个鸡蛋", "早餐花了5元"],
            ["喝了1杯牛奶", "下午3点提醒我加餐"],
            ["吃了1根香蕉", "每天8点提醒我称体重"],
            ["吃了1份盖饭", "明晚7点提醒我上瑜伽课"],
            ["喝了1碗汤", "周日10点提醒我采购"],
            ["买面包花了9元", "下午5点提醒我喝水"],
            ["超市买菜花了20元", "明天早上7点提醒我跑步"],
            ["午饭花了28元", "今晚11点提醒我睡觉"],
            ["买零食花了14元", "上午10点提醒我吃维生素"],
        ],
        // bill 入口：账单句更具体，仍配饮食/待办凑齐三类；12 组 × 2 条 D 混合轮替
        "bill": [
            ["午饭吃了30元", "超市购物花了88元"],
            ["打车花了22元", "早餐吃了8元"],
            ["买书花了45元", "喝了1杯咖啡花了18元"],
            ["加油花了200元", "晚饭花了35元"],
            ["买了1件衣服花了128元", "下周一提醒我交物业费"],
            ["电影票花了60元", "每月15号提醒我还花呗"],
            ["理发花了38元", "明天提醒我续话费"],
            ["网购花了75元", "周六提醒我交水电费"],
            ["超市购物花了88元", "下周一提醒我交房租"],
            ["早餐吃了8元", "周五提醒我还信用卡"],
            ["喝了1杯咖啡花了18元", "明天上午10点提醒我缴费"],
            ["晚饭花了35元", "28号提醒我还房贷"],
        ],
        // todo 入口：待办句更具体，仍配饮食/账单凑齐三类；12 组 × 2 条 D 混合轮替
        "todo": [
            ["晚上吃1份沙拉", "花了15元买水"],
            ["午饭吃了1个鸡腿", "加油花了200元"],
            ["喝了1杯牛奶", "买菜花了33元"],
            ["吃了1个三明治", "买咖啡花了18元"],
            ["吃了1碗馄饨", "明天9点提醒我开会"],
            ["喝了1杯果汁", "周六下午提醒我看牙医"],
            ["吃了1份便当", "周日晚上8点提醒我复盘"],
            ["吃了1个汉堡", "下午2点提醒我打电话给客户"],
            ["买文具花了25元", "明天提醒我交报告"],
            ["打车花了16元", "周五提醒我取体检报告"],
            ["买药花了40元", "每天晚10点提醒我散步"],
            ["买水花了4元", "后天上午提醒我寄快递"],
        ],
    ]
    // <<< CHANGE-[2026-08-23 11:03:38]-[示例文案池扩充+health复用home+识别核对修正] 结束

    /// 按入口来源选池 + 池内随机抽一组（A+B 组合）。兜底回 home 池。
    private static func examplePrompts(for source: String) -> [String] {
        let pool = examplePools[source] ?? examplePools["home"]!
        return pool.randomElement() ?? pool[0]
    }

    /// 返回入口对应的整池（12 组），供首屏示例气泡随机轮播使用。兜底回 home 池。
    private static func examplePool(for source: String) -> [[String]] {
        return examplePools[source] ?? examplePools["home"]!
    }

    /// 首屏示例提问气泡：点一下把示例文本填入输入框并聚焦，引导新用户开口（全部为可直接记录的指令）。
    /// 点击即暂停轮播（examplePaused = true），避免文案在用户阅读/准备点时跳走。
    private func examplePrompt(_ text: String) -> some View {
        Button {
            examplePaused = true
            input = text
            isInputFocused = true
        } label: {
            Text(text)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.blue)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(AIATheme.blue.opacity(0.10))
                .clipShape(Capsule())
        }
        .buttonStyle(PressableCardStyle())
    }
    // <<< CHANGE-[2026-08-23 10:30:00]-[示例文案动态化A+B组合] 结束
    // <<< CHANGE-[2026-08-23 09:59:50]-[首屏示例提问降低冷启动门槛] 结束

    /// 「联系我们」chip 点击：直接以小记身份发送一条带联系方式的 AI 消息进聊天流。
    private func postContactMessage() {
        let body = "如果你需要帮助，或想给我们提供建议，欢迎通过以下方式联系我们😊\n\n微信/Wechat：754727942\n\n邮箱/Email：754727942@qq.com\n\n长按本消息，可复制"
        let aiMessage = ChatMessage(role: .ai, text: body, createdAt: Date())
        context.insert(aiMessage)
        try? context.save()
        // @Query 自动响应式刷新，无需手动 fetchMessages
        // 关掉输入栏焦点，让用户立刻看到小记的回复
        isInputFocused = false
    }

    private func inputActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(AIATheme.Font.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(AIATheme.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(title)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }


    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                fileImportErrorMessage = "无法访问所选文件"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else {
                fileImportErrorMessage = "无法读取所选图片"
                return
            }
            runImageRecognition(image: img, context: context,
                                errorMessage: $fileImportErrorMessage)
        } catch {
            fileImportErrorMessage = error.localizedDescription
        }
    }

    /// 检测常见闲聊/元意图（问候、身份、能力、状态、感谢、再见等），返回更贴合语境的本地回复。
    /// 返回 nil 表示不是已知元意图，继续走后续领域识别。
    private func replyForMetaIntent(_ text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        // 身份
        let identityKw = ["你是谁", "你叫什么", "你是小记", "介绍一下你自己", "你的名字", "你是什么"]
        if identityKw.contains(where: { lower.contains($0) }) {
            return "我是小记，你的私人专属 AI 助理～可以帮你记饮食、账单、待办，也能看看今天的健康数据。今天想记点什么？"
        }

        // 能力
        let capabilityKw = ["你能做什么", "你能帮我", "你会什么", "你会做", "你有什么用", "可以做什么", "能做什么", "功能", "怎么用"]
        if capabilityKw.contains(where: { lower.contains($0) }) {
            return "我会帮你打理日常四件事：\n· 记饮食：说一句「早餐吃了碗燕麦粥」就能估算热量；\n· 记账单：拍小票或者说「买咖啡花了28」；\n· 加待办：「晚上8点提醒我开会」；\n· 看健康：步数、体重趋势都能查。\n直接说就行，我帮你归类好。"
        }

        // 状态 / 在干嘛
        let statusKw = ["你在干嘛", "在干嘛", "你在做什么", "你在忙什么", "在忙啥", "干啥呢", "在吗"]
        if statusKw.contains(where: { lower.contains($0) }) {
            return "正在等你吩咐呀～是想记饮食、账单，还是查今天吃了多少、花了多少？"
        }

        // 感谢
        let thanksKw = ["谢谢", "感谢", "多谢", "辛苦了", "谢啦"]
        if thanksKw.contains(where: { lower.contains($0) }) {
            return "不客气呀，能帮上忙就好～有需要随时叫我。"
        }

        // 再见
        let byeKw = ["再见", "拜拜", "bye", "goodbye", "回头见", "下次见"]
        if byeKw.contains(where: { lower.contains($0) }) {
            return "再见啦，有需要随时叫我哦～"
        }

        // 肯定 / 简单回应（只处理短句，避免误杀带后续内容的句子）
        let ackKw = ["好的", "嗯嗯", "嗯", "ok", "知道了", "明白", "收到"]
        if ackKw.contains(where: { lower == $0 || (lower.hasPrefix($0) && lower.count <= 6) }) {
            return "收到～随时叫我。"
        }

        // 问候（放在较后，避免误覆盖上面的特定意图；只处理短句减少误伤）
        let greetingKw = ["你好", "您好", "嗨", "哈喽", "hello", "hi"]
        if (greetingKw.contains(where: { lower.contains($0) }) || lower == "在吗"), lower.count <= 12 {
            let cal = Calendar.current
            let hour = cal.component(.hour, from: Date())
            let opening: String
            switch hour {
            case 5..<11:  opening = "早上好呀"
            case 11..<14: opening = "中午好"
            case 14..<18: opening = "下午好"
            case 18..<23: opening = "晚上好"
            default:      opening = "这么晚还没休息呀"
            }
            return "\(opening)，我是小记～今天想记录点什么，还是随便聊聊？"
        }

        return nil
    }

    /// 本地内容安全闸：检测明显的违规/有害内容，命中则直接返回拒答文本（不调云端）。
    /// 只拦截高置信的硬违规（色情/暴力/政治敏感/违法/严重歧视），正常闲聊一律放行。
    /// 返回 nil 表示放行，继续走后续 resolveLocally / 云端。
    static func replyForBlockedIntent(_ text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        // 色情相关
        let adultKw = ["做爱","性交","黄片","色情","裸照","裸聊","淫","av ","a片",
                       "约炮","一夜情","援交","卖淫","嫖娼","自慰","春药"]
        if adultKw.contains(where: { lower.contains($0) }) {
            return "哎呀这个我确实帮不上忙呢～不过我可以帮你记生活账呀，比如记一笔、加个待办、看看今天吃了啥，你想试哪个？"
        }

        // 暴力/伤害
        let violenceKw = ["杀人","杀掉","打死","砍死","炸毁","制造炸弹","恐怖袭击",
                          "自杀方法","怎么自杀","如何自杀","自残","伤害他人","打人"]
        if violenceKw.contains(where: { lower.contains($0) }) {
            return "这个我确实帮不上忙呢～我是帮你整理生活记录的小记，记账、记饮食、管待办、查健康这些我都在行，想试试吗？"
        }

        // 政治敏感（常见触发词）
        let politicsKw = ["反党","反政府","推翻","颠覆政权","法轮功","台独","藏独","疆独",
                          "六四","八九","习近平","李克强","政治局","中南海"]
        if politicsKw.contains(where: { lower.contains($0) }) {
            return "这个我确实帮不上忙呢～我只能帮你整理生活记录，比如记一笔、加个待办、看看今天吃了啥，你想试哪个？"
        }

        // 违法犯罪
        let illegalKw = ["怎么造假","如何诈骗","黑客攻击","盗号","洗钱","走私","贩毒",
                         "制毒","偷税漏税","伪造证件","假币","开锁技术"]
        if illegalKw.contains(where: { lower.contains($0) }) {
            return "这个我确实帮不上忙呢～不过我可以帮你记生活账呀，比如记一笔、加个待办、查查健康数据，你想试哪个？"
        }

        return nil
    }

    /// 云端聊天不可用时的本地兜底回复：基于用户的本地数据组织成自然语句。
    /// 覆盖饮食/账单/待办/健康几类常见问题，其余给友好兜底并提示能做什么。
    private func localReply(for text: String) async -> String {
        let data = fetchLlmContextData()
        // 先处理常见闲聊/元意图，避免把「你是谁」「在干嘛」当成未识别意图给通用兜底。
        if let metaReply = replyForMetaIntent(text) {
            return metaReply
        }

        let lower = text.lowercased()
        let cal = Calendar.current
        let now = Date()

        // 饮食 / 卡路里
        if lower.contains("吃") || lower.contains("卡路里") || lower.contains("热量") || lower.contains("饮食") || lower.contains("营养") {
            let todayFoods = data.foods.filter { cal.isDateInToday($0.date) }
            if todayFoods.isEmpty {
                return "今天好像还没记过吃的呢。想记的话，直接跟我说「早餐吃了个水煮蛋」就行，我帮你把热量算好～"
            }
            let names = todayFoods.map { "\($0.meal)的\($0.name)" }.joined(separator: "、")
            let total = todayFoods.reduce(0) { $0 + $1.calories }
            return "今天你记了 \(todayFoods.count) 样：\(names)。加起来大概 \(Int(total)) kcal。还要再记点吗？"
        }

        // 账单 / 花了多少钱（支持"昨天"、"今天"、"最近"）
        if lower.contains("花") || lower.contains("钱") || lower.contains("账单") || lower.contains("支出") || lower.contains("消费") || lower.contains("账") {
            let cal = Calendar.current
            let startOfToday = cal.startOfDay(for: now)
            let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!

            let isYesterday = lower.contains("昨天") || lower.contains("昨日")
            let isRecent = lower.contains("最近") || lower.contains("近")

            // 优先回答昨天/今天；"最近"用 7 天汇总
            let targetBills: [Bill]
            let dayLabel: String
            if isYesterday {
                targetBills = data.bills.filter { $0.time >= startOfYesterday && $0.time < startOfToday }
                dayLabel = "昨天"
            } else if isRecent {
                let startOf7DaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday)!
                targetBills = data.bills.filter { $0.time >= startOf7DaysAgo }
                dayLabel = "最近 7 天"
            } else {
                targetBills = data.bills.filter { cal.isDateInToday($0.time) }
                dayLabel = "今天"
            }

            if targetBills.isEmpty {
                return "\(dayLabel)还没记过账哦。看到小票随手拍我，或者跟我说「买午饭花了25」就可以，我帮你归类。"
            }
            let expense = targetBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
            let income = targetBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
            let f: (Double) -> String = { String(format: "%.0f", $0) }
            let detail = targetBills.filter { !$0.isIncome }.map { "· \($0.category) \($0.merchant) ¥\(f($0.amount))" }.joined(separator: "\n")
            if income > 0 {
                return "\(dayLabel)记了 \(targetBills.count) 笔，支出 ¥\(f(expense))，收入 ¥\(f(income))：\n\(detail)"
            }
            return "\(dayLabel)花了 ¥\(f(expense))，一共 \(targetBills.count) 笔：\n\(detail)"
        }

        // 待办 / 任务
        if lower.contains("待办") || lower.contains("任务") || lower.contains("提醒") || lower.contains("事情") || lower.contains("todo") || lower.contains("安排") {
            // 兜底：如果用户明显是在“新建”待办，但云端没识别出来，直接本地创建
            if let reply = await createTodoLocally(from: text) {
                return reply
            }
            let upcoming = data.reminders
                .filter { !$0.done && ($0.due ?? .distantPast) >= cal.startOfDay(for: now) }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            if upcoming.isEmpty {
                return "目前没有还没做的待办，可以放松一下～有新的事随时跟我说，我帮你记着并到点提醒。"
            }
            // 每条前加「M月d日 HH:mm」+ 标题；今天不重复日期，明日/未来显示「明天 M月d日 HH:mm」「M月d日 HH:mm」。
            let list = upcoming.prefix(3).map { r -> String in
                let title = r.title
                guard let due = r.due else { return "· \(title)" }
                let prefix: String
                if cal.isDateInToday(due) { prefix = "今天 \(AppFormat.hourMinute.string(from: due))" }
                else if cal.isDateInTomorrow(due) { prefix = "明天 \(AppFormat.dateTime.string(from: due))" }
                else { prefix = AppFormat.dateTime.string(from: due) }
                return "· \(prefix) · \(title)"
            }.joined(separator: "\n")
            let more = upcoming.count > 3 ? "\n…还有 \(upcoming.count - 3) 件" : ""
            return "你还有 \(upcoming.count) 件事没做：\n\(list)\(more)\n到点了会自动提醒你，放心～"
        }

        // 健康 / 步数
        if lower.contains("步数") || lower.contains("健康") || lower.contains("运动") || lower.contains("走") || lower.contains("锻炼") {
            if effectiveStepsToday > 0 {
                return "今天已经走了 \(Int(effectiveStepsToday)) 步，活动量不错，继续保持呀～"
            }
            return "我暂时还没读到你的健康数据（可能还没授权健康权限）。不过你今天感觉怎么样？"
        }

        // 兜底：没识别到具体意图，给友好引导（不再道歉式兜底，直接给能力示例）
        return "我目前最擅长帮你记饮食、账单、待办和看健康数据，比如：\n· 「早餐吃了碗燕麦粥」\n· 「记一笔星巴克35」\n· 「晚上8点提醒我开会」\n直接说就行，我帮你归类好。"
    }

    /// 本地兜底创建待办：当云端返回 types:none 但用户明显在新建待办时，直接解析标题和日期并创建。
    private func createTodoLocally(from text: String) async -> String? {
        let lower = text.lowercased()
        // 负面意图：取消/删除提醒时不应创建。注意「关闭」本身是常见提醒内容（如"关闭wifi"），
        // 仅当明确针对"提醒/待办"本身（关掉提醒/取消提醒）时才屏蔽，避免误杀内容型提醒。
        let negative = ["取消", "删除", "删掉", "不要", "移除", "废除",
                        "关掉提醒", "取消提醒", "删除提醒", "去掉提醒"].contains { lower.contains($0) }
        guard !negative else { return nil }
        let hasObject = lower.contains("待办") || lower.contains("提醒") || lower.contains("任务") || lower.contains("事项")
        let hasVerb = lower.contains("增加") || lower.contains("添加") || lower.contains("创建") || lower.contains("新建") || lower.contains("设置") || lower.contains("记") || lower.contains("帮我") || lower.contains("提醒")
        guard hasObject && hasVerb else { return nil }

        // 一句话多条：按连词切分后逐条建待办
        let segments = IntentTextUtils.splitByConjunction(text)
        var todoPayloads: [TodoPayload] = []
        for seg in segments {
            guard let (title, due, repeatRule) = parseTodoCreate(seg) else { continue }
            if WaterIntakeParser.checkDuplicateAndRegister(seg, type: "todo") { continue }
            if DataDeduplicator.isDuplicateReminder(title: title, context: context) { continue }
            // 必须带本地时区偏移（AppFormat.iso）。此处曾裸用 ISO8601DateFormatter()（UTC），
            // 导致「19 点提醒吃饭」序列化成 11:00Z、被 LLM 当成 11 点回传，待办落成 11:00。
            let dueISO = AppFormat.iso.string(from: due)
            todoPayloads.append(TodoPayload(title: title, due: dueISO, repeatRule: repeatRule, priority: nil, action: nil, targetTitle: nil))
        }
        guard !todoPayloads.isEmpty else { return nil }
        UsageAnalytics.logAdd("todo", source: "chat")
        let result = RecognitionResult(types: ["todo"], todos: todoPayloads)
        if await routeRecognition(result, rawText: text) {
            return kHandledCard
        }
        return nil
    }

    /// 判断文本是否为明显**进食意图**（用于走记录流程）。需要包含进食动词或餐次上下文。
    /// 故意**不**包含「牛肉/咖啡/奶茶」等纯食物名关键词——这些单独发送时
    /// 应走营养查询（handleFoodQuery）而非记录，避免「说了个食物名」就追着问重量。
    /// 进食动词：吃/喝/食/进/尝/品；餐次：早/午/晚/宵/餐/菜/汤/粥/点心/饭；
    /// 餐次全名：早饭/午饭/晚饭/早餐/午餐/晚餐/夜宵/加餐/零食/宵夜
    private func isFoodLike(_ text: String) -> Bool {
        let lower = text.lowercased()
        let billKw = ["花了", "花掉", "付了", "付给", "消费", "支出", "账单", "花销", "开销", "扫码付"]
        let explicitBill = billKw.contains(where: { lower.contains($0) })
        if explicitBill { return false }

        let foodKw = ["吃", "喝", "食", "进", "尝", "品",
                      "点心",
                      "早饭", "午饭", "晚饭", "早餐", "午餐", "晚餐", "夜宵", "加餐", "零食",
                      "宵夜", "吃不饱", "吃太撑", "吃撑"]
        return foodKw.contains(where: { lower.contains($0) })
    }

    /// 二次食物意图判断：在「账单分支已命中」的前提下，判断文本是否仍含食物意图。
    /// 与 isFoodLike() 的区别是**不检查账单抑制词**（「花了/付了」等），仅检测食物关键词。
    /// 用于「账单已记、是否还要补一条饮食记录」的二次判定，避免「晚餐吃了汉堡花了10元」漏记饮食。
    private func hasRawFoodIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let foodKw = ["吃", "喝", "奶茶", "咖啡", "可乐", "果汁", "饮料", "饭", "面", "粉", "餐", "菜",
                      "肉", "鱼", "鸡", "鸭", "牛", "羊", "猪", "蛋", "奶", "汤", "粥", "面包", "蛋糕",
                      "饼干", "点心", "水果", "沙拉", "汉堡", "披萨", "炸鸡", "薯条", "寿司", "拉面",
                      "火锅", "烧烤", "饺子", "包子", "馒头", "豆浆", "酸奶", "茶", "酒", "啤酒", "白酒",
                      "红酒", "早饭", "午饭", "晚饭", "早餐", "午餐", "晚餐", "夜宵", "加餐", "零食",
                      "宵夜", "吃不饱", "吃太撑", "吃撑"]
        return foodKw.contains(where: { lower.contains($0) })
    }

    /// 去掉回复文本开头的确认开场白（chatConfirmOpeners 中随机选中的那个 + "："），
    /// 用于把「账单确认」与「饮食确认」合并成「单开场白 + 多行内容」的自然格式。
    private func stripOpener(_ text: String) -> String {
        for op in chatConfirmOpeners {
            let prefix = op + "："
            if text.hasPrefix(prefix) {
                return String(text.dropFirst(prefix.count))
            }
        }
        return text
    }

    // MARK: - 聊天记账防重复
    /// 短时间内重复发送同一句话，不重复入库（防止反复测试 / 误点产生重复记录）。
    /// 仅覆盖本次运行会话内的本地记账路径（账单 / 饮食 / 待办）；图片路径另有 aHash 指纹去重。
    /// 窗口由 24h 改为 30s：原 24h 太激进，正常用户删后重建会一直被误判为重复；
    /// 30s 已足够防误连点/网络重试，又不会拦"删了再记"的正常操作。
    /// 删除记录时务必同步调 `clearDedupKey`，否则上一笔被删后立刻重建仍会被去重。
    private static var recentCreations: [(key: String, at: Date)] = []
    private static let dedupWindow: TimeInterval = 30

    /// 计算去重键：去掉金额与记账 / 提醒动词、语气助词后，保留餐次 / 内容词。
    /// 不同餐次（如「晚餐」vs「午餐」）键不同，不会互相误判；同一句话重复发送则键相同。
    private static func chatDedupKey(_ text: String, type: String) -> String {
        var t = text.lowercased()
        t = t.replacingOccurrences(of: #"\d+(\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
                                   with: "", options: .regularExpression)
        let verbs = ["记一笔","记账","记一下","记个","记下来","记","帮我记","给我记","添加","增加","创建",
                     "新建","保存","录入","花了","花掉","付了","付给","买了","消费","支出","账单",
                     "花销","开销","扫码付","提醒我","提醒","吃了","喝了","喝","吃"]
        for v in verbs { t = t.replacingOccurrences(of: v, with: "") }
        t = t.replacingOccurrences(of: #"[的了在给和去个吧啊呢哦嘛]"#, with: "", options: .regularExpression)
        return "\(type):\(t.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// 命中最近一次相同内容 → 返回 true（调用方不应再入库）；否则登记并返回 false。
    static func checkDuplicateAndRegister(_ text: String, type: String) -> Bool {
        let now = Date()
        recentCreations.removeAll { now.timeIntervalSince($0.at) > dedupWindow }
        let key = chatDedupKey(text, type: type)
        if recentCreations.contains(where: { $0.key == key }) { return true }
        recentCreations.append((key, now))
        return false
    }

    /// 删除/撤销某条记录时清理对应的 dedup key，避免「删了再记同一笔」被误判为重复。
    /// 同时清理所有 type 的同内容键（防食物/账单互吞）。
    static func clearDedupKey(_ text: String, type: String? = nil) {
        let key = chatDedupKey(text, type: type ?? "")
        recentCreations.removeAll { entry in
            entry.key == key || (type != nil && entry.key == chatDedupKey(text, type: ""))
        }
    }

    /// 本地记账（DB 优先、AI 兜底）：解析「记一笔星巴克35」「付了美团28」这类明确账单意图，
    /// 商户分类优先查本地 MerchantMeta 经验库，命中即复用、不调 AI；未命中给"其他"。
    /// 触发条件：① 含明确记账动词（记一笔/花了/付了…）且含金额；② 含食物词且含「金额+货币单位」（如「午饭吃了碗牛肉面32块」）。
    /// 纯饮食（无金额，如「喝了一杯奶茶」）仍返回 nil，走 food 路径，避免误吞饮食/问句。
    private func createBillLocally(from text: String) async -> String? {
        let lower = text.lowercased()
        // 必须先有金额，否则不是本地可解析的账单（纯饮食/问句等交给其它分支）
        guard extractAmount(text) != nil else { return nil }

        // 先判 update 意图（如「把星巴克的账单改成40元」），命中走 update 路径
        if ChatView.hasExplicitUpdateIntent(lower) {
            if let upd = updateBillLocally(from: text, newAmount: extractAmount(text)!) {
                return upd
            }
        }

        let incomeKeywords = ["工资","薪资","薪水","收入","报销","退款","返现","奖金","分红","利息","红包","补贴","收款","进账","提成","劳务费","兼职"]
        let billKw = ["记一笔", "记账", "花了", "花掉", "付了", "付给", "买了", "消费", "支出", "账单", "花销", "开销", "扫码付"]
        let hasExplicitBill = billKw.contains(where: { lower.contains($0) })
        let hasMoneyUnit = lower.contains("元") || lower.contains("块") || lower.contains("￥") || lower.contains("¥")
        let isFoodWithAmount = hasRawFoodIntent(text) && hasMoneyUnit
        let isIncomeWithAmount = incomeKeywords.contains(where: { lower.contains($0) })
        guard hasExplicitBill || isFoodWithAmount || isIncomeWithAmount else { return nil }

        // 一句话多条：先按连词切分，再按餐次词（午餐/晚餐…）切分，逐条建账单。
        // 例：「午餐花了10元晚餐花了15元」无连词，靠餐次词切成两笔，避免两顿被并成一条。
        var segments = IntentTextUtils.splitByConjunction(text)
        var expanded: [String] = []
        for seg in segments { expanded.append(contentsOf: IntentTextUtils.splitBillsByMeal(seg)) }
        segments = expanded
        var billPayloads: [BillPayload] = []
        for seg in segments {
            guard let fields = buildBill(from: seg) else { continue }
            // 解析日期 + 时刻：
            // - 有「昨天/前天/M月D日/12:30」等 → 取对应日期时刻；
            // - 仅含餐次词（如「午餐花了10元」，无时刻）→ 用该餐次默认时刻（12:00）补上，
            //   避免落到当天 0:00 被上海时区序列化成 8:00。
            let billDate = ChatView.resolveBillDate(from: seg)
            if WaterIntakeParser.checkDuplicateAndRegister(seg, type: "bill") { continue }
            if DataDeduplicator.isDuplicateBill(merchant: fields.merchant, amount: fields.amount, time: billDate, context: context) { continue }
            billPayloads.append(BillPayload(merchant: fields.merchant,
                                            amount: fields.amount,
                                            currency: nil,
                                            category: fields.category,
                                            time: AppFormat.iso.string(from: billDate),
                                            note: nil,
                                            action: nil,
                                            targetTitle: nil))
        }
        guard !billPayloads.isEmpty else { return nil }
        UsageAnalytics.logAdd("bill", source: "chat")
        let result = RecognitionResult(types: ["bill"], bills: billPayloads)
        if await routeRecognition(result, rawText: text) {
            return kHandledCard
        }
        return nil
    }

    /// 从单个子句解析出一笔账单的字段（商户/金额/分类/收支），供一句话多条账单复用。
    private func buildBill(from seg: String) -> (merchant: String, amount: Double, category: String, isIncome: Bool)? {
        guard let amount = extractAmount(seg) else { return nil }
        let lower = seg.lowercased()
        var merchant = seg
        merchant = ChatView.stripCommandVerbPrefix(merchant)
        merchant = ChatView.stripSpendPhrase(merchant)
        merchant = merchant.replacingOccurrences(of: #"\d{1,3}(?:[,\，]\d{3})+(?:\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?|\d+(?:\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
                                                 with: "", options: .regularExpression)
        merchant = merchant.replacingOccurrences(of: #"[¥￥\$]"#, with: "", options: .regularExpression)
        let billKw = ["记一笔", "记账", "花了", "花掉", "付了", "付给", "买了", "消费", "支出", "账单", "花销", "开销", "扫码付"]
        for kw in billKw { merchant = merchant.replacingOccurrences(of: kw, with: "") }
        let baWords = ["改成", "改为", "变成", "调成", "调为", "调整为", "设为", "设置为"]
        for kw in baWords { merchant = merchant.replacingOccurrences(of: kw, with: "") }
        merchant = merchant.replacingOccurrences(of: #"(今晚|今天|明天|早上|上午|中午|下午|晚上|刚才|吃了|喝了|喝|吃|买|碗|杯|个|盘|份|根|片|串|块|勺)"#,
                                                 with: "", options: .regularExpression)
        merchant = merchant.replacingOccurrences(of: #"[的了在给和去个吧啊呢哦嘛把]"#,
                                                 with: "", options: .regularExpression)
        merchant = merchant.replacingOccurrences(of: #"[\d,\.，。、\s]+"#,
                                                 with: "", options: .regularExpression)
        merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if merchant.isEmpty { merchant = "其他消费" }

        let incomeKeywords = ["工资","薪资","薪水","收入","报销","退款","返现","奖金","分红","利息","红包","补贴","收款","进账","提成","劳务费","兼职"]
        let isIncomeText = incomeKeywords.contains { lower.contains($0) || merchant.contains($0) }
        var (cat, metaIncome) = MerchantMetaStore.lookup(merchant, in: context) ?? ("其他", false)
        if cat == "其他", let hint = RecognizeService.mealCategoryHint(merchant + " " + seg) {
            cat = hint
        }
        let isIncome = isIncomeText || metaIncome
        if isIncome, ["收入", "进账", "收款", "入账"].contains(merchant) || merchant.isEmpty {
            merchant = "其他收入"
        }
        let category = (isIncome && cat == "其他") ? "收入" : cat
        return (merchant, amount, category, isIncome)
    }

    /// 解析账单最终时间：合并「相对日期 + 时刻/餐次词」。
    /// 旧逻辑用纯日期串（isoDate）序列化，上海时区 +8 后显示 8:00，且盖过餐次默认时刻。
    /// 现改为：优先用文本里真实时刻；无时刻但含餐次词（午餐/晚餐…）则补上对应默认时刻
    /// （12:00 / 18:00…），保证「午餐花了10元」落到当天 12:00 而非 8:00。
    private static func resolveBillDate(from seg: String) -> Date {
        let parsed = RelativeDateParser.parse(from: seg)
        let base = parsed?.date ?? Date()
        let hasTime = parsed?.hasTime ?? false

        guard !hasTime else { return base }

        // 仅餐次词、无真实时刻：用餐次默认时刻替换 base 的时分秒
        let mealMap: [(keywords: [String], hour: Int, minute: Int)] = [
            (["早饭", "早餐", "早点", "早點"], 8, 0),
            (["午饭", "午餐", "中饭", "中餐"], 12, 0),
            (["晚饭", "晚餐", "夜饭"], 18, 0),
            (["夜宵", "宵夜", "夜消"], 22, 0),
        ]
        for (keywords, h, m) in mealMap {
            if keywords.contains(where: { seg.contains($0) }) {
                return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
            }
        }
        return base
    }

    /// 本地修改账单金额（处理「把星巴克的账单改成40元」「改一下：星巴克→40」）。
    /// 命中已有账单：直接改 amount；找不到目标返回 nil（外层会回退为新建）。
    private func updateBillLocally(from text: String, newAmount: Double) -> String? {
        // 从文本中抽出「目标商户名」（去掉把字句、改成动词、金额、记账词等噪声）
        var target = text
        let noise = ["改成", "改为", "变成", "调成", "调为", "调整为", "设为", "设置为",
                     "记一笔", "记账", "花了", "花掉", "付了", "付给", "买了", "消费", "支出", "账单", "花销", "开销", "扫码付",
                     "帮我", "给我", "把", "一下", "改"]
        for kw in noise { target = target.replacingOccurrences(of: kw, with: "") }
        // 去金额
        target = target.replacingOccurrences(of: #"\d{1,3}(?:[,\，]\d{3})+(?:\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?|\d+(?:\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
                                             with: "", options: .regularExpression)
        // 清掉残留的货币符号（¥40 这类符号在金额前，上面的正则清不掉）
        target = target.replacingOccurrences(of: #"[¥￥\$]"#, with: "", options: .regularExpression)
        // 去掉语气助词/数字/标点
        target = target.replacingOccurrences(of: #"[的了在给和去个吧啊呢哦嘛把\s,\.，。、\d]+"#,
                                             with: "", options: .regularExpression)
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)

        // 找到目标账单（找不到返回 nil，让外层回退为新建）
        guard let bill = target.isEmpty ? nil : findBillTarget(targetTitle: target, fallbackToLatest: true)
        else { return nil }

        let oldAmount = bill.amount
        bill.amount = newAmount
        bill.syncUpdatedAt = Date()
        try? context.save()
        WaterIntakeParser.clearDedupKey("\(bill.merchant)\(String(format: "%.2f", oldAmount))", type: "bill")
        WaterIntakeParser.clearDedupKey("\(bill.merchant)\(String(format: "%.2f", newAmount))", type: "bill")
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        return "\(opener)：🔄 已把「\(bill.merchant)」从 ¥\(String(format: "%.2f", oldAmount)) 改成 ¥\(String(format: "%.2f", newAmount))"
    }

    /// 本地创建饮食：食物类文本优先从本地营养库（硬编码 + 用户缓存）估算热量，
    /// 命中即直接建记录，无需等云端返回。未命中返回 nil，由外层走云端识别。
    /// 仅处理「早餐吃了一碗燕麦粥」这类明确饮食意图；有更新/删除/完成意图时返回 nil 交给云端。
    /// 云端查询超时辅助：最多等 12s，超时/失败返回 nil。
    private static func queryFoodOrNil(_ name: String) async -> FoodRef? {
        let task = Task<FoodRef?, Error> {
            try await RecognizeService.queryFood(name: name)
        }
        let timeoutTask = Task<Void, Error> {
            try await Task.sleep(nanoseconds: 12_000_000_000)
            task.cancel()
        }
        let result = try? await task.value
        timeoutTask.cancel()
        return result
    }

    /// 微营养素（纤维/糖/钠）「历史 0 值缓存」重查记录。
    /// 本地库一旦有条目，match 就直接返回、永不再问云端；早期沉淀的全 0 条目会因此永久卡住。
    /// 允许对这类条目回云端刷新一次，但同一食物只试一次（记在这里），云端仍无值就不再重复请求，控制调用成本。
    private static let microRefreshTriedKey = "aia.food.microRefreshTried"

    private static func microRefreshTried(_ name: String) -> Bool {
        let list = UserDefaults.standard.stringArray(forKey: microRefreshTriedKey) ?? []
        return list.contains(name)
    }

    private static func markMicroRefreshTried(_ name: String) {
        var list = UserDefaults.standard.stringArray(forKey: microRefreshTriedKey) ?? []
        guard !list.contains(name) else { return }
        list.append(name)
        if list.count > 300 { list.removeFirst(list.count - 300) }
        UserDefaults.standard.set(list, forKey: microRefreshTriedKey)
    }

    /// 创建本地食物记录。
    /// - Parameters:
    ///   - text: 待解析文本（可能含食物名 + 重量 + 日期/时刻）。
    ///   - preferredDate: 外部已解析好的日期（如用户分两次说，第一步已解析出「昨天」）。传了就用它，不再重新解析文本里的日期。
    ///   - preferredHasTime: 与 preferredDate 配套，标记是否含具体时刻（影响日期字符串是否带时刻）。
    private func createFoodLocally(from text: String, preferredDate: Date? = nil, preferredHasTime: Bool = false) async -> String? {
        if ChatView.hasExplicitUpdateIntent(text) ||
           ChatView.hasExplicitDeleteIntent(text) ||
           ChatView.hasExplicitCompleteIntent(text) {
            return nil
        }
        let meal = WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        // 解析「昨天/前天/大前天/上周X/M月D日」等相对日期词（没有则回退今天）。
        // 若用户还说了具体时刻（如「下午3点」），把完整时间也存进 FoodPayload。
        // 优先使用外部传入的日期/时刻（分两次说时第一步已解析好，避免二次组句丢日期）。
        let (foodDate, foodHasTime): (Date, Bool)
        if let pd = preferredDate {
            foodDate = pd
            foodHasTime = preferredHasTime
        } else {
            (foodDate, foodHasTime) = RelativeDateParser.dateTimeOrToday(from: text)
        }
        let foodDateStr = foodHasTime ? AppFormat.isoLocal.string(from: foodDate) : AppFormat.isoDate.string(from: foodDate)
        let items = ChatView.parseFoodItems(from: text, context: context)
        guard !items.isEmpty else { return nil }

        // 如果用户没给重量/份量，先追问不急着入库。
        // 连同原始日期/时刻一起暂存，避免用户下一步只回重量时丢了「昨天/下午3点」。
        if !ChatView.hasWeightInfo(text) {
            let firstItem = items[0]
            pendingWeightFood = (firstItem.name, meal, foodDate, foodHasTime)
            return nil
        }

        var foodPayloads: [FoodPayload] = []
        var missingNutrition: [String] = []
        var cloudFilled: [String] = []
        for (name, weight, _) in items {
            var ref: FoodRef? = NutritionLibrary.shared.match(name, in: context)
            if ref == nil {
                // 本地库无 → 尝试云端查询营养（带超时，失败降级 0 占位）
                if let cloudRef = await Self.queryFoodOrNil(name) {
                    // 云端结果存本地经验库，下次同名菜本地直出
                    FoodMetaStore.upsert(name: name, displayName: cloudRef.name,
                                         kcal: cloudRef.kcal, protein: cloudRef.protein,
                                         carbs: cloudRef.carbs, fat: cloudRef.fat,
                                         fiber: cloudRef.fiber, sugar: cloudRef.sugar, sodium: cloudRef.sodium,
                                         source: "cloud", in: context)
                    ref = cloudRef
                    cloudFilled.append(name)
                } else {
                    ref = nil
                    missingNutrition.append(name)
                }
            } else if let hit = ref,
                      hit.fiber == 0, hit.sugar == 0, hit.sodium == 0,
                      !FoodMetaStore.isBuiltin(name: hit.name, in: context),
                      !Self.microRefreshTried(name) {
                // 本地命中，但纤维/糖/钠全 0 且不是内置权威值 → 大概率是早期沉淀的脏缓存。
                // match 命中就不再查云端，这个 0 会永久卡住，所以在此主动回云端刷新一次。
                Self.markMicroRefreshTried(name)
                if let cloudRef = await Self.queryFoodOrNil(name),
                   cloudRef.fiber > 0 || cloudRef.sugar > 0 || cloudRef.sodium > 0 {
                    // 用用户实际说的名字建/更新条目，避免覆盖子串命中的通用键（如「禾花鱼」写坏「鱼肉」）
                    FoodMetaStore.upsert(name: name, displayName: cloudRef.name,
                                         kcal: cloudRef.kcal, protein: cloudRef.protein,
                                         carbs: cloudRef.carbs, fat: cloudRef.fat,
                                         fiber: cloudRef.fiber, sugar: cloudRef.sugar, sodium: cloudRef.sodium,
                                         source: "cloud", in: context)
                    ref = cloudRef
                    cloudFilled.append(name)
                }
            }

            let r = ref
            let fname = r?.name ?? name
            // 营养库每 100 克营养，按实际重量缩放成这一份的总量
            let ratio = weight / 100.0
            let fcal = (r?.kcal ?? 0) * ratio
            let fpro = (r?.protein ?? 0) * ratio
            let fcar = (r?.carbs ?? 0) * ratio
            let ffat = (r?.fat ?? 0) * ratio
            let ffib = (r?.fiber ?? 0) * ratio
            let fsug = (r?.sugar ?? 0) * ratio
            let fsod = (r?.sodium ?? 0) * ratio
            foodPayloads.append(FoodPayload(
                name: fname,
                calories: fcal,
                protein: fpro,
                carbs: fcar,
                fat: ffat,
                fiber: ffib,
                sugar: fsug,
                sodium: fsod,
                portion: "约\(Int(weight))克",
                meal: meal,
                date: foodDateStr,
                action: nil,
                targetTitle: nil,
                weightGram: weight
            ))
        }

        // 防重复：以整句话做 key（短期窗口）
        if WaterIntakeParser.checkDuplicateAndRegister(text, type: "food") {
            return "这顿你刚记过啦，我就不重复记了～"
        }
        // 内容级去重：检查 24h 内是否有同名 + 同份量记录（按解析出的日期，避免"昨天"被误判成今天刚记过）
        for p in foodPayloads {
            if DataDeduplicator.isDuplicateFood(name: p.name ?? "", date: foodDate, portion: p.portion ?? "", context: context) {
                return "这顿你刚记过啦，我就不重复记了～"
            }
        }
        guard !foodPayloads.isEmpty else { return nil }
        UsageAnalytics.logAdd("food", source: "chat")
        let result = RecognitionResult(types: ["food"], foods: foodPayloads)
        if await routeRecognition(result, rawText: text) {
            return kHandledCard
        }
        return nil
    }

    /// 用户回复了重量后，组合成完整的食物文本再走正常创建流程。
    /// date/hasTime 来自第一步暂存的原始日期/时刻（如「昨天 下午3点」），必须透传给 createFoodLocally，
    /// 否则合成文本不含这些词时会回退成「今天 + 默认餐次时间」，记错天/时刻。
    private func createFoodWithWeight(name: String, text: String, meal: String, date: Date, hasTime: Bool) async -> String {
        // 构建合成文本让 createFoodLocally 复用同一套解析逻辑；
        // 但日期/时刻用第一步已解析好的，不走合成文本重新解析。
        let syntheticText = "\(meal)吃了\(text)\(name)"
        if let result = await createFoodLocally(from: syntheticText, preferredDate: date, preferredHasTime: hasTime) {
            return result
        }
        // 兜底：即使合成文本也解析失败，至少记下食物名（让用户知道已处理）
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        return "\(opener)：已记录「\(name)」～如需修改可在饮食记录页面调整。"
    }

    /// 用户只说食物名（不记录）时，回复每 100g 营养数据。
    /// 本地营养库命中直接回复；未命中则联网 queryFood 并缓存到 FoodMetaStore。
    private func handleFoodQuery(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 排除有明确记录/查询意图外的其他词（如「好的」「知道了」）
        let nonFoodSignals = ["好的", "知道了", "嗯嗯", "谢谢", "收到", "哈", "哈哈", "没问题", "可以", "ok", "okay", "知道"]
        if nonFoodSignals.contains(trimmed.lowercased()) { return nil }

        // 尝试匹配本地营养库
        var ref: FoodRef? = NutritionLibrary.shared.match(trimmed, in: context)
        if ref == nil {
            // 本地无数据 → 联网查询
            guard let cloudRef = try? await RecognizeService.queryFood(name: trimmed) else { return nil }
            // 缓存到本地，下次直接命中
            FoodMetaStore.upsert(name: trimmed, displayName: cloudRef.name,
                                 kcal: cloudRef.kcal, protein: cloudRef.protein,
                                 carbs: cloudRef.carbs, fat: cloudRef.fat,
                                 fiber: cloudRef.fiber, sugar: cloudRef.sugar, sodium: cloudRef.sodium,
                                 source: "cloud", in: context)
            ref = cloudRef
        }
        guard let ref else { return nil }

        let kcal = String(format: "%.0f", ref.kcal)
        let carb = String(format: "%.1f", ref.carbs)
        let pro  = String(format: "%.1f", ref.protein)
        let fat  = String(format: "%.1f", ref.fat)
        let fib  = String(format: "%.1f", ref.fiber)
        let sug  = String(format: "%.1f", ref.sugar)
        let sod  = String(format: "%.0f", ref.sodium)

        return "小记帮你查到「\(ref.name)」每100克" +
               "热量\(kcal)kcal，碳水\(carb)g，蛋白质\(pro)g，脂肪\(fat)g，" +
               "膳食纤维\(fib)g，糖\(sug)g，钠\(sod)mg，数据仅供参考。"
    }

    /// 云端兜底也失败时的「尽力记录」：本地营养库查不到、云端也识别不出时，
    /// 仍把食物名+份量落库，热量记为 0 并提示用户稍后补全，避免被静默丢弃。
    /// 典型场景：云端 provider 配置缺失导致纯文字被发到视觉模型、识别成 none —— 食物绝不能因此消失。
    private func createFoodLocallyFallback(from text: String) -> String? {
        let meal = WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        // 解析「昨天/前天/上周X/M月D日」等相对日期词（没有则回退今天）
        let (foodDate, _) = RelativeDateParser.dateTimeOrToday(from: text)
        let items = ChatView.parseFoodItems(from: text, context: context)
        guard !items.isEmpty else { return nil }

        var names: [String] = []
        for (name, weight, portion) in items {
            let entry = FoodEntry(name: name, calories: 0, protein: 0, carbs: 0, fat: 0,
                                  fiber: 0, sugar: 0, sodium: 0,
                                  portion: portion, meal: meal,
                                  date: foodDate,
                                  weightGram: weight,
                                  baseCalories: 0, baseProtein: 0, baseCarbs: 0, baseFat: 0,
                                  baseFiber: 0, baseSugar: 0, baseSodium: 0,
                                  imageName: nil)
            context.insert(entry)
            context.insert(FoodSource(foodSyncId: entry.syncId, origin: "chat"))
            names.append("「\(name)」\(portion)")
        }
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let joined = names.joined(separator: "、")
        return "🍽 已记下 \(joined)，但暂时没查到热量，点开记录可以补全哦～"
    }

    /// 账单已记且本地营养库未命中时，异步联网查营养并走统一识别卡片水槽，
    /// 按「文字/语音」设置自动保存或待确认（与图片/文字入口一致）。
    private func routeFoodCloudThenCard(text: String) async {
        let meal = WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        // 解析「昨天/前天/上周X/M月D日」等相对日期词（没有则回退今天）
        let (foodDate, foodHasTime) = RelativeDateParser.dateTimeOrToday(from: text)
        let foodDateStr = foodHasTime ? AppFormat.isoLocal.string(from: foodDate) : AppFormat.isoDate.string(from: foodDate)
        let items = ChatView.parseFoodItems(from: text, context: context)
        guard !items.isEmpty else { return }

        var foodPayloads: [FoodPayload] = []
        for (name, weight, _) in items {
            do {
                if let ref = try await RecognizeService.queryFood(name: name) {
                    FoodMetaStore.upsert(name: name, displayName: ref.name,
                                         kcal: ref.kcal, protein: ref.protein, carbs: ref.carbs, fat: ref.fat,
                                         fiber: ref.fiber, sugar: ref.sugar, sodium: ref.sodium,
                                         source: "cloud", in: context)
                // 营养库每 100 克营养，按实际重量缩放成这一份的总量
                let ratio = weight / 100.0
                foodPayloads.append(FoodPayload(
                    name: ref.name, calories: ref.kcal * ratio, protein: ref.protein * ratio,
                    carbs: ref.carbs * ratio, fat: ref.fat * ratio, fiber: ref.fiber * ratio, sugar: ref.sugar * ratio,
                    sodium: ref.sodium * ratio, portion: "约\(Int(weight))克", meal: meal,
                    date: foodDateStr,
                    action: nil, targetTitle: nil, weightGram: weight))
                }
            } catch {
                print("[routeFoodCloudThenCard] 云端查营养失败：\(error)")
            }
        }
        guard !foodPayloads.isEmpty else { return }
        let result = RecognitionResult(types: ["food"], foods: foodPayloads)
        _ = await routeRecognition(result, rawText: text)
    }

    /// 聊天记录饮水量：直接创建一条 FoodEntry，仅 waterIntake 有值，营养全 0。
    /// 走 `parseWaterIntake` 解析；返回消息（成功确认/失败提示）。
    private func createWaterIntake(from text: String) -> String? {
        guard let (ml, display) = WaterIntakeParser.parse(text) else { return nil }
        let meal = WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)

        // 防重复
        if WaterIntakeParser.checkDuplicateAndRegister(text, type: "water") {
            return "这杯水我刚记过啦～"
        }

        let entry = FoodEntry(
            name: "饮用水",
            calories: 0, protein: 0, carbs: 0, fat: 0,
            fiber: 0, sugar: 0, sodium: 0,
            waterIntake: ml,
            portion: display,
            meal: meal,
            imageName: nil
        )
        context.insert(entry)
        CloudSyncManager.shared.syncAfterLocalChange(context: context)

        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        return "\(opener)：💧 \(meal)喝了 \(display)（\(Int(ml)) ml）"
    }

    /// 聊天记录食物入口：本地营养库未命中时，走云端专项食物营养查询；仍失败则兜底通用识别。
    /// 支持一句话里多个食物，逐项查询并分别建 FoodEntry。
    private func createFoodFromCloud(text: String, recentMessages: [[String: String]]) async -> String {
        let meal = WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        // 解析「昨天/前天/上周X/M月D日」等相对日期词（没有则回退今天）
        let (foodDate, foodHasTime) = RelativeDateParser.dateTimeOrToday(from: text)
        let foodDateStr = foodHasTime ? AppFormat.isoLocal.string(from: foodDate) : AppFormat.isoDate.string(from: foodDate)
        let items = ChatView.parseFoodItems(from: text, context: context)
        guard !items.isEmpty else { return await localReply(for: text) }

        // 1) 优先专项查询每个食物的营养（更可靠，不易被上下文带偏）
        var foodPayloads: [FoodPayload] = []

        for (name, weight, _) in items {
            // A1/A3：本地营养库优先（与「手动搜索」同源）。先用规范名在本地单库 match，
            // 命中即用确定值，保证对话记饮食与手动搜索对同一食物（如「红烧牛肉」vs「牛肉」）数值一致；
            // 仅本地库不认识该食物时，才走云端专项食物营养查询。
            let canonical = NutritionLibrary.canonicalFoodName(name, in: context)
            var ref: FoodRef? = NutritionLibrary.shared.match(canonical, in: context)
            var fromCloud = false

            if ref == nil {
                do {
                    ref = try await RecognizeService.queryFood(name: name)
                    fromCloud = true
                } catch {
                    print("[queryFood] 失败：\(error)")
                }
            }

            if let ref = ref {
                // 仅云端命中才回写缓存（本地命中已是单库内建/沉淀值，无需重复写入）。
                if fromCloud {
                    FoodMetaStore.upsert(name: name, displayName: ref.name,
                                         kcal: ref.kcal, protein: ref.protein, carbs: ref.carbs, fat: ref.fat,
                                         fiber: ref.fiber, sugar: ref.sugar, sodium: ref.sodium,
                                         source: "cloud", in: context)
                }

                // 营养库每 100 克营养，按实际重量缩放成这一份的总量
                let ratio = weight / 100.0
                foodPayloads.append(FoodPayload(
                    name: ref.name,
                    calories: ref.kcal * ratio,
                    protein: ref.protein * ratio,
                    carbs: ref.carbs * ratio,
                    fat: ref.fat * ratio,
                    fiber: ref.fiber * ratio,
                    sugar: ref.sugar * ratio,
                    sodium: ref.sodium * ratio,
                    portion: "约\(Int(weight))克",
                    meal: meal,
                    date: foodDateStr,
                    action: nil,
                    targetTitle: nil,
                    weightGram: weight
                ))
            }
        }

        if !foodPayloads.isEmpty {
            let result = RecognitionResult(types: ["food"], foods: foodPayloads)
            if await routeRecognition(result, rawText: text) {
                return kHandledCard
            }
            // 按设置丢弃（或无需记录）→ 不再强制入库
            return await localReply(for: text)
        }

        // 2) 专项查询全部失败：兜底通用文本识别
        do {
            let (result, _) = try await RecognizeService.parseText(text, recentMessages: recentMessages)
            let summary = saveFromResult(result, originalText: text, allowedTypes: ["food"])
            if !summary.isEmpty {
                let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
                return "\(opener)：\n" + summary.joined(separator: "\n")
            }
        } catch {
            print("[parseText food] 失败：\(error)")
        }

        // 3) 都失败：落多条热量为0的记录，避免食物被静默丢失
        if let fb = createFoodLocallyFallback(from: text) {
            return fb + "\n（云端暂时没查到营养，已先帮你记下来）"
        }
        return await localReply(for: text)
    }

    /// 从用户输入里提取食物名、估算重量和份量描述。
    /// 支持「一碗」「两杯」「100克」等常见中文/阿拉伯数量词；匹配不到数量时默认 100g。
    /// 清理「花费/账单」短语与金额，避免把「汉堡花10元」里的「花10元」残成食物名/商户名。
    /// - 覆盖：花了/花掉/付了/付给/消费/支出/账单/花销/开销/扫码付/记一笔/记账/买了
    /// - 覆盖裸写法：「花」直接接金额，如「汉堡花10元」「晚餐汉堡花32块」
    /// - 用纯字母占位符保护「爆米花/花菜/花生/花卷/花蛤/花螺/红花」等本身含「花」的真实食物/菜品名，
    ///   防止被误当花费动词清掉（占位符不含数字，避免被金额/标点清理误删）。
    static func stripSpendPhrase(_ text: String) -> String {
        let protectedFoods = ["爆米花", "花菜", "花生", "花卷", "花蛤", "花螺", "红花"]
        let placeholders = ["ZFA", "ZFB", "ZFC", "ZFD", "ZFE", "ZFF", "ZFG"]
        var t = text
        for (i, f) in protectedFoods.enumerated() {
            if t.contains(f) {
                t = t.replacingOccurrences(of: f, with: placeholders[i])
            }
        }
        // 先清「花[了]? + 金额」裸写法（支持千分位逗号/中文逗号），再清其它账单关键词
        let amountPattern = #"\d{1,3}(?:[,\，]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"#
        let spendPattern = #"花[了]?\s*\#(amountPattern)\s*(元|块|元钱|块钱|￥|¥)?|花了?|花掉|付了?|付给|消费|支出|账单|花销|开销|扫码付|记一笔|记账|买了"#
        t = t.replacingOccurrences(of: spendPattern, with: "", options: .regularExpression)
        // 再清残留的所有数字金额（含货币单位，单位可选；支持千分位）
        t = t.replacingOccurrences(of: #"\d{1,3}(?:[,\，]\d{3})+(?:\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?|\d+(?:\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
                                   with: "", options: .regularExpression)
        // 还原受保护的含「花」食物/菜品名
        for (i, f) in protectedFoods.enumerated() {
            t = t.replacingOccurrences(of: placeholders[i], with: f)
        }
        return t
    }

    /// 在份量提取「之前」调用：清掉「花」作花费动词且后接金额（含可选「了」，如「汉堡花10元」「汉堡花了10元」「汉堡花32块」）。
    /// 必须放在份量提取前，否则「块」等货币/量词会被当成重量单位吃掉，导致食物名残留成「汉堡花」。
    /// 仅删「花 + 金额」这一短语（不动其它数字），以保留「1个汉堡」里的数量供份量估算使用。
    /// 用纯字母占位符保护爆米花/花菜/花生/花卷/花蛤/花螺/红花等本身含「花」的真实食物名。
    static func stripBareHuaAmount(_ text: String) -> String {
        let protectedFoods = ["爆米花", "花菜", "花生", "花卷", "花蛤", "花螺", "红花"]
        let placeholders = ["ZFA", "ZFB", "ZFC", "ZFD", "ZFE", "ZFF", "ZFG"]
        var t = text
        for (i, f) in protectedFoods.enumerated() {
            if t.contains(f) { t = t.replacingOccurrences(of: f, with: placeholders[i]) }
        }
        t = t.replacingOccurrences(of: #"花[了]?\s*(\d{1,3}(?:[,\，]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)\s*(元|块|元钱|块钱|￥|¥)?"#,
                                   with: "", options: .regularExpression)
        for (i, f) in protectedFoods.enumerated() {
            t = t.replacingOccurrences(of: placeholders[i], with: f)
        }
        return t
    }

    // MARK: - 共享：写入类命令动词前缀清洗
    /// 所有"写记录"类命令动词前缀（记/记录/添加/增加/创建/新建/设置/录入/保存/帮我/给我…）。
    /// 食物名 / 账单商户 / 待办标题 / 云端 create_* 共用同一份，避免换种说法又漏。
    /// 必须按长度降序：否则「帮我记一笔」会被「记」截成「帮我一笔」。
    static let commandVerbPrefixes: [String] = [
        // 记 / 记录
        "帮我记一笔", "给我记一笔", "帮我记录一笔", "给我记录一笔",
        "帮我记一下", "给我记一下", "帮我记个", "给我记个", "帮我记下来", "给我记下来",
        "帮我记账", "给我记账",
        "记一笔", "记一下", "记个", "记下来", "记账", "记录下", "记录了", "记录", "记",
        "帮我记", "给我记", "帮我记录", "给我记录",
        // 添加 / 增加
        "帮我增加一笔", "给我增加一笔", "帮我添加一笔", "给我添加一笔",
        "增加一笔", "添加一笔", "加一笔", "来一笔",
        "帮我增加", "给我增加", "帮我添加", "给我添加",
        "增加", "添加",
        // 创建 / 新建 / 设置
        "帮我创建一个", "给我创建一个", "帮我新建一个", "给我新建一个", "帮我设置一个", "给我设置一个",
        "帮我创建", "给我创建", "帮我新建", "给我新建", "帮我设置", "给我设置",
        "创建", "新建", "设置",
        // 录入 / 保存
        "帮我录入", "给我录入", "录入",
        "帮我保存", "给我保存", "保存",
        // 通用「帮我 / 给我」
        "帮我", "给我"
    ]

    /// 剥离命令动词前缀后，紧接的量词（一个/一条…）也应去掉，避免「帮我添加一个买菜提醒」残留成「一个买菜提醒」。
    static let commandMeasureWords: [String] = [
        "一个", "一条", "一项", "一件", "这台", "这部", "这张", "这把", "那只", "那个", "这个"
    ]

    /// 剥离写入类命令动词前缀（只剥前缀，不全局删除，避免名字里正常的「记/添加」被误删）。
    /// 循环剥离：处理「帮我记一下」这类组合，直到不再命中前缀为止。
    static func stripCommandVerbPrefix(_ text: String) -> String {
        var t = text
        var changed = true
        while changed {
            changed = false
            for p in commandVerbPrefixes where t.hasPrefix(p) {
                t = String(t.dropFirst(p.count))
                changed = true
                break
            }
            for m in commandMeasureWords where t.hasPrefix(m) {
                t = String(t.dropFirst(m.count))
                changed = true
                break
            }
        }
        return t
    }

    static func parseFoodNameAndWeight(_ text: String) -> (name: String, weight: Double, portion: String)? {
        var t = text
        // 剥离写入类命令动词前缀（记/记录/添加/…），避免「记午餐吃了饺子200克」残留成「记饺子」
        t = ChatView.stripCommandVerbPrefix(t)

        // 先去掉餐次词，避免餐次混入食物名
        for meal in ["早餐", "早饭", "早上", "今早",
                     "午餐", "午饭", "中午", "正午",
                     "晚餐", "晚饭", "晚上", "今晚",
                     "夜宵", "加餐", "点心", "零食"] {
            t = t.replacingOccurrences(of: meal, with: "")
        }
        // 餐次词移除后，命令动词可能暴露到句首（如「中午记了…」→「记了…」），再剥一次命令动词前缀。
        t = ChatView.stripCommandVerbPrefix(t)

        // 在份量提取之前，先清掉「花」作花费动词且后接金额（含可选「了」，如「汉堡花10元」「汉堡花了10元」「汉堡花32块」），
        // 否则「块」等会被当成重量单位吃掉，导致残留成「汉堡花」。
        // 用占位符保护爆米花/花菜/花生/花卷/花蛤/花螺/红花等本身含「花」的真实食物名。
        t = ChatView.stripBareHuaAmount(t)

        // 份量映射：单位 → 估算克数
        let unitWeights: [(String, Double)] = [
            ("碗", 300), ("杯", 250), ("瓶", 500), ("罐", 330),
            ("个", 50), ("片", 30), ("份", 200), ("块", 50),
            ("串", 100), ("根", 100), ("盘", 300), ("勺", 15),
            ("两", 50),
            ("盒", 100), ("袋", 100), ("包", 100), ("听", 330),
            ("毫升", 1), ("ml", 1), ("ML", 1), ("斤", 500),
            ("克", 1), ("g", 1), ("G", 1)
        ]
        let unitPattern = unitWeights.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
        let quantityPattern = "([\\d一二两三四五六七八九十半]+)?\\s*(\(unitPattern))"

        var weight: Double?
        var portion = "100克"
        if let regex = try? NSRegularExpression(pattern: quantityPattern) {
            let range = NSRange(location: 0, length: t.utf16.count)
            if let match = regex.firstMatch(in: t, range: range) {
                let unit = (t as NSString).substring(with: match.range(at: 2))
                let numberStr = match.range(at: 1).location != NSNotFound
                    ? (t as NSString).substring(with: match.range(at: 1))
                    : ""
                let count = ChatView.parseChineseNumber(numberStr) ?? 1
                if let uw = unitWeights.first(where: { $0.0 == unit }) {
                    weight = count * uw.1
                    portion = "\(formatCount(count))\(unit)"
                    // 清掉本段里【所有】量词，防止「一碗」「两个」等残留量词污染食物名
                    let allMatches = regex.matches(in: t, range: range)
                    var cleaned = t
                    for m in allMatches.reversed() {
                        cleaned = (cleaned as NSString).replacingCharacters(in: m.range(at: 0), with: "")
                    }
                    t = cleaned
                }
            }
        }

        // 先去掉账单关键词（花了/付了/消费…），再去掉常见动词/语气助词。
        // 顺序关键：必须先于下面的 noise（含「了」），否则「花了」会被「了」拆成「花」+金额，
        // 导致食物名残留成「汉堡花」这类错误。
        let billNoise = ["花了", "花掉", "付了", "付给", "消费", "支出", "账单", "花销", "开销", "扫码付",
                         "记一笔", "记账", "买了"]
        for b in billNoise { t = t.replacingOccurrences(of: b, with: "") }

        // 先清掉花费/账单短语（含「花」直接接金额的裸写法，如「汉堡花10元」），
        // 用占位符保护爆米花/花菜等本身含「花」的真实食物名，避免食物名残留成「汉堡花」
        t = ChatView.stripSpendPhrase(t)

        // 去掉常见动词、语气助词、时间/场景词和残留量词，得到食物名
        let noise = ["吃了", "喝了", "吃", "喝", "做了", "点", "来", "是", "想", "要", "做",
                     "了", "的", "在", "给", "和", "去", "吧", "啊", "呢", "哦", "嘛",
                     // 时间/场景词（避免「中午牛肉」「晚上白菜」）
                     "中午", "早上", "晚上", "上午", "下午", "早晨", "清晨", "午后", "午间",
                     "半夜", "深夜", "凌晨", "黎明", "拂晓", "天亮", "傍晚", "黄昏", "夜里", "夜晚", "今晚",
                     "今天", "明天", "昨天", "刚才", "现在",
                     // 副词/语气
                     "还", "又", "也", "刚", "就", "只", "都", "再", "正好", "大概", "差不多"]
        for n in noise { t = t.replacingOccurrences(of: n, with: "") }

        // 去掉残留的数字金额与货币单位
        t = t.replacingOccurrences(of: #"\d+(\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
                                   with: "", options: .regularExpression)
        // 去掉残留标点与空白，得到干净食物名
        t = t.replacingOccurrences(of: #"[，。、,.\s]+"#, with: "", options: .regularExpression)

        let name = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // 护栏：纯数字、纯热量描述、非真实食物名应拒绝，
        // 避免把「我吃了1500大卡」「今天摄入2000千焦」这类纯热量描述当成食物名建记录。
        let energyUnits = ["大卡", "kcal", "千焦", "kj", "卡路里", "热量", "卡", "KCAL", "kJ"]
        let isPureEnergyDesc = energyUnits.contains { name.lowercased().hasSuffix($0) }
            || name.allSatisfy({ $0.isNumber || $0 == "." || $0 == " " })
        if isPureEnergyDesc || name.isEmpty { return nil }

        return (name, weight ?? 100.0, portion)
    }

    /// 食物名退化补刀：云端/本地解析常把「燕麦粥」这类具体食物退化成泛称「粥」。
    /// 用原始输入文本回查：若解析出的名字是泛称（粥/炒饭/面条…），且原文中存在以该泛称
    /// 结尾的更具体长词（如「燕麦粥」），且本地营养库确有该长词，则把名字升级回具体长词。
    /// 仅做升级、不改动重量/份量，无对应具体词则保持原样。
    static func upgradeFoodNameIfNeeded(_ name: String, originalText: String, context: ModelContext) -> String {
        let genericNames = ["粥", "炒饭", "米饭", "面条", "汤", "包子", "饺子", "馒头", "饼", "沙拉", "炒菜", "盖饭", "粉"]
        guard genericNames.contains(name) else { return name }
        let chars = Array(originalText)
        for generic in genericNames where name == generic {
            let maxLen = min(8, chars.count)
            for len in (generic.count + 1)...maxLen {
                for start in 0...(chars.count - len) {
                    let sub = String(chars[start..<start + len])
                    guard sub.hasSuffix(generic) else { continue }
                    // 优先用 NutritionLibrary.match 查（含内存内置表兜底，seed 未到位也能命中精确长词）；
                    // 再退一步直接查本地库，双保险。
                    if NutritionLibrary.shared.match(sub, in: context) != nil
                        || FoodMetaStore.peek(name: sub, in: context) != nil {
                        return sub
                    }
                }
            }
        }
        return name
    }

    /// 从文本中拆出多个食物项。
    /// 优先按「数量+单位」切分；没有量词时退回整句解析，或按常见连词/标点切分。
    /// 示例：「早餐吃了两个鸡蛋一碗燕麦粥」→ [(鸡蛋, 100, "2个"), (燕麦粥, 300, "1碗")]
    static func parseFoodItems(from text: String, context: ModelContext? = nil) -> [(name: String, weight: Double, portion: String)] {
        let unitWeights: [(String, Double)] = [
            ("碗", 300), ("杯", 250), ("瓶", 500), ("罐", 330),
            ("个", 50), ("片", 30), ("份", 200), ("块", 50),
            ("串", 100), ("根", 100), ("盘", 300), ("勺", 15),
            ("两", 50),
            ("盒", 100), ("袋", 100), ("包", 100), ("听", 330),
            ("毫升", 1), ("ml", 1), ("ML", 1), ("斤", 500),
            ("克", 1), ("g", 1), ("G", 1)
        ]
        let unitPattern = unitWeights.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
        let quantityPattern = "([\\d一二两三四五六七八九十半]+)?\\s*(\(unitPattern))"

        guard let regex = try? NSRegularExpression(pattern: quantityPattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var items: [(name: String, weight: Double, portion: String)] = []

        // 切分策略：贪心配对。
        // 每个量词都应绑定到「其前面的食物名」，因此把每个段定义为
        // 「上一个量词的结束位置 → 当前量词的结束位置」。
        // 首段额外把「首量词之前的文本」一起并入段内（即 0 → 首量词结束），
        // 让 parseFoodNameAndWeight 的 firstMatch 吃到的第一个量词正确归属到
        // 位于其前面的食物名（如「生菜50克…」里的生菜拿到50克）。
        // 这样「吃了生菜50克豆芽50克」/「吃了生菜50克，豆芽50克」都能正确拆成
        // 「生菜50g + 豆芽50g」，而非把首量词漏给下一个食物、首食物回落默认100g。
        var searchFrom = 0
        for (idx, match) in matches.enumerated() {
            let matchEnd = match.range(at: 0).location + match.range(at: 0).length
            // 段起点：第一段从 0 开始（含首量词前文本），其余段从上一量词结束开始
            let segStart = (idx == 0) ? 0 : searchFrom
            // 段终点：当前量词结束
            let segmentRange = NSRange(location: segStart, length: matchEnd - segStart)
            let segment = ns.substring(with: segmentRange).trimmingCharacters(in: .whitespacesAndNewlines)

            // 优先整段解析（覆盖「食物名在重量之前」的情况，如「吃了生菜50克」）。
            // 若段内含量词但解析不到食物名（如「吃了50克苹果」「50克苹果」：重量前置、名字落在 trailing 段），
            // 则把本段与其后的 trailing 文本合并后再解析一次，让重量与食物名 reunite，
            // 否则两者被拆到不同段、双双失败，会回退默认 100 克（见 issue：吃50克苹果记成100克）。
            var parsedItem: (name: String, weight: Double, portion: String)? = nil
            if !segment.isEmpty { parsedItem = parseFoodNameAndWeight(segment) }
            if parsedItem == nil {
                // 找到本段之后、到下一量词（或文末）之间的残余文本
                let nextStart = (idx + 1 < matches.count) ? matches[idx + 1].range(at: 0).location : ns.length
                let nextEnd = (idx + 1 < matches.count)
                    ? (matches[idx + 1].range(at: 0).location + matches[idx + 1].range(at: 0).length)
                    : ns.length
                let combined = ns.substring(with: NSRange(location: segStart, length: nextEnd - segStart))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if combined != segment, let parsed = parseFoodNameAndWeight(combined) {
                    parsedItem = parsed
                    // 不吞掉下一量词：从下一量词【开头】继续切，让后段也能用它算重量
                    searchFrom = nextStart
                }
            }
            if let parsed = parsedItem { items.append(parsed) }
            if searchFrom < matchEnd { searchFrom = matchEnd }
        }

        // 末量词之后若还有残余文本（如额外食物名无量词、或语气词），作为 trailing 段单独解析
        if searchFrom < ns.length {
            let trailingRange = NSRange(location: searchFrom, length: ns.length - searchFrom)
            let trailing = ns.substring(with: trailingRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty, let parsed = parseFoodNameAndWeight(trailing) {
                items.append(parsed)
            }
        }

        // 按量词切出至少一项时直接返回，避免把 trailing 语气词/场景词当成食物。
        if !items.isEmpty {
            return upgradeParsedItems(items, originalText: text, context: context)
        }

        // 没有量词：先尝试整句
        if let parsed = parseFoodNameAndWeight(text) {
            if let context = context {
                let upgradedName = upgradeFoodNameIfNeeded(parsed.name, originalText: text, context: context)
                return [(upgradedName, parsed.weight, parsed.portion)]
            }
            return [parsed]
        }

        // 再按常见连词/标点切分
        let separatorSet = CharacterSet(charactersIn: ",，、和与以及还有")
        let parts = text.components(separatedBy: separatorSet)
        for part in parts where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let parsed = parseFoodNameAndWeight(part) {
                items.append(parsed)
            }
        }
        return upgradeParsedItems(items, originalText: text, context: context)
    }

    static func upgradeParsedItems(_ items: [(name: String, weight: Double, portion: String)], originalText: String, context: ModelContext?) -> [(name: String, weight: Double, portion: String)] {
        guard let context = context else { return items }
        return items.map { item in
            let upgraded = upgradeFoodNameIfNeeded(item.name, originalText: originalText, context: context)
            return (upgraded, item.weight, item.portion)
        }
    }

    /// 从文本提取金额数字（如 35 / 12.5 / 10,000 / 1,234.56）。
    /// 支持英文逗号、中文逗号作为千分位；优先匹配带金额单位（元/块/￥/¥）的数字；
    /// 都没有单位时取最后一个数字（金额常在句末，如「记一笔星巴克35」）。
    private func extractAmount(_ text: String) -> Double? {
        // 千分位可选，小数点可选；逗号用 [,\，] 兼容中英文输入法
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:[,\，]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)"#) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        // 优先带金额单位的数字
        for m in matches {
            let r = m.range(at: 1)
            let raw = ns.substring(with: r)
            let clean = raw.replacingOccurrences(of: #"[,\，]"#, with: "", options: .regularExpression)
            let afterStart = min(r.location + r.length, ns.length)
            let after = ns.substring(from: afterStart)
            if after.hasPrefix("元") || after.hasPrefix("块") || after.hasPrefix("￥") || after.hasPrefix("¥") {
                return Double(clean)
            }
        }
        // 否则取最后一个数字（句末金额）
        if let last = matches.last {
            let raw = ns.substring(with: last.range(at: 1))
            let clean = raw.replacingOccurrences(of: #"[,\，]"#, with: "", options: .regularExpression)
            return Double(clean)
        }
        return nil
    }

    /// 中文时段词 → 目标时分（用于 todo 解析）。
    private static let timeOfDayKeywords: [String: (hour: Int, minute: Int)] = [
        "凌晨": (6,0), "清晨": (6,0), "清早": (6,0),
        "早上": (8,0), "早晨": (8,0), "上午": (8,0),
        "中午": (12,0), "午间": (12,0), "正午": (12,0), "晌午": (12,0), "午饭": (12,0),
        "下午": (14,0), "午后": (14,0),
        "傍晚": (18,0), "黄昏": (18,0),
        "晚上": (20,0), "晚间": (20,0), "夜里": (20,0), "夜晚": (20,0), "今晚": (20,0),
        "深夜": (23,0), "半夜": (23,0), "午夜": (23,0),
        "拂晓": (6,0), "黎明": (6,0), "天亮": (6,0),
        "大早": (8,0), "一大早": (8,0), "大清早": (8,0),
    ]
    private static let timeOfDayPattern: String = {
        ChatView.timeOfDayKeywords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
    }()

    /// 解析文本中的相对时间（如「2分钟后」「1小时后」「半小时后」），基于当前时间返回 Date。
    /// 只支持以当前时刻为基准的分钟/小时偏移，云端常把这类相对时间解析错，用本地兜底更可靠。
    private func parseRelativeTime(from text: String) -> Date? {
        let lower = text.lowercased()
        let cal = Calendar.current
        let now = Date()

        func extractNumber(_ match: NSTextCheckingResult, at idx: Int, in string: String) -> Int? {
            let range = match.range(at: idx)
            guard range.location != NSNotFound else { return nil }
            let s = (string as NSString).substring(with: range)
            return ChatView.parseChineseNumber(s).map(Int.init)
        }

        // 一刻钟 / 半小时
        if let regex = try? NSRegularExpression(pattern: "一刻钟(后|以后)?"),
           regex.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)) != nil {
            return cal.date(byAdding: .minute, value: 15, to: now)
        }
        if let regex = try? NSRegularExpression(pattern: "半小时(后|以后)?"),
           regex.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)) != nil {
            return cal.date(byAdding: .minute, value: 30, to: now)
        }

        // 分钟
        if let regex = try? NSRegularExpression(pattern: "([\\d一二两三四五六七八九十]+)\\s*分钟(后|以后)"),
           let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)),
           let n = extractNumber(match, at: 1, in: lower) {
            return cal.date(byAdding: .minute, value: n, to: now)
        }

        // 小时
        if let regex = try? NSRegularExpression(pattern: "([\\d一二两三四五六七八九十]+)\\s*小时(后|以后)"),
           let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)),
           let n = extractNumber(match, at: 1, in: lower) {
            return cal.date(byAdding: .hour, value: n, to: now)
        }

        return nil
    }

    /// 解析文本中的具体时刻（如「9点」「21:30」「下午3点半」「晚上9点」），返回目标时分。
    /// 优先级高于时段词默认值（如「晚上9点」应解析为 21:00，而非落入时段词默认的 20:00）。
    private func parseClockTime(from text: String) -> (hour: Int, minute: Int)? {
        var hour: Int?
        var minute = 0

        // HH:MM
        if let regex = try? NSRegularExpression(pattern: "(\\d{1,2}):(\\d{2})"),
           let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            let h = Int((text as NSString).substring(with: m.range(at: 1)))
            let mi = Int((text as NSString).substring(with: m.range(at: 2)))
            if let h = h, let mi = mi, h <= 23, mi <= 59 { hour = h; minute = mi }
        }

        // X点X分 / X点 / X点半（支持 8点 / 八点 / 十二点）
        if hour == nil,
           let regex = try? NSRegularExpression(pattern: "([\\d一二两三四五六七八九十]+)\\s*点\\s*(半|([\\d一二两三四五六七八九十]+)\\s*分)?"),
           let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            let hStr = (text as NSString).substring(with: m.range(at: 1))
            if let h = ChatView.parseChineseNumber(hStr).map(Int.init), h <= 23 {
                hour = h
                let g2 = m.range(at: 2)
                if g2.location != NSNotFound {
                    let ms = (text as NSString).substring(with: g2)
                    if ms.contains("半") { minute = 30 }
                    else {
                        // 去掉「分」字后解析分钟（支持中文数字，如「八分」）
                        let minStr = ms.replacingOccurrences(of: "分", with: "")
                                   .trimmingCharacters(in: .whitespaces)
                        if let mi = ChatView.parseChineseNumber(minStr).map(Int.init), mi <= 59 { minute = mi }
                    }
                }
            }
        }

        guard var h = hour else { return nil }
        // 12 小时制偏移：下午/晚上/夜里等前缀 + 小时 ≤ 11 → +12
        let lower = text.lowercased()
        let pmMarkers = ["下午", "午后", "傍晚", "晚上", "晚间", "夜里", "夜晚", "今晚", "深夜", "半夜", "午夜"]
        if h <= 11, pmMarkers.contains(where: { lower.contains($0) }) {
            h += 12
        }
        return (h, minute)
    }

    /// 解析中文时段词（早上、中午、晚上等），返回目标时分。
    private func parseTimeOfDay(from text: String) -> (hour: Int, minute: Int)? {
        if let regex = try? NSRegularExpression(pattern: ChatView.timeOfDayPattern),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           let range = Range(match.range, in: text) {
            let matched = String(text[range])
            return ChatView.timeOfDayKeywords[matched]
        }
        return nil
    }

    /// 解析中文星期表达（下周六、这周六、礼拜天、星期一等），返回目标日期 00:00。
    /// 修饰词含义：
    ///   - 「下周 X / 下星期 X / 下礼拜 X」：总是本周 X 之后的下一个 X；
    ///   - 「这/本/今周 X」或裸「周 X / 星期 X / 礼拜 X」：指即将到来的最近一个 X，若今天就是 X 则指今天。
    private func parseWeekday(from text: String) -> Date? {
        let lower = text.lowercased()
        let cal = Calendar.current
        let now = Date()
        let today = cal.component(.weekday, from: now) // 1=周日...7=周六

        let weekdayMap: [String: Int] = [
            "日": 1, "天": 1, "一": 2, "二": 3, "三": 4,
            "四": 5, "五": 6, "六": 7
        ]
        let digitMap: [String: Int] = [
            "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7
        ]
        func targetWeekday(_ c: Character) -> Int? {
            weekdayMap[String(c)] ?? digitMap[String(c)]
        }

        // 按优先级：下 X > 这/本/今 X > 裸 X
        let patterns = [
            ("下(周|星期|礼拜)([一二三四五六七日天1234567])", true),   // 总是下一个
            ("(这|本|今)(周|星期|礼拜)([一二三四五六七日天1234567])", false), // 最近一个
            ("(周|星期|礼拜)([一二三四五六七日天1234567])", false)          // 最近一个
        ]
        for (pat, forceNext) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat),
                  let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)) else { continue }
            let groupIdx = match.numberOfRanges - 1
            let groupStr = (lower as NSString).substring(with: match.range(at: groupIdx))
            guard let c = groupStr.first, let target = targetWeekday(c) else { continue }
            var offset = (target - today + 7) % 7
            if forceNext, offset == 0 { offset = 7 }
            return cal.date(byAdding: .day, value: offset, to: now).flatMap {
                cal.date(bySettingHour: 0, minute: 0, second: 0, of: $0)
            }
        }
        return nil
    }

    /// 把中文/阿拉伯数字（含「半」，如「一半」「两半」）转成 Double；阿拉伯数字直接返回。
    static func parseChineseNumber(_ string: String) -> Double? {
        if string.isEmpty { return nil }
        if string == "半" { return 0.5 }
        if let n = Double(string) { return n }
        let digits: [Character: Double] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let units: [Character: Double] = [
            "十": 10, "百": 100, "千": 1000
        ]
        var result = 0.0
        var current = 0.0
        for c in string {
            if c == "半" {
                // 「半」表示 0.5：叠加到当前累计值（如「一半」=1.5、「两半」=2.5）；
                // 若前面没有整数（即单独半已在上文处理），这里保底记 0.5。
                current += 0.5
            } else if let d = digits[c] {
                current = current * 10 + d
            } else if let u = units[c] {
                if current == 0 { current = 1 }
                current *= u
                result += current
                current = 0
            } else {
                // 遇到无法识别的字符直接放弃（如混入其它字）
                return nil
            }
        }
        result += current
        return result > 0 ? result : nil
    }

    /// 把计数（可能含 0.5）格式化成展示串，整数不显示小数。
    private static func formatCount(_ count: Double) -> String {
        return count.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", count)
            : String(format: "%.1f", count)
    }

    /// 从文本提取重复规则（覆盖全部周期词，值与 Reminder.repeatRule / repeatOptions 一致）。
    /// 优先级高→低，命中即返回；与日期提取相互独立，两者可叠加。
    static func parseRepeatRule(from text: String) -> String? {
        let t = text
        // 每年（带具体月日也归 yearly）
        if t.contains("每年") || t.contains("每一年") || t.contains("年年") {
            return "yearly"
        }
        if t.contains("每半年") || t.contains("每六月") || t.contains("半年") {
            return "semiannual"
        }
        if t.contains("每季度") || t.contains("每三月") || t.contains("一季度") || t.contains("三个月") {
            return "quarterly"
        }
        if t.contains("每两月") || t.contains("隔月") || t.contains("每2个月") || t.contains("每二个月") {
            return "bimonthly"
        }
        if t.contains("每月") || t.contains("每个月") || t.contains("每一月") {
            return "monthly"
        }
        if t.contains("每两周") || t.contains("隔周") || t.contains("每2周") || t.contains("每二周") {
            return "biweekly"
        }
        if t.contains("每周") || t.contains("每星期") || t.contains("每个星期") {
            return "weekly"
        }
        if t.contains("每天") || t.contains("每日") || t.contains("天天") || t.contains("每一天") {
            return "daily"
        }
        return nil
    }

    /// 从「帮我增加一个7月30日去体检的提醒」这类文本里解析标题和日期。
    private func parseTodoCreate(_ text: String) -> (title: String, due: Date, repeatRule: String?)? {
        let cal = Calendar.current
        let now = Date()
        // 周期词提取独立于日期解析，提前计算以便下方「无具体日期的周期待办」使用
        let repeatRule = ChatView.parseRepeatRule(from: text)
        var due = now
        var dateFound = false
        var hasSpecificTime = false   // 相对时间/具体钟点/时段词都算「已明确具体时刻」，防止被默认 8:00 覆盖
        let lower = text.lowercased()

        // 优先处理相对时间（2分钟后、1小时后、半小时后），云端常把这类词解析错。
        if let relativeDue = parseRelativeTime(from: text) {
            due = relativeDue
            dateFound = true
            hasSpecificTime = true
        }

        // 匹配「7月30日」「7月30号」
        let datePattern = "(\\d{1,2})月(\\d{1,2})[日号]"
        if let regex = try? NSRegularExpression(pattern: datePattern),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            let monthStr = (text as NSString).substring(with: match.range(at: 1))
            let dayStr = (text as NSString).substring(with: match.range(at: 2))
            if let month = Int(monthStr), let day = Int(dayStr) {
                var comps = DateComponents()
                comps.year = cal.component(.year, from: now)
                comps.month = month
                comps.day = day
                if let d = cal.date(from: comps) {
                    due = d
                    dateFound = true
                }
            }
        }

        if !dateFound {
            if lower.contains("后天") {
                due = cal.date(byAdding: .day, value: 2, to: now) ?? now
                dateFound = true
            } else if lower.contains("明天") || lower.contains("明日") || lower.contains("明早") {
                due = cal.date(byAdding: .day, value: 1, to: now) ?? now
                dateFound = true
            } else if lower.contains("今天") || lower.contains("今早") || lower.contains("今晚") {
                // 今天（含「今早/今晚」等组合词），具体时刻交由下方 clock/tod 解析
                dateFound = true
            } else if let weekdayDate = parseWeekday(from: text) {
                due = weekdayDate
                dateFound = true
            }
        }

        // 设置时间：具体时刻 > 时段词 > 默认规则（仅当用户完全没说明日期、也没说明时间时）
        let clock = parseClockTime(from: text)
        let tod = parseTimeOfDay(from: text)
        if let clock {
            due = cal.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: due) ?? due
            hasSpecificTime = true
        } else if let tod {
            due = cal.date(bySettingHour: tod.hour, minute: tod.minute, second: 0, of: due) ?? due
            hasSpecificTime = true
        } else if !dateFound {
            if repeatRule != nil {
                // 识别到周期词但文本无具体日期（如「每天喝水」「每周开会」）：due 取今天此刻，
                // 而非默认的 1 小时后，更符合「每天/每周」从今天开始的直觉；首次完成后下一条按周期顺延。
                due = now
            } else {
                // 既没日期也没时间：默认 1 小时后提醒
                due = cal.date(byAdding: .hour, value: 1, to: now) ?? now
            }
        } else if !hasSpecificTime {
            // 有日期但用户没明确具体时刻（如「7月30日提醒我体检」）：默认当天 8:00，避免变成 00:00 的尴尬提醒
            due = cal.date(bySettingHour: 8, minute: 0, second: 0, of: due) ?? due
        }

        // 提取重复规则已在函数开头完成（repeatRule 变量），与日期解析相互独立，可叠加：
        // 如「每年9月1号」→ repeatRule=yearly + due=9月1日。

        // 提取标题：先移除前缀动词，再移除日期、时段词和「提醒/待办」后缀
        var title = text
        // 去掉命令动词前缀（记/记录/添加/增加/创建/新建/设置/录入/保存/帮我/给我…），
        // 与饮食/账单/云端共用 commandVerbPrefixes，避免「给我记个买菜提醒」残留成「给我记个买菜提醒」。
        title = ChatView.stripCommandVerbPrefix(title)
        title = title.replacingOccurrences(of: datePattern, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "今天|明天|后天|明日|今早|今晚|明早", with: "", options: .regularExpression)
        // 移除星期词（下周六/这周六/礼拜天/星期一等），避免标题残留
        title = title.replacingOccurrences(of: "(这|本|今|下)?(周|星期|礼拜)([一二三四五六七日天])", with: "", options: .regularExpression)
        // 移除相对时间表达，避免标题里保留「2分钟后」「1小时后」等词
        title = title.replacingOccurrences(of: "([\\d一二两三四五六七八九十]+)\\s*(?:分钟|小时|分|时)(后|以后)", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "半小时(后|以后)?|一刻钟(后|以后)?", with: "", options: .regularExpression)
        // 移除时段词（中午/晚上等），避免标题里保留「中午运动」
        title = title.replacingOccurrences(of: ChatView.timeOfDayPattern, with: "", options: .regularExpression)
        // 移除具体时刻（9点 / 21:30 / 下午3点半），避免标题残留「9点运动」
        title = title.replacingOccurrences(of: "(\\d{1,2}):(\\d{2})", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "([\\d一二两三四五六七八九十]+)\\s*点\\s*(半|([\\d一二两三四五六七八九十]+)\\s*分)?", with: "", options: .regularExpression)
        // 先移除「提醒我」，再移除后缀「提醒/待办/任务/事项」，避免标题残留「我」
        title = title.replacingOccurrences(of: "提醒我", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "的?(提醒|待办|任务|事项)", with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "的"))

        if title.isEmpty { return nil }
        return (title, due, repeatRule)
    }

    /// 判断文本是否是记录操作指令（如「记一下」「帮我记」「添加」「删除」「改到」等）。
    /// 这类消息会污染后续确认/闲聊的上下文，导致模型把"好的好的"理解为"再执行一次"。
    private static func isRecordOperationMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        let opVerbs = [
            "记一下", "帮我记", "给我记", "记个", "记一笔", "记下来",
            "帮我添加", "给我添加", "添加", "增加", "创建", "新建", "保存", "录入",
            "删掉", "删除", "删了", "取消", "不要了", "去掉", "移除", "废除",
            "完成", "搞定了", "做完了", "标记完成",
            "改", "改成", "改到", "改一下", "改为", "修改", "更新", "调整", "提前", "延后"
        ]
        return opVerbs.contains { lower.contains($0) }
    }

    /// 判断原文是否有明确创建/记录意图（"记一下""帮我记""添加""创建"）。
    /// 兜底分支只有命中此意图，才允许走 parseText 保存记录；否则强制闲聊兜底。
    private static func hasExplicitCreateIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let createWords = ["记一下", "记一笔", "记个", "记下来", "帮我记", "给我记", "添加", "增加", "创建", "新建", "保存", "录入", "提醒我", "提醒"]
        return createWords.contains { lower.contains($0) }
    }

    /// 识别结果中是否包含"编辑/删除/完成"类动作（而非纯新建）。
    /// 这类动作 processRecognition 不处理，需走原有文本回复路径。
    private static func resultHasEditAction(_ r: RecognitionResult) -> Bool {
        let editActions = ["update", "delete", "complete", "done"]
        let isEdit = { (a: String?) -> Bool in editActions.contains((a ?? "").lowercased()) }
        return r.billList.contains { isEdit($0.action) }
            || r.todoList.contains { isEdit($0.action) }
            || r.foodList.contains { isEdit($0.action) }
    }

    /// 把最近几条聊天记录整理成云端可理解的上下文，用于识别"这个提醒""改成"等指代。
    /// 过滤掉：
    /// - AI 的确认消息（开场白取自 chatConfirmOpeners 池），避免模型把前一笔记录当成模板重复套用；
    /// - 用户的记录操作指令，避免模型把后续"好的好的"当成重复执行。
    private func buildRecentMessages(limit: Int) -> [[String: String]] {
        let recent = orderedMessages.suffix(limit).filter { msg in
            // 协议串消息（发图 / 识别结果卡片）对模型无意义，且 JSON 很长，纯浪费 token
            if msg.text.hasPrefix(USER_IMAGE_PREFIX) || msg.text.hasPrefix(RECOGNITION_RESULT_PREFIX) { return false }
            if msg.role == .ai, chatConfirmOpeners.contains(where: { msg.text.hasPrefix($0) }) { return false }
            if msg.role == .user, ChatView.isRecordOperationMessage(msg.text) { return false }
            return true
        }
        return recent.map { ["role": $0.role == .user ? "user" : "ai", "text": $0.text] }
    }

    private func send() {
        // 录音态：先停录。没说话(仍是占位文案)则不发；说了话则用当前转写直接发送。
        if recognizer.isRecording {
            #if DEBUG
            print("[ChatView] send while recording, stopping recognizer first")
            #endif
            let snapshot = input
            recognizer.stop()
            if snapshot == voicePlaceholder {
                input = "" // 没开口，仅清占位，不发送
                return
            }
            input = snapshot // 用已转写文案继续发送
        }
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        input = ""
        recognizer.transcript = ""  // 清空识别缓冲，防止旧文字在后续录音或 view 重建时回灌
        recognizer.errorMessage = nil  // 发送成功后清理错误提示（如取消任务误报的 No speech detected）
        let userMessage = ChatMessage(role: .user, text: t)
        context.insert(userMessage)
        try? context.save()
        // @Query 自动响应式刷新
        UsageAnalytics.log("chat_send", meta: ["len": t.count])
        pendingQueue.append(userMessage)
        processNext()
    }

    private func processNext() {
        guard !isParsing, !pendingQueue.isEmpty else { return }
        isParsing = true
        chatBubbleInserted = false
        let userMessage = pendingQueue.removeFirst()
        let t = userMessage.text
        // 登录账户 userId（aia.userId）；未登录为空串 → 云端按"userId 缺失"回落普通 chat。
        let agentUserId = UserDefaults.standard.string(forKey: "aia.userId") ?? ""

        Task { @MainActor in
            do {
                let recentMessages = buildRecentMessages(limit: 5)
                let responseText: String
                // —— 本地内容安全闸：命中违规/越界词直接本地拒答，根本不调云端（省成本 + 零风险） ——
                if let blocked = ChatView.replyForBlockedIntent(t) {
                    responseText = blocked
                }
                // —— 本地优先：所有结构化指令（记账/记饮食/待办/饮水/食物查询）先走本地，零云端调用 ——
                else if let local = await resolveLocally(t, recentMessages: recentMessages) {
                    responseText = local
                } else {
                    // —— 仅本地兜不住才走云端 LLM ——
                    let dataContext = buildContext()
                    let agentReply = globalConfig.agentEnabled
                        ? try? await RecognizeService.agentChat(text: t, context: dataContext, userId: agentUserId)
                        : try? await RecognizeService.chat(text: t, context: dataContext)
                    if let r = agentReply, !r.isEmpty {
                        responseText = r
                        if UserDefaults.standard.bool(forKey: "aia.isLoggedIn") {
                            // Agent 可能在云端做了删除/修改/新建等动作（chat agent 是写权限的），
                            // 这些变更只会落在云端，本地 SwiftData 不会自动同步——必须触发完整 sync
                            // （push + pull + cleanupSyncedTombstones）才能让本地看到云端的删除/修改。
                            // 否则会出现「小记说删了，但账单还在」的 UX 假象。
                            Task { @MainActor in
                                await CloudSyncManager.shared.sync(context: context)
                            }
                        }
                    } else {
                        // 云端也失败：本地 resolveLocally 已处理过 todo/bill/water；
                        // 此时只处理云端依赖的路径：createFoodFromCloud / parseText / localReply
                        if isFoodLike(t) {
                            responseText = await createFoodFromCloud(text: t, recentMessages: recentMessages)
                        } else {
                            let hasCreateIntent = ChatView.hasExplicitCreateIntent(t)
                            if hasCreateIntent {
                                let (result, _) = try await RecognizeService.parseText(t, recentMessages: recentMessages)
                                if ChatView.resultHasEditAction(result) {
                                    // 编辑/删除/完成类动作：processRecognition 不处理，沿用原有文本回复，
                                    // 并触发完整云端同步（云端 agent 可能已对记录做了写操作）。
                                    let summary = saveFromResult(result, originalText: t)
                                    if summary.isEmpty {
                                        responseText = await localReply(for: t)
                                    } else {
                                        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
                                        responseText = "\(opener)：\n" + summary.joined(separator: "\n")
                                    }
                                    if UserDefaults.standard.bool(forKey: "aia.isLoggedIn") {
                                        Task { @MainActor in
                                            await CloudSyncManager.shared.sync(context: context)
                                        }
                                    }
                                } else {
                                    // 纯"新建识别"：统一走 processRecognition，按「来源=文字 × 类别」二维设置
                                    // （自动保存 / 待确认 / 丢弃）分流；命中则插入一条识别结果气泡
                                    // （已保存/待确认三态卡片），由气泡承担本次回复，不再插入纯文本。
                                    let outcome = await RecognitionSaver.processRecognition(
                                        result: result, rawText: t, image: nil,
                                        context: context, source: .cloud, entryOrigin: "text")
                                    switch outcome {
                                    case .inserted:
                                        chatBubbleInserted = true
                                        responseText = ""
                                    case .nothing:
                                        responseText = await localReply(for: t)
                                    }
                                }
                            } else {
                                responseText = await localReply(for: t)
                            }
                        }
                    }
                }
                if !chatBubbleInserted {
                    let aiMessage = ChatMessage(role: .ai, text: responseText, createdAt: userMessage.createdAt.addingTimeInterval(0.1))
                    context.insert(aiMessage)
                    try? context.save()
                }
            } catch {
                if !chatBubbleInserted {
                    let aiMessage = ChatMessage(role: .ai, text: await localReply(for: t), createdAt: userMessage.createdAt.addingTimeInterval(0.1))
                    context.insert(aiMessage)
                    try? context.save()
                }
            }
            isParsing = false
            processNext()
        }
    }


    // MARK: - 本地优先意图解析

    /// 本地优先意图解析：纯本地（零云端调用），快速处理结构化指令。
    /// 返回非空表示本地已处理完成；返回 nil 表示需走云端 LLM。
    /// 把解析好的「新建记录」载荷统一走 processRecognition 水槽（与图片同一条路），
    /// 插入识别卡片；若卡片含「已保存」项，在卡片之前插一句简短文字（自动保存类才加）。
    /// 返回 true 表示已插入卡片（调用方据此不再发纯文本回复）。
    private func routeRecognition(_ result: RecognitionResult, rawText: String) async -> Bool {
        let outcome = await RecognitionSaver.processRecognition(
            result: result, rawText: rawText, image: nil,
            context: context, source: .local, entryOrigin: "text")
        switch outcome {
        case .nothing:
            return false
        case .inserted:
            chatBubbleInserted = true
            try? context.save()
            return true
        }
    }

    private func resolveLocally(_ t: String, recentMessages: [[String: String]]) async -> String? {
        // 0. 端侧 LLM 意图分类（iOS 26+ 且可用时）：
        //    用设备端 ~3B 小模型做快速意图分类，比纯正则更鲁棒。
        //    端侧模型不可用时自动跳过，走下方正则链（与现有行为一致）。
        if #available(iOS 26, *), LocalLLMClassifier.isAvailable {
            if let llmIntent = await LocalLLMClassifier.classify(t) {
                switch llmIntent {
                case .chat, .unknown:
                    // 端侧模型判定为闲聊/无法分类 → 直接交给云端，跳过整个本地链
                    return nil
                case .bill:
                    if let bill = await createBillLocally(from: t) {
                        return bill
                    }
                case .food:
                    if let food = await createFoodLocally(from: t) {
                        return food
                    }
                case .todo:
                    if let todo = await createTodoLocally(from: t) {
                        return todo
                    }
                case .water:
                    if let water = createWaterIntake(from: t) {
                        return water
                    }
                case .foodQuery:
                    if let query = await handleFoodQuery(t) {
                        return query
                    }
                }
            }
        }

        // 0.5. 本地删除（针对"刚才/最近 + 删除" 类指令）：直接拿最近一条对应类型的本地记录删除。
        //     解决 Phase 1 引入的回归：本地刚创建但还没推送云端时，云端 agent 找不到记录会幻觉"已删除"。
        //     本地真删不会撒谎，且无网络往返、毫秒级。
        if let deleted = resolveDeleteLocally(t) {
            return deleted
        }

        // 1. 待办意图优先：含「提醒/待办/记得」等明确动词时直接本地建待办，
        //    避免「晚上提醒我吃饭」被食物分支误吞。
        if let localTodo = await createTodoLocally(from: t) {
            return localTodo
        }

        // 2. 本地能解析的明确账单意图（如「记一笔星巴克35」「付了美团28」）
        //    直接本地建，复用 MerchantMeta 分类，跳过 AI。
        if await createBillLocally(from: t) != nil {
            // 账单已统一为识别卡片（kHandledCard）；若该文本同时含食物意图，
            // 继续把饮食也插成卡片（本地命中直接建；未命中异步联网查营养后插卡片）。
            if hasRawFoodIntent(t) {
                if let localFood = await createFoodLocally(from: t) {
                    if localFood == kHandledCard { return kHandledCard }
                } else {
                    Task { @MainActor in
                        await routeFoodCloudThenCard(text: t)
                    }
                }
            }
            return kHandledCard
        }

        // 3. 饮水意图：含「喝+水/饮+水」+ 不含其他真实食物词时直接走饮水路径
        if let waterMsg = createWaterIntake(from: t) {
            return waterMsg
        }

        // 4. 等待重量回复：之前有食物待补充重量（如用户说了「吃了苹果」没给重量）
        // 注意：pendingWeightFood 不在分支开头清空，失败时保留以便用户重试
        if let pending = pendingWeightFood {
            let cancelWords = ["不吃了", "不要了", "算了", "不用了", "没吃", "取消"]
            if cancelWords.contains(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pendingWeightFood = nil
                return "好嘞，那就不记「\(pending.name)」啦～"
            }
            // 用户明确回复了重量 → 组合创建（复用暂存的日期/时刻，避免丢「昨天/下午3点」）
            if let (_, p) = ChatView.parseWeightOnly(t) {
                let saved = pending
                pendingWeightFood = nil
                return await createFoodWithWeight(name: saved.name, text: p, meal: saved.meal, date: saved.date, hasTime: saved.hasTime)
            }
            // 用户说了一个新食物 → 替代 pending，走正常食物分支
            if isFoodLike(t) {
                pendingWeightFood = nil
                if let localFood = await createFoodLocally(from: t) {
                    return localFood
                }
                // 本地也解析不了 → 交给云端 createFoodFromCloud
                return nil
            }
            // 什么都没解析到 → 保留 pending，让用户重试
            return "没明白你说的，你大概吃了多少\(pending.name)呀？（比如\"两个\"或\"200克\"）😊"
        }

        // 5. 食物意图：含「吃/喝/奶茶/咖啡/饭」等词，先尝试本地营养库估算
        if isFoodLike(t) {
            if let localFood = await createFoodLocally(from: t) {
                return localFood
            }
            if let pending = pendingWeightFood {
                // createFoodLocally 识别到食物但用户没给重量 → 追问
                return "你大概吃了多少\(pending.name)呀？😊"
            }
            // 本地未命中 → 交给云端 createFoodFromCloud
            return nil
        }

        // 6. 食物查询：用户只说食物名（如「苹果」「牛肉的热量」），不记录，只回复营养数据
        if let queryReply = await handleFoodQuery(t) {
            return queryReply
        }

        // >>> CHANGE-[2026-08-20 15:30:00]-[小记查询跳转按钮] 开始
        // 数据查询分支（账单/待办/饮食/健康/会员）：本地优先、秒回，命中即插入带跳转按钮的 AI 消息。
        // 与现有记账/待办逻辑并列，不命中 return nil 继续走下方元意图/云端兜底。
        if let result = resolveDataQuery(t) {
            insertAIMessage(text: result.text, actionRoute: result.route)
            // 关键：标记"已插入气泡"，防止返回的 kHandledCard 哨兵被 processNext 当普通文本再插一条 __CARD_INSERTED__ 乱码气泡。
            chatBubbleInserted = true
            return kHandledCard
        }
        // <<< CHANGE-[2026-08-20 15:30:00]-[小记查询跳转按钮] 结束

        // 7. 本地确能回答的元意图（问候/身份），不包含「今天花了多少」等可能需上下文的数据查询
        if let meta = replyForMetaIntent(t) {
            return meta
        }

        // 本地兜不住 → 交给云端 LLM
        return nil
    }

    // >>> CHANGE-[2026-08-20 15:30:00]-[小记查询跳转按钮] 开始
    // 原因：让小记在本地优先链里就能回答数据查询（账单/待办/饮食/健康/会员），并在 AI 气泡下方渲染平级跳转按钮。
    //       一致性铁律：所有汇总复用各页面现成口径（MonthlyReportView 月度算法、RecordsViews.active），
    //       且账单/饮食/待办取数一律带 !$0.syncDeleted（fetchLlmContextData 的 bills/foods 是全量、未过滤软删）。
    // 回退：删除本段 + 删除 resolveLocally 第6、7分支间的调用 + 删除 insertAIMessage + messageBubble 的按钮即可。

    /// 数据查询分支的返回结构：文案 + 可选跳转目标（nil 表示不渲染按钮）。
    private struct DataQueryResult {
        let text: String
        let route: HomeRoute?
    }

    /// 插入一条带跳转路由的 AI 文本消息（复用项目统一插入流程，不重复插）。
    private func insertAIMessage(text: String, actionRoute: HomeRoute?) {
        let msg = ChatMessage(role: .ai, text: text,
                              createdAt: Date().addingTimeInterval(0.1),
                              actionRouteRaw: actionRoute?.routeKey)
        context.insert(msg)
        try? context.save()
    }

    /// 小记数据查询：识别并回答账单/待办/饮食/健康/会员类问题，命中即本地秒回。
    /// 不命中 return nil，由调用方继续走云端兜底（不破坏现有记账/待办逻辑）。
    private func resolveDataQuery(_ t: String) -> DataQueryResult? {
        let lower = t.lowercased()
        let data = fetchLlmContextData()
        let cal = Calendar.current
        let now = Date()
        let f: (Double) -> String = { String(format: "%.0f", $0) }
        let dayLabel: (Date) -> String = { AppFormat.isoDate.string(from: $0) }

        // >>> CHANGE-[2026-08-20 16:00:00]-[小记查询扩充关键词] 开始
        // 原因：用户希望小记查询支持更多说法。仅扩充触发关键词，不改查询逻辑/文案。
        // 回退：删除各分支新增的关键词项即可。
        // —— 会员到期查询（当前空白分支，优先级最高以免被其他词误吞） ——
        if lower.contains("会员") || lower.contains("pro") || lower.contains("订阅") || lower.contains("到期") || lower.contains("过期") || lower.contains("还剩")
            || lower.contains("付费") || lower.contains("包年") || lower.contains("包月") || lower.contains("续费")
            || lower.contains("是不是会员") || lower.contains("是不是pro") || lower.contains("还有多久") || lower.contains("什么时候到期") || lower.contains("有效期") {
            let sub = SubscriptionManager.shared
            if sub.isSubscribed, let exp = sub.expiresAt {
                let days = cal.dateComponents([.day], from: now, to: exp).day ?? 0
                let expStr = AppFormat.isoDate.string(from: exp)
                return DataQueryResult(text: "你的会员将在 \(expStr) 到期，还剩 \(days) 天。", route: .settings)
            } else {
                return DataQueryResult(text: "你目前是免费版，未订阅会员。", route: .settings)
            }
        }

        // —— 饮食汇总（某天吃了多少热量） ——
        if lower.contains("吃了多少") || lower.contains("热量") || lower.contains("今天吃") || lower.contains("吃了什么")
            || lower.contains("吃了啥") || lower.contains("吃了多少卡") || lower.contains("摄入") || lower.contains("消耗") || lower.contains("卡路里") {
            let (foodDate, _) = RelativeDateParser.dateTimeOrToday(from: t)
            let start = cal.startOfDay(for: foodDate)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            let foods = data.foods.filter { !$0.syncDeleted && $0.date >= start && $0.date < end }
            if foods.isEmpty {
                return DataQueryResult(text: "\(dayLabel(foodDate)) 还没有记录饮食呢。", route: .diet)
            }
            let totalKcal = foods.reduce(0.0) { acc, item in
                let gram = item.weightGram ?? 100.0
                return acc + (item.calories * gram / 100.0)
            }
            let detail = foods.prefix(5).map { "· \($0.name) \(Int($0.weightGram ?? 100))g" }.joined(separator: "\n")
            let more = foods.count > 5 ? "\n…等共 \(foods.count) 条" : ""
            return DataQueryResult(text: "\(dayLabel(foodDate)) 共摄入约 \(f(totalKcal)) 千卡：\n\(detail)\(more)", route: .diet)
        }

        // —— 账单查询 ——
        if lower.contains("花") || lower.contains("钱") || lower.contains("账单") || lower.contains("支出") || lower.contains("消费") || lower.contains("账") || lower.contains("商户") || lower.contains("商家")
            || lower.contains("开销") || lower.contains("花费") || lower.contains("进账") || lower.contains("结余") || lower.contains("余额") || lower.contains("预算") || lower.contains("记账") {
            // 商户模糊匹配优先
            if ["商户", "商家"].contains(where: { lower.contains($0) }) {
                // 取商户关键词：如"美团"——简单取"商户"/"商家"后2~4字
                let kw = t.replacingOccurrences(of: "一共", with: "")
                    .replacingOccurrences(of: "花了多少", with: "")
                    .replacingOccurrences(of: "花了多少钱", with: "")
                    .replacingOccurrences(of: "商户", with: "")
                    .replacingOccurrences(of: "商家", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let matched = data.bills.filter { !$0.syncDeleted && $0.merchant.localizedCaseInsensitiveContains(kw) }
                if matched.isEmpty {
                    return DataQueryResult(text: "没找到和「\(kw)」相关的账单记录。", route: .bill)
                }
                let expense = matched.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
                let income = matched.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
                return DataQueryResult(text: "和「\(kw)」相关的账单：支出 ¥\(f(expense))，收入 ¥\(f(income))，共 \(matched.count) 笔。", route: .bill)
            }

            // 时间区间判定（复用 RelativeDateParser 单日 + 新增区间）
            var start: Date
            var end: Date
            var label: String
            if lower.contains("本月") || lower.contains("这个月") || lower.contains("当月") {
                let comps = cal.dateComponents([.year, .month], from: now)
                start = cal.date(from: comps)!
                end = cal.date(byAdding: .month, value: 1, to: start)!
                label = "本月"
            } else if let range = RelativeDateParser.parseRange(from: t) {
                start = range.start; end = range.end
                label = "这段时间内"
            } else if lower.contains("昨天") {
                start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
                end = cal.startOfDay(for: now)
                label = "昨天"
            } else if lower.contains("今天") {
                start = cal.startOfDay(for: now)
                end = cal.date(byAdding: .day, value: 1, to: start)!
                label = "今天"
            } else {
                // 默认最近 7 天（不默认本月，歧义时由兜底反问；此处保留最近7天为最常用）
                start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
                end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
                label = "最近 7 天"
            }
            let targetBills = data.bills.filter { !$0.syncDeleted && $0.time >= start && $0.time < end }
            if targetBills.isEmpty {
                return DataQueryResult(text: "\(label)还没有账单记录哦～", route: .bill)
            }
            let expense = targetBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
            let income = targetBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
            return DataQueryResult(text: "\(label)共支出 ¥\(f(expense))，收入 ¥\(f(income))，涉及 \(targetBills.count) 笔。", route: .bill)
        }

        // —— 待办列表（含"未安排"due==nil，与 RecordsViews.active 口径一致） ——
        if lower.contains("待办") || lower.contains("任务") || lower.contains("提醒") || lower.contains("事情") || lower.contains("todo") || lower.contains("安排")
            || lower.contains("要做的事") || lower.contains("要做") || lower.contains("没做完") || lower.contains("未完成") || lower.contains("还有什么没做")
            || lower.contains("有什么要办") || lower.contains("清单") || lower.contains("待完成") {
            let active = data.reminders.filter { !$0.syncDeleted && !$0.done }
            if active.isEmpty {
                return DataQueryResult(text: "你目前没有未完成的待办，可以放松一下。", route: .todo)
            }
            let sorted = active.sorted {
                let d0 = $0.due ?? .distantFuture
                let d1 = $1.due ?? .distantFuture
                return d0 < d1
            }
            let detail = sorted.prefix(8).map { "· \($0.title)" }.joined(separator: "\n")
            let more = sorted.count > 8 ? "\n…等共 \(sorted.count) 件" : ""
            return DataQueryResult(text: "你还有 \(sorted.count) 件待办没完成：\n\(detail)\(more)", route: .todo)
        }

        // —— 健康查询（步数/睡眠/体重，读已落库 ManualHealthStore） ——
        if lower.contains("步数") || lower.contains("健康") || lower.contains("运动") || lower.contains("走") || lower.contains("锻炼") || lower.contains("睡眠") || lower.contains("睡了") || lower.contains("体重") || lower.contains("多重")
            || lower.contains("走了多少") || lower.contains("走了几步") || lower.contains("今天走了")
            || lower.contains("睡了多久") || lower.contains("睡了几个小时") || lower.contains("几点睡的")
            || lower.contains("多少斤") || lower.contains("几斤") || lower.contains("体重多少") {
            Task { HealthManager.shared.refreshAll() }
            if lower.contains("睡眠") || lower.contains("睡了") {
                let (sleepDate, _) = RelativeDateParser.dateTimeOrToday(from: t)
                let hours = ManualHealthStore.shared.sleepHours(for: sleepDate)
                if hours <= 0 {
                    return DataQueryResult(text: "还没同步到相关睡眠数据，去健康页授权后会更准确～", route: .health)
                }
                let h = Int(hours)
                let m = Int((hours - Double(h)) * 60)
                return DataQueryResult(text: "\(dayLabel(sleepDate)) 睡眠约 \(h) 小时 \(m) 分钟。", route: .health)
            }
            if lower.contains("体重") || lower.contains("多重") {
                let (wDate, _) = RelativeDateParser.dateTimeOrToday(from: t)
                let w = ManualHealthStore.shared.healthKitValue("weight", for: wDate)
                if w > 0 {
                    return DataQueryResult(text: "\(dayLabel(wDate)) 体重约 \(f(w)) kg。", route: .health)
                }
                return DataQueryResult(text: "还没记录体重数据哦。", route: .health)
            }
            let steps = ManualHealthStore.shared.steps(for: now)
            return DataQueryResult(text: "今天步数约 \(steps) 步。", route: .health)
        }

        return nil
    }
    // <<< CHANGE-[2026-08-20 15:30:00]-[小记查询跳转按钮] 结束

    // MARK: - 本地删除助手（针对"刚才/最近" 类指令）

    /// 本地处理"刚才/最近 + 删除" 类指令：直接从本地 SwiftData 拿最近一条记录删除。
    /// - 触发条件：含明确删除动词（删了/删掉/删除/去掉/撤销/撤回/取消）+ 明确指代（刚才/刚刚/最后/最近/上一笔/上一条/那条/那个）。
    /// - 类型推断：用关键词猜；猜不到按 bill → food → reminder 顺序尝试。
    private func resolveDeleteLocally(_ t: String) -> String? {
        let lower = t.lowercased()
        let deleteVerbs = ["删了", "删掉", "删除", "去掉", "撤销", "撤回", "取消"]
        guard deleteVerbs.contains(where: { lower.contains($0) }) else { return nil }
        let references = ["刚才", "刚刚", "最后", "最近", "上一笔", "上一条", "那条", "那个"]
        guard references.contains(where: { lower.contains($0) }) else { return nil }

        // 类型推断
        let mentionsBill = ["账单", "那笔", "支出", "消费", "花了", "花掉", "付了", "买了"].contains { lower.contains($0) }
        let mentionsFood = ["那餐", "那顿", "饮食", "食物", "吃的", "喝的"].contains { lower.contains($0) }
        let mentionsTodo = ["待办", "提醒", "事项", "任务"].contains { lower.contains($0) }

        // 按类型优先级查找（无明确类型时按可能性顺序：账单 > 食物 > 待办）
        if mentionsBill {
            if let r = deleteMostRecentBill() { return r }
            if let r = deleteMostRecentFood() { return r }
            if let r = deleteMostRecentReminder() { return r }
        } else if mentionsFood {
            if let r = deleteMostRecentFood() { return r }
            if let r = deleteMostRecentBill() { return r }
            if let r = deleteMostRecentReminder() { return r }
        } else if mentionsTodo {
            if let r = deleteMostRecentReminder() { return r }
            if let r = deleteMostRecentBill() { return r }
            if let r = deleteMostRecentFood() { return r }
        } else {
            if let r = deleteMostRecentBill() { return r }
            if let r = deleteMostRecentFood() { return r }
            if let r = deleteMostRecentReminder() { return r }
        }
        return nil
    }

    /// 取最近一条 Bill 删除（按 time 倒序）。返回删除成功的回复文案；找不到返回 nil。
    private func deleteMostRecentBill() -> String? {
        var desc = FetchDescriptor<Bill>(
            predicate: #Predicate<Bill> { !$0.syncDeleted },
            sortBy: [SortDescriptor(\.time, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let bills = try? context.fetch(desc), let bill = bills.first else { return nil }
        let label = bill.merchant.isEmpty ? "账单" : "「\(bill.merchant)」账单"
        let amountStr = String(format: "%.2f", bill.amount)
        // 同步清掉该账单对应的 dedup key（用最近一条用户文本无法直接定位，用「商户+金额」反查的 key）
        WaterIntakeParser.clearDedupKey("\(bill.merchant)\(amountStr)", type: "bill")
        context.delete(bill)
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        return "\(opener)：🗑️ 已删除最近\(label)¥\(amountStr)"
    }

    /// 取最近一条 FoodEntry 删除（按 date 倒序，水也按此路径走——"喝水"也算"那餐"）。
    private func deleteMostRecentFood() -> String? {
        var desc = FetchDescriptor<FoodEntry>(
            predicate: #Predicate<FoodEntry> { !$0.syncDeleted },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let foods = try? context.fetch(desc), let food = foods.first else { return nil }
        let name = food.name.isEmpty ? "食物" : "「\(food.name)」"
        WaterIntakeParser.clearDedupKey(food.name, type: "food")
        WaterIntakeParser.clearDedupKey(food.name, type: "water")
        context.delete(food)
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        return "\(opener)：🗑️ 已删除最近一餐\(name)"
    }

    /// 取最近一条 Reminder 删除（按 syncUpdatedAt 倒序，因 Reminder 没有 createdAt）。
    private func deleteMostRecentReminder() -> String? {
        var desc = FetchDescriptor<Reminder>(
            predicate: #Predicate<Reminder> { !$0.syncDeleted },
            sortBy: [SortDescriptor(\.syncUpdatedAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let todos = try? context.fetch(desc), let todo = todos.first else { return nil }
        let title = todo.title.isEmpty ? "提醒" : "「\(todo.title)」"
        WaterIntakeParser.clearDedupKey(todo.title, type: "todo")
        ReminderNotificationManager.cancel(todo)
        context.delete(todo)
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        return "\(opener)：🗑️ 已删除最近一个待办\(title)"
    }

    // 按当前时间判断餐次（与 ResultConfirmView 规则一致）
    private static func defaultMeal(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<11:  return "早餐"
        case 11..<16: return "午餐"
        case 16..<22: return "晚餐"
        default:      return "加餐"
        }
    }

    // 优先用模型返回的 meal，其次从用户原文抽餐次关键词，最后按当前时间兜底
    private func resolveMeal(from modelMeal: String?, text: String) -> String {
        if let m = modelMeal, !m.isEmpty {
            return ChatView.normalizeMeal(m)
        }
        return WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
    }

    private static func normalizeMeal(_ meal: String) -> String {
        let m = meal.trimmingCharacters(in: .whitespaces)
        if m.contains("早") { return "早餐" }
        if m.contains("午") { return "午餐" }
        if m.contains("晚") || m.contains("夜") { return "晚餐" }
        return "加餐"
    }

    // MARK: - 平滑滚动到底部
    // >>> CHANGE-[2026-08-17 16:30:00]-[对话页进入淡入兜底] 开始
    // 调柔滚入 spring：response 0.32→0.42、dampingFraction 0.82→0.9，招呼气泡滚入更顺、
    // 不再"硬跳"，与整页 easeOut 淡入协同，统一两芯片进入观感。
    // 回退：恢复 .spring(response: 0.32, dampingFraction: 0.82)。
    private let scrollAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.9)
    // <<< CHANGE-[2026-08-17 16:30:00]-[对话页进入淡入兜底] 结束
    // 「钉到底」统一入口（微信式）：纯确定性 proxy.scrollTo（等价于 UIScrollView.setContentOffset）。
    // proxy 由调用方从 ScrollViewReader 闭包内传入（当前有效值，不依赖跨闭包失效的 @State 副本）。
    // 不声明式跟随（声明式在键盘安全区过渡态/气泡注入时重算 → 「跳一下」「被挡」）。
    private func scrollToLatest(proxy: ScrollViewProxy, immediate: Bool = true) {
        // >>> CHANGE-[2026-08-22 14:57:57]-[scrollToLatest 锚定底部占位锚点] 开始
        // 原因：原锚定末条气泡 item 底(anchor:.bottom)，吞掉底部 padding，末条被输入栏盖。
        // 修复：锚定「chat-bottom-anchor」占位锚点 = 真·内容底，padding 一并滚入可视区。
        // 回退：恢复 anchor 末条 pid 写法。
        guard !cachedDisplayed.isEmpty || !displayedMessages.isEmpty else { return }
        if immediate {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { proxy.scrollTo("chat-bottom-anchor", anchor: .bottom) }
        } else {
            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
        }
        // <<< CHANGE-[2026-08-22 14:57:57]-[scrollToLatest 锚定底部占位锚点] 结束
    }

    private func scrollToBottom(proxy: ScrollViewProxy, delay: TimeInterval = 0, anchor: UnitPoint = .bottom, animated: Bool = true) {
        // >>> CHANGE-[2026-08-22 14:57:57]-[scrollToBottom 锚定底部占位锚点] 开始
        // 原因：与 scrollToLatest 同因，原锚定末条 item 底吞底部 padding。
        // 修复：统一锚定「chat-bottom-anchor」真·内容底。
        // 回退：恢复 last.id 写法。
        let work = {
            guard !cachedDisplayed.isEmpty else { return }
            if animated {
                withAnimation(scrollAnimation) { proxy.scrollTo("chat-bottom-anchor", anchor: anchor) }
            } else {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { proxy.scrollTo("chat-bottom-anchor", anchor: anchor) }
            }
        }
        // <<< CHANGE-[2026-08-22 14:57:57]-[scrollToBottom 锚定底部占位锚点] 结束
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// 判断原文是否有明确删除意图（避免"周五提醒我交报表"被云端误识别为 delete）
    private static func hasExplicitDeleteIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let deleteWords = ["删除", "删掉", "删了", "取消", "去掉", "不要了", "移除", "废除"]
        return deleteWords.contains { lower.contains($0) }
    }

    /// 判断原文是否有明确修改/更新意图
    private static func hasExplicitUpdateIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let updateWords = ["改", "改成", "改到", "改一下", "改为", "修改", "更新", "调整", "提前", "延后"]
        return updateWords.contains { lower.contains($0) }
    }

    /// 判断原文是否有明确完成/标记完成意图
    private static func hasExplicitCompleteIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let completeWords = ["完成", "完成了", "搞定", "搞定了", "做完了", "标记完成", "已完成", "done"]
        return completeWords.contains { lower.contains($0) }
    }

    /// 用户文本中是否包含明确的重量/份量信息。
    /// 用于判断「吃了苹果」vs「吃了 200 克苹果」——前者没重量，需要追问。
    private static func hasWeightInfo(_ text: String) -> Bool {
        let pattern = #"(?:\d+|[一二两三四五六七八九十半]+)\s*(?:克|g|斤|公斤|毫克|kg|两|碗|杯|瓶|罐|个|份|片|块|串|根|盘|勺|粒|颗|只|包|盒|袋|条)"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// 从纯重量回复中提取份量（如「100克」「200g」「两个」「一碗」「半斤」），返回 (weight_g: Double, portionString)。
    /// 只处理简短重量型文本，不含食物名——用于用户回复小记的「你吃了多少」追问。
    /// 不复用 parseFoodNameAndWeight 是因为后者要求文本必须含食物名，单独「100克」会返回 nil。
    private static func parseWeightOnly(_ text: String) -> (Double, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 取消意图
        let cancelWords = ["不吃了", "不要了", "算了", "不用了", "没吃", "取消"]
        if cancelWords.contains(trimmed) { return nil }

        // 单位 → 克的映射（与 parseFoodNameAndWeight / NutritionLibrary 一致）
        let unitToG: [(String, Double)] = [
            ("克", 1), ("g", 1), ("千克", 1000), ("kg", 1000), ("公斤", 1000),
            ("两", 50), ("斤", 500),
            ("碗", 300), ("杯", 250), ("瓶", 500), ("罐", 330),
            ("个", 50), ("份", 200), ("块", 50), ("片", 30),
            ("串", 100), ("根", 100), ("盘", 300), ("勺", 15),
            ("粒", 5), ("颗", 5), ("只", 50), ("包", 100),
            ("盒", 200), ("袋", 100), ("条", 50)
        ]
        let cnNum: [String: Double] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                       "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
                                       "半": 0.5, "两": 2]

        let units = unitToG.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")

        // 阿拉伯数字：100克 / 200.5g / 1.5kg
        let arPattern = "(\\d+(?:\\.\\d+)?)\\s*(\(units))"
        if let regex = try? NSRegularExpression(pattern: arPattern) {
            let range = NSRange(location: 0, length: (trimmed as NSString).length)
            if let match = regex.firstMatch(in: trimmed, range: range) {
                let numStr = (trimmed as NSString).substring(with: match.range(at: 1))
                let unit = (trimmed as NSString).substring(with: match.range(at: 2))
                if let unitEntry = unitToG.first(where: { $0.0 == unit }),
                   let num = Double(numStr) {
                    let grams = num * unitEntry.1
                    if grams > 0 { return (grams, "\(numStr)\(unit)") }
                }
            }
        }

        // 中文数字：两个 / 一碗 / 半斤
        let cnPattern = "([一二两三四五六七八九十半]+)\\s*(\(units))"
        if let regex = try? NSRegularExpression(pattern: cnPattern) {
            let range = NSRange(location: 0, length: (trimmed as NSString).length)
            if let match = regex.firstMatch(in: trimmed, range: range) {
                let numStr = (trimmed as NSString).substring(with: match.range(at: 1))
                let unit = (trimmed as NSString).substring(with: match.range(at: 2))
                if let unitEntry = unitToG.first(where: { $0.0 == unit }),
                   let num = cnNum[numStr] {
                    let grams = num * unitEntry.1
                    if grams > 0 { return (grams, "\(numStr)\(unit)") }
                }
            }
        }

        return nil
    }

    // 保存云解析结果，返回用于 AI 回复的摘要数组。
    // allowedTypes 非 nil 时，只保存指定类型（如 food 分支强制只存食物，防止上下文把旧账单带出来）。
    @discardableResult
    private func saveFromResult(_ result: RecognitionResult, originalText: String, allowedTypes: [String]? = nil) -> [String] {
        let types = result.types ?? []
        var summary: [String] = []
        let shouldSaveType = { (type: String) -> Bool in
            allowedTypes == nil || allowedTypes!.contains(type)
        }

        if shouldSaveType("food"), types.contains("food") {
            for food in result.food.map({ [$0] }) ?? [] {
                guard let rawName = food.name, !rawName.isEmpty else { continue }
                // 先把云端可能退化成的泛称（如「粥」）升回具体长词（如「燕麦粥」）
                let upgradedName = ChatView.upgradeFoodNameIfNeeded(rawName, originalText: originalText, context: context)
                // 用本地营养库规范化名字：命中就用准确规范名，避免老用户本地脏数据污染
                let canonical = NutritionLibrary.canonicalFoodName(upgradedName, in: context)
                let localRef = NutritionLibrary.shared.match(canonical, in: context)
                let foodName = localRef?.name ?? canonical
                let meal = resolveMeal(from: food.meal, text: originalText)
                let portion = food.portion ?? "100克"
                // 重量优先级：① 份量带「克/g」直接取 ② 模糊单位（一碗）按本地表换算（碗=300）
                // ③ 云端给的 weightGram ④ 兜底 100。确保一碗=300，不被云端乱写 100 覆盖。
                let weight = RecognitionSaver.weightFromPortion(portion)
                    ?? RecognitionSaver.weightFromServingUnit(portion)
                    ?? food.weightGram
                    ?? 100
                let ratio = weight / 100.0
                // 营养值优先用本地权威库（内置表/本地库），云端只作兜底
                let baseCal = localRef?.kcal ?? food.calories ?? 0
                let basePro = localRef?.protein ?? food.protein ?? 0
                let baseCar = localRef?.carbs ?? food.carbs ?? 0
                let baseFat = localRef?.fat ?? food.fat ?? 0
                let baseFiber = food.fiber ?? 0
                let baseSugar = food.sugar ?? 0
                let baseSodium = food.sodium ?? 0
                let cal = baseCal * ratio
                let protein = basePro * ratio
                let carbs = baseCar * ratio
                let fat = baseFat * ratio
                let fiber = baseFiber * ratio
                let sugar = baseSugar * ratio
                let sodium = baseSodium * ratio

                let action = food.action?.lowercased() ?? "create"
                switch action {
                case "update":
                    guard ChatView.hasExplicitUpdateIntent(originalText) else { fallthrough }
                    if let target = findFoodTarget(targetTitle: food.targetTitle, fallbackToLatest: false) {
                        target.name = foodName
                        target.calories = cal
                        target.protein = protein
                        target.carbs = carbs
                        target.fat = fat
                        target.fiber = fiber
                        target.sugar = sugar
                        target.sodium = sodium
                        target.portion = portion
                        target.weightGram = weight
                        target.baseCalories = baseCal
                        target.baseProtein = basePro
                        target.baseCarbs = baseCar
                        target.baseFat = baseFat
                        target.baseFiber = baseFiber
                        target.baseSugar = baseSugar
                        target.baseSodium = baseSodium
                        if let m = food.meal, !m.isEmpty {
                            target.meal = ChatView.normalizeMeal(m)
                        }
                        target.syncUpdatedAt = Date()
                        FoodMetaStore.upsert(name: foodName, displayName: foodName,
                                             kcal: baseCal, protein: basePro, carbs: baseCar, fat: baseFat,
                                             fiber: baseFiber, sugar: baseSugar, sodium: baseSodium,
                                             source: "cloud", in: context)
                        summary.append("🔄 已更新「\(foodName)」：\(target.meal) \(Int(cal)) kcal\n  蛋白 \(String(format: "%.1f", target.protein))g · 碳水 \(String(format: "%.1f", target.carbs))g · 脂肪 \(String(format: "%.1f", target.fat))g · 纤维 \(String(format: "%.1f", target.fiber))g · 糖 \(String(format: "%.1f", target.sugar))g · 钠 \(String(format: "%.0f", target.sodium))mg\n\n结果仅供参考，如需修改可到\"饮食记录\"页面进行修改。")
                    } else {
                        fallthrough
                    }
                case "delete":
                    guard ChatView.hasExplicitDeleteIntent(originalText) else { fallthrough }
                    if let target = findFoodTarget(targetTitle: food.targetTitle, fallbackToLatest: false) {
                        // >>> CHANGE-[2026-08-17 11:21:00]-[临时对象失效崩溃] 开始
                        // 原因：findFoodTarget 返回的活对象在 SafeDelete 的延时闭包中可能已失效（被 @Query 重渲染释放引用）。
                        // 回退：改回 SafeDelete.food(target, in: context)
                        SafeDelete.foodByID(target.persistentModelID, in: context)
                        // <<< CHANGE-[2026-08-17 11:21:00]-[临时对象失效崩溃] 结束
                        summary.append("🗑 已删除「\(foodName)」")
                    } else {
                        summary.append("我没找到你想删除的饮食记录，能再描述一下吗？")
                    }
                default:
                    if baseCal <= 0 && basePro <= 0 && baseCar <= 0 && baseFat <= 0 {
                        summary.append("⚠️ 识别到「\(foodName)」但暂未查到营养数据，已跳过保存")
                        break
                    }
                    let entry = FoodEntry(name: foodName,
                                          calories: cal, protein: protein, carbs: carbs, fat: fat,
                                          fiber: fiber, sugar: sugar, sodium: sodium,
                                          portion: portion, meal: meal,
                                          weightGram: weight,
                                          baseCalories: baseCal,
                                          baseProtein: basePro,
                                          baseCarbs: baseCar,
                                          baseFat: baseFat,
                                          baseFiber: baseFiber,
                                          baseSugar: baseSugar,
                                          baseSodium: baseSodium,
                                          imageName: nil)
                    context.insert(entry)
                    context.insert(FoodSource(foodSyncId: entry.syncId, origin: "chat"))
                    FoodMetaStore.upsert(name: foodName, displayName: foodName,
                                         kcal: baseCal, protein: basePro, carbs: baseCar, fat: baseFat,
                                         fiber: baseFiber, sugar: baseSugar, sodium: baseSodium,
                                         source: "cloud", in: context)
                    summary.append("🍽 \(meal)「\(foodName)」\(Int(cal)) kcal\n  蛋白 \(String(format: "%.1f", protein))g · 碳水 \(String(format: "%.1f", carbs))g · 脂肪 \(String(format: "%.1f", fat))g · 纤维 \(String(format: "%.1f", fiber))g · 糖 \(String(format: "%.1f", sugar))g · 钠 \(String(format: "%.0f", sodium))mg\n\n结果仅供参考，如需修改可到\"饮食记录\"页面进行修改。")
                }
            }
        }

        if shouldSaveType("bill"), types.contains("bill") {
            for bill in result.billList {
                guard let merchant = bill.merchant, !merchant.isEmpty,
                      let amount = bill.amount, amount > 0 else { continue }
                let time = RecognitionSaver.billTime(from: bill.time, merchant: bill.merchant, category: bill.category, entryOrigin: "text")
                let category = bill.category ?? "其他"
                let income = RecognitionSaver.isIncomeCategory(category)

                let action = bill.action?.lowercased() ?? "create"
                switch action {
                case "update":
                    guard ChatView.hasExplicitUpdateIntent(originalText) else { fallthrough }
                    if let target = findBillTarget(targetTitle: bill.targetTitle, fallbackToLatest: false) {
                        target.merchant = merchant
                        target.amount = amount
                        target.category = category
                        target.isIncome = income
                        target.time = time
                        target.syncUpdatedAt = Date()
                        summary.append("🔄 已更新「\(merchant)」：\(String(format: "%.2f", amount))")
                    } else {
                        fallthrough
                    }
                case "delete":
                    guard ChatView.hasExplicitDeleteIntent(originalText) else { fallthrough }
                    if let target = findBillTarget(targetTitle: bill.targetTitle, fallbackToLatest: false) {
                        // >>> CHANGE-[2026-08-17 11:21:30]-[临时对象失效崩溃] 开始
                        // 原因：同 ChatView 饮食删除，避免延时闭包访问失效活对象。
                        // 回退：改回 SafeDelete.bill(target, in: context)
                        SafeDelete.billByID(target.persistentModelID, in: context)
                        // <<< CHANGE-[2026-08-17 11:21:30]-[临时对象失效崩溃] 结束
                        summary.append("🗑 已删除「\(merchant)」")
                    } else {
                        summary.append("我没找到你想删除的账单，能再描述一下吗？")
                    }
                default:
                    context.insert(Bill(merchant: merchant, amount: amount, category: category, time: time,
                                        isIncome: income, imageName: nil))
                    summary.append("🧾 \(income ? "收入" : "支出")「\(merchant)」\(String(format: "%.2f", amount))")
                }
            }
        }

        if shouldSaveType("todo"), types.contains("todo"), let todo = result.todo, let title = todo.title, !title.isEmpty {
            let cal = Calendar.current
            let now = Date()
            // 云端未返回日期时：默认 1 小时后提醒（而不是当前时刻）
            var due = RecognitionResult.date(from: todo.due) ?? (cal.date(byAdding: .hour, value: 1, to: now) ?? now)

            // 本地优先校正相对时间：云端常把「2分钟后」「1小时后」解析错，直接按文本算。
            if let relativeDue = parseRelativeTime(from: originalText) {
                due = relativeDue
            }

            // 兜底校正：如果云端把"明天/后天"等相对时间解析成过去日期，按文本关键词强制推到未来。
            if due < now {
                let lower = originalText.lowercased()
                let parsedComps = cal.dateComponents([.hour, .minute], from: due)
                let baseHour = parsedComps.hour ?? 9
                let baseMinute = parsedComps.minute ?? 0

                if lower.contains("后天") {
                    due = cal.date(byAdding: .day, value: 2, to: now) ?? now
                } else if lower.contains("明天") || lower.contains("明日") {
                    due = cal.date(byAdding: .day, value: 1, to: now) ?? now
                } else {
                    due = cal.date(byAdding: .day, value: 1, to: due) ?? now
                }
                due = cal.date(bySettingHour: baseHour, minute: baseMinute, second: 0, of: due) ?? due
            }

            let action = todo.action?.lowercased() ?? "create"

            switch action {
            case "update":
                guard ChatView.hasExplicitUpdateIntent(originalText) else { fallthrough }
                // 根据 targetTitle 找到目标
                if let target = findReminderTarget(targetTitle: todo.targetTitle, fallbackToLatest: false) {
                    target.due = due
                    target.title = title
                    target.remindTimes = []
                    target.remindAt = nil
                    DefaultReminderSettings.shared.apply(to: target)
                    target.syncUpdatedAt = Date()
                    ReminderNotificationManager.schedule(target)
                    summary.append("🔄 已把「\(target.title)」的提醒时间改成 \(formatShortDate(due))")
                } else {
                    // 找不到目标，退化为创建
                    fallthrough
                }
            case "delete":
                guard ChatView.hasExplicitDeleteIntent(originalText) else { fallthrough }
                if let target = findReminderTarget(targetTitle: todo.targetTitle, fallbackToLatest: false) {
                    // >>> CHANGE-[2026-08-17 11:22:00]-[临时对象失效崩溃] 开始
                    // 原因：同 ChatView 饮食/账单删除，避免延时闭包访问失效活对象。
                    // 回退：改回 SafeDelete.reminder(target, in: context)
                    SafeDelete.reminderByID(target.persistentModelID, in: context)
                    // <<< CHANGE-[2026-08-17 11:22:00]-[临时对象失效崩溃] 结束
                    summary.append("🗑 已删除「\(target.title)」")
                } else {
                    summary.append("我没找到你想删除的提醒，能再描述一下吗？")
                }
            case "complete", "done":
                guard ChatView.hasExplicitCompleteIntent(originalText) else { fallthrough }
                if let target = findReminderTarget(targetTitle: todo.targetTitle, fallbackToLatest: false) {
                    target.done = true
                    target.syncUpdatedAt = Date()
                    summary.append("✅ 已完成「\(target.title)」")
                } else {
                    summary.append("我没找到你想标记完成的提醒。")
                }
            default:
                let r = Reminder(title: title, due: due, imageName: nil)
                DefaultReminderSettings.shared.apply(to: r)
                context.insert(r)
                ReminderNotificationManager.schedule(r)
                summary.append("✅ 待办「\(title)」\n⏰ \(formatShortDateTime(due))")
            }
        }

        if !summary.isEmpty {
            try? context.save()
            // 聊天创建/修改记录后触发防抖同步
            CloudSyncManager.shared.syncAfterLocalChange(context: context)
        }
        return summary
    }

    /// 查找待办修改/删除/完成的目标。优先匹配 targetTitle，否则取最近活跃的未完成待办。
    private func findReminderTarget(targetTitle: String?, fallbackToLatest: Bool) -> Reminder? {
        let data = fetchLlmContextData()
        let active = data.reminders.filter { !$0.done && !$0.syncDeleted }
        if let target = targetTitle, !target.isEmpty {
            let lowered = target.lowercased()
            // 1) 完全包含匹配
            if let exact = active.first(where: { $0.title.lowercased().contains(lowered) || lowered.contains($0.title.lowercased()) }) {
                return exact
            }
            // 2) 简单分词匹配：取 target 中各关键词命中数最多的
            let keywords = lowered.components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count >= 2 }
            let scored = active.map { r -> (Reminder, Int) in
                let rLowered = r.title.lowercased()
                let score = keywords.reduce(0) { $0 + (rLowered.contains($1) ? 1 : 0) }
                return (r, score)
            }
            if let best = scored.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }) {
                return best.0
            }
        }
        if fallbackToLatest {
            return active.max { a, b in a.syncUpdatedAt < b.syncUpdatedAt }
        }
        return nil
    }

    /// 把日期格式化成「7月30日」的友好短格式
    private func formatShortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日"
        return fmt.string(from: date)
    }

    /// 把日期格式化成「7月30日 09:00」的友好短格式（含时间）。
    /// 用于创建/修改提醒后，在对话页把提醒时间展示给用户。
    private func formatShortDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    /// 仅显示时分（HH:mm），用于招呼气泡时间小字。
    private func formatTimeOnly(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    /// 查找饮食记录修改/删除的目标。优先匹配 targetTitle（食物名），否则取最近一条饮食记录。
    private func findFoodTarget(targetTitle: String?, fallbackToLatest: Bool) -> FoodEntry? {
        let data = fetchLlmContextData()
        let all = data.foods.filter { !$0.syncDeleted }
        if let target = targetTitle, !target.isEmpty {
            let lowered = target.lowercased()
            if let exact = all.first(where: { $0.name.lowercased().contains(lowered) || lowered.contains($0.name.lowercased()) }) {
                return exact
            }
            let keywords = lowered.components(separatedBy: .whitespacesAndNewlines).filter { $0.count >= 2 }
            let scored = all.map { f -> (FoodEntry, Int) in
                let fLowered = f.name.lowercased()
                return (f, keywords.reduce(0) { $0 + (fLowered.contains($1) ? 1 : 0) })
            }
            if let best = scored.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }) {
                return best.0
            }
        }
        if fallbackToLatest {
            return all.max { a, b in a.syncUpdatedAt < b.syncUpdatedAt }
        }
        return nil
    }

    /// 查找账单修改/删除的目标。优先匹配 targetTitle（商户名），否则取最近一条账单。
    private func findBillTarget(targetTitle: String?, fallbackToLatest: Bool) -> Bill? {
        let data = fetchLlmContextData()
        let all = data.bills.filter { !$0.syncDeleted }
        if let target = targetTitle, !target.isEmpty {
            let lowered = target.lowercased()
            if let exact = all.first(where: { $0.merchant.lowercased().contains(lowered) || lowered.contains($0.merchant.lowercased()) }) {
                return exact
            }
            let keywords = lowered.components(separatedBy: .whitespacesAndNewlines).filter { $0.count >= 2 }
            let scored = all.map { b -> (Bill, Int) in
                let bLowered = b.merchant.lowercased()
                return (b, keywords.reduce(0) { $0 + (bLowered.contains($1) ? 1 : 0) })
            }
            if let best = scored.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }) {
                return best.0
            }
        }
        if fallbackToLatest {
            return all.max { a, b in a.syncUpdatedAt < b.syncUpdatedAt }
        }
        return nil
    }

    // 把本地数据整理成 JSON 摘要，供 AI 聊天时作为上下文
    private func buildContext() -> [String: Any] {
        let data = fetchLlmContextData()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOf7DaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday)!
        let todayFoods = data.foods.filter { cal.isDateInToday($0.date) }
        let todayBills = data.bills.filter { cal.isDateInToday($0.time) }
        let yesterdayFoods = data.foods.filter { $0.date >= startOfYesterday && $0.date < startOfToday }
        let yesterdayBills = data.bills.filter { $0.time >= startOfYesterday && $0.time < startOfToday }
        let weekFoodEntries = data.foods.filter { $0.date >= startOf7DaysAgo }
        let weekBillEntries = data.bills.filter { $0.time >= startOf7DaysAgo }
        // 重要：传给云端 LLM 的所有日期必须带本地时区偏移（+HH:MM），否则默认 ISO8601 输出 UTC（Z），
        // 本地 11:45 会变成 03:45Z 被 LLM 误读为「凌晨 3 点」。
        let fmt = AppFormat.isoLocal
        let todayTodos = data.reminders.filter { r in
            if let due = r.due { return cal.isDateInToday(due) && !r.done } else { return false }
        }
        let yesterdayTodos = data.reminders.filter { r in
            if let due = r.due { return due >= startOfYesterday && due < startOfToday && !r.done } else { return false }
        }
        return [
            "today": buildContext_daySection(date: Date(), foods: todayFoods, bills: todayBills, todos: todayTodos, fmt: fmt),
            "yesterday": buildContext_daySection(date: startOfYesterday, foods: yesterdayFoods, bills: yesterdayBills, todos: yesterdayTodos, fmt: fmt),
            "last7Days": buildContext_weekSection(weekFoods: weekFoodEntries, weekBills: weekBillEntries, reminders: data.reminders, startOf7DaysAgo: startOf7DaysAgo, fmt: fmt),
            "health": buildContext_healthSection(healths: data.healths, fmt: fmt),
            "upcomingTodos": buildContext_upcomingTodosSection(reminders: data.reminders, fmt: fmt),
            "activeTodos": buildContext_activeTodosSection(reminders: data.reminders, fmt: fmt),
            // —— 最近记录列表（按时间倒序，含 id）—— agent 需要用 id 做 update 工具调用（upsert）。
            // 上限 10 条/类，既覆盖"刚才记的那条"又不让 context 过大。
            "recentFoods": data.foods.sorted { $0.date > $1.date }.prefix(10).map { buildContext_foodDict($0, fmt: fmt) },
            "recentBills": data.bills.sorted { $0.time > $1.time }.prefix(10).map { buildContext_billDict($0, fmt: fmt) },
            "recentReminders": data.reminders.sorted { ($0.due ?? .distantPast) > ($1.due ?? .distantPast) }.prefix(10).map { buildContext_todoDict($0, fmt: fmt) },
            "recentHealth": data.healths.sorted { $0.date > $1.date }.prefix(10).map { buildContext_healthDict($0, fmt: fmt) },
            "merchantRules": data.merchantMetas.sorted { $0.lastSeen > $1.lastSeen }.prefix(20).map { buildContext_merchantDict($0) },
            "recentRecognitions": data.recognitions.prefix(10).map { buildContext_recognitionDict($0, fmt: fmt) },
            // —— 饮水与周期规则（v10/v9 模型，buildContext 之前漏了导致 agent 第一句话看不到）——
            "recentWaters": data.waters.prefix(20).map { ["id": $0.syncId.uuidString, "amount": $0.amount, "date": fmt.string(from: $0.date)] },
            "recurringRules": data.recurringRules.map { ["id": $0.syncId.uuidString, "merchant": $0.merchant, "amount": $0.amount, "category": $0.category, "isIncome": $0.isIncome, "cycleRaw": $0.cycleRaw ?? "monthly", "dayOfMonth": $0.dayOfMonth, "note": $0.note] }
        ]
    }

    private func buildContext_daySection(date: Date, foods: [FoodEntry], bills: [Bill], todos: [Reminder], fmt: ISO8601DateFormatter) -> [String: Any] {
        // 明细只保留最近 15 条（覆盖绝大多数对话场景），聚合 totals 仍基于全量，不影响"今日总热量"等回答准确性。
        let recentFoods = foods.sorted { $0.date > $1.date }.prefix(15)
        let recentBills = bills.sorted { $0.time > $1.time }.prefix(15)
        return [
            "date": fmt.string(from: date),
            "foods": Array(recentFoods).map { buildContext_foodDict($0, fmt: fmt) },
            "totalCalories": foods.reduce(0) { $0 + $1.calories },
            "totalProtein": foods.reduce(0) { $0 + $1.protein },
            "totalCarbs": foods.reduce(0) { $0 + $1.carbs },
            "totalFat": foods.reduce(0) { $0 + $1.fat },
            "bills": Array(recentBills).map { buildContext_billDict($0, fmt: fmt) },
            "totalExpense": bills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount },
            "totalIncome": bills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount },
            "todos": todos.map { buildContext_todoDict($0, fmt: fmt) }
        ]
    }

    private func buildContext_weekSection(weekFoods: [FoodEntry], weekBills: [Bill], reminders: [Reminder], startOf7DaysAgo: Date, fmt: ISO8601DateFormatter) -> [String: Any] {
        // 一周内未完成待办通常很多，明细只保留最近 15 条（按 due 升序），避免 context 膨胀。
        let weekTodos = reminders.filter { r in
            guard let due = r.due else { return false }
            return due >= startOf7DaysAgo && !r.done
        }
        .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        .prefix(15)
        return [
            "dateRange": fmt.string(from: startOf7DaysAgo) + " to " + fmt.string(from: Date()),
            "totalCalories": weekFoods.reduce(0) { $0 + $1.calories },
            "totalProtein": weekFoods.reduce(0) { $0 + $1.protein },
            "totalCarbs": weekFoods.reduce(0) { $0 + $1.carbs },
            "totalFat": weekFoods.reduce(0) { $0 + $1.fat },
            "totalExpense": weekBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount },
            "totalIncome": weekBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount },
            "todos": Array(weekTodos).map { buildContext_todoDictWeekly($0, fmt: fmt) }
        ]
    }

    private func buildContext_healthSection(healths: [HealthMetric], fmt: ISO8601DateFormatter) -> [String: Any] {
        let latestMetrics: [String: [String: Any]] = Dictionary(grouping: healths, by: { $0.metric })
            .mapValues { records -> [String: Any] in
                let r = records.max(by: { $0.date < $1.date })!
                return ["value": r.value, "unit": r.unit, "date": fmt.string(from: r.date)]
            }
        return [
            "stepsToday": effectiveStepsToday,
            "activeEnergyToday": effectiveActiveEnergy,
            "latestMetrics": latestMetrics
        ]
    }

    private func buildContext_upcomingTodosSection(reminders: [Reminder], fmt: ISO8601DateFormatter) -> [[String: Any]] {
        let upcoming = reminders
            .filter { !$0.done && ($0.due ?? .distantPast) > Date() }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(5)
        return Array(upcoming).map { buildContext_todoDict($0, fmt: fmt) }
    }

    private func buildContext_activeTodosSection(reminders: [Reminder], fmt: ISO8601DateFormatter) -> [[String: Any]] {
        let active = reminders.filter { !$0.done }.prefix(10)
        return Array(active).map { buildContext_todoDictWeekly($0, fmt: fmt) }
    }

    private func buildContext_foodDict(_ f: FoodEntry, fmt: ISO8601DateFormatter) -> [String: Any] {
        [
            "id": f.syncId.uuidString,
            "name": f.name,
            "calories": f.calories,
            "protein": f.protein,
            "carbs": f.carbs,
            "fat": f.fat,
            "meal": f.meal,
            "portion": f.portion,
            "weightGram": f.weightGram ?? 0,
            "waterIntake": f.waterIntake,
            "date": fmt.string(from: f.date)
        ]
    }

    private func buildContext_billDict(_ b: Bill, fmt: ISO8601DateFormatter) -> [String: Any] {
        [
            "id": b.syncId.uuidString,
            "merchant": b.merchant,
            "amount": b.amount,
            "category": b.category,
            "isIncome": b.isIncome,
            "time": fmt.string(from: b.time),
            "note": b.note
        ]
    }

    private func buildContext_todoDict(_ r: Reminder, fmt: ISO8601DateFormatter) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.syncId.uuidString,
            "title": r.title,
            "priority": r.priority,
            "done": r.done
        ]
    if let due = r.due { d["due"] = fmt.string(from: due) }
    return d
  }

  private func buildContext_healthDict(_ h: HealthMetric, fmt: ISO8601DateFormatter) -> [String: Any] {
    [
      "id": h.syncId.uuidString,
      "metric": h.metric,
      "value": h.value,
      "unit": h.unit,
      "date": fmt.string(from: h.date),
    ]
  }

  private func buildContext_merchantDict(_ m: MerchantMeta) -> [String: Any] {
    [
      "id": m.syncId.uuidString,
      "merchant": m.merchant,
      "category": m.category,
      "isIncome": m.isIncome,
    ]
  }

  private func buildContext_recognitionDict(_ r: RecognitionRecord, fmt: ISO8601DateFormatter) -> [String: Any] {
    [
      "id": r.syncId.uuidString,
      "rawText": String(r.rawText.prefix(120)),
      "types": r.types,
      "recognizedAt": fmt.string(from: r.recognizedAt),
    ]
  }

    private func buildContext_todoDictWeekly(_ r: Reminder, fmt: ISO8601DateFormatter) -> [String: Any] {
        [
            "title": r.title,
            "due": fmt.string(from: r.due ?? Date()),
            "priority": r.priority,
            "repeatRule": r.repeatRule
        ]
    }

}

/// 微信式居中时间分隔行：仅在与上一条消息间隔较久 / 列表首条时插入。
/// 不是消息实体，不进 SwiftData，只是渲染期的视觉分隔（不响应点击、不可多选删除）。
private struct ChatTimeDivider: View {
    let date: Date

    var body: some View {
        Text(ChatTimeDivider.label(for: date))
            .font(AIATheme.Font.micro)
            .foregroundStyle(AIATheme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
            .accessibilityLabel("消息时间 \(ChatTimeDivider.label(for: date))")
    }

    /// 微信式分档文案。全部走 Calendar.current / 本地时区，不碰 ISO8601 序列化。
    static func label(for date: Date) -> String {
        let cal = Calendar.current
        let hm = AppFormat.hourMinute.string(from: date) // 复用现有 HH:mm
        if cal.isDateInToday(date) { return hm }
        if cal.isDateInYesterday(date) { return "昨天 \(hm)" }
        // 近 7 天内：显示星期
        if let days = cal.dateComponents([.day],
                                         from: cal.startOfDay(for: date),
                                         to: cal.startOfDay(for: .now)).day,
           days < 7 {
            let wd = Self.weekdayNames[cal.component(.weekday, from: date) - 1]
            return "\(wd) \(hm)"
        }
        // 跨年补年份
        if cal.component(.year, from: date) != cal.component(.year, from: .now) {
            return Self.crossYearFormatter.string(from: date)
        }
        return Self.normalFormatter.string(from: date)
    }

    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    private static let crossYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()
    private static let normalFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
