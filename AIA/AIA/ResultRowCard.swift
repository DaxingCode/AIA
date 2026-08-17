// ResultRowCard.swift
// 对话页识别结果卡片：代替旧的全屏确认页（ResultConfirmView sheet）。
// 一条 AI 消息里可包含多张「记录卡片」，支持三态：
//   ① 待确认态（syncId 为空，尚未入库）→ 只读预览 + 底部 {删除 编辑 保存}；
//      点「编辑」/点卡片展示区 = 先按识别结果入库、再弹 EditXxxView 整页弹窗；「保存」= 直接入库。
//   ② 已保存态（syncId 指向真实模型，按 syncId + !syncDeleted 取活对象）→ 只读展示 + 底部 {编辑 复制 删除}；
//      点「编辑」/点卡片展示区 = 弹 EditXxxView 整页弹窗。
//   ③ 已保存记录在「任一端」被删 → 卡片自动消失（双向同步，单一事实源）。
//
// 双向同步机制：已保存态卡片直接引用数据库真实模型实例（按 syncId 在 @Query 取 !syncDeleted 子集），
// 绝不用冻结 JSON 拷贝；in-place 编辑直接改真实实例字段（autosave 触发模块页 @Query 刷新），
// 删除走 SafeDelete.*（软删 syncDeleted=true），模块页 @Query(!syncDeleted) 自动不显示。
import SwiftUI
import SwiftData

// MARK: - 协议前缀与编解码

/// 对话页气泡里的识别结果协议前缀。ChatMessage.text = PREFIX + JSON(RecognitionResultPayload)。
let RECOGNITION_RESULT_PREFIX = "__RECOGNITION_RESULT__"

/// 对话页气泡里的「升级 Pro」引导协议前缀。ChatMessage.text = PREFIX + 可读文案。
/// 用于识别因付费墙（免费版无云端视觉）失败时，给免费版用户一条带升级入口的提示。
let UPGRADE_PRO_PREFIX = "__UPGRADE_PRO__"

enum RecognitionItemType: String, Codable {
    case bill, todo, food, health
}

/// 单条记录的 payload，按类型携带原始识别字段（用于待确认态展示 / 保存时入库）。
enum ItemPayload: Codable {
    case bill(BillPayload)
    case food(FoodPayload)
    case todo(TodoPayload)
    case health(HealthPayload)
}

/// 对话页里的一张记录卡片。
struct RecognitionItem: Identifiable, Codable {
    let id: UUID
    let type: RecognitionItemType
    var syncId: String?        // nil = 待确认；入库后写真实模型的 syncId.uuidString
    var imageName: String?     // 本地原图文件名（仅本地，不上云），用于"查看原图"
    var source: String         // "image" / "text" / "cloud" / "local"（入口/识别来源，兼容旧协议）
    var recogSource: String?   // 识别引擎来源 rawValue："local"/"cloudText"/"cloud"，nil=旧协议串/无标记
    let payload: ItemPayload
}

/// 一条对话消息承载的完整识别结果。
struct RecognitionResultPayload: Codable {
    let types: [String]
    let source: String
    let autoSaved: Bool
    var items: [RecognitionItem]
}

func encodeRecognitionPayload(_ p: RecognitionResultPayload) -> String {
    guard let data = try? JSONEncoder().encode(p),
          let s = String(data: data, encoding: .utf8) else { return "" }
    return RECOGNITION_RESULT_PREFIX + s
}

func decodeRecognitionPayload(_ text: String) -> RecognitionResultPayload? {
    guard text.hasPrefix(RECOGNITION_RESULT_PREFIX) else { return nil }
    let json = String(text.dropFirst(RECOGNITION_RESULT_PREFIX.count))
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(RecognitionResultPayload.self, from: data)
}

/// 判断一条识别结果消息是否整体为「已保存」态（用于决定是否在卡片前补一句简短文字）。
func hasSavedItems(in msg: ChatMessage) -> Bool {
    guard let payload = decodeRecognitionPayload(msg.text) else { return false }
    return payload.autoSaved
}

// MARK: - 用户发出的图片（微信式发图气泡）

/// 对话页「用户发出的图片」协议前缀。ChatMessage.text = PREFIX + LocalImageStore 文件名。
///
/// 为什么用协议串而不给 ChatMessage 加字段：ChatMessage 被 v9~v15 共 7 个 VersionedSchema 直接引用，
/// 加字段会让这 7 个版本 checksum 同时漂移（Duplicate version checksums → 启动白屏）。
/// 协议串沿用本项目既有的 `__RECOGNITION_RESULT__` / `__FOOD_CONFIRM__` 套路，零 schema 迁移。
///
/// 注意：消息文本会随「chat」类型上云，但图片本体只在本地（LocalImageStore），
/// 换设备拉到这条消息时取不到图，渲染侧需降级为占位（见 ChatView.userImageBubble）。
let USER_IMAGE_PREFIX = "__USER_IMAGE__"

/// 解析出用户发图消息里的本地文件名；非发图消息返回 nil。
func decodeUserImageName(_ text: String) -> String? {
    guard text.hasPrefix(USER_IMAGE_PREFIX) else { return nil }
    let name = String(text.dropFirst(USER_IMAGE_PREFIX.count))
    return name.isEmpty ? nil : name
}

/// 把用户提交的图片作为一条「用户消息」插入对话流——像微信一样：先出现你发的图，小记随后回识别卡片。
/// 拍照 / 相册 / 文件导入（`runImageRecognition`）与截屏无感识别共用此入口。
/// - Parameter imageName: 已落盘的文件名（截屏链路 ScreenshotStore 已存过图，传入可避免重复落盘）。
/// - Returns: 本地文件名，便于后续识别结果卡片复用同一张原图。
@discardableResult
@MainActor
func appendUserImageMessage(image: UIImage?, context: ModelContext, imageName: String? = nil) -> String? {
    guard let name = imageName ?? LocalImageStore.save(image) else { return nil }
    context.insert(ChatMessage(role: .user, text: USER_IMAGE_PREFIX + name))
    return name
}

