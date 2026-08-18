// FoodDetailView.swift
// ⑪ 食物详情：按《UI完整页面流.html》屏幕 11 重做。
import SwiftUI
import SwiftData

struct FoodDetailView: View {
    let entry: FoodEntry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 按 entry.syncId 取该饮食记录的来源标记（1:1）
    @Query private var sources: [FoodSource]
    /// 识别引擎来源标记（1:1 关联 FoodEntry.syncId）
    @Query private var recogSources: [RecogSource]

    init(entry: FoodEntry) {
        self.entry = entry
        let sid = entry.syncId
        _sources = Query(filter: #Predicate<FoodSource> { $0.foodSyncId == sid })
        _recogSources = Query(filter: #Predicate<RecogSource> { $0.syncId == sid })
    }

    /// 识别引擎来源中文标签（免费版AI识别 / Pro版AI…），无标记返回 nil
    private var recogSourceLabel: String? {
        recogSources.first.flatMap { RecogSource.displayLabel(for: $0.recogSourceRaw) }
    }

    @State private var toast: String?
    @State private var showEdit = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    private var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: entry.date)
    }
    private var portionLabel: String { entry.portion.isEmpty ? "1 份" : entry.portion }

    /// 来源标签：优先取 FoodSource 标记；无标记（老记录）兜底为「图片识别 / 好记AI帮记」
    private var sourceLabel: String {
        if let o = sources.first?.origin, let label = FoodSource.displayLabel(for: o) { return label }
        return entry.imageName != nil ? NSLocalizedString("food.recognized", comment: "")
                                      : NSLocalizedString("food.by_chat", comment: "")
    }
    private var sourceIcon: String {
        if let o = sources.first?.origin { return FoodSource.icon(for: o) }
        return entry.imageName != nil ? "photo" : "message"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                // 头部：图标 + 名称
                HStack(spacing: 12) {
                    Text("🍜")
                        .font(AIATheme.Font.largeTitle)
                        .frame(width: 56, height: 56)
                        .background(AIATheme.dietBG)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(AIATheme.Font.body.weight(.medium))
                        Text("识别 · \(entry.meal) · 识别于 \(timeLabel)")
                            .font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
                    }
                }
                .padding(.bottom, 14)

