// EditSheets.swift
// 四个模块的「编辑」弹窗：配合列表左滑删除 + 点击编辑 使用。
// 采用「本地副本 + 保存时回写模型」的方式，点取消即不改动，保证可回退。
import SwiftUI
import SwiftData
import UIKit

private let mealOptions = ["早餐", "午餐", "晚餐", "加餐"]
private let priorityOptions: [(value: String, label: String)] = [("high", "高"), ("medium", "中"), ("low", "低")]
private let repeatOptions: [(value: String, label: String)] = [("none", "不重复"), ("daily", "每天"), ("weekly", "每周"), ("monthly", "每月")]
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
struct EditFoodView: View {
    let entry: FoodEntry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    // 食物库本地缓存（hitCount 倒序，热词靠前）
    @Query(sort: \FoodMeta.hitCount, order: .reverse) private var foodMetas: [FoodMeta]

    @State private var name: String
    @State private var meal: String
    @State private var weightText: String
    // 内部保存每100g的营养基准；UI 上显示的是「当前重量下的总量」。
    @State private var baseCaloriesText: String
    @State private var baseProteinText: String
    @State private var baseCarbsText: String
    @State private var baseFatText: String
    @State private var baseFiberText: String       // 膳食纤维（每100g克）
    @State private var baseSugarText: String       // 糖（每100g克）
    @State private var baseSodiumText: String      // 钠（每100g毫克）

    // 备注栏（文字 + 图片附件，存于 FoodNote，仅本地）
    @State private var noteText: String = ""
    @State private var noteImageNames: [String] = []
    // 来源识别原图（entry.imageName），仅本地；展示但不并入备注图片列表
    @State private var sourceImageName: String?

    // 图片添加 / 查看
    @State private var showImageSourceDialog = false
    @State private var showImagePicker = false
    @State private var showCameraPicker = false
    @State private var showFullImage = false
    @State private var fullImageName: String? = nil
    @State private var pickedImage: UIImage? = nil

    // 删除
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    // 食物库搜索（与手动添加页共用 FoodSearcher，改名时自动检索 → 用户确认 → 营养自动更新）
    @State private var searchText: String = ""
    @State private var searchResults: [FoodSearchResult] = []
    @State private var isSearching: Bool = false
    @State private var showSearchResults: Bool = false
    @State private var isCloudSearching: Bool = false
    @State private var cloudErrorMessage: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    init(entry: FoodEntry) {
        self.entry = entry
        let weight = entry.weightGram ?? RecognitionSaver.weightFromPortion(entry.portion)
        let currentWeight = max(weight, 1)
        _name = State(initialValue: entry.name)
        _meal = State(initialValue: entry.meal)
        _weightText = State(initialValue: String(format: "%.0f", weight))
        // 没有持久化基准时，用当前营养反推每100g含量作为基准。
        _baseCaloriesText = State(initialValue: String(format: "%.1f",
            entry.baseCalories ?? (entry.calories / currentWeight * 100)))
        _baseProteinText = State(initialValue: String(format: "%.1f",
            entry.baseProtein ?? (entry.protein / currentWeight * 100)))
        _baseCarbsText = State(initialValue: String(format: "%.1f",
            entry.baseCarbs ?? (entry.carbs / currentWeight * 100)))
        _baseFatText = State(initialValue: String(format: "%.1f",
            entry.baseFat ?? (entry.fat / currentWeight * 100)))
        _baseFiberText = State(initialValue: String(format: "%.1f",
            entry.baseFiber ?? (entry.fiber / currentWeight * 100)))
        _baseSugarText = State(initialValue: String(format: "%.1f",
            entry.baseSugar ?? (entry.sugar / currentWeight * 100)))
        _baseSodiumText = State(initialValue: String(format: "%.1f",
            entry.baseSodium ?? (entry.sodium / currentWeight * 100)))
        _sourceImageName = State(initialValue: entry.imageName)
    }

