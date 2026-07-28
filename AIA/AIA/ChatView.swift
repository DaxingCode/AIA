// ChatView.swift
// ② 对话页 D话：按《UI完整页面流.html》屏幕 2 重做。
// 当前为 UI 壳：示例 AI 气泡 + 快捷意图 chips（跳转到各模块页）+ 输入栏（发送后追加用户气泡与占位回复）。
// 真 LLM 对话未接入（API Key 走云端代理的后续迭代）。
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 本地确认消息的统一开场白池；生成确认消息时随机取一个，避免每条都"记好啦"开头。
/// 同时被下方"过滤 AI 确认消息不进上下文"的逻辑复用，务必与那个过滤集合保持一致。
private let chatConfirmOpeners = ["记好啦", "收到～", "好嘞", "搞定", "记下啦", "OK，记上了"]

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
    @Query private var foods: [FoodEntry]
    @Query private var bills: [Bill]
    @Query(filter: #Predicate<Reminder> { !$0.syncDeleted }) private var reminders: [Reminder]
    @Query(sort: \HealthMetric.date, order: .reverse) private var healths: [HealthMetric]
    @Query private var merchantMetas: [MerchantMeta]
    @Query(sort: \RecognitionRecord.recognizedAt, order: .reverse) private var recognitions: [RecognitionRecord]
    @Query(filter: #Predicate<WaterLog> { !$0.syncDeleted }, sort: \WaterLog.date, order: .reverse) private var waters: [WaterLog]
    @Query(filter: #Predicate<RecurringRule> { !$0.syncDeleted }) private var recurringRules: [RecurringRule]
    @Query(filter: #Predicate<ChatMessage> { !$0.syncDeleted }, sort: \ChatMessage.createdAt, order: .forward) private var messages: [ChatMessage]
    @StateObject private var health = HealthManager.shared
    // 消息多选（contextMenu 「选择」进入；底部条改为「取消 / 删除」）
    @State private var messageMultiSelectMode = false
    @State private var selectedMessageIDs = Set<PersistentIdentifier>()
    @State private var showMessageDeleteConfirm = false
    @Environment(\.modelContext) private var context

    @State private var input = ""

    // 智能问答 Agent 总开关（与「云同步」同组，在设置页控制）。默认关，零污染。
    @AppStorage("aia.agentEnabled") private var agentEnabled: Bool = false
    @AppStorage("aia.greetingLLM") private var greetingLLM: Bool = true
    /// 招呼变体轮换索引（周一至周日自然循环，避免同一天相同变体）
    @AppStorage("aia.greetingVariant") private var greetingVariant = 0
    /// 早餐提醒每日限次：记录当天日期字符串，每天只提醒一次
    @AppStorage("aia.lastBreakfastReminderDate") private var lastBreakfastReminderDate = ""
    @FocusState private var isInputFocused: Bool
    @State private var isParsing = false
    @State private var hasAutoFocused = false
    @State private var pendingQueue: [ChatMessage] = []

    // 语音输入
    @StateObject private var recognizer = SpeechRecognizer()
    /// 从首页底部栏的语音按钮进入时，自动开始语音输入（内联，不跳页面）
    var autostartVoice = false
    /// 从空态 CTA 进入时，自动填入输入框并延迟发送的文本。
    var prefill: String?
    /// 进入聊天页的来源：home / voice / todoReminder
    var entrySource: String = "home"

    // 输入栏扩展功能（拍照/相册/文件）
    @State private var showInputActions = false
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var showFileImporter = false
    @State private var fileImportCoverItem: CameraCoverItem?
    @State private var fileImportErrorMessage: String?

    init(prefill: String? = nil, autostartVoice: Bool = false, entrySource: String = "home") {
        self.prefill = prefill
        self.autostartVoice = autostartVoice
        self.entrySource = entrySource
        #if DEBUG
        print("[ChatView] init prefill=\(prefill ?? "nil") autostartVoice=\(autostartVoice) entrySource=\(entrySource)")
        #endif
    }

    // 当前页面动态生成的阿宝招呼（不持久化），时间戳固定为进入页面时最后一条历史+1秒，
    // 这样新消息时间更晚，会自然把招呼顶上去，而不是永远钉在底部。
    @State private var greetingMessage: ChatMessage?
    /// 进入页面时启动的 LLM 招呼生成任务，离开页面 / 重新进入时取消旧任务避免回灌。
    @State private var greetingTask: Task<Void, Never>?

    /// 用户说了食物但没给重量时，暂存食物名与餐次，等用户回复重量。
    /// 非 nil 时 app 先问「你大概吃了多少重量呀？」，收到重量回复后再结合入库。
    @State private var pendingWeightFood: (name: String, meal: String)?

    private var displayedMessages: [ChatMessage] {
        if let g = greetingMessage {
            return (messages + [g]).sorted { $0.createdAt < $1.createdAt }
        }
        return messages
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(displayedMessages) { m in
                            if let greeting = greetingMessage, m === greeting {
                                greetingBubble(m.text)
                            } else {
                                bubble(m)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .contentShape(Rectangle())
                    .animation(scrollAnimation, value: displayedMessages.count)
                    .onTapGesture {
                        // 点击消息区手动收起键盘，方便阅读长内容
                        isInputFocused = false
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    // 首次进入时聚焦输入框（语音模式不弹键盘，交给外层 onAppear 自动开麦）
                    if !hasAutoFocused {
                        hasAutoFocused = true
                        if !autostartVoice {
                            isInputFocused = true
                        }
                    }
                    // 先快速滚到历史底部，让最新内容可见
                    scrollToBottom(proxy: proxy, delay: 0.1)
                    // 等布局稳定后再生成阿宝招呼并播放入场动画。
                    // 此时列表已在底部，气泡的淡入+滑入动画才会真正被看到；
                    // 紧接着再滚一次确保停留底部。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation(scrollAnimation) {
                            if greetingMessage == nil {
                                // 进入页面（每次进入都弹）生成阿宝招呼，作为对话的第一条。
                                // 1) 立即用本地模板出招呼（避免空白闪屏）；2) 后台异步用 LLM 重写更自然的版本，
                                //    若成功且非空则替换气泡文案（首次渲染的入场动画保留）。
                                // 时间戳固定在「当前历史最后一条 + 1 秒」，让它停在对话流里；
                                // 之后不再被推后，用户回复时新消息排在它下方，它自然被顶到上方。
                                let date = messages.last?.createdAt.addingTimeInterval(1) ?? Date()
                                let initial = buildGreeting()
                                greetingMessage = ChatMessage(role: .ai, text: initial, createdAt: date)
                                startGreetingLLMTask(initial: initial)
                            }
                        }
                        scrollToBottom(proxy: proxy, delay: 0.08)
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    // 招呼气泡已固定在对话流里，新消息来时它会被自然顶上去；
                    // 这里不再改动它的时间戳（否则会被推到最新、永远钉在底部）。
                    scrollToBottom(proxy: proxy, delay: 0.03)
                }
                .onChange(of: isInputFocused) { _, focused in
                    if focused {
                        // 键盘弹出：等 0.30s 键盘滑入完成再滚到底
                        scrollToBottom(proxy: proxy, delay: 0.30)
                    } else {
                        // 键盘收起：0 延迟，跟键盘滑出同步进行
                        scrollToBottom(proxy: proxy, delay: 0)
                    }
                }
            }
        }
        .navigationTitle("阿宝丨AI助理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 中间标题：圆形头像 + "我是阿宝" + 副标（与首条气泡同款内容）
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image("AIAvatar")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AIATheme.hairline, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("我是阿宝")
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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // 处理中提示（放在 chips 上方，避免遮挡输入）
                if isParsing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("阿宝正在思考...")
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
                        chip("记饮食") { FoodListView() }
                        chip("看健康") { HealthListView() }
                        chip("查账单") { BillListView() }
                        chip("加待办") { ReminderListView() }
                        chip("识别记录") { RecognitionRecordsView() }
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
                        Image(systemName: recognizer.isRecording ? "stop.circle.fill" : "mic.fill")
                            .font(AIATheme.Font.title2.weight(.medium))
                            .foregroundStyle(recognizer.isRecording ? AIATheme.warn : AIATheme.sub)
                            .frame(width: 34, height: 34)
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
            }
        }
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
        // 语音输入：录音中实时把转写文字写入输入框（内联，不跳页面）
        .onReceive(recognizer.$transcript) { text in
            if recognizer.isRecording { input = text }
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
        .fullScreenCover(item: $fileImportCoverItem) { item in
            switch item {
            case .recognizing(let img):
                RecognizingOverlay(image: img, onBack: { fileImportCoverItem = nil })
            case .present(let p):
                makeResultConfirmView(p)
                    .environment(\.modelContext, context)
            }
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
                    totalCount: messages.count,
                    onCancel: {
                        messageMultiSelectMode = false
                        selectedMessageIDs.removeAll()
                    },
                    onSelectAll: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let allIDs = Set(messages.map(\.persistentModelID))
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
    }

    /// 阿宝招呼：每次进入页面时根据本地数据与用户习惯实时生成（不持久化，避免重复堆积）。
    private var greeting: String { buildGreeting() }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
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
                    SafeDelete.chatMessage(message, in: context)
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
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(formatValue(value))
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(unit)
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.sub)
                }
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
        HealthManager.shared.saveCaloriesConsumed(pending.cal, date: .now)
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

    /// 顶部阿宝招呼气泡（带小头像，区别于普通聊天记录）
    private func greetingBubble(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image("AIAvatar")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .overlay(Circle().stroke(AIATheme.hairline, lineWidth: 0.5))
            messageBubble(message: nil, text: text, isUser: false)
            Spacer(minLength: 28)
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                 removal: .opacity))
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

            ZStack(alignment: .topTrailing) {
                Text(displayText)
                    .font(.system(size: 13.3))
                    .foregroundStyle(userSide ? .white : .primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(userSide ? AIATheme.blue : AIATheme.billBG)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .opacity(showSelection && !isSelected ? 0.4 : 1.0)

                if showSelection {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Color.green : Color.black.opacity(0.5), Color.white)
                        .font(.system(size: 18))
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
                        SafeDelete.chatMessage(m, in: context)
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

            if !userSide { Spacer(minLength: 28) }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                 removal: .opacity))
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
        for id in selectedMessageIDs {
            SafeDelete.chatMessageByID(id, in: context)
        }
        messageMultiSelectMode = false
        selectedMessageIDs.removeAll()
    }

    /// 生成阿宝打招呼文案。
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
        let intro = "我是阿宝～你的私人AI助理。"
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

    /// 招呼专用上下文：比 buildContext() 精简得多（只喂给 LLM 与招呼相关的字段，省 token 也避免模型分心）。
    /// 字段命名兼容中文（便于模型直接读懂）：时间 / 今日饮食 / 今日账单 / 今日待办 / 步数 / 最新健康指标等。
    private func buildGreetingContext() -> [String: Any] {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)

        // 今日已记饮食（精简字段）
        let todayFoods = foods.filter { cal.isDateInToday($0.date) }
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
        let bfHours = foods.filter { $0.date >= since && $0.meal == "早餐" }.map { cal.component(.hour, from: $0.date) }
        let commonBF: Int? = bfHours.isEmpty ? nil : Int(round(Double(bfHours.reduce(0, +)) / Double(bfHours.count)))

        // 今日待办（仅 today + 未完成 + 未过期）
        let upcomingToday = reminders.filter { r in
            guard let due = r.due else { return false }
            return cal.isDateInToday(due) && !r.done && due >= now
        }
        // 重要：所有传给云端 LLM 的时间戳必须用本地时区（带 +HH:MM 偏移），
        // 否则默认 ISO8601DateFormatter() 是 UTC（Z），本地 11:45 会变成 03:45Z 被 LLM 误读为「凌晨 3 点」。
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = .current
        let upcomingCompact: [[String: Any]] = upcomingToday.prefix(3).map { r in
            [
                "title": r.title,
                "priority": r.priority,
                "due": fmt.string(from: r.due ?? now),
            ]
        }

        // 【D】今日账单概况
        let todayBills = bills.filter { cal.isDateInToday($0.time) && !$0.syncDeleted }
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
        if let lh = healths.first {
            latestMetric = ["metric": lh.metric, "value": lh.value, "unit": lh.unit ?? ""]
        }

        var ctx: [String: Any] = [
            "currentHour": hour,
            "currentTime": DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short),
            "todayFoods": todayFoodsCompact,
            "commonBreakfastHour": commonBF as Any,
            "upcomingTodayCount": upcomingToday.count,
            "upcomingToday": upcomingCompact,
            "totalFoods": foods.count,
            "totalReminders": reminders.count,
            "entrySource": entrySource,                  // 🆕 入口来源
        ]
        if let bs = todayBillSummary { ctx["todayBillSummary"] = bs }  // 🆕
        if let lm = latestMetric { ctx["latestHealthMetric"] = lm }    // 🆕
        if health.stepsToday > 0 {
            ctx["stepsToday"] = health.stepsToday
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

    private func chip(_ title: String, @ViewBuilder destination: () -> some View) -> some View {
        NavigationLink { destination() } label: {
            Text(title)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.sub)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(AIATheme.surfaceSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            // 点击快捷意图跳转时自动收起键盘
            isInputFocused = false
        })
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
        .buttonStyle(.plain)
    }

    /// 「联系我们」chip 点击：直接以阿宝身份发送一条带联系方式的 AI 消息进聊天流。
    private func postContactMessage() {
        let body = "如果你需要帮助，或想给我们提供建议，欢迎通过以下方式联系我们😊\n\n微信/Wechat：754727942\n\n邮箱/Email：754727942@qq.com\n\n长按本消息，可复制"
        let aiMessage = ChatMessage(role: .ai, text: body, createdAt: Date())
        context.insert(aiMessage)
        try? context.save()
        // 关掉输入栏焦点，让用户立刻看到阿宝的回复
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
                                coverItem: $fileImportCoverItem,
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
        let identityKw = ["你是谁", "你叫什么", "你是阿宝", "介绍一下你自己", "你的名字", "你是什么"]
        if identityKw.contains(where: { lower.contains($0) }) {
            return "我是阿宝，你的私人专属 AI 助理～可以帮你记饮食、账单、待办，也能看看今天的健康数据。今天想记点什么？"
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
            return "\(opening)，我是阿宝～今天想记录点什么，还是随便聊聊？"
        }

        return nil
    }

    /// 云端聊天不可用时的本地兜底回复：基于用户的本地数据组织成自然语句。
    /// 覆盖饮食/账单/待办/健康几类常见问题，其余给友好兜底并提示能做什么。
    private func localReply(for text: String) -> String {
        // 先处理常见闲聊/元意图，避免把「你是谁」「在干嘛」当成未识别意图给通用兜底。
        if let metaReply = replyForMetaIntent(text) {
            return metaReply
        }

        let lower = text.lowercased()
        let cal = Calendar.current
        let now = Date()

        // 饮食 / 卡路里
        if lower.contains("吃") || lower.contains("卡路里") || lower.contains("热量") || lower.contains("饮食") || lower.contains("营养") {
            let todayFoods = foods.filter { cal.isDateInToday($0.date) }
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
                targetBills = bills.filter { $0.time >= startOfYesterday && $0.time < startOfToday }
                dayLabel = "昨天"
            } else if isRecent {
                let startOf7DaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday)!
                targetBills = bills.filter { $0.time >= startOf7DaysAgo }
                dayLabel = "最近 7 天"
            } else {
                targetBills = bills.filter { cal.isDateInToday($0.time) }
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
            if let reply = createTodoLocally(from: text) {
                return reply
            }
            let upcoming = reminders
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
                if cal.isDateInToday(due) { prefix = "今天 \(AppFormat.time.string(from: due))" }
                else if cal.isDateInTomorrow(due) { prefix = "明天 \(AppFormat.dateTime.string(from: due))" }
                else { prefix = AppFormat.dateTime.string(from: due) }
                return "· \(prefix) · \(title)"
            }.joined(separator: "\n")
            let more = upcoming.count > 3 ? "\n…还有 \(upcoming.count - 3) 件" : ""
            return "你还有 \(upcoming.count) 件事没做：\n\(list)\(more)\n到点了会自动提醒你，放心～"
        }

        // 健康 / 步数
        if lower.contains("步数") || lower.contains("健康") || lower.contains("运动") || lower.contains("走") || lower.contains("锻炼") {
            if health.stepsToday > 0 {
                return "今天已经走了 \(health.stepsToday) 步，活动量不错，继续保持呀～"
            }
            return "我暂时还没读到你的健康数据（可能还没授权健康权限）。不过你今天感觉怎么样？"
        }

        // 兜底：没识别到具体意图，给友好引导（不再道歉式兜底，直接给能力示例）
        return "我目前最擅长帮你记饮食、账单、待办和看健康数据，比如：\n· 「早餐吃了碗燕麦粥」\n· 「记一笔星巴克35」\n· 「晚上8点提醒我开会」\n直接说就行，我帮你归类好。"
    }

    /// 本地兜底创建待办：当云端返回 types:none 但用户明显在新建待办时，直接解析标题和日期并创建。
    private func createTodoLocally(from text: String) -> String? {
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
        var created: [Reminder] = []
        for seg in segments {
            guard let (title, due) = parseTodoCreate(seg) else { continue }
            if WaterIntakeParser.checkDuplicateAndRegister(seg, type: "todo") { continue }
            if DataDeduplicator.isDuplicateReminder(title: title, context: context) { continue }
            let r = Reminder(title: title, due: due, imageName: nil)
            DefaultReminderSettings.shared.apply(to: r)
            context.insert(r)
            ReminderNotificationManager.schedule(r)
            created.append(r)
        }
        guard !created.isEmpty else { return nil }
        try? context.save()
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        let lines = created.map { "⏰ 已添加待办「\($0.title)」，我会在 \(formatShortDateTime($0.due ?? Date())) 提醒你。" }
        return "\(opener)：\n" + lines.joined(separator: "\n")
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
    private func createBillLocally(from text: String) -> String? {
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

        // 一句话多条：按连词切分后逐条建账单
        let segments = IntentTextUtils.splitByConjunction(text)
        var created: [(merchant: String, amount: Double, isIncome: Bool)] = []
        for seg in segments {
            guard let fields = buildBill(from: seg) else { continue }
            if WaterIntakeParser.checkDuplicateAndRegister(seg, type: "bill") { continue }
            if DataDeduplicator.isDuplicateBill(merchant: fields.merchant, amount: fields.amount, time: .now, context: context) { continue }
            let bill = Bill(merchant: fields.merchant, amount: fields.amount, category: fields.category,
                            time: .now, isIncome: fields.isIncome, imageName: nil)
            context.insert(bill)
            created.append((fields.merchant, fields.amount, fields.isIncome))
        }
        guard !created.isEmpty else { return nil }
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        let lines = created.map { (m, a, inc) in
            let icon = inc ? "💰" : "🧾"
            return "\(icon) 已添加\(inc ? "收入" : "支出")「\(m)」\(String(format: "%.2f", a))"
        }
        return "\(opener)：\n" + lines.joined(separator: "\n")
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

    private func createFoodLocally(from text: String) async -> String? {
        if ChatView.hasExplicitUpdateIntent(text) ||
           ChatView.hasExplicitDeleteIntent(text) ||
           ChatView.hasExplicitCompleteIntent(text) {
            return nil
        }
        let meal = WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        let items = ChatView.parseFoodItems(from: text)
        guard !items.isEmpty else { return nil }

        // 如果用户没给重量/份量，先追问不急着入库
        if !ChatView.hasWeightInfo(text) {
            let firstItem = items[0]
            pendingWeightFood = (firstItem.name, meal)
            return nil
        }

        var entries: [FoodEntry] = []
        var summaries: [String] = []
        var totalCal: Double = 0
        let foodIcon = ["🍽", "🍜", "🍚", "🥗", "😋", "🍱"].randomElement() ?? "🍽"

        var missingNutrition: [String] = []
        var cloudFilled: [String] = []
        for (name, weight, portion) in items {
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
            }

            let ratio = weight / 100.0
            let cal = (ref?.kcal ?? 0) * ratio
            let protein = (ref?.protein ?? 0) * ratio
            let carbs = (ref?.carbs ?? 0) * ratio
            let fat = (ref?.fat ?? 0) * ratio
            let fiber = (ref?.fiber ?? 0) * ratio
            let sugar = (ref?.sugar ?? 0) * ratio
            let sodium = (ref?.sodium ?? 0) * ratio

            let entry = FoodEntry(name: name, calories: cal, protein: protein, carbs: carbs, fat: fat,
                                  fiber: fiber, sugar: sugar, sodium: sodium,
                                  portion: portion, meal: meal,
                                  weightGram: weight,
                                  baseCalories: ref?.kcal,
                                  baseProtein: ref?.protein,
                                  baseCarbs: ref?.carbs,
                                  baseFat: ref?.fat,
                                  baseFiber: ref?.fiber,
                                  baseSugar: ref?.sugar,
                                  baseSodium: ref?.sodium,
                                  imageName: nil)
            entries.append(entry)
            totalCal += cal
            // 展示全部 7 项营养：热量/蛋白/碳水/脂肪/膳食纤维/糖/钠
            // 用「·」串联避免挤在一行；macro 值保留 1 位小数（钠 0 位），0 值也显示以让用户看到全貌
            let macros = String(format: "蛋白 %.1fg · 碳水 %.1fg · 脂肪 %.1fg · 纤维 %.1fg · 糖 %.1fg · 钠 %.0fmg",
                                protein, carbs, fat, fiber, sugar, sodium)
            let pendingTag: String
            if ref == nil {
                pendingTag = "（热量待补全）"
            } else if cloudFilled.contains(name) {
                pendingTag = "（云端查营养）"
            } else {
                pendingTag = ""
            }
            summaries.append("\(foodIcon) \(meal)「\(name)」\(Int(cal)) kcal（\(portion)）\(pendingTag)\n  \(macros)")
        }

        // 防重复：以整句话做 key（短期窗口）
        if WaterIntakeParser.checkDuplicateAndRegister(text, type: "food") {
            return "这顿你刚记过啦，我就不重复记了～"
        }
        // 内容级去重：检查 24h 内是否有同名 + 同份量记录
        for entry in entries {
            if DataDeduplicator.isDuplicateFood(name: entry.name, date: entry.date, portion: entry.portion, context: context) {
                return "这顿你刚记过啦，我就不重复记了～"
            }
        }
        for entry in entries {
            context.insert(entry)
        }
        HealthManager.shared.saveCaloriesConsumed(totalCal, date: .now)
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        var disclaimer = "\n\n结果仅供参考，如需修改可到\"饮食记录\"页面进行修改。"
        if !cloudFilled.isEmpty {
            disclaimer = "\n（「\(cloudFilled.joined(separator: "、"))」已通过云端查询到营养并记下，同时存到了本地食物库）" + disclaimer
        } else if !missingNutrition.isEmpty {
            disclaimer = "\n（「\(missingNutrition.joined(separator: "、"))」本地与云端暂未收录营养，已先按 0 占位记下，到「饮食记录」补全即可）" + disclaimer
        }
        return summaries.count == 1
            ? "\(opener)：\(summaries[0])" + disclaimer
            : "\(opener)：\n" + summaries.joined(separator: "\n") + disclaimer
    }

    /// 用户回复了重量后，组合成完整的食物文本再走正常创建流程。
    private func createFoodWithWeight(name: String, text: String, meal: String) async -> String {
        // 构建合成文本让 createFoodLocally 复用同一套解析逻辑
        let syntheticText = "\(meal)吃了\(text)\(name)"
        if let result = await createFoodLocally(from: syntheticText) {
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

        return "阿宝帮你查到「\(ref.name)」每100克" +
               "热量\(kcal)kcal，碳水\(carb)g，蛋白质\(pro)g，脂肪\(fat)g，" +
               "膳食纤维\(fib)g，糖\(sug)g，钠\(sod)mg，数据仅供参考。"
    }

    /// 云端兜底也失败时的「尽力记录」：本地营养库查不到、云端也识别不出时，
    /// 仍把食物名+份量落库，热量记为 0 并提示用户稍后补全，避免被静默丢弃。
    /// 典型场景：云端 provider 配置缺失导致纯文字被发到视觉模型、识别成 none —— 食物绝不能因此消失。
    private func createFoodLocallyFallback(from text: String) -> String? {
        let meal = WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        let items = ChatView.parseFoodItems(from: text)
        guard !items.isEmpty else { return nil }

        var names: [String] = []
        for (name, weight, portion) in items {
            let entry = FoodEntry(name: name, calories: 0, protein: 0, carbs: 0, fat: 0,
                                  fiber: 0, sugar: 0, sodium: 0,
                                  portion: portion, meal: meal,
                                  weightGram: weight,
                                  baseCalories: 0, baseProtein: 0, baseCarbs: 0, baseFat: 0,
                                  baseFiber: 0, baseSugar: 0, baseSodium: 0,
                                  imageName: nil)
            context.insert(entry)
            names.append("「\(name)」\(portion)")
        }
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let joined = names.joined(separator: "、")
        return "🍽 已记下 \(joined)，但暂时没查到热量，点开记录可以补全哦～"
    }

    /// 账单已记且本地营养库未命中时，异步联网查营养并在聊天中发送确认卡片。
    /// 用户点击"确认记录"后才创建 FoodEntry；查询失败则仅提示，保留账单。
    /// 支持一句话里多个食物：每个食物独立一张确认卡片。
    private func sendFoodConfirmCard(text: String) async {
        let meal = WaterIntakeParser.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        let items = ChatView.parseFoodItems(from: text)
        guard !items.isEmpty else { return }

        let amount = extractAmount(text)
        var anySent = false

        for (name, weight, portion) in items {
            do {
                if let ref = try await RecognizeService.queryFood(name: name) {
                    let ratio = weight / 100.0
                    let cal = ref.kcal * ratio
                    let protein = ref.protein * ratio
                    let carbs = ref.carbs * ratio
                    let fat = ref.fat * ratio
                    let fiber = ref.fiber * ratio
                    let sugar = ref.sugar * ratio
                    let sodium = ref.sodium * ratio

                    FoodMetaStore.upsert(name: name, displayName: ref.name,
                                         kcal: ref.kcal, protein: ref.protein, carbs: ref.carbs, fat: ref.fat,
                                         fiber: ref.fiber, sugar: ref.sugar, sodium: ref.sodium,
                                         source: "cloud", in: context)

                    let pending = PendingFoodConfirm(
                        meal: meal,
                        name: ref.name,
                        portion: portion,
                        weight: weight,
                        cal: cal,
                        protein: protein,
                        carbs: carbs,
                        fat: fat,
                        fiber: fiber,
                        sugar: sugar,
                        sodium: sodium,
                        amount: amount,
                        originalText: text
                    )
                    guard let data = try? JSONEncoder().encode(pending),
                          let json = String(data: data, encoding: .utf8) else { continue }
                    let confirmText = "__FOOD_CONFIRM__" + json
                    let aiMessage = ChatMessage(role: .ai, text: confirmText, createdAt: Date().addingTimeInterval(0.2))
                    context.insert(aiMessage)
                    try? context.save()
                    anySent = true
                } else {
                    let aiMessage = ChatMessage(
                        role: .ai,
                        text: "🍽 没查到「\(name)」的营养信息，支出已经记下啦，你可以稍后手动补录饮食哦～",
                        createdAt: Date().addingTimeInterval(0.2)
                    )
                    context.insert(aiMessage)
                    try? context.save()
                    anySent = true
                }
            } catch {
                print("[sendFoodConfirmCard] 失败：\(error)")
                let aiMessage = ChatMessage(
                    role: .ai,
                    text: "🍽 联网查「\(name)」时出错了，支出已经记下啦，稍后再试吧～",
                    createdAt: Date().addingTimeInterval(0.2)
                )
                context.insert(aiMessage)
                try? context.save()
                anySent = true
            }
        }

        if !anySent {
            let aiMessage = ChatMessage(
                role: .ai,
                text: "🍽 没查到这些食物的营养信息，支出已经记下啦，你可以稍后手动补录饮食哦～",
                createdAt: Date().addingTimeInterval(0.2)
            )
            context.insert(aiMessage)
            try? context.save()
        }
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
        let items = ChatView.parseFoodItems(from: text)
        guard !items.isEmpty else { return localReply(for: text) }

        // 1) 优先专项查询每个食物的营养（更可靠，不易被上下文带偏）
        var entries: [FoodEntry] = []
        var summaries: [String] = []
        var totalCal: Double = 0
        let foodIcon = ["🍽", "🍜", "🍚", "🥗", "😋", "🍱"].randomElement() ?? "🍽"

        for (name, weight, portion) in items {
            do {
                if let ref = try await RecognizeService.queryFood(name: name) {
                    let ratio = weight / 100.0
                    let cal = ref.kcal * ratio
                    let protein = ref.protein * ratio
                    let carbs = ref.carbs * ratio
                    let fat = ref.fat * ratio
                    let fiber = ref.fiber * ratio
                    let sugar = ref.sugar * ratio
                    let sodium = ref.sodium * ratio

                    FoodMetaStore.upsert(name: name, displayName: ref.name,
                                         kcal: ref.kcal, protein: ref.protein, carbs: ref.carbs, fat: ref.fat,
                                         fiber: ref.fiber, sugar: ref.sugar, sodium: ref.sodium,
                                         source: "cloud", in: context)

                    let entry = FoodEntry(name: ref.name, calories: cal, protein: protein, carbs: carbs, fat: fat,
                                          fiber: fiber, sugar: sugar, sodium: sodium,
                                          portion: portion, meal: meal,
                                          weightGram: weight,
                                          baseCalories: ref.kcal,
                                          baseProtein: ref.protein,
                                          baseCarbs: ref.carbs,
                                          baseFat: ref.fat,
                                          baseFiber: ref.fiber,
                                          baseSugar: ref.sugar,
                                          baseSodium: ref.sodium,
                                          imageName: nil)
                    entries.append(entry)
                    totalCal += cal
                    summaries.append("\(foodIcon) \(meal)「\(ref.name)」\(Int(cal)) kcal（\(portion)）")
                }
            } catch {
                print("[queryFood] 失败：\(error)")
            }
        }

        if !entries.isEmpty {
            for entry in entries {
                context.insert(entry)
            }
            HealthManager.shared.saveCaloriesConsumed(totalCal, date: .now)
            CloudSyncManager.shared.syncAfterLocalChange(context: context)
            let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
            return summaries.count == 1
                ? "\(opener)：\(summaries[0])"
                : "\(opener)：\n" + summaries.joined(separator: "\n")
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
        return localReply(for: text)
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
            ("克", 1), ("g", 1)
        ]
        let unitPattern = unitWeights.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
        let quantityPattern = "([\\d一二两三四五六七八九十]+)?\\s*(\(unitPattern))"

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
                    weight = Double(count) * uw.1
                    portion = "\(count)\(unit)"
                    t = (t as NSString).replacingCharacters(in: match.range(at: 0), with: "")
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

    /// 从文本中拆出多个食物项。
    /// 优先按「数量+单位」切分；没有量词时退回整句解析，或按常见连词/标点切分。
    /// 示例：「早餐吃了两个鸡蛋一碗燕麦粥」→ [(鸡蛋, 100, "2个"), (燕麦粥, 300, "1碗")]
    static func parseFoodItems(from text: String) -> [(name: String, weight: Double, portion: String)] {
        let unitWeights: [(String, Double)] = [
            ("碗", 300), ("杯", 250), ("瓶", 500), ("罐", 330),
            ("个", 50), ("片", 30), ("份", 200), ("块", 50),
            ("串", 100), ("根", 100), ("盘", 300), ("勺", 15),
            ("两", 50),
            ("克", 1), ("g", 1)
        ]
        let unitPattern = unitWeights.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
        let quantityPattern = "([\\d一二两三四五六七八九十]+)?\\s*(\(unitPattern))"

        guard let regex = try? NSRegularExpression(pattern: quantityPattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var items: [(name: String, weight: Double, portion: String)] = []

        // 按量词「开始位置」切分：中文习惯「数量+单位+食物名」，
        // 每项从当前量词开始，到下一量词开始之前结束。
        for (idx, match) in matches.enumerated() {
            let start = match.range(at: 0).location
            let end: Int
            if idx + 1 < matches.count {
                end = matches[idx + 1].range(at: 0).location
            } else {
                end = ns.length
            }
            let segmentRange = NSRange(location: start, length: end - start)
            let segment = ns.substring(with: segmentRange)
            if let parsed = parseFoodNameAndWeight(segment) {
                items.append(parsed)
            }
        }

        // 按量词切出至少一项时直接返回，避免把 trailing 语气词/场景词当成食物。
        if !items.isEmpty {
            return items
        }

        // 没有量词：先尝试整句
        if let parsed = parseFoodNameAndWeight(text) {
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
        return items
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
            return ChatView.parseChineseNumber(s)
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

        // X点X分 / X点 / X点半
        if hour == nil,
           let regex = try? NSRegularExpression(pattern: "(\\d{1,2})\\s*点\\s*(半|(\\d{1,2})\\s*分)?"),
           let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            let h = Int((text as NSString).substring(with: m.range(at: 1)))
            if let h = h, h <= 23 {
                hour = h
                let g2 = m.range(at: 2)
                if g2.location != NSNotFound {
                    let ms = (text as NSString).substring(with: g2)
                    if ms.contains("半") { minute = 30 }
                    else if let mi = Int(ms.replacingOccurrences(of: "分", with: "").trimmingCharacters(in: .whitespaces)),
                            mi <= 59 { minute = mi }
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

    /// 把中文数字（如「二」「十二」「两」）转成 Int；阿拉伯数字直接返回。
    static func parseChineseNumber(_ string: String) -> Int? {
        if let n = Int(string) { return n }
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let units: [Character: Int] = [
            "十": 10, "百": 100, "千": 1000
        ]
        var result = 0
        var current = 0
        for c in string {
            if let d = digits[c] {
                current = current * 10 + d
            } else if let u = units[c] {
                if current == 0 { current = 1 }
                current *= u
                result += current
                current = 0
            }
        }
        result += current
        return result > 0 ? result : nil
    }

    /// 从「帮我增加一个7月30日去体检的提醒」这类文本里解析标题和日期。
    private func parseTodoCreate(_ text: String) -> (title: String, due: Date)? {
        let cal = Calendar.current
        let now = Date()
        var due = now
        var dateFound = false
        let lower = text.lowercased()

        // 优先处理相对时间（2分钟后、1小时后、半小时后），云端常把这类词解析错。
        if let relativeDue = parseRelativeTime(from: text) {
            due = relativeDue
            dateFound = true
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
            } else if lower.contains("明天") || lower.contains("明日") {
                due = cal.date(byAdding: .day, value: 1, to: now) ?? now
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
        } else if let tod {
            due = cal.date(bySettingHour: tod.hour, minute: tod.minute, second: 0, of: due) ?? due
        } else if !dateFound {
            // 既没日期也没时间：默认 1 小时后提醒
            due = cal.date(byAdding: .hour, value: 1, to: now) ?? now
        } else {
            // 有日期但用户没说具体时间：默认当天 8:00，避免变成 00:00 的尴尬提醒
            due = cal.date(bySettingHour: 8, minute: 0, second: 0, of: due) ?? due
        }

        // 提取标题：先移除前缀动词，再移除日期、时段词和「提醒/待办」后缀
        var title = text
        // 去掉命令动词前缀（记/记录/添加/增加/创建/新建/设置/录入/保存/帮我/给我…），
        // 与饮食/账单/云端共用 commandVerbPrefixes，避免「给我记个买菜提醒」残留成「给我记个买菜提醒」。
        title = ChatView.stripCommandVerbPrefix(title)
        title = title.replacingOccurrences(of: datePattern, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "明天|后天|明日", with: "", options: .regularExpression)
        // 移除星期词（下周六/这周六/礼拜天/星期一等），避免标题残留
        title = title.replacingOccurrences(of: "(这|本|今|下)?(周|星期|礼拜)([一二三四五六七日天])", with: "", options: .regularExpression)
        // 移除相对时间表达，避免标题里保留「2分钟后」「1小时后」等词
        title = title.replacingOccurrences(of: "([\\d一二两三四五六七八九十]+)\\s*[分钟小时](后|以后)", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "半小时(后|以后)?|一刻钟(后|以后)?", with: "", options: .regularExpression)
        // 移除时段词（中午/晚上等），避免标题里保留「中午运动」
        title = title.replacingOccurrences(of: ChatView.timeOfDayPattern, with: "", options: .regularExpression)
        // 移除具体时刻（9点 / 21:30 / 下午3点半），避免标题残留「9点运动」
        title = title.replacingOccurrences(of: "(\\d{1,2}):(\\d{2})", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "(\\d{1,2})\\s*点\\s*(半|(\\d{1,2})\\s*分)?", with: "", options: .regularExpression)
        // 先移除「提醒我」，再移除后缀「提醒/待办/任务/事项」，避免标题残留「我」
        title = title.replacingOccurrences(of: "提醒我", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "的?(提醒|待办|任务|事项)", with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "的"))

        if title.isEmpty { return nil }
        return (title, due)
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

    /// 把最近几条聊天记录整理成云端可理解的上下文，用于识别"这个提醒""改成"等指代。
    /// 过滤掉：
    /// - AI 的确认消息（开场白取自 chatConfirmOpeners 池），避免模型把前一笔记录当成模板重复套用；
    /// - 用户的记录操作指令，避免模型把后续"好的好的"当成重复执行。
    private func buildRecentMessages(limit: Int) -> [[String: String]] {
        let recent = messages.suffix(limit).filter { msg in
            if msg.role == .ai, chatConfirmOpeners.contains(where: { msg.text.hasPrefix($0) }) { return false }
            if msg.role == .user, ChatView.isRecordOperationMessage(msg.text) { return false }
            return true
        }
        return recent.map { ["role": $0.role == .user ? "user" : "ai", "text": $0.text] }
    }

    private func send() {
        // 若正在录音，先停止：避免 transcript 后续更新把刚清空的 input 重新填回来。
        if recognizer.isRecording {
            #if DEBUG
            print("[ChatView] send while recording, stopping recognizer first")
            #endif
            recognizer.stop()
        }
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        input = ""
        recognizer.transcript = ""  // 清空识别缓冲，防止旧文字在后续录音或 view 重建时回灌
        recognizer.errorMessage = nil  // 发送成功后清理错误提示（如取消任务误报的 No speech detected）
        let userMessage = ChatMessage(role: .user, text: t)
        context.insert(userMessage)
        try? context.save()
        pendingQueue.append(userMessage)
        processNext()
    }

    private func processNext() {
        guard !isParsing, !pendingQueue.isEmpty else { return }
        isParsing = true
        let userMessage = pendingQueue.removeFirst()
        let t = userMessage.text
        // 登录账户 userId（aia.userId）；未登录为空串 → 云端按"userId 缺失"回落普通 chat。
        let agentUserId = UserDefaults.standard.string(forKey: "aia.userId") ?? ""

        Task { @MainActor in
            do {
                let recentMessages = buildRecentMessages(limit: 5)
                let responseText: String
                // —— 本地优先：所有结构化指令（记账/记饮食/待办/饮水/食物查询）先走本地，零云端调用 ——
                if let local = await resolveLocally(t, recentMessages: recentMessages) {
                    responseText = local
                } else {
                    // —— 仅本地兜不住才走云端 LLM ——
                    let dataContext = buildContext()
                    let agentReply = agentEnabled
                        ? try? await RecognizeService.agentChat(text: t, context: dataContext, userId: agentUserId)
                        : try? await RecognizeService.chat(text: t, context: dataContext)
                    if let r = agentReply, !r.isEmpty {
                        responseText = r
                        if UserDefaults.standard.bool(forKey: "aia.isLoggedIn") {
                            // Agent 可能在云端做了删除/修改/新建等动作（chat agent 是写权限的），
                            // 这些变更只会落在云端，本地 SwiftData 不会自动同步——必须触发完整 sync
                            // （push + pull + cleanupSyncedTombstones）才能让本地看到云端的删除/修改。
                            // 否则会出现「阿宝说删了，但账单还在」的 UX 假象。
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
                                let summary = saveFromResult(result, originalText: t)
                                if summary.isEmpty {
                                    responseText = localReply(for: t)
                                } else {
                                    let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
                                    responseText = "\(opener)：\n" + summary.joined(separator: "\n")
                                }
                            } else {
                                responseText = localReply(for: t)
                            }
                        }
                    }
                }
                let aiMessage = ChatMessage(role: .ai, text: responseText, createdAt: userMessage.createdAt.addingTimeInterval(0.1))
                context.insert(aiMessage)
                try? context.save()
            } catch {
                let aiMessage = ChatMessage(role: .ai, text: localReply(for: t), createdAt: userMessage.createdAt.addingTimeInterval(0.1))
                context.insert(aiMessage)
                try? context.save()
            }
            isParsing = false
            processNext()
        }
    }


    // MARK: - 本地优先意图解析

    /// 本地优先意图解析：纯本地（零云端调用），快速处理结构化指令。
    /// 返回非空表示本地已处理完成；返回 nil 表示需走云端 LLM。
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
                    if let bill = createBillLocally(from: t) {
                        return bill
                    }
                case .food:
                    if let food = await createFoodLocally(from: t) {
                        return food
                    }
                case .todo:
                    if let todo = createTodoLocally(from: t) {
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
        if let localTodo = createTodoLocally(from: t) {
            return localTodo
        }

        // 2. 本地能解析的明确账单意图（如「记一笔星巴克35」「付了美团28」）
        //    直接本地建，复用 MerchantMeta 分类，跳过 AI。
        if let localBill = createBillLocally(from: t) {
            // 账单已创建；若该文本同时含食物意图，本地营养库命中则直接建饮食；
            // 未命中则先记账单，再异步联网查营养并以确认卡片让用户确认入库。
            if hasRawFoodIntent(t) {
                if let localFood = await createFoodLocally(from: t) {
                    return localBill + "\n" + stripOpener(localFood)
                } else {
                    Task { @MainActor in
                        await sendFoodConfirmCard(text: t)
                    }
                    return localBill
                }
            }
            return localBill
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
            // 用户明确回复了重量 → 组合创建
            if let (_, p) = ChatView.parseWeightOnly(t) {
                pendingWeightFood = nil
                return await createFoodWithWeight(name: pending.name, text: p, meal: pending.meal)
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

        // 7. 本地确能回答的元意图（问候/身份），不包含「今天花了多少」等可能需上下文的数据查询
        if let meta = replyForMetaIntent(t) {
            return meta
        }

        // 本地兜不住 → 交给云端 LLM
        return nil
    }

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
    private let scrollAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.82)
    private func scrollToBottom(proxy: ScrollViewProxy, delay: TimeInterval = 0, anchor: UnitPoint = .bottom) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let last = displayedMessages.last {
                withAnimation(scrollAnimation) { proxy.scrollTo(last.id, anchor: anchor) }
            }
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
    /// 只处理简短重量型文本，不含食物名——用于用户回复阿宝的「你吃了多少」追问。
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
                guard let foodName = food.name, !foodName.isEmpty else { continue }
                let meal = resolveMeal(from: food.meal, text: originalText)
                let portion = food.portion ?? "100克"
                let weight = RecognitionSaver.weightFromPortion(portion)
                let ratio = weight / 100.0
                let baseCal = food.calories ?? 0
                let basePro = food.protein ?? 0
                let baseCar = food.carbs ?? 0
                let baseFat = food.fat ?? 0
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
                        HealthManager.shared.saveCaloriesConsumed(cal, date: target.date)
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
                        SafeDelete.food(target, in: context)
                        summary.append("🗑 已删除「\(foodName)」")
                    } else {
                        summary.append("我没找到你想删除的饮食记录，能再描述一下吗？")
                    }
                default:
                    if baseCal <= 0 && basePro <= 0 && baseCar <= 0 && baseFat <= 0 {
                        summary.append("⚠️ 识别到「\(foodName)」但暂未查到营养数据，已跳过保存")
                        break
                    }
                    context.insert(FoodEntry(name: foodName,
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
                                             imageName: nil))
                    FoodMetaStore.upsert(name: foodName, displayName: foodName,
                                         kcal: baseCal, protein: basePro, carbs: baseCar, fat: baseFat,
                                         fiber: baseFiber, sugar: baseSugar, sodium: baseSodium,
                                         source: "cloud", in: context)
                    HealthManager.shared.saveCaloriesConsumed(cal, date: .now)
                    summary.append("🍽 \(meal)「\(foodName)」\(Int(cal)) kcal\n  蛋白 \(String(format: "%.1f", protein))g · 碳水 \(String(format: "%.1f", carbs))g · 脂肪 \(String(format: "%.1f", fat))g · 纤维 \(String(format: "%.1f", fiber))g · 糖 \(String(format: "%.1f", sugar))g · 钠 \(String(format: "%.0f", sodium))mg\n\n结果仅供参考，如需修改可到\"饮食记录\"页面进行修改。")
                }
            }
        }

        if shouldSaveType("bill"), types.contains("bill") {
            for bill in result.billList {
                guard let merchant = bill.merchant, !merchant.isEmpty,
                      let amount = bill.amount, amount > 0 else { continue }
                let time = RecognitionResult.date(from: bill.time) ?? .now
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
                        SafeDelete.bill(target, in: context)
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
                    SafeDelete.reminder(target, in: context)
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
        let active = reminders.filter { !$0.done && !$0.syncDeleted }
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

    /// 查找饮食记录修改/删除的目标。优先匹配 targetTitle（食物名），否则取最近一条饮食记录。
    private func findFoodTarget(targetTitle: String?, fallbackToLatest: Bool) -> FoodEntry? {
        let all = foods.filter { !$0.syncDeleted }
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
        let all = bills.filter { !$0.syncDeleted }
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
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOf7DaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday)!
        let todayFoods = foods.filter { cal.isDateInToday($0.date) }
        let todayBills = bills.filter { cal.isDateInToday($0.time) }
        let yesterdayFoods = foods.filter { $0.date >= startOfYesterday && $0.date < startOfToday }
        let yesterdayBills = bills.filter { $0.time >= startOfYesterday && $0.time < startOfToday }
        let weekFoodEntries = foods.filter { $0.date >= startOf7DaysAgo }
        let weekBillEntries = bills.filter { $0.time >= startOf7DaysAgo }
        // 重要：传给云端 LLM 的所有日期必须带本地时区偏移（+HH:MM），否则默认 ISO8601 输出 UTC（Z），
        // 本地 11:45 会变成 03:45Z 被 LLM 误读为「凌晨 3 点」。
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = .current
        let todayTodos = reminders.filter { r in
            if let due = r.due { return cal.isDateInToday(due) && !r.done } else { return false }
        }
        let yesterdayTodos = reminders.filter { r in
            if let due = r.due { return due >= startOfYesterday && due < startOfToday && !r.done } else { return false }
        }
        return [
            "today": buildContext_daySection(date: Date(), foods: todayFoods, bills: todayBills, todos: todayTodos, fmt: fmt),
            "yesterday": buildContext_daySection(date: startOfYesterday, foods: yesterdayFoods, bills: yesterdayBills, todos: yesterdayTodos, fmt: fmt),
            "last7Days": buildContext_weekSection(weekFoods: weekFoodEntries, weekBills: weekBillEntries, startOf7DaysAgo: startOf7DaysAgo, fmt: fmt),
            "health": buildContext_healthSection(fmt: fmt),
            "upcomingTodos": buildContext_upcomingTodosSection(fmt: fmt),
            "activeTodos": buildContext_activeTodosSection(fmt: fmt),
            // —— 最近记录列表（按时间倒序，含 id）—— agent 需要用 id 做 update 工具调用（upsert）。
            // 上限 10 条/类，既覆盖"刚才记的那条"又不让 context 过大。
            "recentFoods": foods.sorted { $0.date > $1.date }.prefix(10).map { buildContext_foodDict($0, fmt: fmt) },
            "recentBills": bills.sorted { $0.time > $1.time }.prefix(10).map { buildContext_billDict($0, fmt: fmt) },
            "recentReminders": reminders.sorted { ($0.due ?? .distantPast) > ($1.due ?? .distantPast) }.prefix(10).map { buildContext_todoDict($0, fmt: fmt) },
            "recentHealth": healths.sorted { $0.date > $1.date }.prefix(10).map { buildContext_healthDict($0, fmt: fmt) },
            "merchantRules": merchantMetas.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }.prefix(20).map { buildContext_merchantDict($0) },
            "recentRecognitions": recognitions.prefix(10).map { buildContext_recognitionDict($0, fmt: fmt) },
            // —— 饮水与周期规则（v10/v9 模型，buildContext 之前漏了导致 agent 第一句话看不到）——
            "recentWaters": waters.prefix(20).map { ["id": $0.syncId.uuidString, "amount": $0.amount, "date": fmt.string(from: $0.date)] },
            "recurringRules": recurringRules.map { ["id": $0.syncId.uuidString, "merchant": $0.merchant, "amount": $0.amount, "category": $0.category, "isIncome": $0.isIncome, "cycleRaw": $0.cycleRaw ?? "monthly", "dayOfMonth": $0.dayOfMonth, "note": $0.note] }
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

    private func buildContext_weekSection(weekFoods: [FoodEntry], weekBills: [Bill], startOf7DaysAgo: Date, fmt: ISO8601DateFormatter) -> [String: Any] {
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

    private func buildContext_healthSection(fmt: ISO8601DateFormatter) -> [String: Any] {
        let latestMetrics: [String: [String: Any]] = Dictionary(grouping: healths, by: { $0.metric })
            .mapValues { records -> [String: Any] in
                let r = records.max(by: { $0.date < $1.date })!
                return ["value": r.value, "unit": r.unit, "date": fmt.string(from: r.date)]
            }
        return [
            "stepsToday": health.stepsToday,
            "activeEnergyToday": health.activeEnergyToday,
            "latestMetrics": latestMetrics
        ]
    }

    private func buildContext_upcomingTodosSection(fmt: ISO8601DateFormatter) -> [[String: Any]] {
        let upcoming = reminders
            .filter { !$0.done && ($0.due ?? .distantPast) > Date() }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(5)
        return Array(upcoming).map { buildContext_todoDict($0, fmt: fmt) }
    }

    private func buildContext_activeTodosSection(fmt: ISO8601DateFormatter) -> [[String: Any]] {
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
