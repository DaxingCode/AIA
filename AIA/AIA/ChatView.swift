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
    @Query(sort: \ChatMessage.createdAt, order: .forward) private var messages: [ChatMessage]
    @StateObject private var health = HealthManager.shared
    @Environment(\.modelContext) private var context

    @State private var input = ""

    // 智能问答 Agent 总开关（与「云同步」同组，在设置页控制）。默认关，零污染。
    @AppStorage("aia.agentEnabled") private var agentEnabled: Bool = false
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

    // 输入栏扩展功能（拍照/相册/文件）
    @State private var showInputActions = false
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var showFileImporter = false
    @State private var fileImportCoverItem: CameraCoverItem?
    @State private var fileImportErrorMessage: String?

    init(prefill: String? = nil, autostartVoice: Bool = false) {
        self.prefill = prefill
        self.autostartVoice = autostartVoice
        #if DEBUG
        print("[ChatView] init prefill=\(prefill ?? "nil") autostartVoice=\(autostartVoice)")
        #endif
    }

    // 当前页面动态生成的阿宝招呼（不持久化），时间戳固定为进入页面时最后一条历史+1秒，
    // 这样新消息时间更晚，会自然把招呼顶上去，而不是永远钉在底部。
    @State private var greetingMessage: ChatMessage?

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
                                // 时间戳固定在「当前历史最后一条 + 1 秒」，让它停在对话流里；
                                // 之后不再被推后，用户回复时新消息排在它下方，它自然被顶到上方。
                                let date = messages.last?.createdAt.addingTimeInterval(1) ?? Date()
                                greetingMessage = ChatMessage(role: .ai, text: buildGreeting(), createdAt: date)
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
                    // 键盘弹出时把最新消息滚入可见区，避免被输入栏/键盘遮挡。
                    // 延迟 0.30s 等键盘动画完成，否则 scrollTo 会被弹出的键盘压住。
                    if focused {
                        scrollToBottom(proxy: proxy, delay: 0.30)
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
                            .foregroundStyle(AIATheme.ink)
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
                            recognizer.stop()
                        } else {
                            isInputFocused = false
                            recognizer.start()
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
                        recognizer.start()
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
                    recognizer.start()
                }
            }
        }
        .onDisappear { recognizer.stop() }
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .fullScreenCover(item: $fileImportCoverItem) { item in
            switch item {
            case .recognizing:
                ProgressView("识别中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
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
    }

    /// 阿宝招呼：每次进入页面时根据本地数据与用户习惯实时生成（不持久化，避免重复堆积）。
    private var greeting: String { buildGreeting() }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        if let pending = parseFoodConfirm(m.text) {
            foodConfirmBubble(pending, message: m)
        } else {
            messageBubble(text: m.text, isUser: m.role == .user)
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
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pending.meal) · \(pending.name) · \(pending.portion)")
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
                Text("约 \(Int(pending.cal)) kcal　蛋白质 \(String(format: "%.1f", pending.protein))g　碳水 \(String(format: "%.1f", pending.carbs))g　脂肪 \(String(format: "%.1f", pending.fat))g")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                if let amount = pending.amount {
                    Text("支出 ¥\(String(format: "%.2f", amount)) 已保留")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                }
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
        .background(AIATheme.dietBG)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button {
                UIPasteboard.general.string = "\(pending.meal) · \(pending.name) · \(pending.portion) · \(Int(pending.cal)) kcal"
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
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
        let foodIcon = ["🍽", "🍜", "🍚", "🥗", "🍔", "🍱"].randomElement() ?? "🍽"
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
            messageBubble(text: text, isUser: false)
            Spacer(minLength: 28)
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                 removal: .opacity))
    }

    private func messageBubble(text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 28) }
            Text(text)
                .font(.system(size: 13.3))
                .foregroundStyle(isUser ? .white : .primary)
                .textSelection(.enabled)
                .padding(10)
                .background(isUser ? AIATheme.blue : AIATheme.billBG)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
            if !isUser { Spacer(minLength: 28) }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                 removal: .opacity))
    }

    /// 基于用户的习惯/本地数据生成招呼文案。
    /// 习惯来源：近 14 天饮食记录推算的常用早餐时段、今日待办、健康数据等。
    /// 文案力求像朋友关心而非机器播报。
    private func buildGreeting() -> String {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)

        let opening: String
        switch hour {
        case 5..<11:  opening = "早上好呀"
        case 11..<14: opening = "中午好"
        case 14..<18: opening = "下午好"
        case 18..<23: opening = "晚上好"
        default:      opening = "这么晚还没休息呀"
        }

        var sentences: [String] = []
        sentences.append("\(opening)，我是阿宝～")

        // 习惯 1：近 14 天推算的常用早餐时段
        let since = cal.date(byAdding: .day, value: -14, to: now) ?? now
        let recentFoods = foods.filter { $0.date >= since }
        let bfHours = recentFoods.filter { $0.meal == "早餐" }.map { cal.component(.hour, from: $0.date) }
        let commonBF = bfHours.isEmpty ? nil : Int(round(Double(bfHours.reduce(0, +)) / Double(bfHours.count)))

        let todayFoods = foods.filter { cal.isDateInToday($0.date) }
        let todayBF = todayFoods.first { $0.meal == "早餐" }

        if let commonBF, hour >= commonBF, todayBF == nil {
            sentences.append("平时你差不多 \(commonBF) 点就吃过早餐了，今天还没见你记呢，记得吃点好的哦。")
        } else if let todayBF {
            sentences.append("早餐的「\(todayBF.name)」我已经帮你记好啦，开启元气满满的一天。")
        }

        // 习惯 2：今日待办（只引用「今天到期且未完成且还没过期」的待办，避免拿过期待办当示例）
        let upcomingToday = reminders.filter { r in
            guard let due = r.due else { return false }
            return cal.isDateInToday(due) && !r.done && due >= now
        }
        if let next = upcomingToday.min(by: { $0.due! < $1.due! }) {
            sentences.append("对了，你今天还有 \(upcomingToday.count) 件事没做，像「\(next.title)」这种，需要我到点提醒你吗？")
        }

        // 习惯 3：健康步数（仅在已授权读到时展示）
        if health.stepsToday > 0 {
            sentences.append("今天已经走了 \(health.stepsToday) 步，动得不错，继续保持呀～")
        }

        if sentences.count == 1 {
            sentences.append("今天想记录点什么，或者随便聊两句，都可以随时叫我。")
        }

        return sentences.joined(separator: " ")
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
            let isToday = !isYesterday && !isRecent

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
            let list = upcoming.prefix(3).map { "· \($0.title)" }.joined(separator: "\n")
            let more = upcoming.count > 3 ? "\n…还有 \(upcoming.count - 3) 件" : ""
            return "你还有 \(upcoming.count) 件事没做：\n\(list)\(more)\n需要我到点提醒你吗？"
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

        guard let (title, due) = parseTodoCreate(text) else { return nil }
        // 防重复：短时间内重复发送同一句话不重复入库
        if ChatView.checkDuplicateAndRegister(text, type: "todo") {
            return "这个提醒你刚记过啦，我就不重复记了～"
        }
        // 内容级去重：检查 24h 内是否有同标题待办
        if DataDeduplicator.isDuplicateReminder(title: title, context: context) {
            return "这个提醒你刚记过啦，我就不重复记了～"
        }
        let r = Reminder(title: title, due: due, imageName: nil)
        DefaultReminderSettings.shared.apply(to: r)
        context.insert(r)
        ReminderNotificationManager.schedule(r)
        try? context.save()
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        return "\(opener)：⏰ 已添加待办「\(title)」，我会在 \(formatShortDateTime(due)) 提醒你。"
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
    private static var recentCreations: [(key: String, at: Date)] = []
    private static let dedupWindow: TimeInterval = 86400 // 24 小时（原 3 分钟，但用户测试间隔可能更长）

    /// 计算去重键：去掉金额与记账 / 提醒动词、语气助词后，保留餐次 / 内容词。
    /// 不同餐次（如「晚餐」vs「午餐」）键不同，不会互相误判；同一句话重复发送则键相同。
    private static func chatDedupKey(_ text: String, type: String) -> String {
        var t = text.lowercased()
        t = t.replacingOccurrences(of: #"\d+(\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
                                   with: "", options: .regularExpression)
        let verbs = ["记一笔","记账","记一下","记个","记下来","帮我记","给我记","添加","增加","创建",
                     "新建","保存","录入","花了","花掉","付了","付给","买了","消费","支出","账单",
                     "花销","开销","扫码付","提醒我","提醒","吃了","喝了","喝","吃"]
        for v in verbs { t = t.replacingOccurrences(of: v, with: "") }
        t = t.replacingOccurrences(of: #"[的了在给和去个吧啊呢哦嘛]"#, with: "", options: .regularExpression)
        return "\(type):\(t.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// 命中最近一次相同内容 → 返回 true（调用方不应再入库）；否则登记并返回 false。
    private static func checkDuplicateAndRegister(_ text: String, type: String) -> Bool {
        let now = Date()
        recentCreations.removeAll { now.timeIntervalSince($0.at) > dedupWindow }
        let key = chatDedupKey(text, type: type)
        if recentCreations.contains(where: { $0.key == key }) { return true }
        recentCreations.append((key, now))
        return false
    }

    /// 本地记账（DB 优先、AI 兜底）：解析「记一笔星巴克35」「付了美团28」这类明确账单意图，
    /// 商户分类优先查本地 MerchantMeta 经验库，命中即复用、不调 AI；未命中给"其他"。
    /// 触发条件：① 含明确记账动词（记一笔/花了/付了…）且含金额；② 含食物词且含「金额+货币单位」（如「午饭吃了碗牛肉面32块」）。
    /// 纯饮食（无金额，如「喝了一杯奶茶」）仍返回 nil，走 food 路径，避免误吞饮食/问句。
    private func createBillLocally(from text: String) -> String? {
        let lower = text.lowercased()
        // 必须先有金额，否则不是本地可解析的账单（纯饮食/问句等交给其它分支）
        guard let amount = extractAmount(text) else { return nil }
        // 本地建账单的两种触发条件：
        // 1) 显式账单关键词（记一笔/花了/付了…）；
        // 2) 食物+金额（如「午饭吃了碗牛肉面32块」），用户既说了吃什么又给了金额，明确是一笔花费。
        //    金额需带货币单位（元/块/￥/¥），以排除「1500大卡」这类把热量当金额误建账单的情况。
        // 纯饮食（如「喝了一杯奶茶」）因无金额已在上面返回 nil，仍走 food 路径，不会误建账单。
        let billKw = ["记一笔", "记账", "花了", "花掉", "付了", "付给", "买了", "消费", "支出", "账单", "花销", "开销", "扫码付"]
        let hasExplicitBill = billKw.contains(where: { lower.contains($0) })
        let hasMoneyUnit = lower.contains("元") || lower.contains("块") || lower.contains("￥") || lower.contains("¥")
        let isFoodWithAmount = hasRawFoodIntent(text) && hasMoneyUnit
        guard hasExplicitBill || isFoodWithAmount else { return nil }

        // 商户名：去掉金额数字及单位、去掉记账关键词、去掉时间/饮食动词与语气助词后剩下的文本
        var merchant = text
        // 去掉「花」作花费动词且后接金额（如「汉堡花10元」），放在金额提取前，避免残留成商户名；
        // 用占位符保护爆米花等含「花」菜品（stripSpendPhrase 已做保护）。
        merchant = ChatView.stripSpendPhrase(merchant)
        merchant = merchant.replacingOccurrences(of: #"\d+(\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
                                                 with: "", options: .regularExpression)
        for kw in billKw { merchant = merchant.replacingOccurrences(of: kw, with: "") }
        // 多字词（时间/餐次/饮食动词/食物量词）用分组 Alternation；务必放在单字语气助词之前或与之并列
        merchant = merchant.replacingOccurrences(of: #"(今晚|今天|明天|早上|上午|中午|下午|晚上|刚才|早饭|午饭|晚饭|早餐|午餐|晚餐|夜宵|加餐|零食|宵夜|吃了|喝了|喝|吃|买|碗|杯|个|盘|份|根|片|串|块|勺)"#,
                                                 with: "", options: .regularExpression)
        // 单字语气助词
        merchant = merchant.replacingOccurrences(of: #"[的了在给和去个吧啊呢哦嘛]"#,
                                                 with: "", options: .regularExpression)
        // 去掉残留的数字与标点，得到干净商户名
        merchant = merchant.replacingOccurrences(of: #"[\d,\.，。、\s]+"#,
                                                 with: "", options: .regularExpression)
        merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        // 清洗后若仍为纯餐次/时间词（非真实商户），回退到"其他消费"
        let nonMerchantWords: Set<String> = ["晚餐", "早餐", "午饭", "午餐", "夜宵", "加餐", "零食", "宵夜", "饭", "餐"]
        if merchant.isEmpty || nonMerchantWords.contains(merchant) { merchant = "其他消费" }

        // 收入关键词识别（工资/报销/退款等），本地记账场景云端常漏判为支出
        let incomeKeywords = ["工资","薪资","薪水","收入","报销","退款","返现","奖金","分红","利息","红包","补贴","收款","进账","提成","劳务费","兼职"]
        let isIncomeText = incomeKeywords.contains { lower.contains($0) || merchant.contains($0) }
        // DB 优先：本地经验库命中则直接用其分类，跳过 AI
        var (cat, metaIncome) = MerchantMetaStore.lookup(merchant, in: context) ?? ("其他", false)
        // 经验库未命中时，再用关键词提示兜底：餐次词（晚餐/夜宵/午饭…）应归「餐饮」而非「其他」。
        // 注意：merchant 清洗后可能是"其他消费"，但原始 text 仍含"晚餐"等餐次词，故同时传入 text 判断。
        if cat == "其他", let hint = RecognizeService.mealCategoryHint(merchant + " " + text) {
            cat = hint
        }
        let isIncome = isIncomeText || metaIncome
        let category = (isIncome && cat == "其他") ? "收入" : cat
        // 防重复：短时间内重复发送同一句话不重复入库
        if ChatView.checkDuplicateAndRegister(text, type: "bill") {
            return "这笔记过啦，我就不重复记了～"
        }
        // 内容级去重：检查 24h 内是否有同商户 + 同金额
        if DataDeduplicator.isDuplicateBill(merchant: merchant, amount: amount, time: .now, context: context) {
            return "这笔记过啦，我就不重复记了～"
        }
        let bill = Bill(merchant: merchant, amount: amount, category: category,
                        time: .now, isIncome: isIncome, imageName: nil)
        context.insert(bill)
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
        let icon = isIncome ? "💰" : "🧾"
        return "\(opener)：\(icon) 已添加\(isIncome ? "收入" : "支出")「\(merchant)」¥\(String(format: "%.2f", amount))"
    }

    /// 本地创建饮食：食物类文本优先从本地营养库（硬编码 + 用户缓存）估算热量，
    /// 命中即直接建记录，无需等云端返回。未命中返回 nil，由外层走云端识别。
    /// 仅处理「早餐吃了一碗燕麦粥」这类明确饮食意图；有更新/删除/完成意图时返回 nil 交给云端。
    private func createFoodLocally(from text: String) -> String? {
        if ChatView.hasExplicitUpdateIntent(text) ||
           ChatView.hasExplicitDeleteIntent(text) ||
           ChatView.hasExplicitCompleteIntent(text) {
            return nil
        }
        let meal = ChatView.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        let items = ChatView.parseFoodItems(from: text)
        guard !items.isEmpty else { return nil }

        // 如果用户没给重量/份量，先追问不急着入库
        if !ChatView.hasWeightInfo(text) {
            let firstItem = items[0]
            pendingWeightFood = (firstItem.name, meal)
            return nil
        }

        // 所有项必须都能本地命中才走本地直存；任一缺营养就交给云端查询路径。
        var entries: [FoodEntry] = []
        var summaries: [String] = []
        var totalCal: Double = 0
        let foodIcon = ["🍽", "🍜", "🍚", "🥗", "🍔", "🍱"].randomElement() ?? "🍽"

        for (name, weight, portion) in items {
            let ref: FoodRef
            if let builtin = NutritionLibrary.shared.match(name) {
                ref = builtin
            } else if let meta = FoodMetaStore.lookup(name, in: context) {
                ref = FoodRef(name: meta.displayName.isEmpty ? name : meta.displayName,
                              kcal: meta.kcal, protein: meta.protein, carbs: meta.carbs, fat: meta.fat,
                              fiber: meta.fiber, sugar: meta.sugar, sodium: meta.sodium)
            } else {
                return nil
            }

            let ratio = weight / 100.0
            let cal = ref.kcal * ratio
            let protein = ref.protein * ratio
            let carbs = ref.carbs * ratio
            let fat = ref.fat * ratio
            let fiber = ref.fiber * ratio
            let sugar = ref.sugar * ratio
            let sodium = ref.sodium * ratio

            let entry = FoodEntry(name: name, calories: cal, protein: protein, carbs: carbs, fat: fat,
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
            // 展示全部 7 项营养：热量/蛋白/碳水/脂肪/膳食纤维/糖/钠
            // 用「·」串联避免挤在一行；macro 值保留 1 位小数（钠 0 位），0 值也显示以让用户看到全貌
            let macros = String(format: "蛋白 %.1fg · 碳水 %.1fg · 脂肪 %.1fg · 纤维 %.1fg · 糖 %.1fg · 钠 %.0fmg",
                                protein, carbs, fat, fiber, sugar, sodium)
            summaries.append("\(foodIcon) \(meal)「\(name)」\(Int(cal)) kcal（\(portion)）\n  \(macros)")
        }

        // 防重复：以整句话做 key（短期窗口）
        if ChatView.checkDuplicateAndRegister(text, type: "food") {
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
        let disclaimer = "\n\n结果仅供参考，如需修改可到\"饮食记录\"页面进行修改。"
        return summaries.count == 1
            ? "\(opener)：\(summaries[0])" + disclaimer
            : "\(opener)：\n" + summaries.joined(separator: "\n") + disclaimer
    }

    /// 用户回复了重量后，组合成完整的食物文本再走正常创建流程。
    private func createFoodWithWeight(name: String, text: String, meal: String) -> String {
        // 构建合成文本让 createFoodLocally 复用同一套解析逻辑
        let syntheticText = "\(meal)吃了\(text)\(name)"
        if let result = createFoodLocally(from: syntheticText) {
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
        let ref: FoodRef
        if let local = NutritionLibrary.shared.match(trimmed) {
            ref = local
        } else if let meta = FoodMetaStore.lookup(trimmed, in: context) {
            ref = FoodRef(name: meta.displayName.isEmpty ? trimmed : meta.displayName,
                          kcal: meta.kcal, protein: meta.protein, carbs: meta.carbs, fat: meta.fat,
                          fiber: meta.fiber, sugar: meta.sugar, sodium: meta.sodium)
        } else {
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
        let meal = ChatView.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
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
        let meal = ChatView.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
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
        guard let (ml, display) = ChatView.parseWaterIntake(text) else { return nil }
        let meal = ChatView.mealFromText(text) ?? ChatView.defaultMeal(for: .now)

        // 防重复
        if ChatView.checkDuplicateAndRegister(text, type: "water") {
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
        let meal = ChatView.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
        let items = ChatView.parseFoodItems(from: text)
        guard !items.isEmpty else { return localReply(for: text) }

        // 1) 优先专项查询每个食物的营养（更可靠，不易被上下文带偏）
        var entries: [FoodEntry] = []
        var summaries: [String] = []
        var totalCal: Double = 0
        let foodIcon = ["🍽", "🍜", "🍚", "🥗", "🍔", "🍱"].randomElement() ?? "🍽"

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
    private static func stripSpendPhrase(_ text: String) -> String {
        let protectedFoods = ["爆米花", "花菜", "花生", "花卷", "花蛤", "花螺", "红花"]
        let placeholders = ["ZFA", "ZFB", "ZFC", "ZFD", "ZFE", "ZFF", "ZFG"]
        var t = text
        for (i, f) in protectedFoods.enumerated() {
            if t.contains(f) {
                t = t.replacingOccurrences(of: f, with: placeholders[i])
            }
        }
        // 先清「花[了]? + 金额」裸写法，再清其它账单关键词
        let spendPattern = #"花[了]?\s*\d+(\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?|花了?|花掉|付了?|付给|消费|支出|账单|花销|开销|扫码付|记一笔|记账|买了"#
        t = t.replacingOccurrences(of: spendPattern, with: "", options: .regularExpression)
        // 再清残留的所有数字金额（含货币单位，单位可选）
        t = t.replacingOccurrences(of: #"\d+(\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
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
    private static func stripBareHuaAmount(_ text: String) -> String {
        let protectedFoods = ["爆米花", "花菜", "花生", "花卷", "花蛤", "花螺", "红花"]
        let placeholders = ["ZFA", "ZFB", "ZFC", "ZFD", "ZFE", "ZFF", "ZFG"]
        var t = text
        for (i, f) in protectedFoods.enumerated() {
            if t.contains(f) { t = t.replacingOccurrences(of: f, with: placeholders[i]) }
        }
        t = t.replacingOccurrences(of: #"花[了]?\s*\d+(\.\d+)?\s*(元|块|元钱|块钱|￥|¥)?"#,
                                   with: "", options: .regularExpression)
        for (i, f) in protectedFoods.enumerated() {
            t = t.replacingOccurrences(of: placeholders[i], with: f)
        }
        return t
    }

    private static func parseFoodNameAndWeight(_ text: String) -> (name: String, weight: Double, portion: String)? {
        var t = text

        // 先去掉餐次词，避免餐次混入食物名
        for meal in ["早餐", "早饭", "早上", "今早",
                     "午餐", "午饭", "中午", "正午",
                     "晚餐", "晚饭", "晚上", "今晚",
                     "夜宵", "加餐", "点心", "零食"] {
            t = t.replacingOccurrences(of: meal, with: "")
        }

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
    private static func parseFoodItems(from text: String) -> [(name: String, weight: Double, portion: String)] {
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

    /// 解析文本中的饮水量。返回 (amount_ml, displayText)。
    /// 命中条件：含「水」+ 含喝类动词（喝/饮/灌） + 不含其他真实食物词。
    /// 单位映射：升/L→1000、毫升/ml→1、杯→250、瓶→500、壶→1000、碗→300。
    /// 示例：
    ///   "喝了 1 升水"    → (1000, "1升水")
    ///   "喝了 500ml 水"  → (500,  "500ml水")
    ///   "喝了两杯水"     → (500,  "2杯水")
    ///   "喝了 1.5 升水"  → (1500, "1.5升水")
    ///   "喝水"           → (250,  "1杯水")
    private static func parseWaterIntake(_ text: String) -> (ml: Double, display: String)? {
        // 必须含「水」+ 喝类动词
        let hasWater = text.contains("水") || text.contains("汤") // 汤也走这条罕见 case
        let hasDrinkVerb = text.contains("喝") || text.contains("饮") || text.contains("灌")
        guard hasWater, hasDrinkVerb else { return nil }

        // 排除「汤/糖水」以外的「其他真实食物」：含蛋/饭/面/菜/肉/鱼/鸡/奶/粥/麦/汤 等就当复合饮食场景，不走水路径
        let foodKeywords = ["蛋", "饭", "面", "菜", "肉", "鱼", "鸡", "鸭", "牛", "羊", "猪", "奶",
                            "粥", "麦", "汤", "果", "豆", "瓜", "薯", "汤圆", "面包", "饼", "燕"]
        for kw in foodKeywords where text.contains(kw) {
            // "水" 在末尾时允许（如 "喝了 1 碗汤 1 杯水"），否则整句有食物就走食物路径
            // 这里保守处理：含食物词就直接放弃水路径，避免「喝了 1 碗燕麦粥 1 杯水」漏记食物
            return nil
        }

        // 单位 → 毫升映射（按常见容量排序，确保长的先匹配，避免「ml」被「m」截胡）
        let units: [(String, Double)] = [
            ("毫升", 1), ("mL", 1), ("ML", 1), ("ml", 1),
            ("升", 1000), ("L", 1000), ("l", 1000),
            ("杯", 250),
            ("瓶", 500),
            ("壶", 1000),
            ("碗", 300),
        ]

        let ns = text as NSString
        // 1) 优先匹配「数量+单位」组合
        for (unit, mlPerUnit) in units {
            let escaped = NSRegularExpression.escapedPattern(for: unit)
            let pattern = "([\\d.]+|[一二两三四五六七八九十百千]+)\\s*\(escaped)"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let numStr = ns.substring(with: m.range(at: 1))
                let count: Double
                if let n = parseChineseNumber(numStr) { count = Double(n) }
                else if let d = Double(numStr) { count = d }
                else { count = 1 }
                return (count * mlPerUnit, "\(numStr)\(unit)水")
            }
        }

        // 2) 没数量+单位：单纯「喝水」「饮水」「灌水」 → 默认 1 杯（250ml）
        if text.contains("喝水") || text.contains("饮水") || text.contains("灌水") {
            return (250, "1杯水")
        }

        return nil
    }

    /// 从文本提取金额数字（如 35 / 12.5）。
    /// 优先匹配带金额单位（元/块/￥/¥）的数字；都没有单位时取最后一个数字（金额常在句末，如「记一笔星巴克35」）。
    private func extractAmount(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(\.\d+)?)"#) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        // 优先带金额单位的数字
        for m in matches {
            let r = m.range(at: 1)
            let s = ns.substring(with: r)
            let afterStart = min(r.location + r.length, ns.length)
            let after = ns.substring(from: afterStart)
            if after.hasPrefix("元") || after.hasPrefix("块") || after.hasPrefix("￥") || after.hasPrefix("¥") {
                return Double(s)
            }
        }
        // 否则取最后一个数字（句末金额）
        if let last = matches.last {
            return Double(ns.substring(with: last.range(at: 1)))
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

    /// 把中文数字（如「二」「十二」「两」）转成 Int；阿拉伯数字直接返回。
    private static func parseChineseNumber(_ string: String) -> Int? {
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
        }

        // 提取标题：先移除前缀动词，再移除日期、时段词和「提醒/待办」后缀
        var title = text
        let prefixes = ["帮我增加一个", "帮我添加一个", "帮我创建一个", "帮我新建一个", "帮我设置一个", "帮我记一个",
                        "增加一个", "添加一个", "创建一个", "新建一个", "设置一个", "记一个",
                        "帮我增加", "帮我添加", "帮我创建", "帮我新建", "帮我设置", "帮我记",
                        "增加", "添加", "创建", "新建", "设置", "记"]
        for p in prefixes where title.hasPrefix(p) {
            title = String(title.dropFirst(p.count))
            break
        }
        title = title.replacingOccurrences(of: datePattern, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "明天|后天|明日", with: "", options: .regularExpression)
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
                if isQuestionLike(t) {
                    let dataContext = buildContext()
                    let reply = agentEnabled
                        ? try await RecognizeService.agentChat(text: t, context: dataContext, userId: agentUserId)
                        : try await RecognizeService.chat(text: t, context: dataContext)
                    responseText = reply.isEmpty ? localReply(for: t) : reply
                } else {
                    // 1. 待办意图优先：含「提醒/待办/记得/叫」等明确动词时直接本地建待办，
                    //    避免「晚上提醒我吃饭」被食物分支误吞。
                    if let localTodo = createTodoLocally(from: t) {
                        responseText = localTodo
                    }
                    // 2. 本地能解析的明确账单意图（如「记一笔星巴克35」「付了美团28」）直接本地建，复用 MerchantMeta 分类，跳过 AI。
                    else if let localBill = createBillLocally(from: t) {
                        // 账单已创建；若该文本同时含食物意图（如「晚餐吃了汉堡花了10元」），
                        // 本地营养库命中则直接建饮食；未命中则先记账单，再异步联网查营养并以确认卡片形式让用户确认入库。
                        if hasRawFoodIntent(t) {
                            if let localFood = createFoodLocally(from: t) {
                                responseText = localBill + "\n" + stripOpener(localFood)
                            } else {
                                responseText = localBill
                                // 异步联网查营养，成功后发送聊天气泡内确认卡片（用户点确认才写入饮食库）
                                Task { @MainActor in
                                    await sendFoodConfirmCard(text: t)
                                }
                            }
                        } else {
                            responseText = localBill
                        }
                    }
                    // 2.5. 饮水意图：含「喝+水/饮+水」+ 不含其他真实食物词时，直接走饮水路径（不查营养库、不走云端），
                    //      避免「喝了 1 升水」被误识别为 food 然后去云端查「水」的营养失败被丢。
                    else if let waterMsg = createWaterIntake(from: t) {
                        responseText = waterMsg
                    }
                    // 2.6. 等待重量回复：之前有食物待补充重量（如用户说了「吃了苹果」没给重量）
                    // 注意：pendingWeightFood 不在分支开头清空，失败时保留以便用户重试
                    else if let pending = pendingWeightFood {
                        // 取消意图
                        let cancelWords = ["不吃了", "不要了", "算了", "不用了", "没吃", "取消"]
                        if cancelWords.contains(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            pendingWeightFood = nil
                            responseText = "好嘞，那就不记「\(pending.name)」啦～"
                        }
                        // 用户明确回复了重量 → 组合创建
                        else if let (w, p) = ChatView.parseWeightOnly(t) {
                            pendingWeightFood = nil  // 成功才清
                            responseText = createFoodWithWeight(name: pending.name, text: p, meal: pending.meal)
                        }
                        // 用户说了一个新食物 → 替代 pending，走正常食物分支
                        else if isFoodLike(t) {
                            pendingWeightFood = nil
                            if let localFood = createFoodLocally(from: t) {
                                responseText = localFood
                            } else if let newPending = self.pendingWeightFood {
                                responseText = "你大概吃了多少\(newPending.name)呀？😊"
                            } else {
                                responseText = await createFoodFromCloud(text: t, recentMessages: recentMessages)
                            }
                        }
                        // 什么都没解析到 → 不清 pending，让用户重试
                        else {
                            responseText = "没明白你说的，你大概吃了多少\(pending.name)呀？（比如\"两个\"或\"200克\"）😊"
                        }
                    }
                    // 3. 食物意图：含「吃/喝/奶茶/咖啡/饭」等词，先尝试本地营养库估算，
                    //    命中则直接创建记录；未命中且非 pending 再走云端查询，避免模型被上下文误导。
                    else if isFoodLike(t) {
                        if let localFood = createFoodLocally(from: t) {
                            responseText = localFood
                        } else if let pending = pendingWeightFood {
                            // createFoodLocally 识别到食物但用户没给重量 → 追问
                            responseText = "你大概吃了多少\(pending.name)呀？😊"
                        } else {
                            responseText = await createFoodFromCloud(text: t, recentMessages: recentMessages)
                        }
                    } else {
                        // 4. 食物查询：用户只说食物名（如「苹果」「米饭」「牛肉的热量」），
                        //    不记录，只回复每100克营养数据。本地命中最快，未命中则联网查并缓存。
                        if let queryReply = await handleFoodQuery(t) {
                            responseText = queryReply
                        } else {
                            // 兜底：只有文本本身带有明确记录/创建意图，才走 parseText 保存记录；
                            // 否则（如"好的好的""嗯嗯""知道了"）强制走 AI 聊天，避免被上下文污染导致重复创建。
                            let hasCreateIntent = ChatView.hasExplicitCreateIntent(t)
                            if hasCreateIntent {
                                let (result, _) = try await RecognizeService.parseText(t, recentMessages: recentMessages)
                                let summary = saveFromResult(result, originalText: t)
                                if summary.isEmpty {
                                    let dataContext = buildContext()
                                    let reply = agentEnabled
                            ? try await RecognizeService.agentChat(text: t, context: dataContext, userId: agentUserId)
                            : try await RecognizeService.chat(text: t, context: dataContext)
                                    responseText = reply.isEmpty ? localReply(for: t) : reply
                                } else {
                                    let opener = chatConfirmOpeners.randomElement() ?? "记好啦"
                                    responseText = "\(opener)：\n" + summary.joined(separator: "\n")
                                }
                            } else {
                                let dataContext = buildContext()
                                let reply = agentEnabled
                            ? try await RecognizeService.agentChat(text: t, context: dataContext, userId: agentUserId)
                            : try await RecognizeService.chat(text: t, context: dataContext)
                                responseText = reply.isEmpty ? localReply(for: t) : reply
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

    /// 简单判断是否为疑问句，疑问句优先走 AI 聊天而非记录意图。
    private func isQuestionLike(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let questionMarks = ["?", "？"]
        let questionWords = ["几点", "多少", "吗", "嘛", "呢", "怎么", "为什么", "什么", "如何", "好不", "行不", "能不能", "会吗", "好吗", "对吗", "谁", "哪位", "哪里", "哪", "请问", "几"]
        if questionMarks.contains(where: { t.hasSuffix($0) }) { return true }
        if questionWords.contains(where: { t.contains($0) }) { return true }
        return false
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
        return ChatView.mealFromText(text) ?? ChatView.defaultMeal(for: .now)
    }

    private static func normalizeMeal(_ meal: String) -> String {
        let m = meal.trimmingCharacters(in: .whitespaces)
        if m.contains("早") { return "早餐" }
        if m.contains("午") { return "午餐" }
        if m.contains("晚") || m.contains("夜") { return "晚餐" }
        return "加餐"
    }

    private static func mealFromText(_ text: String) -> String? {
        let lowered = text.lowercased()
        if lowered.contains("早餐") || lowered.contains("早饭") || lowered.contains("早上") || lowered.contains("今早") { return "早餐" }
        if lowered.contains("午餐") || lowered.contains("午饭") || lowered.contains("中午") || lowered.contains("正午") { return "午餐" }
        if lowered.contains("晚餐") || lowered.contains("晚饭") || lowered.contains("晚上") || lowered.contains("今晚") || lowered.contains("夜宵") { return "晚餐" }
        if lowered.contains("加餐") || lowered.contains("点心") || lowered.contains("零食") { return "加餐" }
        return nil
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
            for food in result.foodList {
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
                let income = RecognitionSaver.isIncomeSignal(category: category, merchant: merchant, rawText: originalText)

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
                        summary.append("🔄 已更新「\(merchant)」：¥\(String(format: "%.2f", amount))")
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
                    summary.append("🧾 \(income ? "收入" : "支出")「\(merchant)」¥\(String(format: "%.2f", amount))")
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
        let fmt = ISO8601DateFormatter()
        let startOfToday = cal.startOfDay(for: Date())

        let todayFoods = foods.filter { cal.isDateInToday($0.date) }
        let todayBills = bills.filter { cal.isDateInToday($0.time) }
        let todayTodos = reminders.filter { r in
            if let due = r.due { return cal.isDateInToday(due) && !r.done } else { return false }
        }

        // 昨日（用于回答"昨天"类问题）
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let endOfYesterday = startOfToday
        let yesterdayFoods = foods.filter { $0.date >= startOfYesterday && $0.date < endOfYesterday }
        let yesterdayBills = bills.filter { $0.time >= startOfYesterday && $0.time < endOfYesterday }
        let yesterdayTodos = reminders.filter { r in
            if let due = r.due { return due >= startOfYesterday && due < endOfYesterday && !r.done } else { return false }
        }

        // 最近 7 天（含今天）的汇总，用于回答"最近"类问题
        let startOf7DaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday)!
        let weekFoodEntries = foods.filter { $0.date >= startOf7DaysAgo }
        let weekBillEntries = bills.filter { $0.time >= startOf7DaysAgo }
        let last7Days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: startOf7DaysAgo)! }

        let upcomingTodos = reminders
            .filter { !$0.done && ($0.due ?? .distantPast) > Date() }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(5)

        let activeTodos = reminders.filter { !$0.done }.prefix(10)

        // 最近的健康指标记录（按 metric 取最新一条），覆盖体重/身高/心率/体检等 SwiftData 数据
        let latestHealthMetrics: [String: [String: Any]] = Dictionary(grouping: healths, by: { $0.metric })
            .mapValues { records in
                let r = records.max(by: { $0.date < $1.date })!
                return ["value": r.value, "unit": r.unit, "date": fmt.string(from: r.date)] as [String: Any]
            }

        return [
            "today": [
                "date": fmt.string(from: Date()),
                "foods": todayFoods.map { [
                    "name": $0.name,
                    "calories": $0.calories,
                    "protein": $0.protein,
                    "carbs": $0.carbs,
                    "fat": $0.fat,
                    "meal": $0.meal,
                    "portion": $0.portion,
                    "date": fmt.string(from: $0.date)
                ] as [String: Any] },
                "totalCalories": todayFoods.reduce(0) { $0 + $1.calories },
                "totalProtein": todayFoods.reduce(0) { $0 + $1.protein },
                "totalCarbs": todayFoods.reduce(0) { $0 + $1.carbs },
                "totalFat": todayFoods.reduce(0) { $0 + $1.fat },
                "bills": todayBills.map { [
                    "merchant": $0.merchant,
                    "amount": $0.amount,
                    "category": $0.category,
                    "isIncome": $0.isIncome,
                    "time": fmt.string(from: $0.time),
                    "note": $0.note
                ] as [String: Any] },
                "totalExpense": todayBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount },
                "totalIncome": todayBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount },
                "todos": todayTodos.map { [
                    "title": $0.title,
                    "due": fmt.string(from: $0.due ?? Date()),
                    "priority": $0.priority
                ] as [String: Any] }
            ],
            "yesterday": [
                "date": fmt.string(from: startOfYesterday),
                "foods": yesterdayFoods.map { [
                    "name": $0.name,
                    "calories": $0.calories,
                    "protein": $0.protein,
                    "carbs": $0.carbs,
                    "fat": $0.fat,
                    "meal": $0.meal,
                    "portion": $0.portion,
                    "date": fmt.string(from: $0.date)
                ] as [String: Any] },
                "totalCalories": yesterdayFoods.reduce(0) { $0 + $1.calories },
                "totalProtein": yesterdayFoods.reduce(0) { $0 + $1.protein },
                "totalCarbs": yesterdayFoods.reduce(0) { $0 + $1.carbs },
                "totalFat": yesterdayFoods.reduce(0) { $0 + $1.fat },
                "bills": yesterdayBills.map { [
                    "merchant": $0.merchant,
                    "amount": $0.amount,
                    "category": $0.category,
                    "isIncome": $0.isIncome,
                    "time": fmt.string(from: $0.time),
                    "note": $0.note
                ] as [String: Any] },
                "totalExpense": yesterdayBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount },
                "totalIncome": yesterdayBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount },
                "todos": yesterdayTodos.map { [
                    "title": $0.title,
                    "due": fmt.string(from: $0.due ?? Date()),
                    "priority": $0.priority
                ] as [String: Any] }
            ],
            "last7Days": [
                "dateRange": "\(fmt.string(from: startOf7DaysAgo)) to \(fmt.string(from: Date()))",
                "totalCalories": weekFoodEntries.reduce(0) { $0 + $1.calories },
                "totalProtein": weekFoodEntries.reduce(0) { $0 + $1.protein },
                "totalCarbs": weekFoodEntries.reduce(0) { $0 + $1.carbs },
                "totalFat": weekFoodEntries.reduce(0) { $0 + $1.fat },
                "totalExpense": weekBillEntries.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount },
                "totalIncome": weekBillEntries.filter { $0.isIncome }.reduce(0) { $0 + $1.amount },
                "dailyFoods": last7Days.map { d -> [String: Any] in
                    let dayFoods = weekFoodEntries.filter { cal.isDate($0.date, inSameDayAs: d) }
                    return [
                        "date": fmt.string(from: d),
                        "totalCalories": dayFoods.reduce(0) { $0 + $1.calories },
                        "totalProtein": dayFoods.reduce(0) { $0 + $1.protein },
                        "totalCarbs": dayFoods.reduce(0) { $0 + $1.carbs },
                        "totalFat": dayFoods.reduce(0) { $0 + $1.fat }
                    ]
                },
                "dailyBills": last7Days.map { d -> [String: Any] in
                    let dayBills = weekBillEntries.filter { cal.isDate($0.time, inSameDayAs: d) }
                    return [
                        "date": fmt.string(from: d),
                        "totalExpense": dayBills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount },
                        "totalIncome": dayBills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount },
                        "bills": dayBills.map { [
                            "merchant": $0.merchant,
                            "amount": $0.amount,
                            "category": $0.category,
                            "isIncome": $0.isIncome,
                            "time": fmt.string(from: $0.time),
                            "note": $0.note
                        ] as [String: Any] }
                    ]
                }
            ],
            "health": [
                "stepsToday": health.stepsToday,
                "activeEnergyToday": health.activeEnergyToday,
                "latestMetrics": latestHealthMetrics
            ],
            "upcomingTodos": Array(upcomingTodos).map { [
                "title": $0.title,
                "due": fmt.string(from: $0.due ?? Date()),
                "priority": $0.priority
            ] as [String: Any] },
            "activeTodos": Array(activeTodos).map { [
                "title": $0.title,
                "due": fmt.string(from: $0.due ?? Date()),
                "priority": $0.priority,
                "repeatRule": $0.repeatRule
            ] as [String: Any] }
        ]
    }
}