/// 用户发出的图片气泡：右对齐缩略图，点开看大图，长按可删除/多选。
/// 做成独立 struct 而非 ChatView 内的 ViewBuilder 函数——它需要持有自己的
/// 「已解码图片」与「查看大图」状态（ViewBuilder 函数无法带 @State）。
struct UserImageBubble: View {
    let imageName: String
    var isSelected: Bool = false
    var showSelection: Bool = false
    var onToggleSelection: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onEnterMultiSelect: (() -> Void)? = nil

    /// 只解码一次并缓存：直接在 body 里调 LocalImageStore.load 会导致每帧读盘+解码，滚动会卡。
    @State private var loaded: UIImage?
    @State private var showFull = false

    var body: some View {
        HStack {
            Spacer(minLength: 28)

            ZStack(alignment: .topTrailing) {
                thumbnail
                    .opacity(showSelection && !isSelected ? 0.4 : 1.0)

                if showSelection {
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
                if !showSelection {
                    if let onDelete {
                        Button(role: .destructive) { onDelete() } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    if let onEnterMultiSelect {
                        Button { onEnterMultiSelect() } label: {
                            Label("选择", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .onTapGesture {
                if showSelection {
                    onToggleSelection?()
                } else if loaded != nil {
                    showFull = true
                }
            }
        }
        .task(id: imageName) {
            if loaded == nil { loaded = LocalImageStore.load(imageName) }
        }
        .fullScreenCover(isPresented: $showFull) {
            if let img = loaded { FullImageView(image: img) }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = loaded {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            // 图片本体绝不上云：换设备拉到这条聊天记录时取不到原图，降级为占位而不是空白。
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(AIATheme.muted)
                Text("图片仅存于原设备")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            .frame(width: 150, height: 150)
            .background(AIATheme.fillSoft)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// 饮食卡通用展示（标题 + 副标题 + 右上大字 kcal + 6 格营养素网格）。
/// - Parameters:
///   - weight: 可选重量文本（如「100克」「一碗」），追加在食物名后。
///   - subtitle: 来源标签（如「小记猜记」「看图识别」），已与重量解耦。
///   - nutrients: (标签, 数值, 是否毫克)；钠为毫克，其余为克。横排一行，label+value 同字号 12pt。
///   - missingMicro: 需要标注「待补」的营养素索引集合（值为 0 时显示「待补」而非 0，提示用户数据缺失而非零摄入）。
func foodCardPreview(name: String, weight: String?, subtitle: String, calories: Double,
                     nutrients: [(String, Double, Bool)],
                     missingMicro: Set<Int> = []) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                fieldLabel("食物")
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 15, weight: .semibold))
                    if let w = weight, !w.isEmpty {
                        Text(w).font(.system(size: 13)).foregroundStyle(AIATheme.reading)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(AIATheme.reading)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                fieldLabel("卡路里")
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(Int(calories))")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AIATheme.food)
                    Text("kcal").font(.system(size: 11)).foregroundStyle(AIATheme.reading)
                }
            }
        }
        // 6 个 macro 表格化展示：3 列、外框 + 内部横竖分隔线。
        let columnCount = 3
        let rowCount = (nutrients.count + columnCount - 1) / columnCount
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { col in
                        let idx = row * columnCount + col
                        if idx < nutrients.count {
                            let (label, val, isMg) = nutrients[idx]
                            HStack(spacing: 2) {
                                Text(label).font(.system(size: 12)).foregroundStyle(AIATheme.reading)
                                if missingMicro.contains(idx) && val == 0 {
                                    Text("待补")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(AIATheme.warning)
                                } else {
                                    let display = (val.truncatingRemainder(dividingBy: 1) == 0)
                                        ? String(format: "%.0f", val)
                                        : String(format: "%.1f", val)
                                    Text("\(display)\(isMg ? "mg" : "g")")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                        } else {
                            Spacer().frame(maxWidth: .infinity)
                        }
                        if col < columnCount - 1 {
                            Rectangle().fill(AIATheme.hairline).frame(width: 0.5)
                        }
                    }
                }
                if row < rowCount - 1 {
                    Rectangle().fill(AIATheme.hairline).frame(height: 0.5)
                }
            }
        }
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
    }
}

/// 由云函数/本地识别结果构造「待确认」卡片列表（syncId 为空）。
/// - Parameter allowed: 非 nil 时只构造这些类别的卡片（按类别「待确认」设置过滤）。
func buildPendingItems(from result: RecognitionResult, source: String,
                       allowed: Set<String>? = nil,
                       recogSource: String? = nil,
                       imageName: String? = nil) -> [RecognitionItem] {
    func keep(_ t: String) -> Bool { allowed.map { $0.contains(t) } ?? true }
    var items: [RecognitionItem] = []
    if keep("bill") {
        for b in result.billList {
            items.append(RecognitionItem(id: UUID(), type: .bill, syncId: nil,
                                         imageName: imageName, source: source, recogSource: recogSource,
                                         payload: .bill(b)))
        }
    }
    if keep("food") {
        for f in result.foodList {
            items.append(RecognitionItem(id: UUID(), type: .food, syncId: nil,
                                         imageName: imageName, source: source, recogSource: recogSource,
                                         payload: .food(f)))
        }
    }
    if keep("todo") {
        for t in result.todoList {
            items.append(RecognitionItem(id: UUID(), type: .todo, syncId: nil,
                                         imageName: nil, source: source, recogSource: recogSource,
                                         payload: .todo(t)))
        }
    }
    if keep("health") {
        for h in result.healthList {
            items.append(RecognitionItem(id: UUID(), type: .health, syncId: nil,
                                         imageName: nil, source: source, recogSource: recogSource,
                                         payload: .health(h)))
        }
    }
    return items
}

// MARK: - 对话页气泡容器

struct ChatRecognitionBubble: View {
    let message: ChatMessage
    @State private var items: [RecognitionItem]
    @Environment(\.modelContext) private var context

    // 四个类型各拉一份「未软删」全集，供卡片按 syncId 取活对象（响应式刷新 → 双向同步）。
    @Query(filter: #Predicate<Bill> { !$0.syncDeleted }) private var allBills: [Bill]
    @Query(filter: #Predicate<Reminder> { !$0.syncDeleted }) private var allReminders: [Reminder]
    @Query(filter: #Predicate<FoodEntry> { !$0.syncDeleted }) private var allFoods: [FoodEntry]
    @Query(filter: #Predicate<HealthMetric> { !$0.syncDeleted }) private var allHealths: [HealthMetric]

    init(message: ChatMessage) {
        self.message = message
        _items = State(initialValue: decodeRecognitionPayload(message.text)?.items ?? [])
    }

    var body: some View {
        // 卡片被删光时整条气泡不渲染（软删生效前的一帧也不留空壳）
        if items.isEmpty {
            EmptyView()
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, _ in
                let element = items[idx]
                let itemBinding = $items[idx]
                switch element.type {
                case .bill:
                    BillRowCard(item: itemBinding,
                                allBills: allBills,
                                persist: persist,
                                onRemove: { removeItem(element.id) })
                case .todo:
                    TodoRowCard(item: itemBinding,
                                allReminders: allReminders,
                                persist: persist,
                                onRemove: { removeItem(element.id) })
                case .food:
                    FoodRowCard(item: itemBinding,
                                allFoods: allFoods,
                                persist: persist,
                                onRemove: { removeItem(element.id) })
                case .health:
                    HealthRowCard(item: itemBinding,
                                  allHealths: allHealths,
                                  persist: persist,
                                  onRemove: { removeItem(element.id) })
                }
            }
        }
        // 方案B：去掉 padding(10)，卡片直接贴到气泡外缘，与外壳圆角(14)自然贴合。
        // 卡片自身的 hairline 描边保留（见 RecognitionCardShell）。
        // 宽度钉死到「屏宽 − 60」，与文字气泡(messageBubble 整列 padding16×2 + 对侧 Spacer28)同口径。
        // min/max 同值 → 窄内容不再收缩，解决卡片过窄；对齐文字气泡边界。
        .frame(minWidth: UIScreen.main.bounds.width - 60,
               maxWidth: UIScreen.main.bounds.width - 60,
               alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func persist() {
        let p = RecognitionResultPayload(
            types: items.map { $0.type.rawValue },
            source: items.first?.source ?? "image",
            autoSaved: false,
            items: items
        )
        message.text = encodeRecognitionPayload(p)
    }

    private func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        if items.isEmpty {
            // 最后一张卡片被删光 → 整条识别气泡一起软删消失，
            // 并连带删除同组的 AI 文字开场白（否则会退化成「（无识别结果）」空壳，
            // 即用户看到的「小圆点」——其实是没了卡片的开场白孤气泡）。
            SafeDelete.chatMessage(message, in: context)
            removePairedOpener()
        } else {
            persist()
        }
    }

    /// 软删与本条卡片同组的 AI 文字开场白。
    /// 依据 `RecognitionSaver.insertRecognitionGroup`：开场白 createdAt 严格早于其所有卡片，
    /// 且文本属于识别开场白话术（判定复用 `RecognitionSaver.isRecognitionOpener`）。
    private func removePairedOpener() {
        let descriptor = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let all = try? context.fetch(descriptor) else { return }
        // 找本条卡片消息之前、最近的一条 AI 开场白话术消息
        var passedSelf = false
        for m in all {
            if m.persistentModelID == message.persistentModelID {
                passedSelf = true
                continue
            }
            guard passedSelf else { continue }
            guard m.role == .ai else { continue }
            if RecognitionSaver.isRecognitionOpener(m.text) {
                SafeDelete.chatMessage(m, in: context)
                return
            }
            // 遇到非开场白的消息说明已超出本组，停止（避免误删更早的其它消息）
            break
        }
    }
}

// MARK: - 卡片通用外观（统一外壳：类型色竖条 + 图标方块 + 关键数值放大）

/// 类型视觉映射：与首页宫格 / 详情页 Hero 图标同源，靠色相即可秒认类型。
private struct TypeVisual {
    let color: Color
    let icon: String
    let label: String
}

private func typeVisual(_ type: RecognitionItemType) -> TypeVisual {
    switch type {
    case .bill:   return TypeVisual(color: AIATheme.bill,   icon: "creditcard.fill", label: "账单")
    case .food:   return TypeVisual(color: AIATheme.food,   icon: "fork.knife",      label: "饮食")
    case .todo:   return TypeVisual(color: AIATheme.todo,   icon: "checklist",        label: "待办")
    case .health: return TypeVisual(color: AIATheme.health, icon: "staroflife",       label: "健康")
    }
}

/// 来源标签：看图识别 / 文字·语音识别。
/// source 字段由 RecognitionSaver 按 entryOrigin 归一到 "image"（图片类入口）
/// 或 "text"（文字/语音/Siri 入口）两种，此处只认 "image"，其余一律归为文字·语音识别。
private func sourceTag(_ source: String) -> String {
    switch source {
    case "image": return "看图识别"
    default: return "文字·语音识别"
    }
}

/// 识别引擎来源中文标签：优先取协议串里的 recogSource（local/cloudText/cloud），
/// 旧协议串无 recogSource 时回退按 source 字段里的 local/cloud 判断。
/// 返回 nil 表示无标记（不显示）。
private func recogLabel(_ item: RecognitionItem) -> String? {
    if let raw = item.recogSource, let label = RecogSource.displayLabel(for: raw) {
        return label
    }
    // 旧协议串回退：source 里若带了 local/cloud 也能推断
    if item.source == "local" { return "免费版AI识别" }
    if item.source == "cloud" { return "Pro版AI识别" }
    if item.source == "cloudText" { return "Pro版文字识别" }
    return nil
}

private extension Date {
    /// 卡片标题栏统一「日期 + 时间」本地化格式，如「2026年8月2日 20:15」。
    var cardHeaderDateTime: String {
        self.formatted(date: .long, time: .shortened)
    }
}

/// 对话页识别卡片统一外壳：左 4pt 类型色竖条 + 顶部 38pt 类型色图标方块 + 标题/来源 + 右侧状态/菜单。
/// 已保存态右侧为 ⋯ 菜单（由调用方注入），待确认态右侧为琥珀「待确认」pill。
/// 关键数值由 content 内用类型色大字呈现；外壳只负责类型锚点与浮起层次。
private struct RecognitionCardShell<MenuContent: View, Content: View>: View {
    let type: RecognitionItemType
    let isPending: Bool
    let subtitle: String
    /// 识别引擎来源中文标签（如「免费版AI识别」/「Pro版AI识别」），nil 不显示。
    var recogLabel: String? = nil
    let dateText: String?
    @ViewBuilder var menu: () -> MenuContent
    @ViewBuilder var content: () -> Content

    private var v: TypeVisual { typeVisual(type) }

    var body: some View {
        HStack(spacing: 0) {
            v.color
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                header
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AIATheme.hairline, lineWidth: 0.5))
        .shadow(color: AIATheme.cardShadow, radius: AIATheme.cardShadowRadius, y: AIATheme.cardShadowY)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(v.color)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: v.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(v.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AIATheme.reading)
                    if let recogLabel {
                        Text(recogLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(AIATheme.sub)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AIATheme.surfaceSecondary)
                            .clipShape(Capsule())
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(AIATheme.reading)
                }
            }
            Spacer(minLength: 6)
            if let dateText {
                Text(dateText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AIATheme.reading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            if isPending {
                Text("待确认")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AIATheme.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                .background(AIATheme.amberBG)
                .clipShape(Capsule())
            } else {
                menu()
            }
        }
    }
}

// MARK: - 账单卡片

struct BillRowCard: View {
    @Binding var item: RecognitionItem
    let allBills: [Bill]
    var persist: () -> Void
    var onRemove: () -> Void
    @Environment(\.modelContext) private var context

    /// 编辑弹窗目标：存 PersistentIdentifier，sheet 内取活实例，避免 @Query 刷新抖动导致 sheet 重弹。
    @State private var editTargetID: PersistentIdentifier?

    private var live: Bill? { allBills.first { $0.syncId.uuidString == (item.syncId ?? "") } }
    private var payloadBill: BillPayload? {
        if case .bill(let p) = item.payload { return p } else { return nil }
    }

    init(item: Binding<RecognitionItem>, allBills: [Bill], persist: @escaping () -> Void, onRemove: @escaping () -> Void) {
        _item = item
        self.allBills = allBills
        self.persist = persist
        self.onRemove = onRemove
    }

    var body: some View {
        Group {
            if item.syncId == nil {
                RecognitionCardShell(type: .bill, isPending: true, subtitle: sourceTag(item.source), recogLabel: recogLabel(item), dateText: nil) {
                    EmptyView()
                } content: {
                    pendingBody
                }
            } else if let bill = live {
                RecognitionCardShell(type: .bill, isPending: false, subtitle: "", recogLabel: recogLabel(item), dateText: bill.time.cardHeaderDateTime) {
                    EmptyView()
                } content: {
                    BillSavedCard(bill: bill,
                                  onDelete: { SafeDelete.bill(bill, in: context); onRemove() },
                                  onCopy: { copySummary(bill.summaryText) },
                                  onEdit: { editTargetID = bill.persistentModelID })
                }
            } else {
                EmptyView()
            }
        }
        .sheet(item: $editTargetID) { id in
            if let b = context.model(for: id) as? Bill {
                EditBillView(bill: b, isAdding: false)
            }
        }
    }

    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            billPreview(merchant: payloadBill?.merchant ?? "未命名商户",
                        amount: payloadBill?.amount ?? 0,
                        isIncome: RecognitionSaver.isIncomeCategory(payloadBill?.category ?? ""),
                        category: payloadBill?.category ?? "其他",
                        note: payloadBill?.note ?? "")
                .contentShape(Rectangle())
                .onTapGesture { editPending() }
            HStack(spacing: 8) {
                Spacer()
                cardIconButton(icon: "trash", label: "删除", color: .red) { onRemove() }
                cardIconButton(icon: "pencil", label: "编辑") { editPending() }
                cardIconButton(icon: "checkmark", label: "保存", color: .white, bg: AIATheme.bill) { save() }
            }
        }
    }

    /// 账单只读预览（待确认 / 已保存共用同一套样式）。点展示区即弹编辑弹窗。
    private func billPreview(merchant: String, amount: Double, isIncome: Bool, category: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(merchant).font(.system(size: 15, weight: .semibold))
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(String(format: "%@ ¥%.2f", isIncome ? "收入" : "支出", amount))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isIncome ? AIATheme.income : AIATheme.expense)
                Text(category)
                    .font(.system(size: 11))
                    .foregroundStyle(AIATheme.reading)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(AIATheme.fillSoft)
                    .clipShape(Capsule())
            }
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(AIATheme.reading)
            }
        }
    }

    private func commitBill() -> Bill {
        let p = payloadBill
        let category = p?.category ?? ""
        let isIncome = RecognitionSaver.isIncomeCategory(category)
        let bill = Bill(merchant: p?.merchant ?? "未命名商户",
                        amount: p?.amount ?? 0,
                        category: category.isEmpty ? "其他" : category,
                        time: RecognitionResult.date(from: p?.time) ?? Date(),
                        note: p?.note ?? "",
                        isIncome: isIncome,
                        imageName: item.imageName)
        context.insert(bill)
        return bill
    }

    private func save() {
        let bill = commitBill()
        item.syncId = bill.syncId.uuidString
        persist()
    }

    /// 待确认态「编辑」/点卡片：先按识别结果入库并切换到已保存壳，
    /// 再把弹 sheet 延后一帧，使转场动画在稳定布局上平滑上滑，避免生硬弹出。
    private func editPending() {
        let bill = commitBill()
        item.syncId = bill.syncId.uuidString
        persist()
        DispatchQueue.main.async { editTargetID = bill.persistentModelID }
    }

    private func copySummary(_ s: String) {
        UIPasteboard.general.string = s
    }
}

struct BillSavedCard: View {
    let bill: Bill
    var onDelete: () -> Void
    var onCopy: () -> Void
    var onEdit: () -> Void

