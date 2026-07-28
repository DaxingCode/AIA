// HealthGoalsView.swift
// 健康目标设置：身高 / 体重 / 步数目标 / 睡眠目标 / 运动时长目标，本地 @AppStorage 持久化。
// 采用输入框形式，点击整行任意位置即可聚焦录入数值（数字键盘）。
// 录入过程中不钳制，仅在失焦 / 回车时校验并钳制到合理范围（避免中间值被误钳到上下限）。
// 与饮食模块的 aia.calorieGoalOverride 同策略（纯本地，不云同步），无 HealthKit entitlement 也能用。
import SwiftUI
import UIKit
import SwiftData

struct HealthGoalsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("aia.heightCm") private var heightCm: Double = 0
    @AppStorage("aia.weightKg") private var weightKg: Double = 0
    @AppStorage("aia.age") private var age: Int = 30
    @AppStorage("aia.bioSex") private var bioSex: Int = 1   // 1 = 男, 0 = 女
    @AppStorage("aia.activityLevel") private var activityLevel: Int = 1   // 0~4
    @AppStorage("aia.targetHeightCm") private var targetHeightCm: Double = 0
    @AppStorage("aia.weightGoalKg") private var weightGoalKg: Double = 65   // 目标体重（与 WeightTrendView / 云同步共用）
    @AppStorage("aia.stepGoal") private var stepGoal: Int = 10000
    @AppStorage("aia.sleepGoalHours") private var sleepGoalHours: Double = 8
    @AppStorage("aia.exerciseGoalMin") private var exerciseGoalMin: Double = 30

    private var bmi: Double? {
        guard heightCm > 0, weightKg > 0 else { return nil }
        let m = heightCm / 100
        return weightKg / (m * m)
    }
    private var bmiCategory: String {
        guard let b = bmi else { return "—" }
        switch b {
        case ..<18.5: return "偏瘦"
        case 18.5..<24: return "正常"
        case 24..<28: return "偏胖"
        default: return "肥胖"
        }
    }
    /// 基础代谢率 BMR（Mifflin-St Jeor），缺身高/体重时无法计算返回 nil。
    private var bmr: Double? {
        mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: age, isMale: bioSex == 1)
    }
    /// 每日总消耗 TDEE = BMR × 活动系数。
    private var tdee: Double? {
        guard let b = bmr else { return nil }
        return b * activityMultiplier(activityLevel)
    }

    /// 身高/体重失焦时，在身体数据（HealthMetric）中新增一条记录，与「身体数据」页保存行为一致。
    private func recordBodyData() {
        guard heightCm > 0, weightKg > 0 else { return }
        let now = Date()
        context.insert(HealthMetric(metric: "身高", value: String(format: "%.1f", heightCm), unit: "cm", date: now))
        context.insert(HealthMetric(metric: "体重", value: String(format: "%.1f", weightKg), unit: "kg", date: now))
        let m = heightCm / 100
        let bmi = weightKg / (m * m)
        context.insert(HealthMetric(metric: "BMI", value: String(format: "%.1f", bmi), unit: "", date: now))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: "身体档案")
                    DoubleGoalRow(title: "当前身高", unit: "cm", sub: "用于计算 BMI / 基础代谢",
                                  range: 100...230, value: $heightCm,
                                  onCommit: recordBodyData)
                    DoubleGoalRow(title: "当前体重", unit: "kg", sub: "当前体重",
                                  range: 30...250, value: $weightKg,
                                  onCommit: recordBodyData)
                    IntGoalRow(title: "年龄", unit: "岁", sub: "用于计算基础代谢",
                               range: 10...120, value: $age)
                    SegmentRow(title: "性别", sub: "用于计算基础代谢",
                               options: [(1, "男"), (0, "女")], selection: $bioSex)
                    SegmentRow(title: "活动水平", sub: "每周运动频率",
                               options: activityLevelOptions, selection: $activityLevel)
                    if let b = bmi {
                        HStack {
                            Text("BMI").font(AIATheme.Font.footnote.weight(.medium))
                            Spacer()
                            Text(String(format: "%.1f · %@", b, bmiCategory))
                                .font(AIATheme.Font.footnote.weight(.semibold))
                                .foregroundStyle(AIATheme.health)
                        }
                        .padding(.horizontal, 12)
                    }

                    if let bmr, let tdee {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("基础代谢 BMR").font(AIATheme.Font.footnote.weight(.medium))
                                Spacer()
                                Text("\(Int(bmr)) kcal").font(AIATheme.Font.footnote.weight(.semibold)).foregroundStyle(AIATheme.health)
                            }
                            HStack {
                                Text("每日总消耗 TDEE").font(AIATheme.Font.footnote.weight(.medium))
                                Spacer()
                                Text("\(Int(tdee)) kcal").font(AIATheme.Font.footnote.weight(.semibold)).foregroundStyle(AIATheme.health)
                            }
                            Text("按 Mifflin-St Jeor 公式：BMR = 10×体重 + 6.25×身高 − 5×年龄 +（男 5 / 女 −161）；TDEE = BMR × 活动系数。能量圆环目标即 TDEE。")
                                .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        }
                        .padding(12)
                        .background(AIATheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    SectionTitle(text: "目标身材")
                    DoubleGoalRow(title: "目标身高", unit: "cm", sub: "理想身高",
                                  range: 100...230, value: $targetHeightCm)
                    DoubleGoalRow(title: "目标体重", unit: "kg", sub: "理想体重（与体重趋势页共用）",
                                  range: 30...250, value: $weightGoalKg)
                    if weightKg > 0, weightGoalKg > 0 {
                        let diff = weightGoalKg - weightKg
                        HStack {
                            Text("距目标体重").font(AIATheme.Font.footnote.weight(.medium))
                            Spacer()
                            Text(diff == 0 ? "已达成" : (diff > 0 ? "还需增 \(String(format: "%.1f", diff)) kg" : "还需减 \(String(format: "%.1f", -diff)) kg"))
                                .font(AIATheme.Font.footnote.weight(.semibold))
                                .foregroundStyle(diff == 0 ? AIATheme.health : .primary)
                        }
                        .padding(.horizontal, 12)
                    }

                    SectionTitle(text: "每日目标")
                    IntGoalRow(title: "步数目标", unit: "步", sub: "每日步行目标",
                               range: 2000...30000, value: $stepGoal)
                    DoubleGoalRow(title: "睡眠目标", unit: "小时", sub: "每日睡眠时长",
                                  range: 4...12, value: $sleepGoalHours)
                    DoubleGoalRow(title: "运动时长目标", unit: "分钟", sub: "每日运动时长",
                                  range: 5...240, value: $exerciseGoalMin)

                    Text("目标仅保存在本机，用于个性化健康圆环与达标提示，不会上传云端。")
                        .font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
                        .padding(.horizontal, 4)
                }
                .padding()
            }
            .onTapGesture {
                // 点击 ScrollView 内空白区域（非输入框行）收起键盘
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            AIBottomBar(entrySource: "healthGoals")
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle("健康目标")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - BMR / 活动系数（Mifflin-St Jeor，供健康目标页与能量圆环共用）

/// 活动水平选项（value 0~4），与 activityMultiplier 一一对应。精简以保证选择器单行显示。
let activityLevelOptions: [(Int, String)] = [
    (0, "久坐"),
    (1, "轻度 1-3 天/周"),
    (2, "中度 3-5 天/周"),
    (3, "高强度 6-7 天/周"),
    (4, "极高 每天训练")
]

/// 活动系数：久坐 1.2 → 极高 1.9
func activityMultiplier(_ level: Int) -> Double {
    switch level {
    case 0: return 1.2
    case 1: return 1.375
    case 2: return 1.55
    case 3: return 1.725
    default: return 1.9
    }
}

/// Mifflin-St Jeor 基础代谢率（kcal/天）。缺身高/体重返回 nil。
func mifflinBMR(weightKg: Double, heightCm: Double, age: Int, isMale: Bool) -> Double? {
    guard weightKg > 0, heightCm > 0, (10...120).contains(age) else { return nil }
    let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(age)
    return isMale ? base + 5 : base - 161
}

// MARK: - 选项行：菜单式 Picker（性别 / 活动水平）

private struct SegmentRow: View {
    let title: String
    let sub: String
    let options: [(Int, String)]
    @Binding var selection: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AIATheme.Font.footnote.weight(.medium))
                Text(sub).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
            }
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { value, label in
                    Text(label).tag(value).font(AIATheme.Font.footnote).lineLimit(1)
                }
            }
            .pickerStyle(.menu)
            .font(AIATheme.Font.footnote)
            .controlSize(.small)
            .tint(AIATheme.health)
        }
        .padding(12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AIATheme.hairline, lineWidth: 0.7).allowsHitTesting(false))
        .contentShape(Rectangle())
    }
}

