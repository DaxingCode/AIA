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

struct AddFoodManualView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \FoodMeta.hitCount, order: .reverse) private var foodMetas: [FoodMeta]

    // 基础信息
    @State private var name: String = ""
    @State private var meal: String = RecognitionSaver.defaultMeal(for: .now)
    @State private var date: Date = Date()
    @State private var weightText: String = "100"

    // 每100g营养基准（用户填写或从搜索结果填充）
    @State private var baseKcalText: String = ""
    @State private var baseProteinText: String = ""
    @State private var baseCarbsText: String = ""
    @State private var baseFatText: String = ""
    @State private var baseFiberText: String = ""
    @State private var baseSugarText: String = ""
    @State private var baseSodiumText: String = ""

    // 搜索
    @State private var searchText: String = ""
    @State private var searchResults: [FoodSearchResult] = []
    @State private var isSearching: Bool = false
    @State private var showSearchResults: Bool = false
    @State private var isCloudSearching: Bool = false        // 本地无命中时联网兜底中
    @State private var cloudErrorMessage: String? = nil       // 联网失败/无结果独立提示
    @State private var searchTask: Task<Void, Never>? = nil   // 防抖 + 取消上一轮联网

    private let mealOptions = ["早餐", "午餐", "晚餐", "加餐"]

    /// 当前重量（至少 1g）
    private var weight: Double { max(Double(weightText) ?? 100, 1) }

    /// 当前重量下的总热量
    private var totalKcal: Double {
        let base = Double(baseKcalText) ?? 0
        return base * weight / 100
    }

    /// 表单是否有效
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !baseKcalText.isEmpty &&
        !weightText.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        searchCard
                        nameCard
                        infoCard
                        nutritionCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: searchText) { _, newValue in
                    performSearch(newValue)
                }
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
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(isValid ? AIATheme.blue : AIATheme.muted)
                        .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - 搜索卡片

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                Text("搜索食物库")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
                if isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            TextField("输入食物名称快速搜索营养数据（如 牛肉、苹果）", text: $searchText)
                .font(AIATheme.Font.body)
                .foregroundStyle(.primary)
                .autocorrectionDisabled()

            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty && showSearchResults {
                // 搜索词非空就展示列表（即使本地 0 命中，也展示「联网搜索」按钮供用户主动查询）
                searchResultList
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

    private var searchResultList: some View {
        VStack(spacing: 0) {
            // ① 本地命中结果（NutritionLibrary 内置库 / FoodMeta 历史缓存）
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

            // ② 联网搜索按钮（始终可见，搜索词非空时展示）
            let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
            if !trimmedSearch.isEmpty {
                // 若有本地结果，加分割线
                if !searchResults.isEmpty {
                    Divider().padding(.leading, 4)
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

    // MARK: - 食用重量卡片（合并自原 nameCard + infoCard 重量行）

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("食用重量")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            HStack(spacing: 6) {
                TextField("100", text: $weightText)
                    .keyboardType(.decimalPad)
                    .font(AIATheme.Font.headline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("克")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
            }
        }
        .padding(14)
        .card()
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

    // MARK: - 营养卡片

    private var nutritionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏（含按当前份量计算的热量 pill）
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("营养成分（按当前重量）")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
                if !baseKcalText.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.food)
                        Text("\(Int(totalKcal)) kcal")
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
                nutritionCell(label: "蛋白质", unit: "g",
                              binding: $baseProteinText)
                nutritionCell(label: "碳水", unit: "g",
                              binding: $baseCarbsText)
                nutritionCell(label: "脂肪", unit: "g",
                              binding: $baseFatText)
                nutritionCell(label: "膳食纤维", unit: "g",
                              binding: $baseFiberText)
                nutritionCell(label: "糖", unit: "g",
                              binding: $baseSugarText)
                nutritionCell(label: "钠", unit: "mg",
                              binding: $baseSodiumText)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .card()
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
        cloudErrorMessage = nil
        isCloudSearching = false

        // ① 本地搜（FoodSearcher 内部已合并 NutritionLibrary + FoodMeta 缓存）
        let results = FoodSearcher.localSearch(trimmed, foodMetas: foodMetas, in: context)
        searchResults = results
        isSearching = false
        // 联网搜索改为用户手动触发：searchResultList 底部始终展示「联网搜索营养」按钮。
    }

    /// 选择搜索结果后，自动填充表单
    private func applySearchResult(_ result: FoodSearchResult) {
        // 云端 queryFood 会为复合菜品返回带口径的名称（如「玉米猪肉饺子（熟，约值）」），
        // 括号内容是模型标注的"估算说明"，不应该作为正式食物名落库或展示给用户。
        // 在落库/展示前一律剥掉「(...)」/「（...）」及其内部内容。
        let cleanName = result.cleanedName()
        name = cleanName
        // 搜索结果的基础营养按 100g 算 → 显式把食用重量重置为 100g，
        // 让"营养成分（按当前重量）" = 基础营养，避免用户之前改的 200g 等
        // 旧值继续影响计算（用户后续可再调）。
        weightText = "100"
        baseKcalText = String(format: "%.1f", result.kcal)
        baseProteinText = result.protein > 0 ? String(format: "%.1f", result.protein) : ""
        baseCarbsText = result.carbs > 0 ? String(format: "%.1f", result.carbs) : ""
        baseFatText = result.fat > 0 ? String(format: "%.1f", result.fat) : ""
        baseFiberText = result.fiber > 0 ? String(format: "%.1f", result.fiber) : ""
        baseSugarText = result.sugar > 0 ? String(format: "%.1f", result.sugar) : ""
        baseSodiumText = result.sodium > 0 ? String(format: "%.1f", result.sodium) : ""
        searchText = cleanName   // 选中后搜索框展示已选食物名（不再清空）
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

    // MARK: - 保存

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let w = weight
        let baseCal = Double(baseKcalText) ?? 0
        let basePro = Double(baseProteinText) ?? 0
        let baseCar = Double(baseCarbsText) ?? 0
        let baseFat = Double(baseFatText) ?? 0
        let baseFib = Double(baseFiberText) ?? 0
        let baseSug = Double(baseSugarText) ?? 0
        let baseSod = Double(baseSodiumText) ?? 0
        let ratio = w / 100

        let entry = FoodEntry(
            name: trimmedName,
            calories: baseCal * ratio,
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
            baseCalories: baseCal,
            baseProtein: basePro,
            baseCarbs: baseCar,
            baseFat: baseFat,
            baseFiber: baseFib,
            baseSugar: baseSug,
            baseSodium: baseSod
        )
        context.insert(entry)
        try? context.save()

        // 也沉淀到 FoodMeta 缓存
        FoodMetaStore.upsertFromTotal(
            name: trimmedName,
            displayName: trimmedName,
            totalKcal: baseCal * ratio,
            totalProtein: basePro * ratio,
            totalCarbs: baseCar * ratio,
            totalFat: baseFat * ratio,
            totalFiber: baseFib * ratio,
            totalSugar: baseSug * ratio,
            totalSodium: baseSod * ratio,
            weightGram: w,
            source: "manual",
            in: context
        )

        // 🐛 iOS 17+ fullScreenCover + context.save() + dismiss() 同帧死锁：
        // @Query foods 重新发布与 cover 关闭动画争主线程布局周期 → UI 完全卡死。推迟 dismiss 一帧。
        DispatchQueue.main.async { dismiss() }
    }
}