    /// 当前重量下的总热量（用于标题栏右侧 pill 显示）。
    private var displayedKcalText: String {
        let base = Double(baseCaloriesText) ?? 0
        let weight = Double(weightText) ?? 100
        return String(format: "%.0f", base * weight / 100)
    }


    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        nameCard
                        infoCard
                        nutritionCard
                        noteCard
                        deleteCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("编辑食物")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(image: $pickedImage)
            }
            .fullScreenCover(isPresented: $showCameraPicker) {
                CameraPicker(image: $pickedImage)
            }
            .fullScreenCover(isPresented: $showFullImage) {
                if let img = LocalImageStore.load(fullImageName) {
                    FullImageView(image: img)
                }
            }
            .confirmationDialog("添加图片", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("拍照") { showCameraPicker = true }
                }
                Button("从相册选择") { showImagePicker = true }
                Button("取消", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                }
            }
            .alert("删除食物记录", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    pendingDeleteID = entry.persistentModelID
                    dismiss()
                }
            } message: {
                Text("删除后不可恢复，确定要删除吗？")
            }
            .onAppear {
                // 懒加载备注：首次进入编辑页时按 syncId 取 FoodNote（1:1）
                let targetSyncId = entry.syncId
                if let existing = try? context.fetch(FetchDescriptor<FoodNote>(
                    predicate: #Predicate { $0.syncId == targetSyncId })).first {
                    noteText = existing.note
                    noteImageNames = existing.imageNames
                }
            }
            .onChange(of: pickedImage) { _, new in
                guard let img = new else { return }
                pickedImage = nil
                if let name = LocalImageStore.save(img) {
                    noteImageNames.append(name)
                }
            }
            .onChange(of: name) { _, newValue in
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
        }
    }

    // MARK: - 卡片
    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("食物名称")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
                if isSearching {
                    ProgressView().scaleEffect(0.7)
                }
            }
            TextField("如 牛肉", text: $name)
                .font(AIATheme.Font.headline)
                .foregroundStyle(.primary)
                .autocorrectionDisabled()

            if showSearchResults && !searchResults.isEmpty {
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
            } else if showSearchResults && !name.isEmpty && searchResults.isEmpty {
                Text("未找到匹配食物，请手动填写下方营养信息")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
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
        }
        .padding(10)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            menuRow(icon: "clock.fill", label: "餐次", selection: $meal,
                    options: mealOptions.map { ($0, $0) })
            Divider().padding(.leading, 46)
            HStack(spacing: 12) {
                Image(systemName: "scalemass.fill")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.muted)
                    .frame(width: 20, alignment: .center)
                Text("重量")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(.primary)
                Spacer()
                TextField("0", text: $weightText)
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

            let hasSource = LocalImageStore.load(sourceImageName) != nil
            let hasNoteImg = !noteImageNames.isEmpty
            if hasSource || hasNoteImg {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        // 来源识别原图（绿色角标「来源」），点击看大图
                        if let sImg = LocalImageStore.load(sourceImageName), let sName = sourceImageName {
                            thumbnail(image: sImg, badge: "来源",
                                      onTap: { fullImageName = sName; showFullImage = true },
                                      onDelete: {
                                          LocalImageStore.delete(sName)
                                          sourceImageName = nil
                                      })
                        }
                        // 备注附件图片
                        ForEach(Array(noteImageNames.enumerated()), id: \.offset) { _, name in
                            if let img = LocalImageStore.load(name) {
                                thumbnail(image: img, badge: nil,
                                          onTap: { fullImageName = name; showFullImage = true },
                                          onDelete: {
                                              LocalImageStore.delete(name)
                                              noteImageNames.removeAll { $0 == name }
                                          })
                            }
                        }
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
                .frame(width: 20, alignment: .center)
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
    private func totalBinding(for base: Binding<String>) -> Binding<String> {
        Binding(
            get: {
                let baseValue = Double(base.wrappedValue) ?? 0
                let weight = Double(self.weightText) ?? 100
                return String(format: "%.0f", baseValue * weight / 100)
            },
            set: { newTotal in
                let total = Double(newTotal) ?? 0
                let weight = max(Double(self.weightText) ?? 100, 1)
                base.wrappedValue = String(format: "%.1f", total / weight * 100)
            }
        )
    }

    private func save() {
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
        dismiss()
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

    /// 当食物名变化时触发检索。流程与 AddFoodManualView.performSearch 完全一致：
    /// 本地 NutritionLibrary + FoodMeta → 无命中时联网兜底（600ms 防抖）。
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

        let results = FoodSearcher.localSearch(trimmed, foodMetas: foodMetas, in: context)
        searchResults = results
        isSearching = false

        if results.isEmpty {
            searchTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 600_000_000)
                    if Task.isCancelled { return }
                    isCloudSearching = true
                    cloudErrorMessage = nil

                    let result: FoodSearchResult?
                    do {
                        result = try await FoodSearcher.cloudSearch(name: trimmed)
                    } catch {
                        isCloudSearching = false
                        cloudErrorMessage = "联网搜索失败，请稍后重试或手动填写"
                        return
                    }
                    if Task.isCancelled { return }

                    guard let result else {
                        isCloudSearching = false
                        cloudErrorMessage = "联网未找到该食物，请手动填写"
                        return
                    }

                    FoodMetaStore.upsert(
                        name: result.name, displayName: result.name,
                        kcal: result.kcal, protein: result.protein,
                        carbs: result.carbs, fat: result.fat,
                        source: "cloud", in: context
                    )

                    if Task.isCancelled { return }
                    searchResults = [result]
                    isCloudSearching = false
                } catch {
                    isCloudSearching = false
                    if !Task.isCancelled {
                        cloudErrorMessage = "联网搜索失败，请稍后重试或手动填写"
                    }
                }
            }
        } else {
            cloudErrorMessage = nil
        }
    }

    /// 用户点击搜索结果：把 base* 字段全部覆盖为该食物每 100g 营养。
    /// 重量保留用户当前值（用户可能之前手动改过），由 displayedKcalText 按比例算出当前份量下的总热量。
    private func applySearchResult(_ result: FoodSearchResult) {
        name = result.name
        baseCaloriesText = String(format: "%.1f", result.kcal)
        baseProteinText = result.protein > 0 ? String(format: "%.1f", result.protein) : ""
        baseCarbsText = result.carbs > 0 ? String(format: "%.1f", result.carbs) : ""
        baseFatText = result.fat > 0 ? String(format: "%.1f", result.fat) : ""
        baseFiberText = result.fiber > 0 ? String(format: "%.1f", result.fiber) : ""
        baseSugarText = result.sugar > 0 ? String(format: "%.1f", result.sugar) : ""
        baseSodiumText = result.sodium > 0 ? String(format: "%.1f", result.sodium) : ""
        searchText = result.name
        searchResults = []
        showSearchResults = false

        FoodMetaStore.upsert(
            name: result.name, displayName: result.name,
            kcal: result.kcal, protein: result.protein,
            carbs: result.carbs, fat: result.fat,
            source: result.source, in: context
        )
    }
}

