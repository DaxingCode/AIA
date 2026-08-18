// AddFoodManualView.swift
// 手动添加食物 + 食物库搜索快速选择。
// 入口：饮食记录页顶部「手动输入」按钮。
// 支持：从 NutritionLibrary / FoodMeta 搜索已有食物快速填充营养值，
//       或手动输入全部营养信息。
import SwiftUI
import SwiftData

// MARK: - 食物搜索结果（全局，EditFoodView / AddFoodManualView 共用）
struct FoodSearchResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let kcal: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    var fiber: Double
    var sugar: Double
    var sodium: Double
    var source: String  // "library" / "cache" / "cloud"

    /// 名称去掉末尾括号及其内容（兼容中英文括号）。
    /// 云端 queryFood 会为复合菜品返回带口径的名称（如「玉米猪肉饺子（熟，约值）」），
    /// 括号内容是模型标注的「估算说明」，不应该作为正式食物名落库或展示。
    /// 例：`玉米猪肉饺子（熟，约值）` → `玉米猪肉饺子`；`牛肉 (瘦, 生)` → `牛肉`。
    /// 若括号不在末尾（如 `xxx(中)yyy`），不动——本项目云端口径只会放在末尾。
    func cleanedName() -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // 末尾的中文括号（...）— 注意全角括号
        if let rParen = trimmed.range(of: "）", options: .backwards),
           let lParen = trimmed.range(of: "（", options: .backwards),
           lParen.upperBound <= rParen.lowerBound {
            return trimmed[..<lParen.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        // 末尾的英文括号 (...)
        if trimmed.hasSuffix(")"),
           let lParen = trimmed.range(of: "(", options: .backwards),
           lParen.upperBound < trimmed.endIndex {
            return trimmed[..<lParen.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}

/// 食物搜索核心逻辑（本地 + 联网兜底）。两边页面共用，避免代码重复。
enum FoodSearcher {
    /// 本地搜：先 NutritionLibrary 命中（精确/别名/子串三级，最终从 FoodMetaStore 取数），再 FoodMeta 缓存命中。
    /// 返回结果已按「归一化名称」去重，library 优先于 cache。
    static func localSearch(_ query: String, foodMetas: [FoodMeta], in context: ModelContext) -> [FoodSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var results: [FoodSearchResult] = []

        // ① NutritionLibrary 命中
        if let ref = NutritionLibrary.shared.match(trimmed, in: context) {
            results.append(FoodSearchResult(
                name: ref.name, kcal: ref.kcal, protein: ref.protein,
                carbs: ref.carbs, fat: ref.fat, fiber: ref.fiber,
                sugar: ref.sugar, sodium: ref.sodium, source: "library"
            ))
        }

        // ② FoodMeta 缓存命中（按归一化名 contains 子串）
        let normQuery = FoodMeta.normalize(trimmed)
        let matchedMetas = foodMetas.filter { meta in
            meta.name.contains(normQuery) || FoodMeta.normalize(meta.displayName).contains(normQuery)
        }
        for meta in matchedMetas {
            if !results.contains(where: { FoodMeta.normalize($0.name) == meta.name }) {
                results.append(FoodSearchResult(
                    name: meta.displayName, kcal: meta.kcal, protein: meta.protein,
                    carbs: meta.carbs, fat: meta.fat, fiber: meta.fiber,
                    sugar: meta.sugar, sodium: meta.sodium, source: "cache"
                ))
            }
        }

        return results
    }

    /// 联网兜底：调云端 queryFood 拿该食物每 100g 营养。
    static func cloudSearch(name: String) async throws -> FoodSearchResult? {
        guard let ref = try await RecognizeService.queryFood(name: name) else { return nil }
        return FoodSearchResult(
            name: ref.name, kcal: ref.kcal, protein: ref.protein,
            carbs: ref.carbs, fat: ref.fat, fiber: ref.fiber,
            sugar: ref.sugar, sodium: ref.sodium, source: "cloud"
        )
    }
}

/// 单张食物草稿（可有多张叠加）。
/// savedEntry 非 nil 表示这张已入库收起成摘要，仅用于持有真实实例供删除。
private struct FoodDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var weightText: String = "100"
    var baseKcalText: String = ""
    var baseProteinText: String = ""
    var baseCarbsText: String = ""
    var baseFatText: String = ""
    var baseFiberText: String = ""
    var baseSugarText: String = ""
    var baseSodiumText: String = ""
    var searchText: String = ""
    var cloudError: String? = nil          // 该卡独立联网搜索错误，避免多卡串扰
    var savedEntry: FoodEntry? = nil
    // >>> CHANGE-[2026-08-18 16:38:05]-[营养元素按重量缩放+区分来源只读] 开始
    // 原因: 用 searchText 非空判断"来自搜索"会误伤"打名字但不选结果"的手动填场景(名称框绑的就是 searchText)。
    //       改用独立标志: 仅 applySearchResult 真正选取搜索结果时置 true。
    // 回退: 改为 var isFromSearch: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty } 并删本行。
    var pickedFromSearch: Bool = false
    // <<< CHANGE-[2026-08-18 16:38:05]-[营养元素按重量缩放+区分来源只读] 结束

    // >>> CHANGE-[2026-08-18 16:38:05]-isValid兼容手动填卡 开始
    // 原因: 手动填路径 baseKcalText 永远为空(界面无此输入框),原 !baseKcalText.isEmpty 会让保存按钮永远点不动。
    //       改为: 有食物名 + 重量非空 + (热量非空 或 三大宏量营养素任一非空) 即可保存。
    // 回退: 恢复 3 行原版(把 hasMacro 那段换回 !baseKcalText.isEmpty)即可
    var isValid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasWeight = !weightText.isEmpty
        let hasKcal = !baseKcalText.isEmpty
        let hasMacro = (Double(baseProteinText) ?? 0) > 0 ||
                       (Double(baseCarbsText) ?? 0) > 0 ||
                       (Double(baseFatText) ?? 0) > 0
        return hasName && hasWeight && (hasKcal || hasMacro)
    }
    // <<< CHANGE-[2026-08-18 16:38:05]-isValid兼容手动填卡 结束
    var weight: Double { max(Double(weightText) ?? 100, 1) }
    // >>> CHANGE-[2026-08-18 16:38:05]-手动填卡自动算热量 开始
    // 原因: 手动添加界面没有 baseKcalText 输入框(只有 6 大营养素 TextField)，原公式 baseKcalText*weight/100 永远为 0
    //       导致用户填完蛋白/碳水/脂肪后热量胶囊不显示。补 4+4+9 自动推算作为兜底。
    // 回退: 恢复 3 行原版(去掉 pro/car/fat 兜底)即可
    var totalKcal: Double {
        let base = Double(baseKcalText) ?? 0
        if base > 0 { return base * weight / 100 }
        // 手动填的草稿卡: baseKcalText 为空,按 4+4+9 从蛋白/碳水/脂肪自动算
        let pro = Double(baseProteinText) ?? 0
        let car = Double(baseCarbsText) ?? 0
        let fat = Double(baseFatText) ?? 0
        return (pro * 4 + car * 4 + fat * 9) * weight / 100
    }
    // <<< CHANGE-[2026-08-18 16:38:05]-手动填卡自动算热量 结束
    // >>> CHANGE-[2026-08-18 16:38:05]-[营养元素按重量缩放+区分来源只读] 开始
    // 原因: 营养元素(蛋白/碳水/脂肪/纤维/糖/钠)此前只展示 base*Text 原始值(按100g)，切重量不变；
    //       热量因有 totalKcal 才跟着缩放。现补齐 6 个按重量缩放的 total* 计算属性，供"来自搜索"的食物只读展示。
    // 回退: 删本段 + nutritionSection 调用处改回 nutritionCell(binding: $drafts[idx].base*Text) + 删 nutritionReadOnlyCell。
    var totalProtein: Double { (Double(baseProteinText) ?? 0) * weight / 100 }
    var totalCarbs:   Double { (Double(baseCarbsText)   ?? 0) * weight / 100 }
    var totalFat:     Double { (Double(baseFatText)     ?? 0) * weight / 100 }
    var totalFiber:   Double { (Double(baseFiberText)   ?? 0) * weight / 100 }
    var totalSugar:   Double { (Double(baseSugarText)   ?? 0) * weight / 100 }
    var totalSodium:  Double { (Double(baseSodiumText)  ?? 0) * weight / 100 }
    /// 是否来自内置库/联网搜索选取：仅真正点选过搜索结果 → 营养只读(按当前重量算)；否则(打名字不选/纯手动) → 可编辑 TextField
    var isFromSearch: Bool { pickedFromSearch }
    // <<< CHANGE-[2026-08-18 16:38:05]-[营养元素按重量缩放+区分来源只读] 结束
    /// 已收起（入库）的展示快照字段
    var savedCalories: Double = 0
    var savedWeight: Double = 0
}

struct AddFoodManualView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \FoodMeta.hitCount, order: .reverse) private var foodMetas: [FoodMeta]

    /// 多张食物草稿，自下而上叠加；初始一张空白待填。
    @State private var drafts: [FoodDraft] = [FoodDraft()]
    /// 餐次 / 日期所有卡共用，保留上次选择（顶部信息卡控制）。
    @State private var meal: String
    @State private var date: Date

    /// 外部传入日期与餐次时自动带上（如从饮食记录页按所选日期/餐次进入）；
    /// 用户在页面内仍可自由修改。两者缺省时按当前时间推断。
    init(initialDate: Date = Date(), initialMeal: String? = nil) {
        _date = State(initialValue: initialDate)
        _meal = State(initialValue: initialMeal ?? RecognitionSaver.defaultMeal(for: initialDate))
    }

    // 搜索（作用于「当前正在编辑的最后一张未收起草稿」）
    @State private var searchResults: [FoodSearchResult] = []
    @State private var isSearching: Bool = false
    @State private var showSearchResults: Bool = false
    @State private var isCloudSearching: Bool = false        // 本地无命中时联网兜底中
    @State private var cloudErrorMessage: String? = nil       // 联网失败/无结果独立提示
    @State private var searchTask: Task<Void, Never>? = nil   // 防抖 + 取消上一轮联网

    private let mealOptions = ["早餐", "午餐", "晚餐", "加餐"]

    /// 当前正在编辑的草稿 = 数组里最后一张未收起的；搜索/营养填充都作用到它。
    private var editingIndex: Int? {
        drafts.lastIndex(where: { $0.savedEntry == nil })
    }

    /// 重量步进调整（步长 10g，下限 0），作用于当前编辑草稿。
    private func adjustWeight(by delta: Int) {
        guard let i = editingIndex else { return }
        let raw = drafts[i].weightText.trimmingCharacters(in: .whitespaces)
        let current = Double(raw) ?? 0
        let newValue = max(0, current + Double(delta))
        if newValue == floor(newValue) {
            drafts[i].weightText = "\(Int(newValue))"
        } else {
            drafts[i].weightText = String(format: "%.1f", newValue)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        // 搜索卡：仅当「没有任何已入库卡」时展示（纯首张空白卡场景）
                        if !drafts.contains(where: { $0.savedEntry != nil }) {
                            searchCard
                        }

                        // 信息卡：餐次 / 日期，所有草稿共用
                        infoCard

                        // 多张食物草稿：已入库的收起成摘要，未入库的是空白输入卡
                        ForEach(drafts.indices, id: \.self) { idx in
                            if drafts[idx].savedEntry != nil {
                                summaryCard(draft: drafts[idx], at: idx)
                            } else {
                                draftInputCard(at: idx)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
                // CHANGE-[2026-08-18 16:43:00] 删重复全局 onChange(of: searchText)：合并输入框后 name 的 onChange 已联动触发 performSearch，避免二次触发。回退: 恢复 .onChange(of: drafts[editingIndex ?? 0].searchText) { performSearch($1) }
                .onDisappear {
                    // 页面消失时取消未完成的联网任务，避免野指针
                    searchTask?.cancel()
                    searchTask = nil
                }
            }
            .navigationTitle("手动添加食物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(AIATheme.sub)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editingIndex != nil ? "保存" : "完成") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(AIATheme.blue)
                }
            }
        }
    }

    /// 当前编辑草稿的搜索词（绑定搜索卡 TextField）。
    private var editingSearchText: String {
        get { editingIndex.map { drafts[$0].searchText } ?? "" }
        set {
            guard let i = editingIndex else { return }
            drafts[i].searchText = newValue
        }
    }

    // MARK: - 搜索卡片

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // >>> CHANGE-[2026-08-18 16:41:38]-合并食物名称与搜索输入框 开始
            // 原因: 用户反馈"食物名称"与"搜索食物库"两个输入框重复，要求合并成一个。
            //       合并后：单框绑定 name（手动填可直接保存），输入时联动 searchText 触发搜索，点搜索结果仍走 applySearchResult 覆盖 name。
            // 回退: 恢复为 16:34:12 版（"食物名称"框 + Divider + "搜索食物库"框 两个输入框）
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.food)
                Text("食物名称")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
                if isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            TextField("输入食物名称（如 牛肉、苹果），可点搜索结果自动填营养", text: $drafts[editingIndex ?? 0].name)
                .font(AIATheme.Font.body)
                .foregroundStyle(.primary)
                .autocorrectionDisabled()
                .onChange(of: drafts[editingIndex ?? 0].name) { _, newValue in
                    // 名称即搜索词：同步 searchText 触发 performSearch
                    drafts[editingIndex ?? 0].searchText = newValue
                    performSearch(newValue)
                }
            // <<< CHANGE-[2026-08-18 16:41:38]-合并食物名称与搜索输入框 结束

            if !drafts[editingIndex ?? 0].searchText.trimmingCharacters(in: .whitespaces).isEmpty && showSearchResults {
                // 搜索词非空就展示列表（即使本地 0 命中，也展示「联网搜索」按钮供用户主动查询）
                searchResultList(for: editingIndex ?? 0)
            } else if let err = cloudErrorMessage, !err.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.warning)
                    Text(err)
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.warning)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .card()
    }

    private func searchResultList(for idx: Int) -> some View {
        VStack(spacing: 0) {
            // ① 本地命中结果（NutritionLibrary 内置库 / FoodMeta 历史缓存）
            ForEach(searchResults) { result in
                Button {
                    applySearchResult(result, into: idx)
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

            // ② 联网搜索按钮（始终可见，搜索词非空时展示）
            let trimmedSearch = drafts[idx].searchText.trimmingCharacters(in: .whitespaces)
            if !trimmedSearch.isEmpty {
                // 若有本地结果，加分割线
                if !searchResults.isEmpty {
                    Divider().padding(.leading, 4)
                }
                Button {
                    triggerCloudSearch(trimmedSearch, into: idx)
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

                // ③ 联网失败/无结果的错误提示（内联显示在按钮下方，取该卡独立错误）
                if let err = drafts[idx].cloudError {
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

    // MARK: - 草稿输入卡（每张未收起的草稿一张）

    private func draftInputCard(at idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 卡标题（第 N 份）
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.food)
                // >>> CHANGE-[2026-08-18 16:38:05]-手动添加食物标题 开始
                // 原因: 用户要求手动填数据的草稿卡标题加「（需手动输入）」提示，来自搜索的保持干净
                // 回退: 恢复本行 Text 为原 "食物信息" 即可
                Text(drafts.count > 1 ? "第 \(idx + 1) 份" : (drafts[idx].pickedFromSearch ? "食物信息" : "食物信息（需手动输入）"))
                    .font(AIATheme.Font.callout.weight(.medium))
                // <<< CHANGE-[2026-08-18 16:38:05]-手动添加食物标题 结束
                    .foregroundStyle(.primary)
                Spacer()
                // 空卡右上角删除按钮（多张时才可点，最后一张空卡不允许删）
                Button {
                    removeEmptyDraft(at: idx)
                } label: {
                    Image(systemName: "trash")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(drafts.count > 1 ? AIATheme.muted : AIATheme.muted.opacity(0.3))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(drafts.count <= 1)
            }

            // 食物名称 + 内联搜索（搜索卡可见时隐藏，避免与上方 searchCard 重复）
            if drafts.contains(where: { $0.savedEntry != nil }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("食物名称")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AIATheme.food.opacity(0.6))
                            .frame(width: 3)
                        TextField("如 牛肉、苹果、燕麦粥", text: $drafts[idx].searchText)
                            .font(AIATheme.Font.body)
                            .foregroundStyle(.primary)
                            .autocorrectionDisabled()
                            .padding(.vertical, 8)
                            .padding(.leading, 6)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AIATheme.rXS)
                            .fill(AIATheme.surfaceSecondary)
                    )
                    .onChange(of: drafts[idx].searchText) { _, newValue in
                        performSearch(newValue)
                    }

                    // 内联搜索结果（仅当该卡搜索词非空）
                    if !drafts[idx].searchText.trimmingCharacters(in: .whitespaces).isEmpty
                        && showSearchResults {
                        searchResultList(for: idx)
                    } else if let err = drafts[idx].cloudError, !err.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.warning)
                            Text(err)
                                .font(AIATheme.Font.caption)
                                .foregroundStyle(AIATheme.warning)
                        }
                        .padding(.top, 4)
                    }
                }
            }

            // 食用重量（含 ±10g 步进 + 预设）
            HStack(spacing: 12) {
                Text("食用重量")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        adjustWeight(at: idx, by: -10)
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
                        TextField("手动输入", text: $drafts[idx].weightText)
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
                            .stroke(drafts[idx].weightText.isEmpty ? AIATheme.hairline : AIATheme.food, lineWidth: 1)
                    )

                    Button {
                        adjustWeight(at: idx, by: 10)
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
                        drafts[idx].weightText = "\(value)"
                    } label: {
                        Text("\(value)g")
                            .font(AIATheme.Font.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(drafts[idx].weightText == "\(value)" ? AIATheme.food : AIATheme.food.opacity(0.12))
                            .foregroundStyle(drafts[idx].weightText == "\(value)" ? .white : AIATheme.food)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)

            // 营养成分网格
            nutritionSection(at: idx)

            // 本卡底部「添加更多食物」：入库收起 → 底部长新空白卡
            addMoreFoodButton(at: idx)
        }
        .padding(14)
        .card()
    }

    /// 重量步进（作用于指定草稿）
    private func adjustWeight(at idx: Int, by delta: Int) {
        let raw = drafts[idx].weightText.trimmingCharacters(in: .whitespaces)
        let current = Double(raw) ?? 0
        let newValue = max(0, current + Double(delta))
        if newValue == floor(newValue) {
            drafts[idx].weightText = "\(Int(newValue))"
        } else {
            drafts[idx].weightText = String(format: "%.1f", newValue)
        }
    }

    // MARK: - 信息卡片

    private var infoCard: some View {
        VStack(spacing: 0) {
            // 餐次选择
            HStack(spacing: 12) {
                Image(systemName: "clock.fill")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                    .frame(width: 20, alignment: .center)
                Text("餐次")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                Menu {
                    ForEach(mealOptions, id: \.self) { option in
                        Button(option) { meal = option }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(meal)
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

            Divider().padding(.leading, 46)

            // 日期选择
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                    .frame(width: 20, alignment: .center)
                Text("日期")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                DatePicker("", selection: $date, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)

        }
        .card()
    }

    // MARK: - 营养卡片（按草稿索引渲染）

    private func nutritionSection(at idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏（含按当前份量计算的热量 pill）
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                // >>> CHANGE-[2026-08-18 16:38:05]-营养区标题提示 开始
                // 原因: 用户要求手动添加食物界面把"按当前重量"改成"录入营养成分，自动算出热量"，让用户知道热量是自动推算
                // 回退: 恢复本 Text 为 "营养成分（按当前重量）" 即可
                Text("录入营养成分，自动算出热量")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                // <<< CHANGE-[2026-08-18 16:38:05]-营养区标题提示 结束
                Spacer()
                if drafts[idx].totalKcal > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.food)
                        Text("\(Int(drafts[idx].totalKcal)) kcal")
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
                // >>> CHANGE-[2026-08-18 16:38:05]-[营养元素按重量缩放+区分来源只读] 开始
                // 来自搜索(内置库/联网): 营养按当前重量自动缩放且只读; 用户手动填: 保留 TextField 手填基础值(按100g)。
                if drafts[idx].isFromSearch {
                    nutritionReadOnlyCell(label: "蛋白质", unit: "g", value: drafts[idx].totalProtein)
                    nutritionReadOnlyCell(label: "碳水", unit: "g", value: drafts[idx].totalCarbs)
                    nutritionReadOnlyCell(label: "脂肪", unit: "g", value: drafts[idx].totalFat)
                    nutritionReadOnlyCell(label: "膳食纤维", unit: "g", value: drafts[idx].totalFiber)
                    nutritionReadOnlyCell(label: "糖", unit: "g", value: drafts[idx].totalSugar)
                    nutritionReadOnlyCell(label: "钠", unit: "mg", value: drafts[idx].totalSodium)
                } else {
                    nutritionCell(label: "蛋白质", unit: "g",
                              binding: $drafts[idx].baseProteinText)
                    nutritionCell(label: "碳水", unit: "g",
                              binding: $drafts[idx].baseCarbsText)
                    nutritionCell(label: "脂肪", unit: "g",
                              binding: $drafts[idx].baseFatText)
                    nutritionCell(label: "膳食纤维", unit: "g",
                              binding: $drafts[idx].baseFiberText)
                    nutritionCell(label: "糖", unit: "g",
                              binding: $drafts[idx].baseSugarText)
                    nutritionCell(label: "钠", unit: "mg",
                              binding: $drafts[idx].baseSodiumText)
                }
                // <<< CHANGE-[2026-08-18 16:38:05]-[营养元素按重量缩放+区分来源只读] 结束
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
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

    /// 营养网格单元：名称 + 输入框 + 单位，2×3 网格布局使用。
    /// 视觉上比 nutritionRow 更紧凑，适合等宽 cell。2026-07-24 去 icon（按用户要求只展示文字）。
    private func nutritionCell(label: String, unit: String,
                               binding: Binding<String>) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(AIATheme.Font.caption)
                .foregroundStyle(.primary)
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
        .background(AIATheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rXS)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rXS))
    }

    // >>> CHANGE-[2026-08-18 16:38:05]-[营养元素按重量缩放+区分来源只读] 开始
    /// 营养网格只读单元：来自搜索的食物按当前重量自动算，展示数值不可编辑。复用 nutritionCell 视觉。
    private func nutritionReadOnlyCell(label: String, unit: String, value: Double) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(AIATheme.Font.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value > 0 ? String(format: "%.1f", value) : "—")
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
        .background(AIATheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rXS)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rXS))
    }
    // <<< CHANGE-[2026-08-18 16:38:05]-[营养元素按重量缩放+区分来源只读] 结束

    // MARK: - 搜索

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

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // 取消上一轮未完成的联网任务（防抖）
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
        isCloudSearching = false
        // 清当前编辑卡的独立错误（全局 cloudErrorMessage 仅 searchCard 场景用）
        if let ei = editingIndex {
            drafts[ei].cloudError = nil
        }

        // ① 本地搜（FoodSearcher 内部已合并 NutritionLibrary + FoodMeta 缓存）
        let results = FoodSearcher.localSearch(trimmed, foodMetas: foodMetas, in: context)
        searchResults = results
        isSearching = false
        // 联网搜索改为用户手动触发：searchResultList 底部始终展示「联网搜索营养」按钮。
    }

    /// 选择搜索结果后，自动填充到指定草稿
    private func applySearchResult(_ result: FoodSearchResult, into idx: Int) {
        // 云端 queryFood 会为复合菜品返回带口径的名称（如「玉米猪肉饺子（熟，约值）」），
        // 括号内容是模型标注的"估算说明"，不应该作为正式食物名落库或展示给用户。
        // 在落库/展示前一律剥掉「(...)」/「（...）」及其内部内容。
        let cleanName = result.cleanedName()
        guard drafts.indices.contains(idx) else { return }
        drafts[idx].name = cleanName
        // 搜索结果的基础营养按 100g 算 → 显式把食用重量重置为 100g，
        // 让"营养成分（按当前重量）" = 基础营养，避免用户之前改的 200g 等
        // 旧值继续影响计算（用户后续可再调）。
        drafts[idx].weightText = "100"
        drafts[idx].baseKcalText = String(format: "%.1f", result.kcal)
        drafts[idx].baseProteinText = result.protein > 0 ? String(format: "%.1f", result.protein) : ""
        drafts[idx].baseCarbsText = result.carbs > 0 ? String(format: "%.1f", result.carbs) : ""
        drafts[idx].baseFatText = result.fat > 0 ? String(format: "%.1f", result.fat) : ""
        drafts[idx].baseFiberText = result.fiber > 0 ? String(format: "%.1f", result.fiber) : ""
        drafts[idx].baseSugarText = result.sugar > 0 ? String(format: "%.1f", result.sugar) : ""
        drafts[idx].baseSodiumText = result.sodium > 0 ? String(format: "%.1f", result.sodium) : ""
        drafts[idx].searchText = cleanName   // 选中后搜索框展示已选食物名（不再清空）
        drafts[idx].pickedFromSearch = true  // >>> 标记为来自搜索，营养区走只读自动缩放
        drafts[idx].cloudError = nil
        searchResults = []
        showSearchResults = false

        // 也写入 FoodMeta 缓存，下次可直接命中
        FoodMetaStore.upsert(
            name: cleanName,
            displayName: cleanName,
            kcal: result.kcal,
            protein: result.protein,
            carbs: result.carbs,
            fat: result.fat,
            fiber: result.fiber,
            sugar: result.sugar,
            sodium: result.sodium,
            source: result.source,
            in: context
        )
    }

    /// 用户点击「联网搜索营养」按钮触发：调云端 queryFood，命中后自动填充表单并落库 FoodMeta。
    private func triggerCloudSearch(_ query: String, into idx: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // 取消旧任务，避免上一轮未完成覆盖本轮结果
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)  // 300ms 防抖，连点不浪费请求
                if Task.isCancelled { return }
                isCloudSearching = true
                drafts[idx].cloudError = nil
                let result: FoodSearchResult?
                do {
                    result = try await FoodSearcher.cloudSearch(name: trimmed)
                } catch let e as NSError where e.domain == "Recognize" && e.code == -4 {
                    // 云端业务错误（如"该食物不在数据库"）：直接展示云端给的原因
                    isCloudSearching = false
                    drafts[idx].cloudError = e.localizedDescription
                    return
                } catch {
                    // 网络/超时等系统错误：给通用提示，避免暴露底层技术信息
                    isCloudSearching = false
                    drafts[idx].cloudError = "联网搜索失败，请检查网络后重试"
                    return
                }
                if Task.isCancelled { return }
                guard let result else {
                    isCloudSearching = false
                    drafts[idx].cloudError = "联网未找到该食物，请手动填写"
                    return
                }
                // 命中：自动填充表单 + 落库 FoodMeta（applySearchResult 内部已 upsert）
                applySearchResult(result, into: idx)
                isCloudSearching = false
            } catch {
                isCloudSearching = false
                if !Task.isCancelled {
                    drafts[idx].cloudError = "联网搜索失败，请稍后重试"
                }
            }
        }
    }

    // MARK: - 添加更多食物按钮（每张草稿底部一份）

    private func addMoreFoodButton(at idx: Int) -> some View {
        Button {
            saveAndContinue(at: idx)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(AIATheme.Font.subhead.weight(.medium))
                Text("添加更多食物")
                    .font(AIATheme.Font.callout.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.food.opacity(0.6))
            }
            .foregroundStyle(AIATheme.food)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AIATheme.food.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .overlay(
                RoundedRectangle(cornerRadius: AIATheme.rMD)
                    .stroke(AIATheme.food.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!drafts[idx].isValid)
        .opacity(drafts[idx].isValid ? 1 : 0.5)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: - 已入库摘要卡

    private func summaryCard(draft: FoodDraft, at idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 第一行：第 N 份 + 食物名称（左），删除按钮（右）
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.food)
                Text("第 \(idx + 1) 份")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                Text(draft.savedEntry?.name ?? draft.name)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    deleteDraft(at: idx)
                } label: {
                    Image(systemName: "trash")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(AIATheme.muted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }

            // 第二行：餐次·重量（左）+ 热量（右）
            HStack(spacing: 6) {
                Text(draft.savedEntry?.meal ?? meal)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.sub)
                if draft.savedWeight > 0 {
                    Text("· \(Int(draft.savedWeight))g")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.food)
                    Text("\(Int(draft.savedCalories)) kcal")
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(AIATheme.food)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
        .overlay(
            RoundedRectangle(cornerRadius: AIATheme.rSM)
                .stroke(AIATheme.hairline, lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.2), value: drafts.count)
    }

    // MARK: - 保存

    /// 构建一条 FoodEntry（按草稿索引取字段）。
    private func buildEntry(from draft: FoodDraft) -> FoodEntry {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespaces)
        let w = draft.weight
        let baseCal = Double(draft.baseKcalText) ?? 0
        let basePro = Double(draft.baseProteinText) ?? 0
        let baseCar = Double(draft.baseCarbsText) ?? 0
        let baseFat = Double(draft.baseFatText) ?? 0
        let baseFib = Double(draft.baseFiberText) ?? 0
        let baseSug = Double(draft.baseSugarText) ?? 0
        let baseSod = Double(draft.baseSodiumText) ?? 0
        let ratio = w / 100

        return FoodEntry(
            name: trimmedName,
            calories: draft.totalKcal,
            protein: basePro * ratio,
            carbs: baseCar * ratio,
            fat: baseFat * ratio,
            fiber: baseFib * ratio,
            sugar: baseSug * ratio,
            sodium: baseSod * ratio,
            portion: "\(Int(w))克",
            meal: meal,
            date: date,
            weightGram: w,
            // >>> CHANGE-[2026-08-18 16:38:05]-手动填卡baseCalories兜底 开始
            // 原因: 手动填卡 baseKcalText 为空,baseCal=0 会让 baseCalories 落 0,后续按其他重量重算热量出错。
            //       改为: 有 baseKcalText 用 baseKcalText,否则用 4+4+9 推算法(与 totalKcal 一致)。
            // 回退: 恢复 baseCalories: baseCal
            baseCalories: baseCal > 0 ? baseCal : ((basePro * 4 + baseCar * 4 + baseFat * 9)),
            baseProtein: basePro,
            baseCarbs: baseCar,
            baseFat: baseFat,
            baseFiber: baseFib,
            baseSugar: baseSug,
            baseSodium: baseSod
        )
    }

    /// 入库一张草稿（插入 + 来源 + 缓存 + 同步 + 桌面组件刷新）。返回真实实例。
    private func persist(draft: FoodDraft) -> FoodEntry {
        let entry = buildEntry(from: draft)
        context.insert(entry)
        context.insert(FoodSource(foodSyncId: entry.syncId, origin: "manual"))
        // >>> CHANGE-[2026-08-18 16:38:05]-persist保存日志 开始
        // 原因: 手动填卡保存后列表不显示，怀疑 save 静默失败。try? 吞掉错误，改为 do-try-catch 打印定位。
        // 回退: 恢复 try? context.save() 单行即可
        do {
            try context.save()
            print("[AddFoodManual] save OK: \(entry.name) cal=\(entry.calories) meal=\(entry.meal) date=\(entry.date)")
        } catch {
            print("[AddFoodManual] save FAILED: \(error)")
        }
        // <<< CHANGE-[2026-08-18 16:38:05]-persist保存日志 结束
        UsageAnalytics.logAdd("food", source: "manual")
        WidgetSnapshot.refreshAfterWrite()

        FoodMetaStore.upsertFromTotal(
            name: draft.name.trimmingCharacters(in: .whitespaces),
            displayName: draft.name.trimmingCharacters(in: .whitespaces),
            totalKcal: entry.calories,
            totalProtein: entry.protein,
            totalCarbs: entry.carbs,
            totalFat: entry.fat,
            totalFiber: entry.fiber,
            totalSugar: entry.sugar,
            totalSodium: entry.sodium,
            weightGram: entry.weightGram ?? 0,
            source: "manual",
            in: context
        )
        return entry
    }

    /// 保存：把最后一张未收起的草稿也入库，然后关闭页面。
    private func save() {
        guard let i = editingIndex, drafts[i].isValid else {
            // 没有待保存的草稿（全部已入库）→ 直接关闭
            DispatchQueue.main.async { dismiss() }
            return
        }
        let draft = drafts[i]
        let entry = persist(draft: draft)
        drafts[i].savedEntry = entry
        drafts[i].savedCalories = entry.calories
        drafts[i].savedWeight = entry.weightGram ?? 0
        DispatchQueue.main.async { dismiss() }
    }

    /// 保存当前草稿并收起，底部长出一张新空白卡（保留日期/餐次，不关闭页面）。
    private func saveAndContinue(at idx: Int) {
        let draft = drafts[idx]
        guard draft.isValid else { return }
        let entry = persist(draft: draft)
        // 该草稿收起：持有真实实例 + 记录展示快照
        drafts[idx].savedEntry = entry
        drafts[idx].savedCalories = entry.calories
        drafts[idx].savedWeight = entry.weightGram ?? 0
        // 重置该草稿为空白（name/营养清空，重量回到 100），但保留它的 id 用于 ForEach 稳定
        drafts[idx].name = ""
        drafts[idx].weightText = "100"
        drafts[idx].baseKcalText = ""
        drafts[idx].baseProteinText = ""
        drafts[idx].baseCarbsText = ""
        drafts[idx].baseFatText = ""
        drafts[idx].baseFiberText = ""
        drafts[idx].baseSugarText = ""
        drafts[idx].baseSodiumText = ""
        drafts[idx].searchText = ""
        drafts[idx].cloudError = nil
        // 底部长一张新空白卡
        drafts.append(FoodDraft())
        // 搜索区复位（指向新的编辑卡）
        searchResults = []
        showSearchResults = false
        cloudErrorMessage = nil
    }

    /// 删除已收起草稿：走 SafeDelete.foodByID 软删，避免滚动后 fault 闪退。
    private func deleteDraft(at idx: Int) {
        guard let entry = drafts[idx].savedEntry else { return }
        let id = entry.persistentModelID
        drafts.remove(at: idx)
        SafeDelete.foodByID(id, in: context)
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
    }

    /// 删除空白输入卡（尚未入库）：直接从数组移除，无需软删。
    private func removeEmptyDraft(at idx: Int) {
        guard drafts.indices.contains(idx) else { return }
        guard drafts.count > 1 else { return }  // 至少保留一张空白输入卡
        drafts.remove(at: idx)
    }
}