    /// 与账单页「编辑」入口对齐：点卡片展示区或「编辑」按钮都弹 EditBillView 整页 sheet。
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            billPreview
                .contentShape(Rectangle())
                .onTapGesture { onEdit() }
            HStack(spacing: 8) {
                Spacer()
                cardIconButton(icon: "pencil", label: "编辑") { onEdit() }
                cardIconButton(icon: "doc.on.doc", label: "复制") { onCopy() }
                cardIconButton(icon: "trash", label: "删除", color: .red) { onDelete() }
            }
        }
    }

    private var billPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bill.merchant).font(.system(size: 15, weight: .semibold))
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(String(format: "%@ ¥%.2f", bill.isIncome ? "收入" : "支出", bill.amount))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(bill.isIncome ? AIATheme.income : AIATheme.expense)
                Text(bill.category)
                    .font(.system(size: 11))
                    .foregroundStyle(AIATheme.reading)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(AIATheme.fillSoft)
                    .clipShape(Capsule())
            }
            if !bill.note.isEmpty {
                Text(bill.note)
                    .font(.system(size: 13))
                    .foregroundStyle(AIATheme.reading)
            }
        }
    }
}

// MARK: - 待办卡片

struct TodoRowCard: View {
    @Binding var item: RecognitionItem
    let allReminders: [Reminder]
    var persist: () -> Void
    var onRemove: () -> Void
    @Environment(\.modelContext) private var context

