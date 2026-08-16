import SwiftUI

/// 静息心率录入 sheet：整数 bpm，±1 步进（手动记录模式方案 A）。
/// 自动模式由调用方负责写 HealthKit；本 sheet 只负责数值选择，不关心存储落点。
struct RestingHeartRateInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bpm: Int
    let initial: Int
    let onSave: (Int) -> Void

    init(initial: Int, onSave: @escaping (Int) -> Void) {
        _bpm = State(initialValue: initial > 0 ? initial : 60)
        self.initial = initial
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("静息心率")
                    .font(AIATheme.Font.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 24) {
                    Button {
                        if bpm > 30 { bpm -= 1 }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(AIATheme.health)
                    }
                    Text("\(bpm)")
                        .font(AIATheme.Font.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(minWidth: 96)
                    Button {
                        if bpm < 220 { bpm += 1 }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(AIATheme.health)
                    }
                }
                Text("bpm")
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(AIATheme.sub)
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("录入静息心率")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(bpm)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(AIATheme.health)
                }
            }
        }
    }
}
