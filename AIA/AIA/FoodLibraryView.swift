// FoodLibraryView.swift
// 我的食物库：列出用户「主动添加」(source=="user") 与「餐次记录过」(source=="manual") 的食物，
// 支持左滑删除、点击编辑（修改每100g营养与显示名）。删除仅删本地 FoodMeta 行，
// 不影响已有的餐次记录（FoodEntry 自带营养快照）。
// >>> CHANGE-[2026-09-24 16:00:00]-[我的食物库页面] 开始
// 原因: 新增「添加到食物库」能力后，需要一个查看/管理入口。复用 FoodMeta（source 区分），
//       口径：库 = 用户主动添加(user) + 餐次记录沉淀(manual) 的全部食物；builtin/cloud 不在此列。
//       手动餐次记录自动进库，无需额外写入。
// 回退: 删本文件 + ContentView 的 HomeRoute.foodLibrary 与 destination 分支即可。
import SwiftUI
import SwiftData

struct FoodLibraryView: View {
    @Environment(\.modelContext) private var context

    @Query(
        filter: #Predicate<FoodMeta> { $0.source == "user" || $0.source == "manual" },
        sort: \FoodMeta.lastSeen,
        order: .reverse
    )
    private var items: [FoodMeta]

    @State private var showAddFood = false
    @State private var editingMeta: FoodMeta?

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                // >>> CHANGE-[2026-09-24]-[食物库列表改 List 支持左滑] 开始
                // 原因: 用户要求「左滑删除 + 点击编辑」。ScrollView 不支持 swipeActions，改用 List 原生能力。
                // 回退: 改回 ScrollView + VStack，并恢复 row 内 trash 按钮。
                List {
                    ForEach(items, id: \.name) { meta in
                        row(meta)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .contentShape(Rectangle())
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { delete(meta) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .onTapGesture { editingMeta = meta }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // <<< CHANGE-[2026-09-24]-[食物库列表改 List 支持左滑] 结束
            }
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle("我的食物库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddFood = true
                } label: {
                    Image(systemName: "plus")
                        .font(AIATheme.Font.headline)
                        .foregroundStyle(AIATheme.blue)
                }
            }
        }
        .fullScreenCover(isPresented: $showAddFood) {
            // >>> CHANGE-[2026-09-24]-[食物库内添加入口] 开始
            // 从我的食物库进入添加页，预开「仅保存到食物库」，直接入库。
            // 回退: 改回 AddFoodManualView()。
            AddFoodManualView(initialSaveToLibraryOnly: true)
            // <<< CHANGE-[2026-09-24]-[食物库内添加入口] 结束
        }
        .sheet(item: $editingMeta) { meta in
            FoodMetaEditor(meta: meta)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.system(size: 40))
                .foregroundStyle(AIATheme.muted)
            Text("还没有食物")
                .font(AIATheme.Font.callout)
                .foregroundStyle(AIATheme.sub)
            Text("你手动添加、或记录过餐次的食物，都会出现在这里。")
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 100)
    }

    // >>> CHANGE-[2026-09-24]-[食物库卡片改营养网格样式] 开始
    // 原因: 用户要求按设计稿展示每条食物卡：名称+来源副标题+右侧每100g热量，下方六格营养网格。
    //       圆点颜色区分来源（琥珀=手动添加，蓝=餐次记录沉淀）。无 trash 按钮（删除走左滑）。
    // 回退: 恢复旧 row（单行 名称 + P/C/F 文本 + trash）与 body 的单卡+Divider 结构。
    private func row(_ meta: FoodMeta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(meta.source == "user" ? AIATheme.food : AIATheme.blue)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.displayName.isEmpty ? meta.name : meta.displayName)
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(meta.source == "user" ? "手动添加" : "餐次记录") · 每100克")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(meta.kcal))")
                        .font(AIATheme.Font.headline.weight(.bold))
                        .foregroundStyle(AIATheme.food)
                    Text("kcal")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                nutrientCell("蛋白", meta.protein, "g")
                nutrientCell("脂肪", meta.fat, "g")
                nutrientCell("碳水", meta.carbs, "g")
                nutrientCell("纤维", meta.fiber, "g")
                nutrientCell("糖", meta.sugar, "g")
                nutrientCell("钠", meta.sodium, "mg")
            }
        }
        .padding(12)
        .card()
    }

    private func nutrientCell(_ label: String, _ value: Double, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            Text("\(fmt(value))\(unit)")
                .font(AIATheme.Font.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(AIATheme.fillSoft)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
    // <<< CHANGE-[2026-09-24]-[食物库卡片改营养网格样式] 结束

    private func delete(_ meta: FoodMeta) {
        context.delete(meta)
        do {
            try context.save()
            print("[FoodLibrary] delete OK: \(meta.name)")
        } catch {
            print("[FoodLibrary] delete FAILED: \(error)")
        }
    }
}

// >>> CHANGE-[2026-09-24]-[食物库点击编辑] 开始
// 原因: 用户要求库内卡片点击进入编辑，修改每100g营养与显示名。复用 FoodMeta 实例(@Bindable 双向绑定)，
//       保存即写回 SwiftData。名称(name)为唯一键不在此编辑（改名会破坏已有餐次引用）。
// 回退: 删本 struct + body 的 .sheet(item: $editingMeta) 即可。
struct FoodMetaEditor: View {
    @Bindable var meta: FoodMeta
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("食物名称") {
                    TextField("名称", text: $meta.displayName)
                }
                Section("每 100 克营养") {
                    nutrientField("热量", $meta.kcal, "kcal")
                    nutrientField("蛋白质", $meta.protein, "g")
                    nutrientField("碳水", $meta.carbs, "g")
                    nutrientField("脂肪", $meta.fat, "g")
                    nutrientField("纤维", $meta.fiber, "g")
                    nutrientField("糖", $meta.sugar, "g")
                    nutrientField("钠", $meta.sodium, "mg")
                    // >>> CHANGE-[2026-09-24]-[编辑页按营养素自动算热量] 开始
                    // 原因: 用户希望输入蛋白/碳水/脂肪克重后自动算出热量（4/4/9 估算，纤维已含在碳水内不重复计）。
                    //       做成一键填入而非实时覆盖，避免营养标签上的实际热量被公式值冲掉。
                    // 回退: 删本 Button 行 + 下方 autoKcal 计算属性即可。
                    Button {
                        meta.kcal = autoKcal
                    } label: {
                        HStack {
                            Label("按营养素计算热量", systemImage: "wand.and.stars")
                                .font(AIATheme.Font.footnote.weight(.medium))
                                .foregroundStyle(AIATheme.blue)
                            Spacer()
                            Text("≈ \(Int(autoKcal.rounded())) kcal")
                                .font(AIATheme.Font.footnote)
                                .foregroundStyle(AIATheme.sub)
                        }
                    }
                    // <<< CHANGE-[2026-09-24]-[编辑页按营养素自动算热量] 结束
                }
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("删除该食物", systemImage: "trash")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(meta.displayName.isEmpty ? meta.name : meta.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        try? meta.modelContext?.save()
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(AIATheme.Font.headline)
                            .foregroundStyle(AIATheme.blue)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        try? meta.modelContext?.save()
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "删除该食物后，已记录的餐次不受影响。",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    context.delete(meta)
                    try? context.save()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    /// 4/4/9 估算：蛋白 4、碳水 4、脂肪 9 kcal/g（纤维已计入碳水，不重复计）
    private var autoKcal: Double {
        meta.protein * 4 + meta.carbs * 4 + meta.fat * 9
    }

    private func nutrientField(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            DecimalField(value: value)
            Text(unit)
                .foregroundStyle(.secondary)
                .font(AIATheme.Font.micro)
        }
    }

    // >>> CHANGE-[2026-09-24]-[营养输入支持小数] 开始
    // 原因: TextField(value:format:.number) 逐键解析，输入 "12." 这类中间态会解析失败被回退，导致打不出小数点。
    //       改为文本驱动输入，宽松解析（兼容全角句号/逗号），失焦后再规整显示。
    // 回退: DecimalField 换回 TextField(value:format: .number) 即可。
    private struct DecimalField: View {
        @Binding var value: Double
        @State private var text: String = ""
        @FocusState private var focused: Bool

        var body: some View {
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
                .focused($focused)
                .onAppear { text = Self.display(value) }
                .onChange(of: text) { _, new in
                    if let v = Self.parse(new) { value = v }
                }
                .onChange(of: focused) { _, isOn in
                    if !isOn { text = Self.display(value) }
                }
                .onChange(of: value) { _, v in
                    // 外部改值（如点「按营养素计算热量」）时同步显示；正在输入时不打断
                    if !focused { text = Self.display(v) }
                }
        }

        private static func parse(_ s: String) -> Double? {
            let normalized = s
                .replacingOccurrences(of: "。", with: ".")
                .replacingOccurrences(of: "，", with: ".")
                .replacingOccurrences(of: ",", with: ".")
            guard !normalized.isEmpty, normalized != "." else { return nil }
            return Double(normalized)
        }

        private static func display(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(v)
        }
    }
    // <<< CHANGE-[2026-09-24]-[营养输入支持小数] 结束
}
// <<< CHANGE-[2026-09-24]-[食物库点击编辑] 结束

// <<< CHANGE-[2026-09-24 16:00:00]-[我的食物库页面] 结束