    /// 编辑弹窗目标：存 PersistentIdentifier，sheet 内取活实例，避免 @Query 刷新抖动导致 sheet 重弹。
    @State private var editTargetID: PersistentIdentifier?

    private var live: Reminder? { allReminders.first { $0.syncId.uuidString == (item.syncId ?? "") } }
    private var payloadTodo: TodoPayload? {
        if case .todo(let p) = item.payload { return p } else { return nil }
    }

    init(item: Binding<RecognitionItem>, allReminders: [Reminder], persist: @escaping () -> Void, onRemove: @escaping () -> Void) {
        _item = item
        self.allReminders = allReminders
        self.persist = persist
        self.onRemove = onRemove
    }

    var body: some View {
        Group {
            if item.syncId == nil {
                RecognitionCardShell(type: .todo, isPending: true, subtitle: sourceTag(item.source), recogLabel: recogLabel(item), dateText: nil) {
                    EmptyView()
                } content: {
                    pendingBody
                }
            } else if let r = live {
                RecognitionCardShell(type: .todo, isPending: false, subtitle: "", recogLabel: recogLabel(item), dateText: (r.due?.cardHeaderDateTime) ?? "未安排") {
                    EmptyView()
                } content: {
                    TodoSavedCard(reminder: r,
                                  onDelete: { SafeDelete.reminder(r, in: context); onRemove() },
                                  onCopy: { UIPasteboard.general.string = r.title },
                                  onEdit: { editTargetID = r.persistentModelID })
                }
            } else {
                EmptyView()
            }
        }
        .sheet(item: $editTargetID) { id in
            if let r = context.model(for: id) as? Reminder {
                EditTodoSheet(reminder: r, isAdding: false)
            }
        }
    }

    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            todoPreview(title: payloadTodo?.title ?? "未命名待办",
                        dueText: dueText(from: payloadTodo?.due))
                .contentShape(Rectangle())
                .onTapGesture { editPending() }
            HStack(spacing: 8) {
                Spacer()
                cardIconButton(icon: "trash", label: "删除", color: .red) { onRemove() }
                cardIconButton(icon: "pencil", label: "编辑") { editPending() }
                cardIconButton(icon: "checkmark", label: "保存", color: .white, bg: AIATheme.todo) { save() }
            }
        }
    }

    private func dueText(from dueString: String?) -> String {
        guard let dueString, !dueString.isEmpty else { return "未安排" }
        let d = RecognitionSaver.dueDate(from: dueString)
        return d.cardHeaderDateTime
    }

    /// 待办只读预览（待确认 / 已保存共用同一套样式）。
    private func todoPreview(title: String, dueText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(dueText)
                .font(.system(size: 12))
                .foregroundStyle(AIATheme.reading)
        }
    }

    private func commitReminder() -> Reminder {
        let p = payloadTodo
        let hasDue = (p?.due != nil && !p!.due!.isEmpty)
        let r = Reminder(title: p?.title ?? "未命名待办",
                         due: hasDue ? RecognitionSaver.dueDate(from: p?.due) : nil,
                         priority: "medium",
                         imageName: item.imageName)
        context.insert(r)
        return r
    }

    private func save() {
        let r = commitReminder()
        item.syncId = r.syncId.uuidString
        persist()
    }

    /// 待确认态「编辑」/点卡片：先入库切壳，再把弹 sheet 延后一帧，
    /// 让 .sheet 在稳定的已保存壳上做转场，避免生硬弹出。
    private func editPending() {
        let r = commitReminder()
        item.syncId = r.syncId.uuidString
        persist()
        DispatchQueue.main.async { editTargetID = r.persistentModelID }
    }
}