// MARK: - 账单编辑（支持编辑 + 手动添加两种模式；UI/逻辑共用，仅 deleteCard 和 title 切换）
struct EditBillView: View {
    let bill: Bill
    let isAdding: Bool          // true = 手动添加模式（不显示删除按钮，title 改"添加账单"）
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

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
    @State private var showCameraPicker = false
    @State private var showFullImage = false
    @State private var showDeleteConfirm = false
    @State private var pickedImage: UIImage? = nil
    @State private var pendingDeleteID: PersistentIdentifier? = nil

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
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        infoCard
                        incomeCard
                        noteCard
                        if !isAdding { deleteCard }    // 添加模式不显示删除按钮
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle(isAdding ? "添加账单" : "编辑账单")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCategoryPicker) {
                BillCategoryPickerSheet(selection: $category)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                }
            }
            .confirmationDialog("添加图片", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("拍照") { showCameraPicker = true }
                }
                Button("从相册选择") { showImagePicker = true }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(image: $pickedImage)
            }
            .fullScreenCover(isPresented: $showCameraPicker) {
                CameraPicker(image: $pickedImage)
            }
            .fullScreenCover(isPresented: $showFullImage) {
                if let img = LocalImageStore.load(imageName) {
                    FullImageView(image: img)
                }
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

    // MARK: - 卡片
    private var infoCard: some View {
        VStack(spacing: 0) {
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
                            showFullImage = true
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
        dismiss()
    }
}

// MARK: - 账单分类选择器
struct BillCategoryPickerSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    private var displaySelection: String {
        selection.trimmingCharacters(in: .whitespaces).isEmpty ? "其他" : selection
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(billCategoryOptions, id: \.self) { cat in
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
        }
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

// MARK: - 待办编辑（支持编辑 + 手动添加两种模式；UI/逻辑共用，仅 deleteCard 和 title 切换）
struct EditTodoView: View {
    let reminder: Reminder
    let isAdding: Bool          // true = 手动添加模式（不显示删除按钮，title 改"添加待办"；save() 时草稿 syncDeleted 复活）
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

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

    // 删除（参照 EditBillView 模式：先 dismiss，等 onDisappear 真正软删）
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil

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
            ScrollView {
                VStack(spacing: 16) {
                    titleCard
                    timeAlertCard
                    // 2026-07-24 顺序调整：propertyCard（状态+设置：已完成/优先级/重复）上移
                    // 备注 noteCard 下移 —— 用户截图反馈"先看状态/再写备注"更符合视觉流
                    propertyCard
                    noteCard
                    if !isAdding { deleteCard }    // 添加模式不显示删除按钮
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle(isAdding ? "添加待办" : "编辑待办")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // sheet 弹起模式：左「取消」dismiss 关闭 sheet（无系统返回箭头）
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(AIATheme.blue)
            }
        }
        .sheet(item: $editingCustom) { item in
            customTimeSheet(item: item)
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
            Text("内容")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
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
                HStack(spacing: 16) {
                    VStack(alignment: .center, spacing: 4) {
                        Text("日期")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                        DatePicker("", selection: $due, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                    }
                    .frame(maxWidth: .infinity)
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

    // MARK: - 备注卡（仅文字，不带图片附件，参照 EditBillView 简洁模式 + FoodNote 1:1 关联风格）
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
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
            Spacer()
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
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
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
        // 方案A：开关打开但用户未手动添加任何提醒节点时，自动补一个「准时」提醒，
        // 避免「设了截止时间却收不到任何提醒」的违和（用户预期=到点会响）。
        var effectiveAlerts = alertItems
        if hasDue && effectiveAlerts.isEmpty {
            effectiveAlerts = [AlertItem(option: .atTime, customDate: due ?? Date())]
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
}

// MARK: - 健康指标编辑
struct EditHealthView: View {
    let metric: HealthMetric
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var metricName: String
    @State private var valueText: String
    @State private var unit: String
    @State private var date: Date

    init(metric: HealthMetric) {
        self.metric = metric
        _metricName = State(initialValue: metric.metric)
        _valueText = State(initialValue: metric.value)
        _unit = State(initialValue: metric.unit)
        _date = State(initialValue: metric.date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("指标") {
                    TextField("指标名称（如 体重）", text: $metricName)
                    HStack {
                        TextField("数值", text: $valueText).keyboardType(.decimalPad)
                        Divider().frame(height: 24)
                        TextField("单位", text: $unit).frame(width: 70)
                    }
                    DatePicker("日期", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
            }
            .navigationTitle("编辑健康指标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let trimmed = metricName.trimmingCharacters(in: .whitespaces)
        metric.metric = trimmed.isEmpty ? metric.metric : trimmed
        metric.value = valueText.trimmingCharacters(in: .whitespaces)
        metric.unit = unit.trimmingCharacters(in: .whitespaces)
        metric.date = date
        metric.syncUpdatedAt = .now
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
