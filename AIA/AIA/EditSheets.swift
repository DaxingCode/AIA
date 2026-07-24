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
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("编辑食物")
            .navigationBarTitleDisplayMode(.inline)
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
        }
    }

    // MARK: - 卡片
    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("食物名称")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            TextField("如 牛肉", text: $name)
                .font(AIATheme.Font.headline)
                .foregroundStyle(.primary)
        }
        .padding(14)
        .card()
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
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("营养成分（按当前重量）")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            VStack(spacing: 0) {
                nutritionRow(icon: "flame.fill", label: "热量", unit: "kcal",
                             binding: totalBinding(for: $baseCaloriesText), color: AIATheme.food)
                Divider().padding(.leading, 46)
                nutritionRow(icon: "fish.fill", label: "蛋白质", unit: "g",
                             binding: totalBinding(for: $baseProteinText), color: AIATheme.food)
                Divider().padding(.leading, 46)
                nutritionRow(icon: "leaf.fill", label: "碳水", unit: "g",
                             binding: totalBinding(for: $baseCarbsText), color: AIATheme.food)
                Divider().padding(.leading, 46)
                nutritionRow(icon: "drop.fill", label: "脂肪", unit: "g",
                             binding: totalBinding(for: $baseFatText), color: AIATheme.food)
                Divider().padding(.leading, 46)
                nutritionRow(icon: "leaf", label: "膳食纤维", unit: "g",
                             binding: totalBinding(for: $baseFiberText), color: AIATheme.food)
                Divider().padding(.leading, 46)
                nutritionRow(icon: "cube.fill", label: "糖", unit: "g",
                             binding: totalBinding(for: $baseSugarText), color: AIATheme.food)
                Divider().padding(.leading, 46)
                nutritionRow(icon: "bolt.fill", label: "钠", unit: "mg",
                             binding: totalBinding(for: $baseSodiumText), color: AIATheme.food)
            }
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .card()
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
        entry.syncUpdatedAt = .now
        try? context.save()
        dismiss()
    }
}

// MARK: - 账单编辑
struct EditBillView: View {
    let bill: Bill
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

    init(bill: Bill) {
        self.bill = bill
        _merchant = State(initialValue: bill.merchant)
        _amountText = State(initialValue: String(format: "%.2f", bill.amount))
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
                        deleteCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("编辑账单")
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

// MARK: - 待办编辑
struct EditTodoView: View {
    let reminder: Reminder
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

    init(reminder: Reminder) {
        self.reminder = reminder
        _title = State(initialValue: reminder.title)
        _hasDue = State(initialValue: reminder.due != nil)
        _due = State(initialValue: reminder.due ?? Date())
        _priority = State(initialValue: reminder.priority)
        _repeatRule = State(initialValue: reminder.repeatRule)
        _done = State(initialValue: reminder.done)
        _alertItems = State(initialValue: alerts(from: reminder))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AIATheme.fillSoft.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        titleCard
                        dueCard
                        alertCard
                        propertyCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("编辑待办")
            .navigationBarTitleDisplayMode(.inline)
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
            .sheet(item: $editingCustom) { item in
                customTimeSheet(item: item)
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

    private var dueCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow(icon: "calendar.badge.clock", label: "设置截止时间", isOn: $hasDue)
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
        .padding(.top, 4)
        .card()
    }

    private var alertCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "bell.badge")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Text("提醒通知")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                Spacer()
                Text("\(alertItems.count)/4")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            if !hasDue {
                Text("设置截止时间后，可添加最多 4 个通知时间")
                    .font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
                    .padding(.vertical, 8)
            } else {
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
                        let newItem = AlertItem(option: .before1Hour, customDate: due)
                        alertItems.append(newItem)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(AIATheme.Font.body)
                                .foregroundStyle(AIATheme.blue)
                            Text("添加提醒时间")
                                .font(AIATheme.Font.subhead.weight(.medium))
                                .foregroundStyle(AIATheme.blue)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .card()
    }

    private var propertyCard: some View {
        VStack(spacing: 0) {
            menuRow(icon: "flag", label: "优先级", selection: $priority,
                    options: priorityOptions.map { ($0.value, $0.label) })
            Divider().padding(.leading, 46)
            menuRow(icon: "arrow.clockwise", label: "重复", selection: $repeatRule,
                    options: repeatOptions.map { ($0.value, $0.label) })
            Divider().padding(.leading, 46)
            toggleRow(icon: "checkmark.circle", label: "已完成", isOn: $done)
        }
        .card()
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
        HStack(spacing: 12) {
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

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        reminder.title = trimmed.isEmpty ? reminder.title : trimmed
        reminder.due = hasDue ? due : nil
        reminder.priority = priority
        reminder.repeatRule = repeatRule
        reminder.done = done
        let times = hasDue ? reminderTimes(from: alertItems, due: due) : []
        reminder.remindTimes = times
        reminder.remindAt = times.first
        reminder.syncUpdatedAt = .now
        try? context.save()
        if done {
            ReminderNotificationManager.cancel(reminder)
        } else if hasDue {
            ReminderNotificationManager.schedule(reminder)
        } else {
            ReminderNotificationManager.cancel(reminder)
        }
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
