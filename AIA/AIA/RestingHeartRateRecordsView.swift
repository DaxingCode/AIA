import SwiftUI

// >>> CHANGE-[2026-08-19 13:37:50]-静息心率每天记录页 开始
// 原因: 用户需要在健康管理页点静息心率方块跳到"每天一条静息心率"记录页(自动模式也可手动覆盖), 默认展示最近90天
// 回退: 删除本文件 + 撤销 HomeRoute.restingHeartRateRecords + ContentView 注册 + RecordsViews 小方块跳转即可

/// 静息心率每天记录页：倒序列出最近 90 天，每天一条。
/// 展示优先级：先读 manual 行（用户手动录入/覆盖），再读 hk 行（HealthKit 自动均值）。
/// 任意一天均可点击录入，写入 manual 行覆盖（自动模式那天也能改）。
struct RestingHeartRateRecordsView: View {
    @State private var days: [Date] = []
    @State private var showInput = false
    @State private var inputDay: Date = Date()
    @State private var inputInitial: Int = 0
    // >>> CHANGE-[2026-09-19 10:11:35]-[iOS27手动健康数据刷新(首页/心率页/饮食页)] 开始
    /// 手动健康数据（DailyHealthMetric）变更票据：自增即触发本页重算，行内数值重新从 store 读取。
    @State private var dailyHealthTick = 0
    // <<< CHANGE-[2026-09-19 10:11:35]-[iOS27手动健康数据刷新(首页/心率页/饮食页)] 结束

    private let calendar = Calendar.current
    private let daysToShow = 90

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    row(for: day)
                    Divider().padding(.leading, 16)
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(NSLocalizedString("health.restingHR.records.title", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { buildDays() }
        .onReceive(HealthManager.shared.debouncedChange) { _ in
            // HealthKit 自动数据刷新后重绘（只读 @State 里存的值会在 body 重新计算）
        }
        // >>> CHANGE-[2026-09-19 10:11:35]-[iOS27手动健康数据刷新(首页/心率页/饮食页)] 开始
        // 手动录入/覆盖静息心率（本页 sheet 保存、健康页点其他环）后重算本页：
        // iOS 27 起 @Query 按实体刷新，本页无 DailyHealthMetric 订阅，靠写入侧广播兜底。
        .onReceive(NotificationCenter.default.publisher(for: .dailyHealthStoreChanged)) { _ in
            dailyHealthTick &+= 1
        }
        // <<< CHANGE-[2026-09-19 10:11:35]-[iOS27手动健康数据刷新(首页/心率页/饮食页)] 结束
        .sheet(isPresented: $showInput) {
            RestingHeartRateInputSheet(
                initial: inputInitial,
                date: inputDay,
                onSave: { bpm in
                    ManualHealthStore.shared.setRestingHeartRate(bpm, for: inputDay)
                    // 重跑 buildDays 触发 @State 变化 → body 重绘 → value(for:) 重新从 ManualHealthStore 读取最新值
                    buildDays()
                }
            )
        }
    }

    private func buildDays() {
        let today = calendar.startOfDay(for: Date())
        days = (0..<daysToShow).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
    }

    private func value(for day: Date) -> (bpm: Int, isManual: Bool) {
        let manual = ManualHealthStore.shared.restingHeartRate(for: day)
        if manual > 0 { return (Int(manual), true) }
        let hk = ManualHealthStore.shared.healthKitValue("heartRate", for: day)
        if hk > 0 { return (Int(hk), false) }
        return (0, false)
    }

    private func row(for day: Date) -> some View {
        let v = value(for: day)
        return Button {
            inputDay = day
            inputInitial = v.bpm
            showInput = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayLabel(day))
                        .font(AIATheme.Font.body)
                        .foregroundStyle(.primary)
                    if v.bpm > 0 {
                        Text(v.isManual
                             ? NSLocalizedString("health.restingHR.tag.manual", comment: "")
                             : NSLocalizedString("health.restingHR.tag.auto", comment: ""))
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(v.isManual ? AIATheme.health : AIATheme.muted)
                    }
                }
                Spacer(minLength: 0)
                // >>> CHANGE-[2026-08-20 14:00:00]-[深色模式文字色整改] 开始
                // 原因: 数值用 ink(dark 0x2c2c2e) 深色下与底同色看不见; 改 reading(dark 0xd1d1d6) 清晰; "—"占位同步亮化
                // 回退: 改回 AIATheme.ink : AIATheme.muted
                Text(v.bpm > 0 ? "\(v.bpm) bpm" : "—")
                    .font(AIATheme.Font.body.weight(.medium))
                    .foregroundStyle(AIATheme.reading)
                // <<< CHANGE-[2026-08-20 14:00:00]-[深色模式文字色整改] 结束
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let isThisYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        f.dateFormat = isThisYear ? "M月d日 EEE" : "yyyy年M月d日"
        return f.string(from: day)
    }
}

// <<< CHANGE-[2026-08-19 13:37:50]-静息心率每天记录页 结束