struct TodoSavedCard: View {
    let reminder: Reminder
    var onDelete: () -> Void
    var onCopy: () -> Void
    var onEdit: () -> Void

    /// 与待办页「编辑待办」入口对齐：点卡片展示区或「编辑」按钮都弹 EditTodoSheet 整页 sheet。
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title).font(.system(size: 15, weight: .semibold))
                Text((reminder.due?.cardHeaderDateTime) ?? "未安排")
                    .font(.system(size: 12))
                    .foregroundStyle(AIATheme.reading)
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }
            HStack(spacing: 8) {
                Spacer()
                cardIconButton(icon: "pencil", label: "编辑") { onEdit() }
                cardIconButton(icon: "doc.on.doc", label: "复制") { onCopy() }
                cardIconButton(icon: "trash", label: "删除", color: .red) { onDelete() }
            }
        }
    }
}

// MARK: - 饮食卡片

struct FoodRowCard: View {
    @Binding var item: RecognitionItem
    let allFoods: [FoodEntry]
    var persist: () -> Void
    var onRemove: () -> Void
    @Environment(\.modelContext) private var context

    /// 编辑弹窗目标：存 PersistentIdentifier（ID 永远稳定），sheet 内再取活实例，
    /// 避免后台 @Query 刷新导致 FoodEntry 引用/fault 抖动、sheet item identity 变化触发 dismiss→重弹。
    @State private var editTargetID: PersistentIdentifier?

