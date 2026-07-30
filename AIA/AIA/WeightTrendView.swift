// WeightTrendView.swift
// ⑫ 体重趋势：按《UI完整页面流.html》屏幕 12 重做。数据来自 HealthMetric 中「体重」记录。
import SwiftUI
import SwiftData
import Charts

private struct WPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}
struct WeightTrendView: View {
    @Query(filter: #Predicate<HealthMetric> { !$0.syncDeleted }, sort: \HealthMetric.date, order: .reverse) private var healths: [HealthMetric]
    @State private var toast: String?
    @State private var chartAppear = false   // 曲线淡入动画开关
    @AppStorage("aia.weightGoalKg") private var weightGoalKg: Double = 65
    @Environment(\.modelContext) private var context
    @State private var showWeightGoalEditor = false
    @State private var editedWeightGoal: Double = 65

    private var weights: [(date: Date, value: Double)] {
        healths.compactMap { m -> (Date, Double)? in
            guard m.metric.contains("体重") || m.metric.lowercased().contains("weight") else { return nil }
            guard let v = Double(m.value) else { return nil }
            return (m.date, v)
        }.sorted { $0.date < $1.date }
    }
    /// 最近 7 条体重记录（按时间升序，便于折线从左到右）。不按日历日期分组/过滤，仅取末尾 7 条。
    private var recent7: [(date: Date, value: Double)] { Array(weights.suffix(7)) }
    private var current: Double? { recent7.last?.value }
    private var maxV: Double? { recent7.max(by: { $0.value < $1.value })?.value }
    private var minV: Double? { recent7.min(by: { $0.value < $1.value })?.value }
    private var avg: Double? { recent7.isEmpty ? nil : recent7.reduce(0) { $0 + $1.value } / Double(recent7.count) }
    private var delta: Double? {
        guard let cur = current, let first = recent7.first?.value else { return nil }
        return cur - first
    }
    /// x 轴用序号 1..7（不挂钩日期），y 轴为 kg。
    private var points: [WPoint] {
        recent7.enumerated().map { i, w in
            WPoint(label: "\(i + 1)", value: w.value)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let c = current {
                        Text(String(format: "当前 %.1f kg", c)).font(AIATheme.Font.callout.weight(.semibold))
                    } else {
                        Text("暂无体重").font(AIATheme.Font.callout.weight(.semibold))
                    }
                    Spacer()
                    if let d = delta {
                        let down = d < 0
                        Text(String(format: "%@ %.1f / 近7次", down ? "↓" : "↑", abs(d)))
                            .font(AIATheme.Font.micro)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(AIATheme.ok.opacity(0.14))
                            .foregroundStyle(AIATheme.ok)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 10) {
                    StatCard(value: String(format: "%.1f", maxV ?? 0), caption: "最高")
                    StatCard(value: String(format: "%.1f", minV ?? 0), caption: "最低")
                    StatCard(value: String(format: "%.1f", avg ?? 0), caption: "均值")
                }

                SectionTitle(text: "最近 7 次体重")
                if points.isEmpty {
                    Text("暂无体重记录，去首页截一张体重截屏").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        .frame(height: 80)
                } else {
                    Chart(points) { p in
                        LineMark(x: .value("日", p.label), y: .value("kg", p.value))
                            .foregroundStyle(AIATheme.health).interpolationMethod(.monotone)
                        PointMark(x: .value("日", p.label), y: .value("kg", p.value))
                            .foregroundStyle(AIATheme.health)
                    }
                    .frame(height: 120)
                    .chartYScale(domain: safeYDomain(recent7.map(\.value)))
                    .chartYAxis(.hidden).chartXAxis(.hidden)
                    // 曲线进入：透明度 + 轻微缩放淡入。iOS 26 下 Swift Charts 路径描边动画不可靠，
                    // 用淡入替代真·描边生长，稳定且观感一致；「减弱动态效果」下直接显示。
                    .opacity(chartAppear ? 1 : 0)
                    .scaleEffect(chartAppear ? 1 : 0.96, anchor: .leading)
                    .onAppear {
                        if AIATheme.motionReduce { chartAppear = true }
                        else { withAnimation(.easeOut(duration: 0.6)) { chartAppear = true } }
                    }
                }

                SectionTitle(text: "记录方式")
                CardRow(icon: "⌚", iconBG: AIATheme.ok.opacity(0.16), title: "体脂秤自动同步", subtitle: "每日 07:30", value: "已连接")
                Button { toast = "手动录入体重" } label: {
                    CardRow(icon: "✏️", iconBG: AIATheme.surfaceSecondary, title: "手动录入体重", subtitle: "无设备时保持连续", value: "›")
                }.buttonStyle(.plain)
                Button {
                    editedWeightGoal = weightGoalKg
                    showWeightGoalEditor = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("设置体重目标").font(AIATheme.Font.footnote.weight(.medium))
                            Text("当前 \(String(format: "%.1f", weightGoalKg)) kg").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(AIATheme.muted)
                    }
                    .padding(11).background(AIATheme.surface).clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }.buttonStyle(.plain)
            }
            .padding()
        }
        AIBottomBar(entrySource: "health")
    }
    .background(Color(.secondarySystemBackground))
    .navigationTitle("体重趋势")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(toast ?? "") }
        .sheet(isPresented: $showWeightGoalEditor) {
            VStack(spacing: 0) {
                HStack {
                    Text("设置体重目标")
                        .font(AIATheme.Font.headline.weight(.semibold))
                    Spacer()
                    Button("完成") { showWeightGoalEditor = false }
                        .font(AIATheme.Font.body.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                }
                .padding()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("目标体重")
                            .font(AIATheme.Font.footnote)
                            .foregroundStyle(AIATheme.sub)
                        Spacer()
                    }
                    HStack {
                        TextField("体重目标", value: $editedWeightGoal, format: .number)
                            .keyboardType(.decimalPad)
                            .font(AIATheme.Font.hero.weight(.semibold))
                        Text("kg")
                            .font(AIATheme.Font.subhead)
                            .foregroundStyle(AIATheme.muted)
                        Spacer()
                    }
                }
                .padding()
                .background(AIATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                .padding(.horizontal)

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        if editedWeightGoal > 0 { weightGoalKg = editedWeightGoal }
                        showWeightGoalEditor = false
                        // 记录修改时间并触发增量同步：随后经 aia_records(type:"setting") 上云，绑定后小程序可见。
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "userSettingUpdatedAt")
                        CloudSyncManager.shared.syncAfterLocalChange(context: context)
                    } label: {
                        Text("保存")
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(AIATheme.blue)
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
        }
    }
}