// MARK: - 双击行：本地文本编辑，失焦/回车时才钳制

private struct DoubleGoalRow: View {
    let title: String
    let unit: String
    let sub: String
    let range: ClosedRange<Double>
    @Binding var value: Double
    var onCommit: (() -> Void)? = nil   // 失焦/回车时回调（用于创建 HealthMetric 历史）

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var display: String { value == 0 ? "" : String(format: "%.0f", value) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AIATheme.Font.footnote.weight(.medium))
                Text(sub).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
            }
            Spacer()
            HStack(spacing: 4) {
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 56, maxWidth: 100)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onAppear { text = display }
                    .onChange(of: text) { _, newText in
                        guard isFocused,
                              let parsed = Double(newText.replacingOccurrences(of: ",", with: ".")),
                              parsed >= 0 else { return }
                        value = parsed                 // 实时自动保存到 @AppStorage
                    }
                    .onChange(of: isFocused) { old, new in
                        if new { text = display }      // 进入编辑：显示当前值便于修改
                        else { commit() }              // 离开编辑：校验并钳制
                    }
                    .onSubmit { commit() }
                Text(unit).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
            }
        }
        .padding(12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AIATheme.hairline, lineWidth: 0.7).allowsHitTesting(false))
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private func commit() {
        let parsed = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        value = clamped
        // 钳制后回填，空输入则回显为占位符
        text = clamped == 0 ? "" : String(format: "%.0f", clamped)
        onCommit?()
    }
}

private struct IntGoalRow: View {
    let title: String
    let unit: String
    let sub: String
    let range: ClosedRange<Int>
    @Binding var value: Int
    var onCommit: (() -> Void)? = nil   // 失焦/回车时回调

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var display: String { value == 0 ? "" : "\(value)" }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AIATheme.Font.footnote.weight(.medium))
                Text(sub).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
            }
            Spacer()
            HStack(spacing: 4) {
                TextField("0", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 56, maxWidth: 100)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onAppear { text = display }
                    .onChange(of: text) { _, newText in
                        guard isFocused,
                              let parsed = Int(newText),
                              parsed >= 0 else { return }
                        value = parsed                 // 实时自动保存到 @AppStorage
                    }
                    .onChange(of: isFocused) { old, new in
                        if new { text = display }
                        else { commit() }
                    }
                    .onSubmit { commit() }
                Text(unit).font(AIATheme.Font.micro).foregroundStyle(AIATheme.sub)
            }
        }
        .padding(12)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AIATheme.hairline, lineWidth: 0.7).allowsHitTesting(false))
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private func commit() {
        let parsed = Int(text) ?? 0
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        value = clamped
        text = clamped == 0 ? "" : "\(clamped)"
        onCommit?()
    }
}

