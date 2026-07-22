// FoodDetailView.swift
// ⑪ 食物详情：按《UI完整页面流.html》屏幕 11 重做。
import SwiftUI
import SwiftData

struct FoodDetailView: View {
    let entry: FoodEntry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var toast: String?
    @State private var showEdit = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    private var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: entry.date)
    }
    private var portionLabel: String { entry.portion.isEmpty ? "1 份" : entry.portion }

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

                // 热量卡
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(entry.calories))").font(AIATheme.Font.title3.weight(.semibold)).foregroundStyle(AIATheme.ok)
                        Text("热量 kcal").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                    }
                    Divider().frame(height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("分量 \(portionLabel)").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        Text("识别置信度 —").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                    }
                }
                .padding(12).background(AIATheme.dietBG).clipShape(RoundedRectangle(cornerRadius: 14))

                SectionTitle(text: "营养明细")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    MacroCard(title: "蛋白质", value: "\(Int(entry.protein))g", progress: entry.protein / 75, color: AIATheme.blue)
                    MacroCard(title: "碳水", value: "\(Int(entry.carbs))g", progress: entry.carbs / 220, color: AIATheme.amber)
                    MacroCard(title: "脂肪", value: "\(Int(entry.fat))g", progress: entry.fat / 55, color: AIATheme.green)
                    MacroCard(title: "膳食纤维", value: "—", progress: 0, color: AIATheme.health)
                }

                if entry.imageName != nil {
                    SectionTitle(text: "识别原图")
                    AttachmentSection(imageName: entry.imageName)
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
            .padding()
        }
        AIBottomBar()
    }
    .background(Color(.secondarySystemBackground))
    .navigationTitle("食物详情")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(toast ?? "") }
        .sheet(isPresented: $showEdit) { EditFoodView(entry: entry) }
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
