// EditSheets.swift
// 四个模块的「编辑」弹窗：配合列表左滑删除 + 点击编辑 使用。
// 采用「本地副本 + 保存时回写模型」的方式，点取消即不改动，保证可回退。
import SwiftUI
import SwiftData
import UIKit

private let mealOptions = ["早餐", "午餐", "晚餐", "加餐"]
private let priorityOptions: [(value: String, label: String)] = [("high", "高"), ("medium", "中"), ("low", "低")]
private let repeatOptions: [(value: String, label: String)] = [
    ("none", "不重复"), ("daily", "每天"), ("weekly", "每周"),
    ("biweekly", "每2周"), ("monthly", "每月"), ("bimonthly", "每2个月"),
    ("quarterly", "每3个月"), ("semiannual", "每6个月"),
    ("yearly", "每年")
]
private let reminderOptions: [ReminderOption] = [.atTime, .before15, .before30, .before1Hour, .before1Day, .before1Week, .custom]

// MARK: - 账单分类选项（保持与 BillCategoryHelpers 图标/颜色一致）
let billCategoryOptions: [String] = [
    "餐饮", "交通", "购物", "住房", "娱乐", "医疗", "教育",
    "通讯", "保险", "运动", "宠物", "旅行", "家居", "服饰",
    "美妆", "数码", "云服务", "礼品", "人情", "投资", "工资",
    "办公", "快递", "母婴", "慈善", "其他"
]

// MARK: - 通知时间 UI 状态
struct AlertItem: Identifiable, Hashable {
    let id = UUID()
    var option: ReminderOption
    var customDate: Date
}

private func alerts(from reminder: Reminder) -> [AlertItem] {
    let times = reminder.remindTimes.isEmpty ? (reminder.remindAt.map { [$0] } ?? []) : reminder.remindTimes
    guard let due = reminder.due else { return [] }
    return times.map { time in
        let option = ReminderOption.from(remindAt: time, due: due)
        return AlertItem(option: option, customDate: time)
    }
}

private func reminderTimes(from alerts: [AlertItem], due: Date?) -> [Date] {
    guard let due else { return [] }
    return alerts.compactMap { alert in
        ReminderOption.remindAt(for: due, option: alert.option, custom: alert.customDate)
    }.sorted()
}

// MARK: - 饮食编辑
// >>> CHANGE-[2026-08-18 17:30:00]-[EditFoodView改持有ID根治失效崩溃] 开始
// 原因: 对话页识别链路在 @Query 竞争时机传给 EditFoodView 的 FoodEntry 引用可能 backing 已失效
//       （临时 ID 行被 @Query 重 fetch 替换），直接持有 entry 在 init/onAppear/save 访问 entry.xxx 会
//       fatal("model instance was invalidated... temporary identifier")，表现为"卡住/动不了"。
//       改为持有 PersistentIdentifier(entryID)，每次访问都经 resolveEntry() 现取活实例；
//       init 不再读 backing（@State 初值给空，onAppear 里填充），从根上绕开失效 backing 读取。
// 回退: 恢复 let entry: FoodEntry 直接持有；init 里读 entry.xxx 回填 @State；所有 resolveEntry() 调用改回 entry。
struct EditFoodView: View {
    let entryID: PersistentIdentifier?
    /// 草稿模式：待确认卡点"编辑"时传入识别 payload，编辑页保存时才真正落库；
    /// 取消则什么都不落库（方案 B：先改草稿、保存才入库）。
    let draftPayload: FoodPayload?
    let draftImageName: String?
    var onDraftSaved: ((String) -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// 按 entryID 现取活实例；失效/临时行返回 nil（SwiftData 已保证对失效 ID 返回 nil）。
    /// 所有访问入口统一走本函数，避免持有失效 backing 引用。
    /// 草稿模式（draftPayload != nil）不依赖 entryID 解析（传 nil）。
    init(entryID: PersistentIdentifier? = nil, draftPayload: FoodPayload? = nil, draftImageName: String? = nil, onDraftSaved: ((String) -> Void)? = nil) {
        self.entryID = entryID
        self.draftPayload = draftPayload
        self.draftImageName = draftImageName
        self.onDraftSaved = onDraftSaved
    }

    private func resolveEntry() -> FoodEntry? {
        guard let id = entryID else { return nil }
        let r = context.model(for: id) as? FoodEntry
        return r
    }

    /// 草稿模式：把识别 payload 反推成每 100g 营养与日期，回填 @State（与 FoodRowCard.commitEntry 算法一致）。
    /// 仅在草稿模式（draftPayload != nil）调用；保存时才真正建 FoodEntry 入库。
    private func loadDraftIntoState(_ p: FoodPayload) {
        let weight = p.weightGram
            ?? RecognitionSaver.weightFromPortion(p.portion?.isEmpty == false ? p.portion : nil)
            ?? RecognitionSaver.weightFromServingUnit(p.portion?.isEmpty == false ? p.portion : nil)
            ?? 100
        let ratio = weight / 100
        let df: (Double?) -> String = { v in
            guard let v, v > 0, ratio > 0 else { return "" }
            return String(format: "%.1f", v / ratio)
        }
        name = p.name ?? ""
        meal = p.meal ?? RecognitionSaver.defaultMeal(for: Date())
        weightText = String(format: "%.0f", weight)
        baseCaloriesText = df(p.calories)
        baseProteinText  = df(p.protein)
        baseCarbsText    = df(p.carbs)
        baseFatText      = df(p.fat)
        baseFiberText    = df(p.fiber)
        baseSugarText    = df(p.sugar)
        baseSodiumText   = df(p.sodium)
        // 餐次用已有的 meal(String),infoCard 的 $meal 选择器直接生效,无需枚举
        entryDate = draftEntryDate(p)
        sourceImageName = draftImageName
        didInitialLoad = true
        // 草稿无 FoodNote（未落库），备注留空
    }

    /// 草稿日期解析：与 FoodRowCard.commitEntry 的 entryDate 逻辑一致（支持完整 ISO 时刻与纯日期两种）。
    private func draftEntryDate(_ p: FoodPayload) -> Date {
        guard let d = p.date else { return Date() }
        if d.count > 10,
           let parsed = AppFormat.isoLocal.date(from: d)
             ?? AppFormat.iso.date(from: d)
             ?? AppFormat.isoLocalNoFrac.date(from: d)
             ?? AppFormat.isoNoFrac.date(from: d) {
            return parsed
        }
        if let parsed = AppFormat.isoDate.date(from: d) {
            let m = p.meal ?? RecognitionSaver.defaultMeal(for: parsed)
            let hour: Int
            switch m {
            case let x where x.contains("早"): hour = 8
            case let x where x.contains("午") || x.contains("中"): hour = 12
            case let x where x.contains("晚"): hour = 18
            case let x where x.contains("夜") || x.contains("宵"): hour = 22
            default: hour = 12
            }
            return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: parsed) ?? parsed
        }
        return Date()
    }

    // 食物库本地缓存（hitCount 倒序，热词靠前）
    @Query(sort: \FoodMeta.hitCount, order: .reverse) private var foodMetas: [FoodMeta]
    /// 来源标记（1:1 关联 FoodEntry.syncId），body 里按 resolveEntry()?.syncId 过滤，避免 init 时访问失效 backing
    @Query private var sources: [FoodSource]
    /// 识别引擎来源标记（1:1 关联 FoodEntry.syncId）
    @Query private var recogSources: [RecogSource]

    @State private var name: String = ""
    @State private var meal: String = ""
    @State private var weightText: String = ""
    // 内部保存每100g的营养基准；UI 上显示的是「当前重量下的总量」。
    @State private var baseCaloriesText: String = "0"
    @State private var baseProteinText: String = "0"
    @State private var baseCarbsText: String = "0"
    @State private var baseFatText: String = "0"
    @State private var baseFiberText: String = "0"       // 膳食纤维（每100g克）
    @State private var baseSugarText: String = "0"       // 糖（每100g克）
    @State private var baseSodiumText: String = "0"      // 钠（每100g毫克）

    // 备注栏（文字 + 图片附件，存于 FoodNote，仅本地）
    @State private var noteText: String = ""
    @State private var noteImageNames: [String] = []
    // 来源识别原图（entry.imageName），仅本地；展示但不并入备注图片列表
    @State private var sourceImageName: String?
    // >>> CHANGE-[2026-08-18 17:53:30]-[草稿日期状态补声明] 开始
    // 原因: 草稿模式(待确认卡点编辑)新建 FoodEntry 必须传 date,但 EditFoodView 原本没有独立日期状态
    //       (非草稿路径沿用实例原日期,不在此编辑)。补一个 @State 承接 payload 解析出的日期。
    // 回退: 删除本行 + loadDraftIntoState 里的 entryDate 赋值 + save 草稿分支的 date: entryDate
    @State private var entryDate: Date = Date()
    // <<< CHANGE-[2026-08-18 17:53:30]-[草稿日期状态补声明] 结束

    // 图片添加 / 查看
    @State private var showImageSourceDialog = false
    @State private var showImagePicker = false
    // >>> CHANGE-[2026-08-17 11:20:00]-[食物编辑大图白屏] 开始
    // 原因: 大图页 fullScreenCover 内重新读文件易落空导致白屏，改为点击时直接传已加载的 UIImage
    // 回退: 删除 selectedImage 这一行及下方 fullScreenCover/点击回调的 selectedImage 赋值即可
    @State private var selectedImage: UIImage? = nil
    // <<< CHANGE-[2026-08-17 11:20:00]-[食物编辑大图白屏] 结束
    @State private var pickedImage: UIImage? = nil

    // 删除
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    // >>> CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 开始
    // 原因: 备注图片记录一打开就同步 LocalImageStore.load 读盘 + performSearch localSearch 双重主线程阻塞，
    //       超过 sheet 入场动画容忍阈值，系统判呈现失败→dismiss→重弹，表现即"白屏几秒后消失又重开"。
    //       改为异步缓存：进入 onAppear 后台读图，body 只读缓存，无图时显示占位。
    // 回退: 删除 loadedImages 这一行、onAppear 里的 Task.detached 读图段、noteCard 里 loadedImages 读取替换回 LocalImageStore.load 即可
    @State private var loadedImages: [String: UIImage] = [:]
    // 首帧守卫：init 给的初值 name 不要触发搜索，避免 sheet 入场时主线程 fetch 阻塞
    @State private var didInitialLoad = false
    // <<< CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 结束

    // 食物库搜索（与手动添加页共用 FoodSearcher，改名时自动检索 → 用户确认 → 营养自动更新）
    @State private var searchText: String = ""
    @State private var searchResults: [FoodSearchResult] = []
    @State private var isSearching: Bool = false
    @State private var showSearchResults: Bool = false
    @State private var isCloudSearching: Bool = false
    @State private var cloudErrorMessage: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    /// 当前重量下的总热量（用于标题栏右侧 pill 显示）。
    private var displayedKcalText: String {
        let base = Double(baseCaloriesText) ?? 0
        let weight = Double(weightText) ?? 100
        return String(format: "%.0f", base * weight / 100)
    }

    /// 来源标签：优先取 FoodSource 标记；无标记（老记录）兜底为「图片识别 / 好记AI帮记」
    private var sourceLabel: String {
        guard let entry = resolveEntry() else { return "" }
        if let o = sources.first?.origin, let label = FoodSource.displayLabel(for: o) { return label }
        return entry.imageName != nil ? NSLocalizedString("food.recognized", comment: "")
                                      : NSLocalizedString("food.by_chat", comment: "")
    }
    private var sourceIcon: String {
        guard let entry = resolveEntry() else { return "questionmark" }
        if let o = sources.first?.origin { return FoodSource.icon(for: o) }
        return entry.imageName != nil ? "photo" : "message"
    }
    /// 识别引擎来源中文标签（免费版AI识别 / Pro版AI…），无标记返回 nil
    private var recogSourceLabel: String? {
        recogSources.first.flatMap { RecogSource.displayLabel(for: $0.recogSourceRaw) }
    }
    private var sourceTag: some View {
        HStack(spacing: 4) {
            Image(systemName: sourceIcon)
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.sub)
            Text(sourceLabel)
                .font(AIATheme.Font.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let recogSourceLabel {
                Text(recogSourceLabel)
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(AIATheme.surfaceSecondary)
                    .clipShape(Capsule())
                    .lineLimit(1)
            }
        }
    }


