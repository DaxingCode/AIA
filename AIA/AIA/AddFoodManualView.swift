// AddFoodManualView.swift
// 手动添加食物 + 食物库搜索快速选择。
// 入口：饮食记录页顶部「手动输入」按钮。
// 支持：从 NutritionLibrary / FoodMeta 搜索已有食物快速填充营养值，
//       或手动输入全部营养信息。
import SwiftUI
import SwiftData

// MARK: - 食物搜索结果
private struct FoodSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let kcal: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    var fiber: Double
    var sugar: Double
    var sodium: Double
    var source: String  // "library" / "cache"
}

struct AddFoodManualView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \FoodMeta.hitCount, order: .reverse) private var foodMetas: [FoodMeta]

    // 基础信息
    @State private var name: String = ""
    @State private var meal: String = "午餐"
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

    private let mealOptions = ["早餐", "午餐", "晚餐", "加餐"]

    private let library = NutritionLibrary.shared

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

            if showSearchResults && !searchResults.isEmpty {
                searchResultList
            } else if showSearchResults && !searchText.isEmpty && searchResults.isEmpty {
                Text("未找到匹配食物，请手动填写下方营养信息")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
                    .padding(.top, 4)
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
                        Text(result.source == "library" ? "内置库" : "历史缓存")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AIATheme.surfaceSecondary)
                            .clipShape(Capsule())
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
        }
        .padding(10)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    // MARK: - 名称卡片

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("食物名称")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            TextField("如 牛肉、苹果", text: $name)
                .font(AIATheme.Font.headline)
                .foregroundStyle(.primary)
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

            Divider().padding(.leading, 46)

            // 重量
            HStack(spacing: 12) {
                Image(systemName: "scalemass.fill")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                    .frame(width: 20, alignment: .center)
                Text("重量")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                TextField("100", text: $weightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(AIATheme.Font.headline.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 80)
                Text("g")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(.vertical, 14)
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
                nutritionCell(icon: "fish.fill", label: "蛋白质", unit: "g",
                              binding: $baseProteinText, color: AIATheme.blue)
                nutritionCell(icon: "leaf.fill", label: "碳水", unit: "g",
                              binding: $baseCarbsText, color: AIATheme.amber)
                nutritionCell(icon: "drop.fill", label: "脂肪", unit: "g",
                              binding: $baseFatText, color: AIATheme.green)
                nutritionCell(icon: "crop", label: "膳食纤维", unit: "g",
                              binding: $baseFiberText, color: AIATheme.health)
                nutritionCell(icon: "circle.hexagongrid", label: "糖", unit: "g",
                              binding: $baseSugarText, color: AIATheme.warn)
                nutritionCell(icon: "drop.triangle", label: "钠", unit: "mg",
                              binding: $baseSodiumText, color: AIATheme.todo)
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

    // MARK: - 搜索

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            showSearchResults = false
            return
        }
        isSearching = true
        showSearchResults = true

        // 1) 从 NutritionLibrary 匹配
        var results: [FoodSearchResult] = []
        if let ref = library.match(trimmed) {
            results.append(FoodSearchResult(
                name: ref.name, kcal: ref.kcal, protein: ref.protein,
                carbs: ref.carbs, fat: ref.fat, fiber: ref.fiber,
                sugar: ref.sugar, sodium: ref.sodium, source: "library"
            ))
        }

        // 2) 从 FoodMeta 缓存搜索（归一化名称包含搜索词的）
        let normQuery = FoodMeta.normalize(trimmed)
        let matchedMetas = foodMetas.filter { meta in
            meta.name.contains(normQuery) || FoodMeta.normalize(meta.displayName).contains(normQuery)
        }
        for meta in matchedMetas {
            // 避免与 NutritionLibrary 结果重复
            if !results.contains(where: { FoodMeta.normalize($0.name) == meta.name }) {
                results.append(FoodSearchResult(
                    name: meta.displayName, kcal: meta.kcal, protein: meta.protein,
                    carbs: meta.carbs, fat: meta.fat, fiber: meta.fiber,
                    sugar: meta.sugar, sodium: meta.sodium, source: "cache"
                ))
            }
        }

        // 3) 如果 NutritionLibrary 没有精确匹配，也尝试子串搜索库内食物
        if results.isEmpty {
            if let ref = library.match(trimmed) {
                results.append(FoodSearchResult(
                    name: ref.name, kcal: ref.kcal, protein: ref.protein,
                    carbs: ref.carbs, fat: ref.fat, fiber: ref.fiber,
                    sugar: ref.sugar, sodium: ref.sodium, source: "library"
                ))
            }
        }

        searchResults = results
        isSearching = false
    }

    /// 选择搜索结果后，自动填充表单
    private func applySearchResult(_ result: FoodSearchResult) {
        name = result.name
        baseKcalText = String(format: "%.1f", result.kcal)
        baseProteinText = result.protein > 0 ? String(format: "%.1f", result.protein) : ""
        baseCarbsText = result.carbs > 0 ? String(format: "%.1f", result.carbs) : ""
        baseFatText = result.fat > 0 ? String(format: "%.1f", result.fat) : ""
        baseFiberText = result.fiber > 0 ? String(format: "%.1f", result.fiber) : ""
        baseSugarText = result.sugar > 0 ? String(format: "%.1f", result.sugar) : ""
        baseSodiumText = result.sodium > 0 ? String(format: "%.1f", result.sodium) : ""
        searchText = ""
        searchResults = []
        showSearchResults = false

        // 也写入 FoodMeta 缓存，下次可直接命中
        FoodMetaStore.upsert(
            name: result.name,
            displayName: result.name,
            kcal: result.kcal,
            protein: result.protein,
            carbs: result.carbs,
            fat: result.fat,
            source: result.source,
            in: context
        )
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
            weightGram: w,
            source: "manual",
            in: context
        )

        dismiss()
    }
}
