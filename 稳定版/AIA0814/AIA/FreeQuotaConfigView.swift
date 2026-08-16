// FreeQuotaConfigView.swift
// 开发者中心 → 免费额度配置：开关、每月次数 N、单日上限、全局月度熔断、各功能权重（v1 生效）。
import SwiftUI

struct FreeQuotaConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var global = GlobalConfigStore.shared

    @State private var enabled: Bool
    @State private var perMonth: Int
    @State private var dailyCap: Int
    @State private var globalMonthly: Int
    @State private var weights: [String: Int]
    @State private var saving = false
    @State private var msg: String?

    init() {
        let g = GlobalConfigStore.shared
        _enabled = State(initialValue: g.freeQuotaEnabled)
        _perMonth = State(initialValue: g.freeQuotaPerMonth)
        _dailyCap = State(initialValue: g.freeQuotaDailyCap)
        _globalMonthly = State(initialValue: g.freeQuotaGlobalMonthly)
        _weights = State(initialValue: g.freeQuotaWeights)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("返回").foregroundStyle(AIATheme.blue).contentShape(Rectangle()).onTapGesture { dismiss() }
                Spacer()
                Text("免费额度配置").font(AIATheme.Font.headline.weight(.semibold))
                Spacer()
                Text("保存").foregroundStyle(AIATheme.blue).font(AIATheme.Font.body.weight(.semibold)).contentShape(Rectangle()).onTapGesture {
                    save()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(AIATheme.surface)

            if let msg {
                Text(msg).font(AIATheme.Font.footnote).foregroundStyle(AIATheme.muted)
                    .padding(.horizontal, 16).padding(.top, 8)
            }

            Form {
                Section {
                    Toggle("开启免费额度", isOn: $enabled)
                    numberRow("每月免费次数 N", value: $perMonth, range: 0...100000)
                    numberRow("单日上限", value: $dailyCap, range: 0...100000)
                } header: {
                    Text("免费额度（未付费用户每月可免费用 N 次云端功能）")
                } footer: {
                    Text("N 的具体数值请先按使用成本评估后再填（视觉识别/查食物成本远高于文本解析）。置 0 表示不限制——正式开放前务必填写合理值。")
                        .font(AIATheme.Font.footnote).foregroundStyle(AIATheme.muted)
                }

                Section("全局月度总额度（成本熔断）") {
                    numberRow("全平台每月上限", value: $globalMonthly, range: 0...100000000)
                    Text("触顶后全平台关闭免费额度（保护成本）。0 = 不熔断。建议按预算填一个安全上限。")
                        .font(AIATheme.Font.footnote).foregroundStyle(AIATheme.muted)
                }

                Section("各功能消耗权重（v1 生效）") {
                    ForEach(PaidFeature.allCases, id: \.rawValue) { f in
                        numberRow(featureName(f), value: Binding(
                            get: { weights[f.rawValue] ?? 1 },
                            set: { weights[f.rawValue] = $0 }
                        ), range: 1...100)
                    }
                    Text("权重越高，消耗越快。例如视觉识别设 5、文本解析设 1，则一次识图抵 5 次文本解析。默认全 1。")
                        .font(AIATheme.Font.footnote).foregroundStyle(AIATheme.muted)
                }
            }
        }
        .navigationTitle("免费额度").navigationBarTitleDisplayMode(.inline)
    }

    private func numberRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(AIATheme.Font.body.monospacedDigit())
                .frame(width: 90)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AIATheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: value.wrappedValue) { _, newValue in
                    if newValue < range.lowerBound { value.wrappedValue = range.lowerBound }
                    else if newValue > range.upperBound { value.wrappedValue = range.upperBound }
                }
        }
    }

    private func featureName(_ f: PaidFeature) -> String {
        switch f {
        case .cloudVision: return "图片视觉识别"
        case .cloudTextParse: return "文本意图解析"
        case .cloudChat: return "云端对话"
        case .cloudFoodQuery: return "食物营养查询"
        case .cloudAgent: return "智能问答 Agent"
        case .cloudSyncPush: return "云同步上传（不覆盖）"
        }
    }

    private func save() {
        saving = true; msg = "保存中…"
        Task {
            let ok = await global.saveFreeQuota(freeQuotaEnabled: enabled, freeQuotaPerMonth: perMonth,
                                                freeQuotaWeights: weights, freeQuotaDailyCap: dailyCap,
                                                freeQuotaGlobalMonthly: globalMonthly)
            await MainActor.run {
                saving = false
                msg = ok ? "已保存 ✓" : "保存失败 ✗（看 Xcode Console → filter GlobalConfig）"
            }
        }
    }
}