    // MARK: - 主体内容（拆分自 body，降低类型推导深度）
    // >>> CHANGE-[2026-08-17 20:15:00]-[body 拆分降类型推导深度] 开始
    // 原因: body 主表达式原先内嵌 ZStack+ScrollView+6 个修饰链，触发 Swift 编译器
    //       「unable to type-check this expression in reasonable time」
    //       （249 行 toolbar Button 处的连锁报错，实为整个 body 表达式深度超限）。
    //       把 ZStack 内容抽成 contentStack，body 只剩一层修饰链。
    // 回退: 把 contentStack 展开回原 ZStack { ... } 整段即可。
    private var contentStack: some View {
        ZStack {
            AIATheme.fillSoft.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                        nameCard
                        infoCard
                        weightCard
                        nutritionCard
                        noteCard
                        deleteCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
    }
    // <<< CHANGE-[2026-08-17 20:15:00]-[body 拆分降类型推导深度] 结束

    var body: some View {
        // >>> CHANGE-[2026-08-17 16:40:00]-[编辑页去掉内部NavigationStack] 开始
        // 原因: sheet 内自建 NavigationStack + 条件 toolbar 首帧多轮重算，触发项目已知
        //       _NavigationRequestObserver 断言导致主线程卡死（页面渲染完成但"动不了"）。
        //       参照 EditTodoView+EditTodoSheet 已验证模式（2026-07-24 注释）：
        //       NavigationStack 移到 sheet 入口包一层。
        // 回退: 恢复 NavigationStack { 包裹，并把 RecordsViews.swift 的 sheet 入口改回直出 EditFoodView。
        contentStack
            // >>> CHANGE-[2026-08-17 21:10:00]-[食物编辑大图改全屏fullScreenCover] 开始
            // 原因: 用户要求编辑食物进大图=像聊天页那样全屏新页面。原 .overlay 浮层不是独立全屏容器，
            //       .statusBarHidden(true) 不生效（状态栏白胶囊仍在），且顶部"关闭/保存"被编辑页导航栏区域吞成色块。
            //       现 body 已拆 contentStack（20:15 解决 type-check）、点击时已传已加载 UIImage（11:20 解决白屏），
            //       fullScreenCover 两条历史坑均已排除，故改回与聊天页一致的 fullScreenCover。
            // 回退: 恢复 .overlay(alignment: .center) { if let selectedImage { ... } } 整段即可。
            .fullScreenCover(isPresented: Binding(
                get: { selectedImage != nil },
                set: { if !$0 { selectedImage = nil } }
            )) {
                if let img = selectedImage {
                    FullImageView(image: img, onDismiss: { selectedImage = nil })
                }
            }
            // <<< CHANGE-[2026-08-17 21:10:00]-[食物编辑大图改全屏fullScreenCover] 结束
            .navigationTitle("编辑食物")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(image: $pickedImage)
            }
            .confirmationDialog("添加图片", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    // 直接弹独立黑窗相机（不经 fullScreenCover，无白屏过渡）；
                    // 结果写回 pickedImage，触发下方既有的 onChange 存图逻辑。
                    Button("拍照") {
                        CameraPresenter.shared.present { img in
                            if let img { pickedImage = img }
                        }
                    }
                }
                Button("从相册选择") { showImagePicker = true }
                Button("取消", role: .cancel) {}
            }
            // >>> CHANGE-[2026-08-17 16:05:00]-[看大图时隐藏编辑页顶部按钮] 开始
            // 原因: 大图改成 ZStack 条件渲染后，NavigationStack 顶部"取消/保存"仍浮在大图上方，看大图时应隐藏。
            // 回退: 去掉外层 if selectedImage == nil 包裹，恢复两个 ToolbarItem 直接并列即可。
            .toolbar {
                // >>> CHANGE-[2026-08-17 16:40:00]-[toolbar稳定化] 开始
                // 原因: 条件 if selectedImage == nil 让 NavigationStack 首帧反复重建导航栏，
                //       加剧 _NavigationRequestObserver 多轮重算卡死。改为结构恒定的两个 ToolbarItem，
                //       看大图时用 opacity+disabled 隐藏，行为与原条件渲染一致。
                // 回退: 恢复 if selectedImage == nil 条件包裹即可。
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .opacity(selectedImage == nil ? 1 : 0)
                        .disabled(selectedImage != nil)
                        .accessibilityHidden(selectedImage != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(selectedImage == nil ? AIATheme.blue : .clear)
                        .disabled(selectedImage != nil)
                        .accessibilityHidden(selectedImage != nil)
                }
                // <<< CHANGE-[2026-08-17 16:40:00]-[toolbar稳定化] 结束
            }
            // <<< CHANGE-[2026-08-17 16:05:00]-[看大图时隐藏编辑页顶部按钮] 结束
            .alert("删除食物记录", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    pendingDeleteID = entryID
                    dismiss()
                }
            } message: {
                Text("删除后不可恢复，确定要删除吗？")
            }
            .onAppear {
                // >>> CHANGE-[2026-08-18 17:13:00]-[编辑页第一次点白屏] 开始
                // 原因: sheet 入场动画 + onAppear 同步写 13 个 @State,触发 NavigationStack 第二次 body diff,
                //       iOS 26 触发 NavigationRequestObserver 断言 → 白屏。改为先 snapshot backing 字段、再延后到
                //       下一帧(Task @MainActor)异步回填 @State,让入场动画跑完再设置,单次 body diff 即可。
                //       第二次点能进是因为状态容器缓存已填好的 @State。
                // 回退: 删除本 Task 包裹,改回同步写 @State。
                // 草稿模式：从 payload 填 @State 后即返回，不依赖 entryID 解析；保存时才落库。
                if let p = draftPayload {
                    loadDraftIntoState(p)
                    return
                }
                guard let entry = resolveEntry() else {
                    // 记录已失效/被删 → 直接关掉编辑页，不进崩溃路径
                    dismiss()
                    return
                }
                // 先把 entry 所有需读 backing 的字段 snapshot 出来(本闭包内完成),后续 Task 不再碰 backing
                let snapshotWeight = entry.weightGram ?? 100
                let snapshotName = entry.name
                let snapshotMeal = entry.meal
                let snapshotImageName = entry.imageName
                func deriveBase(_ base: Double?, _ total: Double, _ weight: Double) -> Double {
                    if let b = base, b > 0 { return b }
                    if total > 0 { return total / max(weight, 1) * 100 }
                    return 0
                }
                let snapshotBaseCal = deriveBase(entry.baseCalories, entry.calories, snapshotWeight)
                let snapshotBaseP = deriveBase(entry.baseProtein, entry.protein, snapshotWeight)
                let snapshotBaseC = deriveBase(entry.baseCarbs, entry.carbs, snapshotWeight)
                let snapshotBaseF = deriveBase(entry.baseFat, entry.fat, snapshotWeight)
                let snapshotBaseFi = deriveBase(entry.baseFiber, entry.fiber, snapshotWeight)
                let snapshotBaseS = deriveBase(entry.baseSugar, entry.sugar, snapshotWeight)
                let snapshotBaseNa = deriveBase(entry.baseSodium, entry.sodium, snapshotWeight)
                let targetSyncId = entry.syncId
                // 延后到下一帧,让 sheet 入场动画先跑完,避免与 @State 首次赋值竞争 NavigationStack 重算
                Task { @MainActor in
                    name = snapshotName
                    meal = snapshotMeal
                    weightText = String(format: "%.0f", snapshotWeight)
                    baseCaloriesText = String(format: "%.1f", snapshotBaseCal)
                    baseProteinText  = String(format: "%.1f", snapshotBaseP)
                    baseCarbsText    = String(format: "%.1f", snapshotBaseC)
                    baseFatText      = String(format: "%.1f", snapshotBaseF)
                    baseFiberText    = String(format: "%.1f", snapshotBaseFi)
                    baseSugarText    = String(format: "%.1f", snapshotBaseS)
                    baseSodiumText   = String(format: "%.1f", snapshotBaseNa)
                    sourceImageName = snapshotImageName
                    didInitialLoad = true  // 确保 onChange(name) 在首次填值后才触发搜索
                    // 懒加载备注：首次进入编辑页时按 syncId 取 FoodNote（1:1）
                    if let existing = try? context.fetch(FetchDescriptor<FoodNote>(
                        predicate: #Predicate { $0.syncId == targetSyncId })).first {
                        noteText = existing.note
                        noteImageNames = existing.imageNames
                    }
                    // 异步读图：避免主线程同步读文件阻塞
                    let names = ([snapshotImageName] + noteImageNames).compactMap { $0 }
                    Task.detached(priority: .userInitiated) {
                        let localDict: [String: UIImage] = {
                            var d: [String: UIImage] = [:]
                            for n in names {
                                if let img = LocalImageStore.load(n) {
                                    d[n] = img
                                }
                            }
                            return d
                        }()
                        await MainActor.run { loadedImages = localDict }
                    }
                }
                // <<< CHANGE-[2026-08-18 17:13:00]-[编辑页第一次点白屏] 结束
            }
            .onChange(of: pickedImage) { _, new in
                guard let img = new else { return }
                pickedImage = nil
                if let name = LocalImageStore.save(img) {
                    noteImageNames.append(name)
                    // >>> CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 开始
                    loadedImages[name] = img
                    // <<< CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 结束
                }
            }
            .onChange(of: name) { _, newValue in
                // >>> CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 开始
                // 首帧（init 设的初值）不触发搜索，避免 sheet 入场时主线程 fetch 阻塞
                if !didInitialLoad {
                    didInitialLoad = true
                    return
                }
                // <<< CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 结束
                performSearch(newValue)
            }
            .onDisappear {
                // 与 EditBillView 同款：先 dismiss 回列表，等动画结束后再执行删除，
                // 避免 syncDeleted 触发 @Query 重 fetch 与动画叠加卡死。
                if let id = pendingDeleteID {
                    pendingDeleteID = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        SafeDelete.foodByID(id, in: context)
                    }
                }
                // 取消未完成的联网任务，避免野指针
                searchTask?.cancel()
                searchTask = nil
            }
        // <<< CHANGE-[2026-08-17 16:40:00]-[编辑页去掉内部NavigationStack] 结束
    }

    // MARK: - 卡片
    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 与手动添加食物页一致：左侧放大镜 + "搜索食物库" 占位，提示可搜索本地/联网
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(AIATheme.Font.body)
                    .foregroundStyle(AIATheme.muted)
                TextField("搜索食物库", text: $name)
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
                    .autocorrectionDisabled()
                    .layoutPriority(1)
                if isSearching {
                    ProgressView().scaleEffect(0.7)
                } else {
                    sourceTag
                }
            }

            if showSearchResults {
                searchResultList
            } else if isCloudSearching {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("联网搜索中...")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.blue)
                }
            } else if let err = cloudErrorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.warning)
                    Text(err)
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.warning)
                }
            }
        }
        .padding(14)
        .card()
    }

    private var searchResultList: some View {
        VStack(spacing: 0) {
            ForEach(searchResults) { result in
                Button {
                    applySearchResult(result)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(AIATheme.Font.subhead.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("\(Int(result.kcal)) kcal/100g · P\(Int(result.protein)) C\(Int(result.carbs)) F\(Int(result.fat))")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.sub)
                        }
                        Spacer(minLength: 0)
                        sourceBadge(result.source)
                        Image(systemName: "arrow.right.circle.fill")
                            .font(AIATheme.Font.body)
                            .foregroundStyle(AIATheme.blue)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if result.id != searchResults.last?.id {
                    Divider().padding(.leading, 4)
                }
            }

            // ② 联网搜索按钮（始终可见，食物名非空时展示）——与手动添加食物页逻辑一致
            let trimmedSearch = name.trimmingCharacters(in: .whitespaces)
            if !trimmedSearch.isEmpty {
                if !searchResults.isEmpty {
                    Divider().padding(4)
                }
                Button {
                    triggerCloudSearch(trimmedSearch)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(AIATheme.blue.opacity(0.12))
                                .frame(width: 28, height: 28)
                            if isCloudSearching {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Image(systemName: "cloud.fill")
                                    .font(AIATheme.Font.caption.weight(.medium))
                                    .foregroundStyle(AIATheme.blue)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isCloudSearching ? "联网搜索中..." : "联网搜索营养")
                                .font(AIATheme.Font.subhead.weight(.medium))
                                .foregroundStyle(isCloudSearching ? AIATheme.muted : AIATheme.blue)
                            Text(isCloudSearching
                                 ? "正在查询 '\(trimmedSearch)' 的热量和营养信息"
                                 : "未在库中查到时，点击查询并自动填充表单")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.muted)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if !isCloudSearching {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(AIATheme.Font.body)
                                .foregroundStyle(AIATheme.blue)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isCloudSearching)

                // ③ 联网失败/无结果的错误提示（内联显示在按钮下方）
                if let err = cloudErrorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.warning)
                        Text(err)
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(AIATheme.warning)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            menuRow(icon: "clock.fill", label: "餐次", selection: $meal,
                    options: mealOptions.map { ($0, $0) })
        }
        .card()
    }

    private var weightCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("食用重量")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        adjustWeight(by: -10)
                    } label: {
                        Image(systemName: "minus")
                            .font(AIATheme.Font.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(AIATheme.food)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 4) {
                        TextField("手动输入", text: $weightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(AIATheme.Font.headline.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(minWidth: 44)
                        Text("克")
                            .font(AIATheme.Font.subhead)
                            .foregroundStyle(AIATheme.muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: AIATheme.rSM)
                            .stroke(weightText.isEmpty ? AIATheme.hairline : AIATheme.food, lineWidth: 1)
                    )

                    Button {
                        adjustWeight(by: 10)
                    } label: {
                        Image(systemName: "plus")
                            .font(AIATheme.Font.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(AIATheme.food)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("快速选择 · 或手动输入")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)

            let presets: [Int] = [50, 100, 150, 200, 250, 300]
            HStack(spacing: 10) {
                ForEach(presets, id: \.self) { value in
                    Button {
                        weightText = "\(value)"
                    } label: {
                        Text("\(value)g")
                            .font(AIATheme.Font.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(weightText == "\(value)" ? AIATheme.food : AIATheme.food.opacity(0.12))
                            .foregroundStyle(weightText == "\(value)" ? .white : AIATheme.food)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .card()
    }

    private var nutritionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏（含按当前重量计算的热量 pill）
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("营养成分（按当前重量）")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
                if !baseCaloriesText.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.food)
                        Text("\(displayedKcalText) kcal")
                            .font(AIATheme.Font.subhead.weight(.semibold))
                            .foregroundStyle(AIATheme.food)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AIATheme.food.opacity(0.10))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // 2×3 营养网格：6 大营养素；热量已在标题 pill 展示
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                      spacing: 8) {
                nutritionCell(icon: "fish.fill", label: "蛋白质", unit: "g",
                              binding: totalBinding(for: $baseProteinText), color: AIATheme.blue)
                nutritionCell(icon: "leaf.fill", label: "碳水", unit: "g",
                              binding: totalBinding(for: $baseCarbsText), color: AIATheme.amber)
                nutritionCell(icon: "drop.fill", label: "脂肪", unit: "g",
                              binding: totalBinding(for: $baseFatText), color: AIATheme.green)
                nutritionCell(icon: "leaf", label: "膳食纤维", unit: "g",
                              binding: totalBinding(for: $baseFiberText), color: AIATheme.health)
                nutritionCell(icon: "cube.fill", label: "糖", unit: "g",
                              binding: totalBinding(for: $baseSugarText), color: AIATheme.warn)
                nutritionCell(icon: "bolt.fill", label: "钠", unit: "mg",
                              binding: totalBinding(for: $baseSodiumText), color: AIATheme.food)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .card()
    }

    // MARK: - 备注卡（文字 + 来源原图 + 多图附件）
    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "note.text")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("备注")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
            }

            TextEditor(text: $noteText)
                .font(AIATheme.Font.body)
                .foregroundStyle(.primary)
                .frame(minHeight: 48)
                .scrollContentBackground(.hidden)

            // >>> CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 开始
            let hasSource = sourceImageName.map { loadedImages[$0] != nil } ?? false
            let hasNoteImg = noteImageNames.contains { loadedImages[$0] != nil }
            if hasSource || hasNoteImg {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        // 来源识别原图（绿色角标「来源」），点击看大图
                        if let sName = sourceImageName, let sImg = loadedImages[sName] {
                            thumbnail(image: sImg, badge: "来源",
                                      onTap: { selectedImage = sImg },
                                      onDelete: {
                                          LocalImageStore.delete(sName)
                                          loadedImages[sName] = nil
                                          sourceImageName = nil
                                      })
                        }
                        // 备注附件图片
                        ForEach(Array(noteImageNames.enumerated()), id: \.offset) { _, name in
                            if let img = loadedImages[name] {
                                thumbnail(image: img, badge: nil,
                                          onTap: { selectedImage = img },
                                          onDelete: {
                                              LocalImageStore.delete(name)
                                              loadedImages[name] = nil
                                              noteImageNames.removeAll { $0 == name }
                                          })
                            }
                        }
                        // <<< CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 结束
                        addImageButton
                    }
                    .padding(.vertical, 2)
                }
            } else {
                addImageButton
            }
        }
        .padding(14)
        .card()
    }

    /// 统一缩略图：点击看大图；右上角 X 删除；可选角标（如「来源」）。
    private func thumbnail(image: UIImage, badge: String?,
                           onTap: @escaping () -> Void,
                           onDelete: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                .overlay(alignment: .bottomLeading) {
                    if let badge {
                        Text(badge)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AIATheme.food)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "xmark.circle.fill")
                        .font(AIATheme.Font.body)
                        .foregroundStyle(AIATheme.muted)
                        .background(Circle().fill(AIATheme.surface))
                        .offset(x: 8, y: -8)
                }
        }
        .buttonStyle(.plain)
    }

    private var addImageButton: some View {
        Button {
            showImageSourceDialog = true
        } label: {
            RoundedRectangle(cornerRadius: AIATheme.rSM)
                .stroke(AIATheme.hairline, lineWidth: 1)
                .frame(width: 72, height: 72)
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(AIATheme.Font.headline.weight(.medium))
                            .foregroundStyle(AIATheme.muted)
                        Text("图片")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var deleteCard: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            Text("删除食物记录")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(AIATheme.warn)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AIATheme.warn.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: AIATheme.rMD).stroke(AIATheme.warn.opacity(0.25), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 通用行组件
    private func menuRow<T: Hashable>(icon: String, label: String, selection: Binding<T>,
                                       options: [(T, String)]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.muted)
                .frame(width: 20, height: 20, alignment: .center)
            Text(label)
                .font(AIATheme.Font.callout)
                .foregroundStyle(.primary)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { option in
                    Button(option.1) { selection.wrappedValue = option.0 }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first(where: { $0.0 == selection.wrappedValue })?.1 ?? "")
                        .font(AIATheme.Font.headline.weight(.medium))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
    }

    private func nutritionRow(icon: String, label: String, unit: String,
                              binding: Binding<String>, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AIATheme.Font.body)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12))
                .clipShape(Circle())
            Text(label)
                .font(AIATheme.Font.callout)
                .foregroundStyle(.primary)
            Spacer()
            TextField("0", text: binding)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(AIATheme.Font.headline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 80)
            Text(unit)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.muted)
                .frame(minWidth: 34, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    /// 营养网格单元：icon + 名称 + 输入框 + 单位，2×3 网格布局使用。
    /// 视觉上比 nutritionRow 更紧凑，适合等宽 cell。
    private func nutritionCell(icon: String, label: String, unit: String,
                               binding: Binding<String>, color: Color) -> some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(color)
                Text(label)
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                TextField("0", text: binding)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Text(unit)
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(AIATheme.fillSoft)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rXS))
    }

    /// 把「每100g基准」和「当前重量」映射成「当前重量下的总量」Binding。
    /// 用户编辑总量时，反向更新每100g基准，保证改重量后能正确联动。
    // >>> CHANGE-[2026-08-18 18:14:44]-[营养成分显示精度] 开始
    // 原因: 营养板块6格(蛋白质/碳水/脂肪/纤维/糖/钠)原 get 闭包用 %.0f 永远整数,需求要求有小数显示1位
    // 回退: 恢复 %.0f 即可
    private func totalBinding(for base: Binding<String>) -> Binding<String> {
        Binding(
            get: {
                let baseValue = Double(base.wrappedValue) ?? 0
                let weight = Double(self.weightText) ?? 100
                let total = baseValue * weight / 100
                let rounded = (total * 10).rounded() / 10
                if rounded == rounded.rounded(.towardZero) {
                    return "\(Int(rounded))"
                } else {
                    return String(format: "%.1f", rounded)
                }
            },
            set: { newTotal in
                let total = Double(newTotal) ?? 0
                let weight = max(Double(self.weightText) ?? 100, 1)
                base.wrappedValue = String(format: "%.1f", total / weight * 100)
            }
        )
    }
    // <<< CHANGE-[2026-08-18 18:14:44]-[营养成分显示精度] 结束

    /// 重量步进调整（步长 10g，下限 0）
    private func adjustWeight(by delta: Int) {
        let raw = weightText.trimmingCharacters(in: .whitespaces)
        let current = Double(raw) ?? 0
        let newValue = max(0, current + Double(delta))
        if newValue == floor(newValue) {
            weightText = "\(Int(newValue))"
        } else {
            weightText = String(format: "%.1f", newValue)
        }
    }

    private func save() {
        // 草稿模式：保存时才真正建 FoodEntry 入库（方案 B：先改草稿、保存才落库）
        if let p = draftPayload {
            let entry = FoodEntry(
                name: name.trimmingCharacters(in: .whitespaces).isEmpty ? (p.name ?? "未命名食物") : name.trimmingCharacters(in: .whitespaces),
                calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sugar: 0, sodium: 0,
                portion: "\(Int(max(Double(weightText) ?? 100, 1)))克",
                meal: meal,
                date: entryDate,
                weightGram: max(Double(weightText) ?? 100, 1),
                baseCalories: nil, baseProtein: nil, baseCarbs: nil, baseFat: nil,
                baseFiber: nil, baseSugar: nil, baseSodium: nil,
                imageName: sourceImageName)
            // >>> CHANGE-[2026-08-26 12:14:09]-[待确认卡保存崩溃加固] 开始
            // 原因：草稿模式新建的 FoodEntry 在 context.insert 之前访问属性，
            //       某些 SwiftData 配置下 backing 尚未就绪，写属性会触发
            //       _InvalidFutureBackingData 断言崩(EXC_BREAKPOINT)。
            //       改为先 insert 拿到合法 backing，再 applyState 写属性。
            // 回退：把下面两行顺序换回 applyState(to: entry) 在前、context.insert(entry) 在后。
            context.insert(entry)
            applyState(to: entry)
            // <<< CHANGE-[2026-08-26 12:14:09]-[待确认卡保存崩溃加固] 结束
            // 备注：草稿首次保存即新建 FoodNote
            if !(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !noteImageNames.isEmpty {
                context.insert(FoodNote(syncId: entry.syncId, note: noteText, imageNames: noteImageNames))
            }
            try? context.save()
            CloudSyncManager.shared.syncAfterLocalChange(context: context)
            onDraftSaved?(entry.syncId.uuidString)
            dismiss()
            return
        }

        // 现取活实例；失效/被删直接放弃保存（不崩）
        guard let entry = resolveEntry() else { return }
        applyState(to: entry)

        // 备注：按 syncId 关联 FoodNote；无内容则删除（若有）
        let targetSyncId = entry.syncId
        let existing = try? context.fetch(FetchDescriptor<FoodNote>(
            predicate: #Predicate { $0.syncId == targetSyncId })).first
        let noteEmpty = noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if noteEmpty && noteImageNames.isEmpty {
            if let existing { context.delete(existing) }
        } else if let existing {
            existing.note = noteText
            existing.imageNames = noteImageNames
            existing.updatedAt = .now
        } else {
            let fn = FoodNote(syncId: entry.syncId, note: noteText, imageNames: noteImageNames)
            context.insert(fn)
        }

        try? context.save()
        // 编辑饮食记录后触发增量同步，让改动尽快推上云端，绑定后小程序可见
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        dismiss()
    }

    /// 把当前 @State 字段写入给定 FoodEntry（草稿新建 & 已保存实例两种路径复用）。
    private func applyState(to entry: FoodEntry) {
        // >>> CHANGE-[2026-08-26 12:14:09]-[待确认卡保存崩溃加固] 开始
        // 防御：传入的 entry 若 backing 已失效(幽灵对象/未就绪)，
        //       写属性会触发 SwiftData _InvalidFutureBackingData 断言崩(EXC_BREAKPOINT)。
        //       草稿新建实例 insert 后 storeIdentifier 非 nil、modelContext 非 nil；
        //       已保存实例经 resolveEntry 取回时同样校验，避免崩。
        guard entry.persistentModelID.storeIdentifier != nil else { return }
        guard entry.modelContext != nil else { return }
        guard !entry.syncDeleted else { return }
        // <<< CHANGE-[2026-08-26 12:14:09]-[待确认卡保存崩溃加固] 结束
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        entry.name = trimmed.isEmpty ? entry.name : trimmed
        entry.meal = meal
        let weight = max(Double(weightText) ?? 100, 1)
        let baseCal = Double(baseCaloriesText) ?? 0
        let basePro = Double(baseProteinText) ?? 0
        let baseCar = Double(baseCarbsText) ?? 0
        let baseFat = Double(baseFatText) ?? 0
        let baseFib = Double(baseFiberText) ?? 0
        let baseSug = Double(baseSugarText) ?? 0
        let baseSod = Double(baseSodiumText) ?? 0
        entry.weightGram = weight
        entry.baseCalories = baseCal
        entry.baseProtein = basePro
        entry.baseCarbs = baseCar
        entry.baseFat = baseFat
        entry.baseFiber = baseFib
        entry.baseSugar = baseSug
        entry.baseSodium = baseSod
        entry.calories = baseCal * weight / 100
        entry.protein = basePro * weight / 100
        entry.carbs = baseCar * weight / 100
        entry.fat = baseFat * weight / 100
        entry.fiber = baseFib * weight / 100
        entry.sugar = baseSug * weight / 100
        entry.sodium = baseSod * weight / 100
        entry.portion = "\(Int(weight))克"
        entry.imageName = sourceImageName
        entry.syncUpdatedAt = .now
    }

    // MARK: - 食物库搜索（与 AddFoodManualView 共用 FoodSearcher）

    /// 结果项来源 badge：内置库（绿） / 历史缓存（灰） / 联网查询（蓝）
    @ViewBuilder
    private func sourceBadge(_ source: String) -> some View {
        switch source {
        case "cloud":
            Text("联网查询")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.blue)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(AIATheme.blue.opacity(0.12))
                .clipShape(Capsule())
        case "cache":
            Text("历史缓存")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(AIATheme.surfaceSecondary)
                .clipShape(Capsule())
        default:
            Text("内置库")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.green)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(AIATheme.green.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    /// 当食物名变化时触发检索（本地）。联网搜索改为用户手动点「联网搜索营养」按钮触发，
    /// 与手动添加食物页逻辑一致：本地 NutritionLibrary + FoodMeta 命中即展示，
    /// 未命中时由用户在结果列表底部点按钮主动联网查询，不再自动发起。
    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            searchResults = []
            showSearchResults = false
            isCloudSearching = false
            cloudErrorMessage = nil
            return
        }
        isSearching = true
        showSearchResults = true
        cloudErrorMessage = nil
        isCloudSearching = false

        // >>> CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 开始
        // 本地检索依赖 ModelContext（Swift 6 下为 main-actor 隔离），必须在主线程执行。
        // 搜索为内存 NutritionLibrary 命中 + 单次 FoodMeta fetch，耗时极短，不在入场动画期
        // （onChange 由用户输字触发，已被 didInitialLoad 守卫避开首帧），主线程同步执行可接受。
        let results = FoodSearcher.localSearch(trimmed, foodMetas: foodMetas, in: context)
        searchResults = results
        isSearching = false
        // <<< CHANGE-[2026-08-17 14:30:00]-[编辑页白屏重弹] 结束
        // 联网搜索由 searchResultList 底部的「联网搜索营养」按钮手动触发，不自动发起。
    }

    /// 用户点击「联网搜索营养」按钮触发：调云端 queryFood，命中后自动填充表单并落库 FoodMeta。
    /// 逻辑与手动添加食物页 triggerCloudSearch 完全一致（300ms 防抖 + 业务错误/系统错误分别提示）。
    private func triggerCloudSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // 取消旧任务，避免上一轮未完成覆盖本轮结果
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)  // 300ms 防抖，连点不浪费请求
                if Task.isCancelled { return }
                isCloudSearching = true
                cloudErrorMessage = nil
                let result: FoodSearchResult?
                do {
                    result = try await FoodSearcher.cloudSearch(name: trimmed)
                } catch let e as NSError where e.domain == "Recognize" && e.code == -4 {
                    // 云端业务错误（如"该食物不在数据库"）：直接展示云端给的原因
                    isCloudSearching = false
                    cloudErrorMessage = e.localizedDescription
                    return
                } catch {
                    // 网络/超时等系统错误：给通用提示，避免暴露底层技术信息
                    isCloudSearching = false
                    cloudErrorMessage = "联网搜索失败，请检查网络后重试"
                    return
                }
                if Task.isCancelled { return }
                guard let result else {
                    isCloudSearching = false
                    cloudErrorMessage = "联网未找到该食物，请手动填写"
                    return
                }
                // 命中：自动填充表单 + 落库 FoodMeta（applySearchResult 内部已 upsert）
                applySearchResult(result)
                isCloudSearching = false
            } catch {
                isCloudSearching = false
                if !Task.isCancelled {
                    cloudErrorMessage = "联网搜索失败，请稍后重试"
                }
            }
        }
    }

    /// 用户点击搜索结果：把 base* 字段全部覆盖为该食物每 100g 营养。
    /// 重量保留用户当前值（用户可能之前手动改过），由 displayedKcalText 按比例算出当前份量下的总热量。
    private func applySearchResult(_ result: FoodSearchResult) {
        // 云端 queryFood 会为复合菜品返回带口径的名称（如「玉米猪肉饺子（熟，约值）」），
        // 括号内容是模型标注的"估算说明"，在落库/展示前一律剥掉。
        let cleanName = result.cleanedName()
        name = cleanName
        baseCaloriesText = String(format: "%.1f", result.kcal)
        baseProteinText = result.protein > 0 ? String(format: "%.1f", result.protein) : ""
        baseCarbsText = result.carbs > 0 ? String(format: "%.1f", result.carbs) : ""
        baseFatText = result.fat > 0 ? String(format: "%.1f", result.fat) : ""
        baseFiberText = result.fiber > 0 ? String(format: "%.1f", result.fiber) : ""
        baseSugarText = result.sugar > 0 ? String(format: "%.1f", result.sugar) : ""
        baseSodiumText = result.sodium > 0 ? String(format: "%.1f", result.sodium) : ""
        searchText = cleanName
        searchResults = []
        showSearchResults = false

        FoodMetaStore.upsert(
            name: cleanName, displayName: cleanName,
            kcal: result.kcal, protein: result.protein,
            carbs: result.carbs, fat: result.fat,
            fiber: result.fiber, sugar: result.sugar, sodium: result.sodium,
            source: result.source, in: context
        )
    }
}

