import SwiftUI

/// 静息心率录入 sheet：整数 bpm，±1 步进。
/// 支持指定 date，可录入/覆盖任意一天（手动模式方案 A；自动模式亦可覆盖写 manual 行）。
struct RestingHeartRateInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bpm: Int
    let initial: Int
    let date: Date
    let onSave: (Int) -> Void

    init(initial: Int, date: Date = Date(), onSave: @escaping (Int) -> Void) {
        _bpm = State(initialValue: initial > 0 ? initial : 60)
        self.initial = initial
        self.date = date
        self.onSave = onSave
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("录入静息心率")
                    .font(AIATheme.Font.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(dateLabel)
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.sub)
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