    private var live: FoodEntry? { allFoods.first { $0.syncId.uuidString == (item.syncId ?? "") } }

    private var payloadFood: FoodPayload? {
        if case .food(let p) = item.payload { return p } else { return nil }
    }

    /// 待确认态重量文本：「100克」或 `portion` 自带克数时原样输出（如「一碗」「1 份」）。
    /// 用于追加到食物名后；与 `foodSubtitle` 的来源标签解耦。
    private var foodWeightText: String {
        let p = payloadFood
        let portionText = p?.portion ?? ""
        let weight = p?.weightGram ?? RecognitionSaver.weightFromPortion(portionText.isEmpty ? nil : portionText) ?? 100
        return portionText.isEmpty ? "\(Int(weight))克" : portionText
    }

    /// 待确认态副标题：仅来源（图片=看图识别 / 本地=本地识别 / 文字·云端=小记猜记）。
    /// 份量已挪到标题行后面，此处不再拼重量。
    private var foodSubtitle: String {
        ""
    }

    init(item: Binding<RecognitionItem>, allFoods: [FoodEntry], persist: @escaping () -> Void, onRemove: @escaping () -> Void) {
        _item = item
        self.allFoods = allFoods
        self.persist = persist
        self.onRemove = onRemove
    }

    var body: some View {
        Group {
            if item.syncId == nil {
                pendingCard
            } else if let f = live {
                savedCard(f)
            }
        }
        // EditFoodView 自包 NavigationStack，sheet 内点「保存/取消/删除」自己 dismiss；
        // .sheet(item:) 在用户关闭时自动把 editTargetID 置 nil。
        .sheet(item: $editTargetID) { id in
            if let f = context.model(for: id) as? FoodEntry {
                EditFoodView(entry: f)
            }
        }
    }