// MARK: - 账单多草稿（添加模式，参照 AddFoodManualView 的 FoodDraft）
private struct BillDraft: Identifiable {
    let id = UUID()
    /// 编辑/首个草稿挂靠的真实 Bill（添加模式首个由 caller 软删传入；其余为 nil，保存时新建）
    var existingBill: Bill?
    var merchant: String
    var amountText: String
    var category: String
    var time: Date
    var isIncome: Bool
    var note: String
    var imageName: String?
    // 每卡独立 UI 状态
    var showCategoryPicker = false
    var showImageSourceDialog = false
    var showImagePicker = false
    var pickedImage: UIImage? = nil
    // >>> CHANGE-[2026-08-17 15:00:00]-[草稿卡大图改ZStack overlay] 开始
    var selectedImage: UIImage? = nil
    // <<< CHANGE-[2026-08-17 15:00:00]-[草稿卡大图改ZStack overlay] 结束
    // 结果态
    var saved = false
    var savedBill: Bill? = nil

    init(bill: Bill) {
        self.existingBill = bill
        self.merchant = bill.merchant
        self.amountText = bill.amount > 0 ? String(format: "%.2f", bill.amount) : ""
        self.category = bill.category
        self.time = bill.time
        self.isIncome = bill.isIncome
        self.note = bill.note
        self.imageName = bill.imageName
    }

