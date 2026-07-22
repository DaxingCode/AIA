// HealthDetailView.swift
// 健康指标详情：从「全部记录」点击健康行进入。展示指标信息，支持编辑与删除。
import SwiftUI
import SwiftData

struct HealthDetailView: View {
    let metric: HealthMetric
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Text("❤️")
                            .font(AIATheme.Font.largeTitle)
                            .frame(width: 56, height: 56)
                            .background(AIATheme.healthBG)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.metric).font(AIATheme.Font.body.weight(.medium))
                            Text("\(metric.value)\(metric.unit)")
                                .font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
                        }
                    }
                    .padding(.bottom, 14)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(metric.value)").font(AIATheme.Font.title3.weight(.semibold))
                                .foregroundStyle(AIATheme.health)
                            Text(metric.unit.isEmpty ? "数值" : metric.unit)
                                .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        }
                        Divider().frame(height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("记录于").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                            Text(AppFormat.dateTime.string(from: metric.date))
                                .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        }
                    }
                    .padding(12)
                    .background(AIATheme.healthBG)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    SectionTitle(text: "操作")
                    row(title: "编辑指标", sub: "名称 / 数值 / 单位", action: { showEdit = true })
                    Divider()
                    Button {
                        // 先标记删除意图并 pop 回列表，等 onDisappear（pop 动画完全结束）
                        // 再真正执行 SafeDelete。避免 syncDeleted=true 触发 @Query 重 fetch
                        // 与 NavigationStack pop 动画叠加，导致最后一条删除时卡死。
                        // 只保存 ID，不捕获 metric 对象，防止返回列表后对象被 fault 化后访问属性闪退。
                        pendingDeleteID = metric.persistentModelID
                        dismiss()
                    } label: {
                        HStack {
                            Text("删除该记录").foregroundStyle(AIATheme.warn)
                                .font(AIATheme.Font.footnote.weight(.medium))
                            Spacer()
                            Image(systemName: "trash").foregroundStyle(AIATheme.warn)
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            AIBottomBar()
        }
        .navigationTitle("健康指标")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEdit) { EditHealthView(metric: metric) }
        .onDisappear {
            // 2026-07-20 实测：onDisappear 仍可能在父页面刚刚显示、pop 动画尚未完全收尾时调用。
            // 同步改模型触发 @Query 重 fetch，会与父页面初始渲染竞争，导致返回列表后卡死。
            // 延迟 600ms 等父页面彻底稳定后再真正执行 SafeDelete。
            // 关键：不直接捕获 metric 对象，只保存 persistentModelID；返回列表后若对象被 fault 化，
            // 直接访问属性会触发 fault 异常。通过 context.model(for:) 重新取活对象可避免此问题。
            if let id = pendingDeleteID {
                pendingDeleteID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    SafeDelete.healthByID(id, in: context)
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
                Image(systemName: "chevron.right").font(AIATheme.Font.caption)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