    private var pendingCard: some View {
        RecognitionCardShell(type: .food, isPending: true, subtitle: sourceTag(item.source), recogLabel: recogLabel(item), dateText: nil) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                let p = payloadFood
                let hasMacro = (p?.calories ?? 0) > 0 || (p?.protein ?? 0) > 0 || (p?.carbs ?? 0) > 0 || (p?.fat ?? 0) > 0
                let nutrients: [(String, Double, Bool)] = [
                    ("碳水", p?.carbs ?? 0, false),
                    ("蛋白", p?.protein ?? 0, false),
                    ("脂肪", p?.fat ?? 0, false),
                    ("纤维", p?.fiber ?? 0, false),
                    ("糖", p?.sugar ?? 0, false),
                    ("钠", p?.sodium ?? 0, true),
                ]
                // micro 三项（索引 3/4/5）值为 0 且 macro 已填 → 数据缺失，标「待补」。
                // 用立即执行闭包在 ViewBuilder 之外计算，避免 if+insert 被 ViewBuilder 误判为 View 表达式。
                let missing: Set<Int> = {
                    guard hasMacro else { return [] }
                    var s = Set<Int>()
                    if (p?.fiber ?? 0) == 0 { s.insert(3) }
                    if (p?.sugar ?? 0) == 0 { s.insert(4) }
                    if (p?.sodium ?? 0) == 0 { s.insert(5) }
                    return s
                }()
                foodCardPreview(name: p?.name ?? "食物",
                                weight: foodWeightText,
                                subtitle: foodSubtitle,
                                calories: p?.calories ?? 0,
                                nutrients: nutrients,
                                missingMicro: missing)
                    .contentShape(Rectangle())
                    .onTapGesture { editPending() }
                HStack(spacing: 8) {
                    Spacer()
                    cardIconButton(icon: "trash", label: "删除", color: .red) { onRemove() }
                    cardIconButton(icon: "pencil", label: "编辑") { editPending() }
                    cardIconButton(icon: "checkmark", label: "保存", color: .white, bg: AIATheme.food) { save() }
                }
            }
        }
    }

    private func savedCard(_ f: FoodEntry) -> some View {
        RecognitionCardShell(type: .food, isPending: false, subtitle: "", recogLabel: recogLabel(item), dateText: f.date.cardHeaderDateTime) {
            EmptyView()
        } content: {
            FoodSavedCard(food: f,
                          onDelete: { SafeDelete.food(f, in: context); onRemove() },
                          onCopy: { UIPasteboard.general.string = f.name },
                          onEdit: { editTargetID = f.persistentModelID })
        }
    }

    /// 由识别 payload 直接构造 FoodEntry 入库（不再经过行内表单 @State），返回刚建的实例。
    private func commitEntry() -> FoodEntry? {
        guard let p = payloadFood else { return nil }
        let portionText = p.portion?.isEmpty == false ? p.portion! : "1份"
        let weight = p.weightGram ?? RecognitionSaver.weightFromPortion(p.portion?.isEmpty == false ? p.portion : nil) ?? RecognitionSaver.weightFromServingUnit(p.portion?.isEmpty == false ? p.portion : nil) ?? 100
        let ratio = weight / 100
        let c = p.calories ?? 0
        let totalP = p.protein ?? 0
        let totalC = p.carbs ?? 0
        let totalF = p.fat ?? 0
        let totalFiber = p.fiber ?? 0
        let totalSugar = p.sugar ?? 0
        let totalSod = p.sodium ?? 0
        // 解析 FoodPayload 里的日期/时刻（支持完整 ISO 时间和纯日期两种旧新格式）。
        let entryDate: Date = {
            if let d = p.date {
                if d.count > 10, let parsed = AppFormat.isoLocal.date(from: d)
                ?? AppFormat.iso.date(from: d)
                ?? AppFormat.isoLocalNoFrac.date(from: d)
                ?? AppFormat.isoNoFrac.date(from: d) {
                    return parsed
                }
                if let parsed = AppFormat.isoDate.date(from: d) {
                    let meal = p.meal ?? RecognitionSaver.defaultMeal(for: parsed)
                    let hour: Int
                    switch meal {
                    case let m where m.contains("早"): hour = 8
                    case let m where m.contains("午") || m.contains("中"): hour = 12
                    case let m where m.contains("晚"): hour = 18
                    case let m where m.contains("夜") || m.contains("宵"): hour = 22
                    default: hour = 12
                    }
                    return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: parsed) ?? parsed
                }
            }
            return Date()
        }()
        // 营养素原样入库（不写 0），并把 base* 反推成每 100g，供编辑页反算。
        let f = FoodEntry(
            name: p.name ?? "未命名食物",
            calories: c,
            protein: totalP, carbs: totalC, fat: totalF,
            fiber: totalFiber, sugar: totalSugar, sodium: totalSod,
            portion: portionText,
            meal: p.meal ?? RecognitionSaver.defaultMeal(for: entryDate),
            date: entryDate,
            weightGram: weight,
            baseCalories: ratio > 0 ? c / ratio : nil,
            baseProtein: ratio > 0 ? totalP / ratio : nil,
            baseCarbs: ratio > 0 ? totalC / ratio : nil,
            baseFat: ratio > 0 ? totalF / ratio : nil,
            baseFiber: ratio > 0 ? totalFiber / ratio : nil,
            baseSugar: ratio > 0 ? totalSugar / ratio : nil,
            baseSodium: ratio > 0 ? totalSod / ratio : nil,
            imageName: item.imageName)
        context.insert(f)
        return f
    }

    private func save() {
        guard let f = commitEntry() else { return }
        item.syncId = f.syncId.uuidString
        persist()
    }

    /// 待确认态「编辑」：先按识别结果入库并切到已保存壳，
    /// 再把弹 sheet 延后一帧，让转场在稳定布局上平滑上滑。
    private func editPending() {
        guard let f = commitEntry() else { return }
        item.syncId = f.syncId.uuidString
        persist()
        DispatchQueue.main.async { editTargetID = f.persistentModelID }
    }
}

struct FoodSavedCard: View {
    let food: FoodEntry
    var onDelete: () -> Void
    var onCopy: () -> Void
    var onEdit: () -> Void

    /// 与饮食页「编辑食物」入口对齐：点卡片展示区或「编辑」按钮都弹 EditFoodView 整页 sheet。
    /// 不再做 in-place 卡片内编辑——既冗余又和饮食页 UX 不一致。
    @State private var presentingEdit = false

    /// 已保存态重量文本：与待确认态同款逻辑。
    private var foodWeightText: String {
        let weight = food.weightGram ?? RecognitionSaver.weightFromPortion(food.portion.isEmpty ? nil : food.portion) ?? 100
        return food.portion.isEmpty ? "\(Int(weight))克" : food.portion
    }

    /// 已保存态副标题：仅来源（看图识别 / 小记猜记）。份量已挪到标题行。
    private var foodSubtitle: String {
        ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let hasMacro = food.calories > 0 || food.protein > 0 || food.carbs > 0 || food.fat > 0
            let missing: Set<Int> = {
                guard hasMacro else { return [] }
                var s = Set<Int>()
                if food.fiber == 0 { s.insert(3) }
                if food.sugar == 0 { s.insert(4) }
                if food.sodium == 0 { s.insert(5) }
                return s
            }()
            foodCardPreview(name: food.name, weight: foodWeightText, subtitle: foodSubtitle, calories: food.calories, nutrients: [
                ("碳水", food.carbs, false),
                ("蛋白", food.protein, false),
                ("脂肪", food.fat, false),
                ("纤维", food.fiber, false),
                ("糖", food.sugar, false),
                ("钠", food.sodium, true),
            ], missingMicro: missing)
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }
            HStack(spacing: 8) {
                Spacer()
                cardIconButton(icon: "pencil", label: "编辑") { onEdit() }
                cardIconButton(icon: "doc.on.doc", label: "复制") { onCopy() }
                cardIconButton(icon: "trash", label: "删除", color: .red) { onDelete() }
            }
        }
    }
}

// MARK: - 健康卡片

struct HealthRowCard: View {
    @Binding var item: RecognitionItem
    let allHealths: [HealthMetric]
    var persist: () -> Void
    var onRemove: () -> Void
    @Environment(\.modelContext) private var context