    init() {
        self.merchant = ""
        self.amountText = ""
        self.category = "餐饮"
        self.time = .now
        self.isIncome = false
        self.note = ""
        self.imageName = nil
    }
}

// MARK: - 账单编辑（支持编辑 + 手动添加两种模式；UI/逻辑共用，仅 deleteCard 和 title 切换）
struct EditBillView: View {
    let bill: Bill
    let isAdding: Bool          // true = 手动添加模式（不显示删除按钮，title 改"添加账单"）
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 识别引擎来源标记（1:1 关联 Bill.syncId）
    @Query private var recogSources: [RecogSource]

    @State private var merchant: String
    @State private var amountText: String
    @State private var category: String
    @State private var time: Date
    @State private var note: String
    @State private var isIncome: Bool
    @State private var imageName: String?
    @State private var showCategoryPicker = false
    @State private var showImageSourceDialog = false
    @State private var showImagePicker = false
    @State private var showDeleteConfirm = false
    // >>> CHANGE-[2026-08-17 11:20:00]-[账单编辑大图白屏] 开始
    @State private var selectedImage: UIImage? = nil
    // <<< CHANGE-[2026-08-17 11:20:00]-[账单编辑大图白屏] 结束
    @State private var pickedImage: UIImage? = nil
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    /// 添加模式下的多草稿（参照 AddFoodManualView）：每张卡是一个独立 BillDraft，
    /// 保存后变只读摘要卡，可继续"添加账单"连续添加，不退出页面。
    @State private var drafts: [BillDraft] = []

    /// 添加模式下，被用户删除的"已保存草稿"对应的真实 Bill 的 persistentModelID。
    /// 删除交互只做内存 removeAll，真实软删延后到 onDisappear 用 ID 版本执行，
    /// 避免删除瞬间 syncDeleted=true 触发 @Query 重 fetch 与 ForEach 动画竞态卡死。
    @State private var pendingDeleteBillIDs: Set<PersistentIdentifier> = []