                // 热量卡：左热量 + 右份量/餐次·时间（去掉无意义的「识别置信度 —」占位）
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(entry.calories))")
                            .font(AIATheme.Font.title3.weight(.semibold))
                            .foregroundStyle(AIATheme.ok)
                        Text("热量 kcal")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.sub)
                    }
                    Divider().frame(height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("份量 \(portionLabel)")
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("\(entry.meal) · \(timeLabel)")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.sub)
                    }
                    Spacer()
                }
                .padding(12).background(AIATheme.dietBG).clipShape(RoundedRectangle(cornerRadius: 14))

                SectionTitle(text: "营养明细")
                VStack(spacing: 8) {
                    macroRow("碳水", entry.carbs, entry.baseCarbs ?? entry.carbs, "g", AIATheme.amber)
                    macroRow("蛋白质", entry.protein, entry.baseProtein ?? entry.protein, "g", AIATheme.blue)
                    macroRow("脂肪", entry.fat, entry.baseFat ?? entry.fat, "g", AIATheme.green)
                    macroRow("膳食纤维", entry.fiber, entry.baseFiber ?? entry.fiber, "g", AIATheme.purple)
                    macroRow("糖", entry.sugar, entry.baseSugar ?? entry.sugar, "g", AIATheme.warn)
                    macroRow("钠", entry.sodium, entry.baseSodium ?? entry.sodium, "mg", AIATheme.warning)
                }

                SectionTitle(text: "来源")
                HStack(spacing: 8) {
                    Image(systemName: sourceIcon).foregroundStyle(AIATheme.sub)
                    Text(sourceLabel).font(AIATheme.Font.footnote).foregroundStyle(.primary)
                    if let recogSourceLabel {
                        Text(recogSourceLabel)
                            .font(AIATheme.Font.micro.weight(.medium))
                            .foregroundStyle(AIATheme.sub)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AIATheme.surfaceSecondary)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(12)
                .background(AIATheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))

                if entry.imageName != nil {
                    SectionTitle(text: "识别原图")
                    AttachmentSection(imageName: entry.imageName, title: nil)
                }

                SectionTitle(text: "操作")
                row(title: "编辑条目", sub: "名称 / 餐次 / 营养", action: { showEdit = true })
                Divider()
                Button {
                    // 先标记删除意图并 pop 回列表，等 onDisappear（pop 动画完全结束）
                    // 再真正执行 SafeDelete。避免 syncDeleted=true 触发 @Query 重 fetch
                    // 与 NavigationStack pop 动画叠加，导致最后一条删除时卡死。
                    // 只保存 ID，不捕获 entry 对象，防止返回列表后对象被 fault 化后访问属性闪退。
                    pendingDeleteID = entry.persistentModelID
                    dismiss()
                } label: {
                    HStack {
                        Text("删除该条目").foregroundStyle(AIATheme.warn).font(AIATheme.Font.footnote.weight(.medium))
                        Spacer()
                        Image(systemName: "xmark").foregroundStyle(AIATheme.warn)
                    }
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        AIBottomBar(entrySource: "food")
    }
    .background(Color(.secondarySystemBackground))
    .navigationTitle("食物详情")
        .navigationBarTitleDisplayMode(.inline)
        .centeredAlert(isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } }),
                       message: toast ?? "")
        // >>> CHANGE-[2026-08-17 17:25:00]-[编辑食物统一EditFoodSheet] 开始
        // 原因: 统一走 EditFoodSheet wrapper，避免此入口编辑页无导航栏（看不到取消/保存按钮）。
        // 回退: 改回 EditFoodView(entry: entry)。
        .sheet(isPresented: $showEdit) { EditFoodSheet(entryID: entry.persistentModelID) }
        // <<< CHANGE-[2026-08-17 17:25:00]-[编辑食物统一EditFoodSheet] 结束
        .onDisappear {
            // 2026-07-20 实测：onDisappear 仍可能在父页面刚刚显示、pop 动画尚未完全收尾时调用。
            // 同步改模型触发 @Query 重 fetch，会与父页面初始渲染竞争，导致返回列表后卡死。
            // 延迟 600ms 等父页面彻底稳定后再真正执行 SafeDelete。
            // 关键：不直接捕获 entry 对象，只保存 persistentModelID；返回列表后若对象被 fault 化，
            // 直接访问属性会触发 fault 异常。通过 context.model(for:) 重新取活对象可避免此问题。
            if let id = pendingDeleteID {
                pendingDeleteID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    SafeDelete.foodByID(id, in: context)
                }
            }
        }
    }

    // 单条营养明细行：色点 + 名称 + 当前总量 + (/100g 基准)。与 ResultConfirmView.macroRow 同款，
    // 整端视觉统一（聊天确认卡片 / 列表行 / 结果确认页 / 详情页都是这一行式样）。
    private func macroRow(_ name: String, _ total: Double, _ per100: Double, _ unit: String, _ color: Color) -> some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name)
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(AIATheme.sub)
            }
            Spacer()
            Text("\(formatValue(total)) \(unit)")
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(.primary)
            Text("(\(formatValue(per100)) / 100\(unit == "mg" ? "g" : "g"))")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rSM))
    }

    /// 数值格式化：整数显整数，否则保留 1 位小数，0 显示 0。
    private func formatValue(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(v))"
        }
        return String(format: "%.1f", v)
    }

    private func row(title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AIATheme.Font.footnote.weight(.medium))
                    Text(sub).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                }
                Spacer()
                Image(systemName: "chevron.right").font(AIATheme.Font.caption).foregroundStyle(AIATheme.muted)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