    /// 编辑弹窗目标：存 PersistentIdentifier，sheet 内取活实例，避免 @Query 刷新抖动导致 sheet 重弹。
    @State private var editTargetID: PersistentIdentifier?

    private var live: HealthMetric? { allHealths.first { $0.syncId.uuidString == (item.syncId ?? "") } }
    private var payloadHealth: HealthPayload? {
        if case .health(let p) = item.payload { return p } else { return nil }
    }

    init(item: Binding<RecognitionItem>, allHealths: [HealthMetric], persist: @escaping () -> Void, onRemove: @escaping () -> Void) {
        _item = item
        self.allHealths = allHealths
        self.persist = persist
        self.onRemove = onRemove
    }

    var body: some View {
        Group {
            if item.syncId == nil {
                RecognitionCardShell(type: .health, isPending: true, subtitle: sourceTag(item.source), recogLabel: recogLabel(item), dateText: nil) {
                    EmptyView()
                } content: {
                    pendingBody
                }
            } else if let h = live {
                RecognitionCardShell(type: .health, isPending: false, subtitle: "", recogLabel: recogLabel(item), dateText: h.date.cardHeaderDateTime) {
                    EmptyView()
                } content: {
                    HealthSavedCard(health: h,
                                    onDelete: { SafeDelete.health(h, in: context); onRemove() },
                                    onCopy: { UIPasteboard.general.string = "\(h.metric) \(h.value)\(h.unit)" },
                                    onEdit: { editTargetID = h.persistentModelID })
                }
            } else {
                EmptyView()
            }
        }
        .sheet(item: $editTargetID) { id in
            if let h = context.model(for: id) as? HealthMetric {
                EditHealthView(metric: h)
            }
        }
    }

    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            healthPreview(metric: payloadHealth?.metric ?? "指标",
                          value: payloadHealth?.value ?? "",
                          unit: payloadHealth?.unit ?? "")
                .contentShape(Rectangle())
                .onTapGesture { editPending() }
            HStack(spacing: 8) {
                Spacer()
                cardIconButton(icon: "trash", label: "删除", color: .red) { onRemove() }
                cardIconButton(icon: "pencil", label: "编辑") { editPending() }
                cardIconButton(icon: "checkmark", label: "保存", color: .white, bg: AIATheme.health) { save() }
            }
        }
    }

    /// 健康只读预览（待确认 / 已保存共用同一套样式）。
    private func healthPreview(metric: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric).font(.system(size: 15, weight: .semibold))
            Text("\(value)\(unit)").font(.system(size: 13)).foregroundStyle(AIATheme.reading)
        }
    }

    private func commitHealth() -> HealthMetric {
        let p = payloadHealth
        let h = HealthMetric()
        h.metric = p?.metric ?? "指标"
        h.value = p?.value ?? ""
        h.unit = p?.unit ?? ""
        h.date = Date()
        h.imageName = item.imageName
        context.insert(h)
        return h
    }

    private func save() {
        let h = commitHealth()
        item.syncId = h.syncId.uuidString
        persist()
    }

    /// 待确认态「编辑」/点卡片：先入库切壳，再把弹 sheet 延后一帧，
    /// 让 .sheet 在稳定的已保存壳上做转场，避免生硬弹出。
    private func editPending() {
        let h = commitHealth()
        item.syncId = h.syncId.uuidString
        persist()
        DispatchQueue.main.async { editTargetID = h.persistentModelID }
    }
}

struct HealthSavedCard: View {
    let health: HealthMetric
    var onDelete: () -> Void
    var onCopy: () -> Void
    var onEdit: () -> Void

    /// 与健康页「编辑健康指标」入口对齐：点卡片展示区或「编辑」按钮都弹 EditHealthView 整页 sheet。
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(health.metric).font(.system(size: 15, weight: .semibold))
                Text("\(health.value)\(health.unit)").font(.system(size: 13)).foregroundStyle(AIATheme.reading)
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }
            HStack(spacing: 8) {
                Spacer()
                cardIconButton(icon: "pencil", label: "编辑") { onEdit() }
                cardIconButton(icon: "doc.on.doc", label: "复制") { onCopy() }
                cardIconButton(icon: "trash", label: "删除", color: .red) { onDelete() }
            }
        }
    }
}

// MARK: - 摘要扩展

extension Bill {
    var summaryText: String {
        "\(isIncome ? "收入" : "支出") \(merchant) \(String(format: "%.2f", amount)) \(category)"
    }
}

// MARK: - 卡片包装 / 字段辅助（ResultRowCard 各卡片复用）

/// 字段名标签：灰底小字，用于识别卡片每个值前面（如「商户 / 对象」「金额」）。
/// 字重提到 semibold + 字号 12：原 11pt medium 在深色下被压缩、与主标题（15pt semibold）
/// 区分度不够，用户反馈「食物」「商户」等小字段名在深色模式看不清。reading 已是亮灰，
/// 配合 semibold 后深色对比度足够且不会盖过主标题。
private func fieldLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AIATheme.reading)
}

/// 识别卡片统一图标操作按钮：28×28 圆形，省掉文字宽度，比 .bordered 文字按钮矮一截。
private func cardIconButton(icon: String, label: String,
                            color: Color = AIATheme.sub,
                            bg: Color = AIATheme.fillSoft,
                            action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(bg)
            .clipShape(Circle())
    }
    .accessibilityLabel(label)
    .buttonStyle(.plain)
}

/// 紧凑字段框：浅灰底圆角，可选小标题；用于识别卡片的可编辑字段，替代 .roundedBorder 与独占行的 fieldLabel。
private func compactField<Content: View>(label: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        if let label { fieldLabel(label) }
        content()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, label == nil ? 7 : 5)
    .background(AIATheme.fillSoft)
    .clipShape(RoundedRectangle(cornerRadius: 8))
}