    init(bill: Bill, isAdding: Bool = false) {
        self.bill = bill
        self.isAdding = isAdding
        _merchant = State(initialValue: bill.merchant)
        // 添加模式：amountText 初值空，让 placeholder "0.00" 像"如 星巴克"一样点击消失；
        // 编辑模式：保留原数值，placeholder 不显示。
        _amountText = State(initialValue: isAdding ? "" : String(format: "%.2f", bill.amount))
        _category = State(initialValue: bill.category)
        _time = State(initialValue: bill.time)
        _note = State(initialValue: bill.note)
        _isIncome = State(initialValue: bill.isIncome)
        _imageName = State(initialValue: bill.imageName)
        let sid = bill.syncId
        _recogSources = Query(filter: #Predicate<RecogSource> { $0.syncId == sid })
        // 添加模式：用 caller 传入的软删草稿 Bill 初始化第一张卡
        if isAdding {
            _drafts = State(initialValue: [BillDraft(bill: bill)])
        }
    }

    /// 识别引擎来源中文标签（免费版AI识别 / Pro版AI…），无标记返回 nil
    private var recogSourceLabel: String? {
        recogSources.first.flatMap { RecogSource.displayLabel(for: $0.recogSourceRaw) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            // 顶部锚点：删除草稿前滚回此处，归零偏移，
                            // 避免删最后一张时 ScrollView contentOffset 越界卡死。
                            Color.clear.frame(height: 0).id("billDraftTop")
                            if isAdding {
                                addMoreBody(proxy: proxy)
                            } else {
                                infoCard
                                incomeCard
                                noteCard
                                deleteCard    // 添加模式不显示删除按钮
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.immediately)
                }
                // >>> CHANGE-[2026-08-17 15:00:00]-[编辑页大图改ZStack overlay] 开始
                // 原因: fullScreenCover 挂在 NavigationStack 上 present 首帧易撞 NavigationStack 多轮重算断言被强制 dismiss，
                //      表现点小图白屏后自动回编辑页。改为 ZStack 内条件渲染绕开系统转场。
                // 回退: 删除此 if 块，恢复 fullScreenCover(isPresented: $showFullImage) 写法即可
                if let selectedImage {
                    FullImageView(image: selectedImage, onDismiss: { self.selectedImage = nil })
                        .ignoresSafeArea()
                        .zIndex(100)
                        .transition(.opacity)
                }
                // <<< CHANGE-[2026-08-17 15:00:00]-[编辑页大图改ZStack overlay] 结束
            }
            .navigationTitle(isAdding ? "添加账单" : "编辑账单")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCategoryPicker) {
                BillCategoryPickerSheet(selection: $category)
            }
            // >>> CHANGE-[2026-08-17 16:05:00]-[看大图时隐藏编辑页顶部按钮] 开始
            // 原因: 大图改成 ZStack 条件渲染后，NavigationStack 顶部"取消/保存/完成"仍浮在大图上方，看大图时应隐藏。
            // 回退: 去掉外层 if selectedImage == nil 包裹，恢复 ToolbarItem 直接并列即可。
            .toolbar {
                if selectedImage == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isAdding {
                            // 还有待保存草稿 → "保存"（批量入库）；全部已保存 → "完成"直接关闭
                            if drafts.contains(where: { !$0.saved }) {
                                Button("保存") { saveAllDrafts() }
                                    .font(AIATheme.Font.callout.weight(.semibold))
                                    .foregroundStyle(AIATheme.blue)
                            } else {
                                Button("完成") { dismiss() }
                                    .font(AIATheme.Font.callout.weight(.semibold))
                                    .foregroundStyle(AIATheme.blue)
                            }
                        } else {
                            Button("保存") { save() }
                                .font(AIATheme.Font.callout.weight(.semibold))
                                .foregroundStyle(AIATheme.blue)
                        }
                    }
                }
            }
            // <<< CHANGE-[2026-08-17 16:05:00]-[看大图时隐藏编辑页顶部按钮] 结束
            .confirmationDialog("添加图片", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    // 直接弹独立黑窗相机（不经 fullScreenCover，无白屏过渡）；
                    // 结果写回 pickedImage，触发既有的 onChange 存图逻辑。
                    Button("拍照") {
                        CameraPresenter.shared.present { img in
                            if let img { pickedImage = img }
                        }
                    }
                }
                Button("从相册选择") { showImagePicker = true }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(image: $pickedImage)
            }
            .alert("删除账单", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    pendingDeleteID = bill.persistentModelID
                    dismiss()
                }
            } message: {
                Text("删除后不可恢复，确定要删除吗？")
            }
            .onChange(of: pickedImage) { _, new in
                guard let img = new else { return }
                pickedImage = nil
                if let name = LocalImageStore.save(img) {
                    imageName = name
                }
            }
            .onDisappear {
                // 与 BillDetailView 同款：先 dismiss 回列表，等 sheet 动画完全结束后再执行删除，
                // 避免 syncDeleted=true 触发 @Query 重 fetch 与动画叠加卡死。
                if let id = pendingDeleteID {
                    pendingDeleteID = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        SafeDelete.billByID(id, in: context)
                    }
                }
            }
        }
    }

    // MARK: - 添加模式：多草稿主体
    private func addMoreBody(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 16) {
            ForEach($drafts, id: \.id) { $d in
                if d.saved, let b = d.savedBill {
                    savedBillSummary(b, draft: $d, proxy: proxy)
                } else {
                    draftForm($d, proxy: proxy)
                }
            }
        }
        .onDisappear {
            // 用户关闭整页时才真正软删被删的已保存草稿。
            // 此刻页面已离开视图树，@Query 重 fetch 不会与删除动画竞争，无卡死风险。
            let ids = pendingDeleteBillIDs
            pendingDeleteBillIDs.removeAll()
            for id in ids {
                SafeDelete.billByID(id, in: context)
            }
        }
    }

    /// 未保存草稿卡：独立可编辑表单 + 底部"保存 / 删除"
    private func draftForm(_ draft: Binding<BillDraft>, proxy: ScrollViewProxy) -> some View {
        ZStack {
            VStack(spacing: 0) {
            VStack(spacing: 0) {
                billRow(icon: "building.2.fill", label: "商户 / 对象", text: draft.merchant, placeholder: "如 星巴克")
                Divider().padding(.leading, 46)
                HStack(spacing: 12) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(AIATheme.muted)
                        .frame(width: 20, alignment: .center)
                    Text("金额")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("¥")
                        .font(AIATheme.Font.headline.weight(.medium))
                        .foregroundStyle(AIATheme.muted)
                    TextField("0.00", text: draft.amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(AIATheme.Font.headline.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(width: 100)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                Divider().padding(.leading, 46)
                // 分类选择行
                let selected = draft.category.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty ? "其他" : draft.category.wrappedValue
                Button {
                    draft.showCategoryPicker.wrappedValue = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tag.fill")
                            .font(AIATheme.Font.subhead)
                            .foregroundStyle(AIATheme.muted)
                            .frame(width: 20, alignment: .center)
                        Text("分类")
                            .font(AIATheme.Font.callout)
                            .foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 6) {
                            Text(BillCategoryHelpers.icon(for: selected))
                                .font(AIATheme.Font.subhead)
                            Text(selected)
                                .font(AIATheme.Font.headline.weight(.medium))
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.right")
                                .font(AIATheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AIATheme.muted)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 46)
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(AIATheme.muted)
                        .frame(width: 20, alignment: .center)
                    Text("时间")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(.primary)
                    Spacer()
                    DatePicker("", selection: draft.time, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .labelsHidden()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }
            .card()

            // 收入开关
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                    .frame(width: 20, alignment: .center)
                Text("收入（非支出）")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("", isOn: draft.isIncome)
                    .labelsHidden()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .card()

            // 备注 + 图片
            VStack(alignment: .leading, spacing: 8) {
                Text("备注")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                TextEditor(text: draft.note)
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .scrollContentBackground(.hidden)
                if let img = LocalImageStore.load(draft.imageName.wrappedValue) {
                    HStack(spacing: 12) {
                        ZStack(alignment: .topTrailing) {
                            Button {
                                draft.selectedImage.wrappedValue = img
                            } label: {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                            }
                            .buttonStyle(.plain)

                            Button {
                                draft.imageName.wrappedValue = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(AIATheme.Font.body)
                                    .foregroundStyle(AIATheme.muted)
                                    .background(Circle().fill(AIATheme.surface))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                        }

                        Button {
                            draft.showImageSourceDialog.wrappedValue = true
                        } label: {
                            RoundedRectangle(cornerRadius: AIATheme.rSM)
                                .stroke(AIATheme.hairline, lineWidth: 1)
                                .frame(width: 64, height: 64)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(AIATheme.Font.headline.weight(.medium))
                                        .foregroundStyle(AIATheme.muted)
                                }
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                } else {
                    Button {
                        draft.showImageSourceDialog.wrappedValue = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(AIATheme.Font.subhead)
                            Text("添加图片")
                                .font(AIATheme.Font.callout.weight(.medium))
                        }
                        .foregroundStyle(AIATheme.sub)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(AIATheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .card()

            // 底部"删除单条"：仅当草稿 ≥ 2 张时展示（刚进入 1 张时不展示）
            if drafts.count > 1 {
                HStack(spacing: 12) {
                    Button {
                        requestDeleteDraft(draft)
                    } label: {
                        Text("删除")
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(AIATheme.warn)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AIATheme.warn.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: AIATheme.rMD).stroke(AIATheme.warn.opacity(0.25), lineWidth: 0.5))
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
        }
        // >>> CHANGE-[2026-08-17 15:00:00]-[草稿卡大图改ZStack overlay] 开始
        if let sel = draft.selectedImage.wrappedValue {
            FullImageView(image: sel, onDismiss: { draft.selectedImage.wrappedValue = nil })
                .ignoresSafeArea()
                .zIndex(100)
                .transition(.opacity)
        }
        // <<< CHANGE-[2026-08-17 15:00:00]-[草稿卡大图改ZStack overlay] 结束
        }
        .sheet(isPresented: draft.showCategoryPicker) {
            BillCategoryPickerSheet(selection: draft.category)
        }
        .confirmationDialog("添加图片", isPresented: draft.showImageSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍照") {
                    CameraPresenter.shared.present { img in
                        if let img { draft.pickedImage.wrappedValue = img }
                    }
                }
            }
            Button("从相册选择") { draft.showImagePicker.wrappedValue = true }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: draft.showImagePicker) {
            ImagePicker(image: draft.pickedImage)
        }
        .onChange(of: draft.pickedImage.wrappedValue) { _, new in
            guard let img = new else { return }
            draft.pickedImage.wrappedValue = nil
            if let name = LocalImageStore.save(img) {
                draft.imageName.wrappedValue = name
            }
        }
    }

    /// 已保存摘要卡（只读，可"编辑"退回草稿或"删除"）
    private func savedBillSummary(_ b: Bill, draft: Binding<BillDraft>, proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: b.isIncome ? "arrow.down.circle.fill" : "creditcard.fill")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(b.isIncome ? AIATheme.income : AIATheme.expense)
                Text(b.merchant.isEmpty ? "未命名" : b.merchant)
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(String(format: "%@¥%.2f", b.isIncome ? "+" : "-", b.amount))
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(b.isIncome ? AIATheme.income : AIATheme.expense)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)
            HStack(spacing: 6) {
                Text(BillCategoryHelpers.icon(for: b.category.isEmpty ? "其他" : b.category))
                    .font(AIATheme.Font.subhead)
                Text(b.category.isEmpty ? "其他" : b.category)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            HStack(spacing: 12) {
                Button {
                    draft.wrappedValue.saved = false   // 退回草稿重新编辑
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .font(AIATheme.Font.caption)
                        Text("编辑")
                    }
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                Divider()
                Button {
                    requestDeleteDraft(draft)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(AIATheme.Font.caption)
                        Text("删除")
                    }
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.warn)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 10)
        }
        .card()
    }

    /// 把一张草稿持久化成真实 Bill（复用 syncAfterLocalChange 触发同步）
    private func persistDraft(_ draft: Binding<BillDraft>) {
        var d = draft.wrappedValue
        let trimmed = d.merchant.trimmingCharacters(in: .whitespaces)
        let amount = Double(d.amountText) ?? 0
        if let b = d.existingBill {
            b.merchant = trimmed.isEmpty ? b.merchant : trimmed
            b.amount = amount
            b.category = d.category.trimmingCharacters(in: .whitespaces)
            b.time = d.time
            b.note = d.note
            b.isIncome = d.isIncome
            b.imageName = d.imageName
            b.syncDeleted = false
            b.syncUpdatedAt = .now
            d.savedBill = b
        } else {
            let b = Bill(
                merchant: trimmed.isEmpty ? "未命名" : trimmed,
                amount: amount,
                category: d.category.trimmingCharacters(in: .whitespaces),
                time: d.time,
                confirmed: true
            )
            b.isIncome = d.isIncome
            b.note = d.note
            b.imageName = d.imageName
            b.syncDeleted = false
            context.insert(b)
            d.savedBill = b
        }
        d.saved = true
        draft.wrappedValue = d
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        // 全部已保存则自动关闭（与 toolbar "保存" 行为一致）
        if !drafts.contains(where: { !$0.saved }) {
            dismiss()
        }
    }

    /// 请求删除一张草稿：就地实时移除该卡片，不关闭整个页面。
    /// 删除交互全程零 SwiftData 写入：只做纯内存 removeAll（ForEach 用稳定 UUID id 正确 diff 卸载），
    /// 真实 Bill 的软删延后到 onDisappear 用 billByID（ID 版本）执行 —— 此时页面已不在视图树，
    /// @Query 重 fetch 不会与删除动画在主线程同步竞争，彻底消除"删第二张卡死"。
    /// 未保存草稿本就未入库（savedBill == nil），无需记 ID。
    private func requestDeleteDraft(_ draft: Binding<BillDraft>) {
        let targetID = draft.wrappedValue.id
        if let bill = draft.wrappedValue.savedBill ?? draft.wrappedValue.existingBill {
            pendingDeleteBillIDs.insert(bill.persistentModelID)
        }
        drafts.removeAll { $0.id == targetID }
    }

    /// 批量保存所有未保存草稿（toolbar "保存"）
    private func saveAllDrafts() {
        // 先快照未保存草稿的 id，循环内不直接按下标改 drafts，避免下标越界
        let unsavedIDs = drafts.filter { !$0.saved }.map { $0.id }
        for id in unsavedIDs {
            if let index = drafts.firstIndex(where: { $0.id == id }) {
                let binding = $drafts[index]
                persistDraft(binding)
            }
        }
        // 全部保存完毕 → 关闭页面
        dismiss()
    }

    // MARK: - 卡片
    private var infoCard: some View {
        VStack(spacing: 0) {
            if let recogSourceLabel {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                    Text(recogSourceLabel)
                        .font(AIATheme.Font.micro.weight(.medium))
                        .foregroundStyle(AIATheme.sub)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            billRow(icon: "building.2.fill", label: "商户 / 对象", text: $merchant, placeholder: "如 星巴克")
            Divider().padding(.leading, 46)
            HStack(spacing: 12) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                    .frame(width: 20, alignment: .center)
                Text("金额")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                Text("¥")
                    .font(AIATheme.Font.headline.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(AIATheme.Font.headline.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 100)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            Divider().padding(.leading, 46)
            categoryRow
            Divider().padding(.leading, 46)
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                    .frame(width: 20, alignment: .center)
                Text("时间")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                DatePicker("", selection: $time, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
        }
        .card()
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("备注")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            TextEditor(text: $note)
                .font(AIATheme.Font.body)
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
                .scrollContentBackground(.hidden)
            if let img = LocalImageStore.load(imageName) {
                HStack(spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        Button {
                            selectedImage = img
                        } label: {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                        }
                        .buttonStyle(.plain)

                        Button {
                            imageName = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(AIATheme.Font.body)
                                .foregroundStyle(AIATheme.muted)
                                .background(Circle().fill(AIATheme.surface))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }

                    Button {
                        showImageSourceDialog = true
                    } label: {
                        RoundedRectangle(cornerRadius: AIATheme.rSM)
                            .stroke(AIATheme.hairline, lineWidth: 1)
                            .frame(width: 64, height: 64)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(AIATheme.Font.headline.weight(.medium))
                                    .foregroundStyle(AIATheme.muted)
                            }
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            } else {
                Button {
                    showImageSourceDialog = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(AIATheme.Font.subhead)
                        Text("添加图片")
                            .font(AIATheme.Font.callout.weight(.medium))
                    }
                    .foregroundStyle(AIATheme.sub)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(AIATheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .card()
    }

    private var incomeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.muted)
                .frame(width: 20, alignment: .center)
            Text("收入（非支出）")
                .font(AIATheme.Font.callout)
                .foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: $isIncome)
                .labelsHidden()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .card()
    }

    private var deleteCard: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            Text("删除账单")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(AIATheme.warn)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AIATheme.warn.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: AIATheme.rMD).stroke(AIATheme.warn.opacity(0.25), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分类选择行
    private var categoryRow: some View {
        let selected = category.trimmingCharacters(in: .whitespaces).isEmpty ? "其他" : category
        return Button {
            showCategoryPicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag.fill")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                    .frame(width: 20, alignment: .center)
                Text("分类")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 6) {
                    Text(BillCategoryHelpers.icon(for: selected))
                        .font(AIATheme.Font.subhead)
                    Text(selected)
                        .font(AIATheme.Font.headline.weight(.medium))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func billRow(icon: String, label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.muted)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(AIATheme.Font.callout)
                .foregroundStyle(.primary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .font(AIATheme.Font.headline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
    }

    private func save() {
        let trimmed = merchant.trimmingCharacters(in: .whitespaces)
        bill.merchant = trimmed.isEmpty ? bill.merchant : trimmed
        bill.amount = Double(amountText) ?? bill.amount
        bill.category = category.trimmingCharacters(in: .whitespaces)
        bill.time = time
        bill.note = note
        bill.isIncome = isIncome
        bill.imageName = imageName
        bill.syncUpdatedAt = .now
        if isAdding {
            // 草稿 Bill 在 addNewBill 时设了 syncDeleted=true（被 @Query 谓词过滤，sheet 期间背景干净）；
            // 用户点保存 → 把 syncDeleted 改回 false，Bill 复活并显示在列表里
            bill.syncDeleted = false
        }
        try? context.save()
        // 编辑/新增账单后触发增量同步，让改动尽快推上云端，绑定后小程序可见
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        dismiss()
    }
}

// MARK: - 账单分类选择器
struct BillCategoryPickerSheet: View {
    @Binding var selection: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var sortedCategories: [String] = billCategoryOptions

    private var displaySelection: String {
        selection.trimmingCharacters(in: .whitespaces).isEmpty ? "其他" : selection
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(sortedCategories, id: \.self) { cat in
                            categoryCell(cat)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("选择分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear(perform: sortCategoriesByUsage)
        }
    }

    /// 按用户实际使用次数排序：使用次数多的靠前；次数相同保持原固定顺序；新增分类排在已知分类之后；"其他"始终垫底。
    private func sortCategoriesByUsage() {
        var counts: [String: Int] = [:]
        var userCategories: Set<String> = []
        if let bills = try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { !$0.syncDeleted })) {
            for b in bills {
                let cat = b.category.trimmingCharacters(in: .whitespaces)
                guard !cat.isEmpty else { continue }
                counts[cat, default: 0] += 1
                userCategories.insert(cat)
            }
        }
        let others = "其他"
        // 合并固定选项与用户实际账单中产生的分类（如识别自动新增的分类）
        let allCategories = Array(Set(billCategoryOptions).union(userCategories))
        let sortedMain = allCategories.filter { $0 != others }.sorted { a, b in
            let ca = counts[a, default: 0]
            let cb = counts[b, default: 0]
            if ca != cb { return ca > cb }
            // 次数相同：已知分类按 billCategoryOptions 原顺序；新增分类放最后，且彼此按字母序稳定
            let ia = billCategoryOptions.firstIndex(of: a)
            let ib = billCategoryOptions.firstIndex(of: b)
            switch (ia, ib) {
            case let (.some(i), .some(j)): return i < j
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a < b
            }
        }
        sortedCategories = sortedMain + [others]
    }

    private func categoryCell(_ cat: String) -> some View {
        let isSelected = displaySelection == cat
        let color = BillCategoryHelpers.color(for: cat)
        return Button {
            selection = cat
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Text(BillCategoryHelpers.icon(for: cat))
                    .font(AIATheme.Font.title3)
                Text(cat)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AIATheme.Font.body)
                        .foregroundStyle(AIATheme.blue)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(isSelected ? color.opacity(0.15) : AIATheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AIATheme.rSM)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 待办多草稿（添加模式，参照 AddFoodManualView 的 FoodDraft / BillDraft）
private struct TodoDraft: Identifiable {
    let id = UUID()
    /// 编辑/首个草稿挂靠的真实 Reminder（添加模式首个由 caller 软删传入；其余为 nil，保存时新建）
    var existingReminder: Reminder?
    var title: String
    var hasDue: Bool
    var due: Date
    var priority: String
    var repeatRule: String
    var done: Bool
    var alertItems: [AlertItem]
    var noteText: String
    var imageName: String?
    // 每卡独立 UI 状态
    var editingCustom: AlertItem? = nil
    var showImagePicker = false
    var showImageSourceDialog = false
    var pickedImage: UIImage? = nil
    // >>> CHANGE-[2026-08-17 15:00:00]-[草稿卡大图改ZStack overlay] 开始
    var selectedImage: UIImage? = nil
    // <<< CHANGE-[2026-08-17 15:00:00]-[草稿卡大图改ZStack overlay] 结束
    // 结果态
    var saved = false
    var savedReminder: Reminder? = nil

    init(reminder: Reminder) {
        self.existingReminder = reminder
        self.title = reminder.title
        let fallbackDue = reminder.due ?? Date().addingTimeInterval(3600)
        self.due = fallbackDue
        if reminder.due != nil {
            self.hasDue = true
            self.alertItems = alerts(from: reminder)
        } else {
            // 新增占位符（due=nil）：默认开启提醒 + 预填「准时」，与 init() 一致
            self.hasDue = true
            self.alertItems = [AlertItem(option: .atTime, customDate: fallbackDue)]
        }
        self.priority = reminder.priority
        self.repeatRule = reminder.repeatRule
        self.done = reminder.done
        self.imageName = reminder.imageName
        self.noteText = ""
    }

    init() {
        self.title = ""
        self.hasDue = true
        let fallbackDue = Date().addingTimeInterval(3600)
        self.due = fallbackDue
        self.alertItems = [AlertItem(option: .atTime, customDate: fallbackDue)]
        self.priority = "中"
        self.repeatRule = "不重复"
        self.done = false
        self.noteText = ""
        self.imageName = nil
    }
}

// MARK: - 待办编辑（支持编辑 + 手动添加两种模式；UI/逻辑共用，仅 deleteCard 和 title 切换）
struct EditTodoView: View {
    let reminder: Reminder
    let isAdding: Bool          // true = 手动添加模式（不显示删除按钮，title 改"添加待办"；save() 时草稿 syncDeleted 复活）
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 识别引擎来源标记（1:1 关联 Reminder.syncId）
    @Query private var recogSources: [RecogSource]

    @State private var title: String
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var priority: String
    @State private var repeatRule: String
    @State private var done: Bool
    @State private var alertItems: [AlertItem]
    @State private var editingCustom: AlertItem?

    // 备注（关联 Reminder.syncId → ReminderNote，仅本地，参照 FoodNote 风格）
    @State private var noteText: String = ""

    // 来源识别原图（Reminder.imageName），仅本地；在备注卡展示，与 EditBillView 同款
    @State private var imageName: String?
    // >>> CHANGE-[2026-08-17 11:20:00]-[待办编辑大图白屏] 开始
    @State private var selectedImage: UIImage? = nil
    // <<< CHANGE-[2026-08-17 11:20:00]-[待办编辑大图白屏] 结束
    @State private var showImageSourceDialog = false
    @State private var showImagePicker = false
    @State private var pickedImage: UIImage? = nil

    // 删除（参照 EditBillView 模式：先 dismiss，等 onDisappear 真正软删）
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    // 保存时存在空白标题 → 拦截并提示
    @State private var showEmptyTitleAlert = false

    /// 添加模式下的多草稿（参照 BillDraft / FoodDraft）：每张卡是一个独立 TodoDraft，
    /// 保存后变只读摘要卡，可继续"添加待办"连续添加，不退出页面。
    @State private var drafts: [TodoDraft] = []

    // 删除草稿：按钮只记录待删索引（绝不在闭包里改数组/dismiss/访问 Reminder），
    // 数组移除延后到淡出动画结束后（约 0.3s）在页面内执行，使下方内容自动顶上来并滚动；
    // 真实 Reminder 的软删延后到 onDisappear，避免 syncDeleted 触发 @Query 重 fetch 与动画叠加卡死。
    @State private var pendingDeleteTodoIndices: Set<TodoDraft.ID> = []
    // 待软删的真实 Reminder 的 persistentModelID，点击删除时即记录，与数组索引解耦，
    // 避免 onDisappear 时数组已移除导致索引失效、无法取到待删对象。
    @State private var pendingDeleteTodoReminderIDs: [PersistentIdentifier] = []

    init(reminder: Reminder, isAdding: Bool = false) {
        self.reminder = reminder
        self.isAdding = isAdding
        _title = State(initialValue: reminder.title)
        // 默认时间：新增场景（reminder.due == nil）= 当前时间 + 1 小时（2026-07-24 改）；
        // 编辑场景（reminder.due 有值）保留原值不动。Date() 含分钟秒，
        // addingTimeInterval(3600) 后是「下个整点前 1 小时」级别近似，符合"1 小时后"直觉。
        let fallbackDue = reminder.due ?? Date().addingTimeInterval(3600)
        _due = State(initialValue: fallbackDue)
        // 新增待办：提醒时间开关默认打开，并预置一条「准时」提醒，
        // 让用户一进来就看到「设置提醒时间」已启用 + 列表里已有「准时」节点。
        // 编辑待办：严格按 reminder.due 是否已有值决定开关状态。
        if isAdding {
            _hasDue = State(initialValue: true)
            _alertItems = State(initialValue: [AlertItem(option: .atTime, customDate: fallbackDue)])
        } else {
            _hasDue = State(initialValue: reminder.due != nil)
            _alertItems = State(initialValue: alerts(from: reminder))
        }
        _priority = State(initialValue: reminder.priority)
        _repeatRule = State(initialValue: reminder.repeatRule)
        _done = State(initialValue: reminder.done)
        _imageName = State(initialValue: reminder.imageName)
        let sid = reminder.syncId
        _recogSources = Query(filter: #Predicate<RecogSource> { $0.syncId == sid })
        // 添加模式：用 caller 传入的软删草稿 Reminder 初始化第一张卡
        if isAdding {
            _drafts = State(initialValue: [TodoDraft(reminder: reminder)])
        }
    }

    /// 识别引擎来源中文标签（免费版AI识别 / Pro版AI…），无标记返回 nil
    private var recogSourceLabel: String? {
        recogSources.first.flatMap { RecogSource.displayLabel(for: $0.recogSourceRaw) }
    }

    var body: some View {
        // 调用点（2026-07-24 改为统一 sheet 弹起）：
        // ① AllRecordsView.swift:163 .sheet(item: $editTodo) { EditTodoSheet(reminder: $0) }
        // ② RecordsViews.swift:1808 ReminderListView 内的 .sheet(item: $editTodo) { EditTodoSheet(reminder: $0) }
        // 两个 sheet 入口都用 EditTodoSheet wrapper（带 NavigationStack 包装）调用。
        // EditTodoView 自身**不能**自己包 NavigationStack——一旦未来再加回 navigationDestination 推入父级
        // NavigationStack 的入口（与 .sheet 双调用点），self-contained 的 NavigationStack 会触发
        // AnyNavigationPath.Error.comparisonTypeMismatch try! 崩（2026-07-24 二次踩坑已写入 MEMORY.md）。
        // 因此本 body 直接是 ScrollView，调用方一律走 EditTodoSheet。
        ZStack {
            AIATheme.fillSoft.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        // 顶部锚点：删除草稿前滚回此处，归零偏移，
                        // 避免删最后一张时 ScrollView contentOffset 越界卡死。
                        Color.clear.frame(height: 0).id("todoDraftTop")
                        if isAdding {
                            addTodoBody(proxy: proxy)
                        } else {
                            titleCard
                            timeAlertCard
                            // 2026-07-24 顺序调整：propertyCard（状态+设置：已完成/优先级/重复）上移
                            // 备注 noteCard 下移 —— 用户截图反馈"先看状态/再写备注"更符合视觉流
                            propertyCard
                            noteCard
                            if !isAdding { deleteCard }    // 添加模式不显示删除按钮
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            // >>> CHANGE-[2026-08-17 15:00:00]-[编辑页大图改ZStack overlay] 开始
            // 原因: fullScreenCover 挂在 NavigationStack 上 present 首帧易撞 NavigationStack 多轮重算断言被强制 dismiss,
            //      表现点小图白屏后自动回编辑页。改为 ZStack 内条件渲染绕开系统转场。
            // 回退: 删除此 if 块，恢复 fullScreenCover(isPresented: $showFullImage) 写法即可
            if let selectedImage {
                FullImageView(image: selectedImage, onDismiss: { self.selectedImage = nil })
                    .ignoresSafeArea()
                    .zIndex(100)
                    .transition(.opacity)
            }
            // <<< CHANGE-[2026-08-17 15:00:00]-[编辑页大图改ZStack overlay] 结束
        }
        .navigationTitle(isAdding ? "添加待办" : "编辑待办")
        .navigationBarTitleDisplayMode(.inline)
        // >>> CHANGE-[2026-08-17 16:05:00]-[看大图时隐藏编辑页顶部按钮] 开始
        // 原因: 大图改成 ZStack 条件渲染后，NavigationStack 顶部"取消/保存/完成"仍浮在大图上方，看大图时应隐藏。
        // 回退: 去掉外层 if selectedImage == nil 包裹，恢复 ToolbarItem 直接并列即可。
        .toolbar {
            if selectedImage == nil {
                // sheet 弹起模式：左「取消」dismiss 关闭 sheet（无系统返回箭头）
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        // 还有待保存草稿 → "保存"（批量入库）；全部已保存 → "完成"直接关闭
                        if drafts.contains(where: { !$0.saved }) {
                            Button("保存") { saveAllTodoDrafts() }
                                .font(AIATheme.Font.callout.weight(.semibold))
                                .foregroundStyle(AIATheme.blue)
                        } else {
                            Button("完成") { dismiss() }
                                .font(AIATheme.Font.callout.weight(.semibold))
                                .foregroundStyle(AIATheme.blue)
                        }
                    } else {
                        Button("保存") { save() }
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(AIATheme.blue)
                    }
                }
            }
        }
        // <<< CHANGE-[2026-08-17 16:05:00]-[看大图时隐藏编辑页顶部按钮] 结束
        .sheet(item: $editingCustom) { item in
            customTimeSheet(item: item)
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $pickedImage)
        }
        .confirmationDialog("添加图片", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                // 直接弹独立黑窗相机（不经 fullScreenCover，无白屏过渡）；
                // 结果写回 pickedImage，触发既有的 onChange 存图逻辑。
                Button("拍照") {
                    CameraPresenter.shared.present { img in
                        if let img { pickedImage = img }
                    }
                }
            }
            Button("从相册选择") { showImagePicker = true }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: pickedImage) { _, new in
            guard let img = new else { return }
            pickedImage = nil
            if let name = LocalImageStore.save(img) {
                imageName = name
            }
        }
        .alert("删除待办", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                pendingDeleteID = reminder.persistentModelID
                dismiss()
            }
        } message: {
            Text("删除后不可恢复，确定要删除吗？")
        }
        .alert("待办标题不能为空", isPresented: $showEmptyTitleAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请为每张待办填写标题后再保存。")
        }
            .onAppear {
                // 懒加载备注：首次进入编辑页时按 syncId 取 ReminderNote（1:1，参照 FoodNote 模式）
                let targetSyncId = reminder.syncId
                if let existing = try? context.fetch(FetchDescriptor<ReminderNote>(
                    predicate: #Predicate { $0.syncId == targetSyncId })).first {
                    noteText = existing.note
                }
            }
            .onDisappear {
                // 与 EditBillView 同款：先 dismiss 回列表，等 sheet 动画完全结束后再执行删除，
                // 避免 syncDeleted=true 触发 @Query 重 fetch 与动画叠加卡死。
                // 只保存 ID，不捕获 reminder 对象，防止返回列表后对象被 fault 后访问属性闪退。
                if let id = pendingDeleteID {
                    pendingDeleteID = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        SafeDelete.reminderByID(id, in: context)
                    }
                }
            }
    }

    // MARK: - 卡片
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("内容")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                if let recogSourceLabel {
                    Text(recogSourceLabel)
                        .font(AIATheme.Font.micro.weight(.medium))
                        .foregroundStyle(AIATheme.sub)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(AIATheme.surfaceSecondary)
                        .clipShape(Capsule())
                }
            }
            TextField("待办标题", text: $title)
                .font(AIATheme.Font.body)
                .foregroundStyle(.primary)
        }
        .padding(14)
        .card()
    }

    // MARK: - 时间与提醒（合并 dueSection + alertSection：一个语义=「在某天某时提醒我」+「最多 4 次提醒」，Divider 分段，更紧凑）
    private var timeAlertCard: some View {
        VStack(spacing: 0) {
            // 段一：提醒时间开关 + 日期/时间（hasDue=false 时仅显示开关，逻辑含义=是否启用提醒）
            dueSection
            if hasDue {
                Divider().padding(.leading, 14)
                alertSection
            }
        }
        .padding(.top, 4)
        .card()
    }

    // 段一：提醒时间开关 + 日期 + 时间（语义升级：截止时间 → 提醒基准时间）
    private var dueSection: some View {
        VStack(spacing: 0) {
            toggleRow(icon: "calendar.badge.clock", label: "设置提醒时间", isOn: $hasDue)
            if hasDue {
                Divider().padding(.leading, 46)
                HStack(spacing: 12) {
                    VStack(alignment: .center, spacing: 4) {
                        Text("日期")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                        DatePicker("", selection: $due, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        due = Calendar.current.date(byAdding: .day, value: 1, to: due)
                            ?? due.addingTimeInterval(86400)
                    } label: {
                        Text("+1天")
                            .font(AIATheme.Font.caption.weight(.medium))
                            .foregroundStyle(AIATheme.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AIATheme.blue.opacity(0.10))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)

                    VStack(alignment: .center, spacing: 4) {
                        Text("时间")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                        DatePicker("", selection: $due, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }

    // 段二：提醒时间列表（依赖 hasDue=基准时间已设；最多 4 条 option 都相对基准时间偏移：准时/提前 N 分钟/提前 N 天/自定义）
    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "bell.badge")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("提醒时间（最多可设置4次提醒）")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
                Text("\(alertItems.count)/4")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            VStack(spacing: 0) {
                ForEach($alertItems) { $item in
                    alertRow(item: $item)
                    if item.id != alertItems.last?.id {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
            if alertItems.count < 4 {
                Button {
                    // 阶梯式默认 option（按用户截图标注）：
                    //   第 1 次按 → .atTime（准时）；第 2 次 → .before30（提前 30 分钟）；
                    //   第 3 次 → .before1Day（提前 1 天）；第 4 次 → .before1Week（提前一周）
                    let newItem = AlertItem(option: defaultNextOption(), customDate: due)
                    alertItems.append(newItem)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(AIATheme.Font.body)
                            .foregroundStyle(AIATheme.blue)
                        Text("添加提醒时间（最多4次）")
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .foregroundStyle(AIATheme.blue)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    private var propertyCard: some View {
        VStack(spacing: 0) {
            // 「已完成」提到第一行：状态最常切换，比设置更显眼
            toggleRow(icon: "checkmark.circle", label: "已完成", isOn: $done)
            Divider().padding(.leading, 46)
            menuRow(icon: "flag", label: "优先级", selection: $priority,
                    options: priorityOptions.map { ($0.value, $0.label) })
            Divider().padding(.leading, 46)
            menuRow(icon: "arrow.clockwise", label: "重复", selection: $repeatRule,
                    options: repeatOptions.map { ($0.value, $0.label) })
        }
        .card()
    }

    // MARK: - 备注卡（文字 + 来源识别原图缩略图，与 EditBillView 同款）
    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "note.text")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("备注")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            TextEditor(text: $noteText)
                .font(AIATheme.Font.body)
                .foregroundStyle(.primary)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
            if let img = LocalImageStore.load(imageName) {
                HStack(spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        Button {
                            selectedImage = img
                        } label: {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                        }
                        .buttonStyle(.plain)

                        Button {
                            imageName = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(AIATheme.Font.body)
                                .foregroundStyle(AIATheme.muted)
                                .background(Circle().fill(AIATheme.surface))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }

                    Button {
                        showImageSourceDialog = true
                    } label: {
                        RoundedRectangle(cornerRadius: AIATheme.rSM)
                            .stroke(AIATheme.hairline, lineWidth: 1)
                            .frame(width: 64, height: 64)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(AIATheme.Font.headline.weight(.medium))
                                    .foregroundStyle(AIATheme.muted)
                            }
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            } else {
                Button {
                    showImageSourceDialog = true
                } label: {
                    RoundedRectangle(cornerRadius: AIATheme.rSM)
                        .stroke(AIATheme.hairline, lineWidth: 1)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "plus")
                                .font(AIATheme.Font.headline.weight(.medium))
                                .foregroundStyle(AIATheme.muted)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 删除卡（与 EditBillView.deleteCard 同款：warn 红 + 半透明背景 + hairline 描边 + 确认弹窗）
    private var deleteCard: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            Text("删除待办")
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(AIATheme.warn)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AIATheme.warn.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: AIATheme.rMD).stroke(AIATheme.warn.opacity(0.25), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 通用行组件
    private func menuRow<T: Hashable>(icon: String, label: String, selection: Binding<T>,
                                       options: [(T, String)]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.muted)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.sub)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { option in
                    Button(option.1) { selection.wrappedValue = option.0 }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first(where: { $0.0 == selection.wrappedValue })?.1 ?? "")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
    }

    private func toggleRow(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.muted)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.sub)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    // MARK: - 提醒时间行
    private func alertRow(item: Binding<AlertItem>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .center, spacing: 4) {
                Menu {
                    ForEach(reminderOptions) { option in
                        Button(option.label) {
                            item.wrappedValue.option = option
                            if option == .custom {
                                editingCustom = item.wrappedValue
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.wrappedValue.option.label)
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
                .buttonStyle(.plain)
                Text(formatAlert(item.wrappedValue))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            if item.wrappedValue.option == .custom {
                Button(formatCustom(item.wrappedValue.customDate)) {
                    editingCustom = item.wrappedValue
                }
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.blue)
                .padding(.trailing, 4)
            }
            Button {
                if let index = alertItems.firstIndex(where: { $0.id == item.wrappedValue.id }) {
                    alertItems.remove(at: index)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(AIATheme.Font.title2)
                    .foregroundStyle(AIATheme.warn)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private func customTimeSheet(item: AlertItem) -> some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                Form {
                    DatePicker("提醒时间", selection: Binding(
                        get: { item.customDate },
                        set: { newDate in
                            if let index = alertItems.firstIndex(where: { $0.id == item.id }) {
                                alertItems[index].customDate = newDate
                            }
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                }
            }
            .navigationTitle("自定义提醒时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { editingCustom = nil }
                }
            }
        }
    }

    private func formatAlert(_ item: AlertItem) -> String {
        guard let due = reminder.due else { return "" }
        let time = ReminderOption.remindAt(for: due, option: item.option, custom: item.customDate)
        guard let time else { return "无提醒" }
        return "将在 \(AppFormat.dateTime.string(from: time)) 提醒"
    }

    private func formatCustom(_ date: Date) -> String {
        AppFormat.dateTime.string(from: date)
    }

    /// 「+ 添加提醒时间」按钮按 N 次的阶梯默认 option（与外层 if alertItems.count < 4 配套；count=4 不会再调用）：
    /// count=0 → 准时；count=1 → 提前 30 分钟；count=2 → 提前 1 天；count=3 → 提前 1 周。
    /// 用户每次都可手动改成任意 option（atTime/before15/before30/before1Hour/before1Day/before1Week/custom）。
    private func defaultNextOption() -> ReminderOption {
        switch alertItems.count {
        case 0:  return .atTime
        case 1:  return .before30
        case 2:  return .before1Day
        case 3:  return .before1Week
        default: return .atTime   // 不会走到（外层已限定 count<4 才能点 + 按钮）
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        reminder.title = trimmed.isEmpty ? reminder.title : trimmed
        reminder.due = hasDue ? due : nil
        reminder.priority = priority
        reminder.repeatRule = repeatRule
        reminder.done = done
        reminder.imageName = imageName
        // 方案A：开关打开但用户未手动添加任何提醒节点时，自动补一个「准时」提醒，
        // 避免「设了截止时间却收不到任何提醒」的违和（用户预期=到点会响）。
        var effectiveAlerts = alertItems
        if hasDue && effectiveAlerts.isEmpty {
            effectiveAlerts = [AlertItem(option: .atTime, customDate: due)]
        }
        let times = hasDue ? reminderTimes(from: effectiveAlerts, due: due) : []
        reminder.remindTimes = times
        reminder.remindAt = times.first
        reminder.syncUpdatedAt = .now
        if isAdding {
            // 草稿 Reminder 在 addNewTodo 时设了 syncDeleted=true（被 @Query 谓词过滤，sheet 期间背景干净）；
            // 用户点保存 → 把 syncDeleted 改回 false，Reminder 复活并显示在列表里
            reminder.syncDeleted = false
        }
        try? context.save()
        if done {
            ReminderNotificationManager.cancel(reminder)
        } else if hasDue {
            ReminderNotificationManager.schedule(reminder)
        } else {
            ReminderNotificationManager.cancel(reminder)
        }

        // 备注：按 syncId 关联 ReminderNote；无内容则删除（若有），参照 FoodNote 懒加载模式
        let targetSyncId = reminder.syncId
        let existing = try? context.fetch(FetchDescriptor<ReminderNote>(
            predicate: #Predicate { $0.syncId == targetSyncId })).first
        let noteEmpty = noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if noteEmpty {
            if let existing { context.delete(existing) }
        } else if let existing {
            existing.note = noteText
            existing.updatedAt = .now
        } else {
            let rn = ReminderNote(syncId: reminder.syncId, note: noteText)
            context.insert(rn)
        }
        try? context.save()
        dismiss()
    }

    // MARK: - 添加模式：多草稿主体
    private func addTodoBody(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 16) {
            ForEach($drafts, id: \.id) { $d in
                if d.saved, let r = d.savedReminder {
                    savedTodoSummary(r, draft: $d, proxy: proxy)
                } else {
                    todoForm($d, showDelete: drafts.count > 1, proxy: proxy)
                }
            }
        }
        .onDisappear {
            // 数组移除已提前到点击删除后（淡出动画结束）在页面内执行，这里只做真实 Reminder 软删。
            // 仅依赖点击时记录的 pendingDeleteTodoReminderIDs（persistentModelID），不捕获对象、不碰数组，
            // 避免 syncDeleted=true 触发 @Query 重 fetch 与动画叠加主线程卡死。
            let toDeleteIDs = pendingDeleteTodoReminderIDs
            pendingDeleteTodoReminderIDs.removeAll()
            pendingDeleteTodoIndices.removeAll()
            guard !toDeleteIDs.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for id in toDeleteIDs {
                    SafeDelete.reminderByID(id, in: context)
                }
            }
        }
    }

    /// 未保存草稿卡：独立可编辑表单 + 底部"删除"（仅多于 1 张时显示）
    private func todoForm(_ draft: Binding<TodoDraft>, showDelete: Bool, proxy: ScrollViewProxy) -> some View {
        ZStack {
            VStack(spacing: 0) {
            // 内容
            VStack(alignment: .leading, spacing: 8) {
                Text("内容")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                TextField("待办标题", text: draft.title)
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
            }
            .padding(14)
            .card()

            // 时间 + 提醒
            dueSectionDraft(draft: draft)
                .card()

            // 状态 + 设置
            VStack(spacing: 0) {
                toggleRow(icon: "checkmark.circle", label: "已完成", isOn: draft.done)
                Divider().padding(.leading, 46)
                menuRow(icon: "exclamationmark.circle", label: "优先级", selection: draft.priority, options: priorityOptions)
                Divider().padding(.leading, 46)
                menuRow(icon: "repeat", label: "重复", selection: draft.repeatRule, options: repeatOptions)
            }
            .card()

            // 备注 + 图片
            VStack(alignment: .leading, spacing: 8) {
                Text("备注")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                TextEditor(text: draft.noteText)
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .scrollContentBackground(.hidden)
                imageAreaDraft(draft: draft)
            }
            .padding(14)
            .card()

            // 底部"删除"（仅当草稿多于 1 张时才出现，删的是单条）
            if showDelete {
                Button {
                    deleteTodoDraft(draft, proxy: proxy)
                } label: {
                    Text("删除")
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AIATheme.warn)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AIATheme.warn.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: AIATheme.rMD).stroke(AIATheme.warn.opacity(0.25), lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        // >>> CHANGE-[2026-08-17 15:00:00]-[草稿卡大图改ZStack overlay] 开始
        if let sel = draft.selectedImage.wrappedValue {
            FullImageView(image: sel, onDismiss: { draft.selectedImage.wrappedValue = nil })
                .ignoresSafeArea()
                .zIndex(100)
                .transition(.opacity)
        }
        // <<< CHANGE-[2026-08-17 15:00:00]-[草稿卡大图改ZStack overlay] 结束
        }
        .sheet(item: draft.editingCustom) { item in
            customTimeSheetDraft(item: item, draft: draft)
        }
        .sheet(isPresented: draft.showImagePicker) {
            ImagePicker(image: draft.pickedImage)
        }
        .confirmationDialog("添加图片", isPresented: draft.showImageSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍照") {
                    CameraPresenter.shared.present { img in
                        if let img { draft.pickedImage.wrappedValue = img }
                    }
                }
            }
            Button("从相册选择") { draft.showImagePicker.wrappedValue = true }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: draft.pickedImage.wrappedValue) { _, new in
            guard let img = new else { return }
            draft.pickedImage.wrappedValue = nil
            if let name = LocalImageStore.save(img) {
                draft.imageName.wrappedValue = name
            }
        }
    }

    /// 已保存摘要卡（只读，可"编辑"退回草稿或"删除"）
    private func savedTodoSummary(_ r: Reminder, draft: Binding<TodoDraft>, proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: r.done ? "checkmark.circle.fill" : "circle")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(r.done ? AIATheme.sub : AIATheme.blue)
                Text(r.title.isEmpty ? "未命名" : r.title)
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(r.done ? AIATheme.muted : .primary)
                    .strikethrough(r.done)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)
            HStack(spacing: 6) {
                if let due = r.due {
                    Text(AppFormat.dateTime.string(from: due))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                } else {
                    Text("未安排时间")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
                Text("· \(r.priority)")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            HStack(spacing: 12) {
                Button {
                    draft.wrappedValue.saved = false   // 退回草稿重新编辑
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .font(AIATheme.Font.caption)
                        Text("编辑")
                    }
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                Divider()
                Button {
                    deleteTodoDraft(draft, proxy: proxy)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(AIATheme.Font.caption)
                        Text("删除")
                    }
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.warn)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 10)
        }
        .card()
    }

    private func imageAreaDraft(draft: Binding<TodoDraft>) -> some View {
        let name = draft.imageName.wrappedValue
        return Group {
        if let img = LocalImageStore.load(name) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Button {
                        draft.selectedImage.wrappedValue = img
                    } label: {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                    }
                    .buttonStyle(.plain)

                    Button {
                        draft.imageName.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(AIATheme.Font.body)
                            .foregroundStyle(AIATheme.muted)
                            .background(Circle().fill(AIATheme.surface))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }

                Button {
                    draft.showImageSourceDialog.wrappedValue = true
                } label: {
                    RoundedRectangle(cornerRadius: AIATheme.rSM)
                        .stroke(AIATheme.hairline, lineWidth: 1)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "plus")
                                .font(AIATheme.Font.headline.weight(.medium))
                                .foregroundStyle(AIATheme.muted)
                        }
                }
                .buttonStyle(.plain)

                Spacer()
            }
        } else {
            Button {
                draft.showImageSourceDialog.wrappedValue = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(AIATheme.Font.subhead)
                    Text("添加图片")
                        .font(AIATheme.Font.callout.weight(.medium))
                }
                .foregroundStyle(AIATheme.sub)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(AIATheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
            }
            .buttonStyle(.plain)
        }
        }
    }

    // MARK: - 草稿版 dueSection（参照原 dueSection，绑定改为 draft）
    private func dueSectionDraft(draft: Binding<TodoDraft>) -> some View {
        VStack(spacing: 0) {
            toggleRow(icon: "bell", label: "设置提醒时间", isOn: draft.hasDue)
            if draft.hasDue.wrappedValue {
                Divider().padding(.leading, 46)
                DatePicker("", selection: draft.due, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)

                if !draft.alertItems.wrappedValue.isEmpty {
                    Divider().padding(.leading, 46)
                    VStack(spacing: 0) {
                        ForEach(draft.alertItems) { $item in
                            if let idx = draft.alertItems.wrappedValue.firstIndex(where: { $0.id == item.id }),
                               idx < draft.alertItems.wrappedValue.count - 1 {
                                Divider().padding(.leading, 8)
                            }
                            alertRowDraft(item: $item, draft: draft)
                        }
                    }
                }

                if draft.alertItems.wrappedValue.count < 4 {
                    Divider().padding(.leading, 46)
                    Button {
                        let next = defaultNextOptionDraft(count: draft.alertItems.wrappedValue.count)
                        draft.alertItems.wrappedValue.append(AlertItem(option: next, customDate: draft.due.wrappedValue))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(AIATheme.blue)
                            Text("添加提醒时间")
                                .font(AIATheme.Font.subhead)
                                .foregroundStyle(AIATheme.blue)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func alertRowDraft(item: Binding<AlertItem>, draft: Binding<TodoDraft>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .center, spacing: 4) {
                Menu {
                    ForEach(reminderOptions) { option in
                        Button(option.label) {
                            item.wrappedValue.option = option
                            if option == .custom {
                                draft.editingCustom.wrappedValue = item.wrappedValue
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.wrappedValue.option.label)
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
                .buttonStyle(.plain)
                Text(formatAlertDraft(item.wrappedValue, due: draft.due.wrappedValue))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            if item.wrappedValue.option == .custom {
                Button(formatCustom(item.wrappedValue.customDate)) {
                    draft.editingCustom.wrappedValue = item.wrappedValue
                }
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.blue)
                .padding(.trailing, 4)
            }
            Button {
                draft.alertItems.wrappedValue.removeAll { $0.id == item.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(AIATheme.Font.title2)
                    .foregroundStyle(AIATheme.warn)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private func customTimeSheetDraft(item: AlertItem, draft: Binding<TodoDraft>) -> some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                Form {
                    DatePicker("提醒时间", selection: Binding(
                        get: { item.customDate },
                        set: { newDate in
                            if let index = draft.alertItems.wrappedValue.firstIndex(where: { $0.id == item.id }) {
                                draft.alertItems.wrappedValue[index].customDate = newDate
                            }
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                }
            }
            .navigationTitle("自定义提醒时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { draft.editingCustom.wrappedValue = nil }
                }
            }
        }
    }

    private func formatAlertDraft(_ item: AlertItem, due: Date) -> String {
        let time = ReminderOption.remindAt(for: due, option: item.option, custom: item.customDate)
        guard let time else { return "无提醒" }
        return "将在 \(AppFormat.dateTime.string(from: time)) 提醒"
    }

    private func defaultNextOptionDraft(count: Int) -> ReminderOption {
        switch count {
        case 0:  return .atTime
        case 1:  return .before30
        case 2:  return .before1Day
        case 3:  return .before1Week
        default: return .atTime
        }
    }

    /// 把一张草稿持久化成真实 Reminder（复用 syncAfterLocalChange 触发同步 + 提醒调度）
    private func persistTodo(_ draft: Binding<TodoDraft>) {
        var d = draft.wrappedValue
        let trimmed = d.title.trimmingCharacters(in: .whitespaces)
        // 方案A：开关打开但无提醒节点时自动补「准时」
        let effectiveAlerts = (d.hasDue && d.alertItems.isEmpty) ? [AlertItem(option: .atTime, customDate: d.due)] : d.alertItems
        let times = d.hasDue ? reminderTimes(from: effectiveAlerts, due: d.due) : []
        let noteEmpty = d.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let r = d.existingReminder {
            r.title = trimmed.isEmpty ? r.title : trimmed
            r.due = d.hasDue ? d.due : nil
            r.priority = d.priority
            r.repeatRule = d.repeatRule
            r.done = d.done
            r.imageName = d.imageName
            r.remindTimes = times
            r.remindAt = times.first
            r.syncUpdatedAt = .now
            r.syncDeleted = false
            d.savedReminder = r
            applyNote(r.syncId, noteEmpty: noteEmpty, note: d.noteText)
        } else {
            let r = Reminder(title: trimmed.isEmpty ? "未命名" : trimmed, due: d.hasDue ? d.due : nil, done: d.done)
            r.priority = d.priority
            r.repeatRule = d.repeatRule
            r.remindTimes = times
            r.remindAt = times.first
            r.imageName = d.imageName
            r.syncDeleted = false
            context.insert(r)
            d.savedReminder = r
            applyNote(r.syncId, noteEmpty: noteEmpty, note: d.noteText)
        }
        d.saved = true
        draft.wrappedValue = d
        try? context.save()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        if let r = d.savedReminder {
            if d.done {
                ReminderNotificationManager.cancel(r)
            } else if d.hasDue {
                ReminderNotificationManager.schedule(r)
            } else {
                ReminderNotificationManager.cancel(r)
            }
        }
    }

    /// 备注落库（按 syncId 关联 ReminderNote，复用 save() 同款逻辑）
    private func applyNote(_ syncId: UUID, noteEmpty: Bool, note: String) {
        let existing = try? context.fetch(FetchDescriptor<ReminderNote>(
            predicate: #Predicate { $0.syncId == syncId })).first
        if noteEmpty {
            if let existing { context.delete(existing) }
        } else if let existing {
            existing.note = note
            existing.updatedAt = Date.now
        } else {
            let rn = ReminderNote(syncId: syncId, note: note)
            context.insert(rn)
        }
        try? context.save()
    }

    /// 删除一张草稿：按钮只记录待删索引（绝不在闭包里改数组/访问 Reminder），
    /// 点击时即记录待软删的真实 Reminder 的 persistentModelID（与数组索引解耦）；
    /// 数组移除延后到淡出动画结束后（约 0.1s）无动画执行，
    /// 使下方内容自动顶上来并滚动；真实软删仍延后到 onDisappear 执行，
    /// 避免 syncDeleted=true 触发 @Query 重 fetch 与转场动画叠加导致视图树损坏卡死。
    /// 注意：removeAll 不能包在 withAnimation 里——ForEach($bindings) 转场动画与
    /// 子视图超长修饰符链（.card() 等）不兼容，动画中途部分修饰符无法平滑插值会令
    /// 视图树半损坏、动画结束不恢复，表现为卡片背景丢失、页面卡死。opacity 已提供视觉过渡。
    private func deleteTodoDraft(_ draft: Binding<TodoDraft>, proxy: ScrollViewProxy) {
        let targetID = draft.wrappedValue.id
        // 点击当时即记录待软删的真实 Reminder 的 persistentModelID（与数组索引解耦）
        if let rid = draft.wrappedValue.savedReminder?.persistentModelID
            ?? draft.wrappedValue.existingReminder?.persistentModelID {
            pendingDeleteTodoReminderIDs.append(rid)
        }
        // 即时移除：ForEach 用稳定 UUID id，SwiftUI 能正确 diff 卸载子视图树，
        // Binding 随之释放不悬空。延后一帧的 removeAll 反而会在 ScrollView 滚顶
        // 动画期间触发越界崩溃（见记忆 ID:75222852）。
        proxy.scrollTo("todoDraftTop", anchor: .top)
        drafts.removeAll { $0.id == targetID }
    }

    /// 批量保存所有未保存草稿（toolbar "保存"）
    private func saveAllTodoDrafts() {
        // 校验：任一未保存草稿标题为空 → 拦截、不关闭、提示用户
        let hasEmpty = drafts.contains { !$0.saved && $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !hasEmpty else {
            showEmptyTitleAlert = true
            return
        }
        for i in drafts.indices where !drafts[i].saved {
            let d = drafts[i]
            let binding = Binding<TodoDraft>(
                get: { d },
                set: { drafts[i] = $0 }
            )
            persistTodo(binding)
        }
        dismiss()   // 全部入库后自动关闭页面
    }
}

// MARK: - 健康指标编辑
struct EditHealthView: View {
    let metric: HealthMetric
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 识别引擎来源标记（1:1 关联 HealthMetric.syncId）
    @Query private var recogSources: [RecogSource]

    @State private var metricName: String
    @State private var valueText: String
    @State private var unit: String
    @State private var date: Date

    // 备注（关联 HealthMetric.syncId → HealthNote，仅本地）
    @State private var noteText: String = ""

    // 来源识别原图（HealthMetric.imageName），仅本地；在备注卡展示，与 EditBillView 同款
    @State private var imageName: String?
    // >>> CHANGE-[2026-08-17 11:20:00]-[健康编辑大图白屏] 开始
    @State private var selectedImage: UIImage? = nil
    // <<< CHANGE-[2026-08-17 11:20:00]-[健康编辑大图白屏] 结束
    @State private var showImageSourceDialog = false
    @State private var showImagePicker = false
    @State private var pickedImage: UIImage? = nil

    init(metric: HealthMetric) {
        self.metric = metric
        _metricName = State(initialValue: metric.metric)
        _valueText = State(initialValue: metric.value)
        _unit = State(initialValue: metric.unit)
        _date = State(initialValue: metric.date)
        _imageName = State(initialValue: metric.imageName)
        let sid = metric.syncId
        _recogSources = Query(filter: #Predicate<RecogSource> { $0.syncId == sid })
    }

    /// 识别引擎来源中文标签（免费版AI识别 / Pro版AI…），无标记返回 nil
    private var recogSourceLabel: String? {
        recogSources.first.flatMap { RecogSource.displayLabel(for: $0.recogSourceRaw) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        metricCard
                        noteCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
                // >>> CHANGE-[2026-08-17 15:00:00]-[编辑页大图改ZStack overlay] 开始
                // 原因: fullScreenCover 挂在 NavigationStack 上 present 首帧易撞 NavigationStack 多轮重算断言被强制 dismiss,
                //      表现点小图白屏后自动回编辑页。改为 ZStack 内条件渲染绕开系统转场。
                // 回退: 删除此 if 块，恢复 fullScreenCover(isPresented: $showFullImage) 写法即可
                if let selectedImage {
                    FullImageView(image: selectedImage, onDismiss: { self.selectedImage = nil })
                        .ignoresSafeArea()
                        .zIndex(100)
                        .transition(.opacity)
                }
                // <<< CHANGE-[2026-08-17 15:00:00]-[编辑页大图改ZStack overlay] 结束
            }
            .navigationTitle("编辑健康指标")
            .navigationBarTitleDisplayMode(.inline)
            // >>> CHANGE-[2026-08-17 16:05:00]-[看大图时隐藏编辑页顶部按钮] 开始
            // 原因: 大图改成 ZStack 条件渲染后，NavigationStack 顶部"取消/保存"仍浮在大图上方，看大图时应隐藏。
            // 回退: 去掉外层 if selectedImage == nil 包裹，恢复两个 ToolbarItem 直接并列即可。
            .toolbar {
                if selectedImage == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(AIATheme.blue)
                    }
                }
            }
            // <<< CHANGE-[2026-08-17 16:05:00]-[看大图时隐藏编辑页顶部按钮] 结束
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(image: $pickedImage)
            }
            .confirmationDialog("添加图片", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    // 直接弹独立黑窗相机（不经 fullScreenCover，无白屏过渡）；
                    // 结果写回 pickedImage，触发既有的 onChange 存图逻辑。
                    Button("拍照") {
                        CameraPresenter.shared.present { img in
                            if let img { pickedImage = img }
                        }
                    }
                }
                Button("从相册选择") { showImagePicker = true }
                Button("取消", role: .cancel) {}
            }
            .onChange(of: pickedImage) { _, new in
                guard let img = new else { return }
                pickedImage = nil
                if let name = LocalImageStore.save(img) {
                    imageName = name
                }
            }
            .onAppear {
                // 懒加载备注：首次进入编辑页时按 syncId 取 HealthNote（1:1，参照 ReminderNote 模式）
                let targetSyncId = metric.syncId
                if let existing = try? context.fetch(FetchDescriptor<HealthNote>(
                    predicate: #Predicate { $0.syncId == targetSyncId })).first {
                    noteText = existing.note
                }
            }
        }
    }

    private var metricCard: some View {
        VStack(spacing: 0) {
            if let recogSourceLabel {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                    Text(recogSourceLabel)
                        .font(AIATheme.Font.micro.weight(.medium))
                        .foregroundStyle(AIATheme.sub)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("指标")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                TextField("指标名称（如 体重）", text: $metricName)
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
            }
            .padding(14)
            Divider().padding(.leading, 14)
            HStack(spacing: 12) {
                TextField("数值", text: $valueText)
                    .keyboardType(.decimalPad)
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
                Divider().frame(height: 24)
                TextField("单位", text: $unit)
                    .frame(width: 70)
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
            }
            .padding(14)
            Divider().padding(.leading, 14)
            HStack(spacing: 12) {
                Text("日期")
                    .font(AIATheme.Font.body)
                    .foregroundStyle(.primary)
                Spacer()
                DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
            .padding(14)
        }
        .card()
    }

    // MARK: - 备注卡（文字 + 来源识别原图缩略图，与 EditBillView/EditTodoView 同款）
    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "note.text")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("备注")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            TextEditor(text: $noteText)
                .font(AIATheme.Font.body)
                .foregroundStyle(.primary)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
            if let img = LocalImageStore.load(imageName) {
                HStack(spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        Button {
                            selectedImage = img
                        } label: {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
                        }
                        .buttonStyle(.plain)

                        Button {
                            imageName = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(AIATheme.Font.body)
                                .foregroundStyle(AIATheme.muted)
                                .background(Circle().fill(AIATheme.surface))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }

                    Button {
                        showImageSourceDialog = true
                    } label: {
                        RoundedRectangle(cornerRadius: AIATheme.rSM)
                            .stroke(AIATheme.hairline, lineWidth: 1)
                            .frame(width: 64, height: 64)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(AIATheme.Font.headline.weight(.medium))
                                    .foregroundStyle(AIATheme.muted)
                            }
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            } else {
                Button {
                    showImageSourceDialog = true
                } label: {
                    RoundedRectangle(cornerRadius: AIATheme.rSM)
                        .stroke(AIATheme.hairline, lineWidth: 1)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "plus")
                                .font(AIATheme.Font.headline.weight(.medium))
                                .foregroundStyle(AIATheme.muted)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .card()
    }

    private func save() {
        let trimmed = metricName.trimmingCharacters(in: .whitespaces)
        metric.metric = trimmed.isEmpty ? metric.metric : trimmed
        metric.value = valueText.trimmingCharacters(in: .whitespaces)
        metric.unit = unit.trimmingCharacters(in: .whitespaces)
        metric.date = date
        metric.imageName = imageName
        metric.syncUpdatedAt = .now
        try? context.save()

        // 备注：按 syncId 关联 HealthNote；无内容则删除（若有），参照 ReminderNote 模式
        let targetSyncId = metric.syncId
        let existing = try? context.fetch(FetchDescriptor<HealthNote>(
            predicate: #Predicate { $0.syncId == targetSyncId })).first
        let noteEmpty = noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if noteEmpty {
            if let existing { context.delete(existing) }
        } else if let existing {
            existing.note = noteText
            existing.updatedAt = .now
        } else {
            let hn = HealthNote(syncId: metric.syncId, note: noteText)
            context.insert(hn)
        }
        try? context.save()
        dismiss()
    }
}

/// EditTodoView 的 sheet 包装：所有 sheet 入口必须用本 wrapper（自身包 NavigationStack 提供 toolbar context）。
/// EditTodoView 自身不带 NavigationStack 包装，**只**通过本 wrapper 在 sheet 模式下被调用。
/// 2026-07-24 改为统一 sheet 弹起（与「编辑账单」一致）：
/// - AllRecordsView.swift:163  .sheet(item: $editTodo) { EditTodoSheet(reminder: $0) }
/// - RecordsViews.swift:1808   ReminderListView 内 .sheet(item: $editTodo) { EditTodoSheet(reminder: $0) }
/// 禁止把 EditTodoView 直接放进 navigationDestination(for: HomeRoute.self) ——
/// EditTodoView 自身不包 NavigationStack，被 push 到父级 NavigationStack 后 toolbar 标题栏不会渲染（视觉异常）。
struct EditTodoSheet: View {
    let reminder: Reminder
    let isAdding: Bool

    init(reminder: Reminder, isAdding: Bool = false) {
        self.reminder = reminder
        self.isAdding = isAdding
    }

    var body: some View {
        NavigationStack {
            EditTodoView(reminder: reminder, isAdding: isAdding)
        }
    }
}

/// EditFoodView 的 sheet 包装：所有 sheet 入口必须用本 wrapper（自身包 NavigationStack 提供 toolbar context）。
/// EditFoodView 自身不带 NavigationStack 包装，**只**通过本 wrapper 在 sheet 模式下被调用（与 EditTodoSheet 同模式）。
// >>> CHANGE-[2026-08-17 17:25:00]-[编辑食物统一EditFoodSheet] 开始
// 原因: 曾只有一个入口(RecordsViews)包 NavigationStack，其余三个(ResultRowCard/AllRecordsView/FoodDetailView)漏包，
//      导致这些入口进来的编辑页没有导航栏、看不到「取消/保存」按钮。统一为 wrapper 后不再易漏。
// 回退: 删除本 struct，并把各入口恢复为直接调 EditFoodView(entry:)。
// >>> CHANGE-[2026-08-18 16:51:31]-[临时实例失效崩溃止血] 开始
// 原因: 对话页识别链路在 @Query 竞争时机可能拿到 backing 已失效的临时 FoodEntry 实例，
//       直接持有 entry 传给 EditFoodView.init 后访问 entry.syncId 会 fatal("model instance was invalidated... temporary identifier")。
//       改为持有 PersistentIdentifier，body 内用 context.model(for:) 取活对象；失效 ID 返回 nil → 显示空视图不崩。
// 回退: 恢复 init(entry: FoodEntry) 直接持有 entry 的旧实现，各调用点改回 EditFoodSheet(entry: xxx)
struct EditFoodSheet: View {
    let entryID: PersistentIdentifier?
    // 草稿模式参数（待确认卡点编辑：保存才落库）
    let draftPayload: FoodPayload?
    let draftImageName: String?
    var onDraftSaved: ((String) -> Void)?

    @Environment(\.modelContext) private var context

    /// 真实实例入口（已保存卡 / 之前路径）
    init(entryID: PersistentIdentifier) {
        self.entryID = entryID
        self.draftPayload = nil
        self.draftImageName = nil
        self.onDraftSaved = nil
    }

    /// 草稿入口（待确认卡点编辑，保存才落库）
    init(draftPayload: FoodPayload, imageName: String?, onDraftSaved: @escaping (String) -> Void) {
        self.entryID = nil // 草稿模式不解析，EditFoodView 走 payload 分支
        self.draftPayload = draftPayload
        self.draftImageName = imageName
        self.onDraftSaved = onDraftSaved
    }

    var body: some View {
        return Group {
            // EditFoodView 现在只持有 entryID，自行 resolveEntry()；本 wrapper 不提前解析，
            // 让 EditFoodView 在 onAppear 时按最新 backing 取活实例，彻底绕开"init 时持有失效引用"。
            // 草稿模式传 draftPayload，EditFoodView 内部走草稿分支（保存才落库）。
            NavigationStack {
                EditFoodView(entryID: entryID, draftPayload: draftPayload, draftImageName: draftImageName, onDraftSaved: onDraftSaved)
            }
        }
    }
}
// <<< CHANGE-[2026-08-18 16:51:31]-[临时实例失效崩溃止血] 结束
// <<< CHANGE-[2026-08-17 17:25:00]-[编辑食物统一EditFoodSheet] 结束
