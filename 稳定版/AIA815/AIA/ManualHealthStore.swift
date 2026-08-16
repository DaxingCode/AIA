// ManualHealthStore.swift
// 兼容门面：对外 API 保持不变（RecordsViews / ContentView / ChatView / WidgetSnapshot /
// HealthManager / CloudSyncManager / SleepSession 等仍调用这些方法），内部实现已切换到
// DailyHealthStore（SwiftData 正式库）。
//
// 旧 UserDefaults 方案在 2026-08-15 正式废弃：每日健康指标改为存进 App Group 共享 store
// 的 DailyHealthMetric 表，Widget 等独立进程可直接读同一份 SQLite，不再依赖 App 进程
// buildSnapshot 中转，也不受 UserDefaults 跨进程读取限制。
import Foundation
import WidgetKit

final class ManualHealthStore {
    nonisolated static let shared = ManualHealthStore()

    private let store = DailyHealthStore.shared

    /// 录入变更时触发（由 AppDelegate 注入，内部走 CloudSyncManager 防抖同步）。
    var syncTrigger: (() -> Void)? {
        get { store.syncTrigger }
        set { store.syncTrigger = newValue }
    }

    private init() {}

    /// 旧 UserDefaults 数据一次性迁移（幂等，仅首次执行）。
    func migrateFromUserDefaultsIfNeeded() {
        store.migrateFromUserDefaultsIfNeeded()
    }

    // MARK: - 导出 / 导入（云同步用）
    typealias ManualHealthSnapshot = DailyHealthStore.ManualHealthSnapshot

    func syncId(forDayTs dayTs: Int) -> UUID {
        // 仅兼容旧 CloudSyncManager 调用；新逻辑在 DailyHealthStore 内按 source 派生。
        let s = String(format: "A1B2C3D4-E5F6-4789-8ABC-%012X", UInt(dayTs))
        return UUID(uuidString: s) ?? UUID()
    }

    func exportModified(since: Date) -> [ManualHealthSnapshot] {
        store.exportModified(since: since)
    }

    func importSnapshot(_ s: ManualHealthSnapshot) {
        store.importSnapshot(s)
    }

    func clearDay(_ dayTs: Int) {
        store.clearDay(dayTs)
    }

    // MARK: - HealthKit 自动槽位（.hk 后缀，物理隔离手动数据）

    func setHealthKitValue(_ value: Double, metric: String, for date: Date) {
        store.setHealthKitValue(value, metric: metric, for: date)
    }

    func healthKitValue(_ metric: String, for date: Date) -> Double {
        store.healthKitValue(metric, for: date)
    }

    func clearAll() {
        store.clearAll()
    }

    // MARK: - 步数
    func steps(for date: Date) -> Int { store.steps(for: date) }
    func setSteps(_ value: Int, for date: Date) { store.setSteps(value, for: date) }

    // MARK: - 睡眠（小时）
    func sleepHours(for date: Date) -> Double { store.sleepHours(for: date) }
    func setSleepHours(_ value: Double, for date: Date) { store.setSleepHours(value, for: date) }

    // MARK: - 运动时长（分钟）
    func exerciseMinutes(for date: Date) -> Int { store.exerciseMinutes(for: date) }
    func setExerciseMinutes(_ value: Int, for date: Date) { store.setExerciseMinutes(value, for: date) }

    // MARK: - 活动热量（kcal）
    func activeCalories(for date: Date) -> Int { store.activeCalories(for: date) }
    func setActiveCalories(_ value: Int, for date: Date) { store.setActiveCalories(value, for: date) }

    // MARK: - 静息心率（bpm）
    func restingHeartRate(for date: Date) -> Int { store.restingHeartRate(for: date) }
    func setRestingHeartRate(_ bpm: Int, for date: Date) { store.setRestingHeartRate(bpm, for: date) }

    // MARK: - 自增（点击圆环 +N）
    func addSteps(_ delta: Int, for date: Date) { store.addSteps(delta, for: date) }
    func addSleepHours(_ delta: Double, for date: Date) { store.addSleepHours(delta, for: date) }
    func addExerciseMinutes(_ delta: Int, for date: Date) { store.addExerciseMinutes(delta, for: date) }
    func addActiveCalories(_ delta: Int, for date: Date) { store.addActiveCalories(delta, for: date) }
}
