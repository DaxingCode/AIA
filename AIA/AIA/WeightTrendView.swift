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
private let wFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "M/d"; return f
}()

struct WeightTrendView: View {
    @Query(sort: \HealthMetric.date, order: .reverse) private var healths: [HealthMetric]
    @State private var toast: String?
    @State private var chartAppear = false   // 曲线淡入动画开关

    private var weights: [(date: Date, value: Double)] {
        healths.compactMap { m -> (Date, Double)? in
            guard m.metric.contains("体重") || m.metric.lowercased().contains("weight") else { return nil }
            guard let v = Double(m.value) else { return nil }
            return (m.date, v)
        }.sorted { $0.date < $1.date }
    }
    private var current: Double? { weights.last?.value }
    private var maxV: Double? { weights.max(by: { $0.value < $1.value })?.value }
    private var minV: Double? { weights.min(by: { $0.value < $1.value })?.value }
    private var avg: Double? { weights.isEmpty ? nil : weights.reduce(0) { $0 + $1.value } / Double(weights.count) }
    private var delta30: Double? {
        guard let cur = current, let first = weights.first?.value else { return nil }
        return cur - first
    }
    private var points: [WPoint] {
        weights.map { WPoint(label: wFmt.string(from: $0.date), value: $0.value) }
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
                    if let d = delta30 {
                        let down = d < 0
                        Text(String(format: "%@ %.1f / 30天", down ? "↓" : "↑", abs(d)))
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

                SectionTitle(text: "近 30 天曲线")
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
                Button { toast = "设置体重目标" } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("设置体重目标").font(AIATheme.Font.footnote.weight(.medium))
                            Text("当前 65.0 kg").font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(AIATheme.muted)
                    }
                    .padding(11).background(AIATheme.surface).clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }.buttonStyle(.plain)
            }
            .padding()
        }
        AIBottomBar()
    }
    .navigationTitle("体重趋势")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(toast ?? "") }
    }
}
