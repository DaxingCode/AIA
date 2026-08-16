// ManualHealthStore.swift
// 未接入 HealthKit 时，手动健康指标（步数/睡眠/运动时长/活动热量）按日期存储，
// 每天 0 点自然归零，避免昨天的手动值一直带到今天。
//
// HealthKit 自动模式：HealthKit 拉到的历史值也落在这里的「.hk」后缀槽位（与手动
// 槽位物理隔离），按来源开关二选一展示，同一天手动+自动互不覆盖。HealthKit 值
// 不进云同步（exportModified 只遍历手动 key，天然排除 .hk 槽位）。
//
// 云同步：手动数据不入 HealthMetric 表（以免污染健康记录列表），而是作为独立的
// type="manualHealth" 记录上云。录入时标记 updatedAt 并触发增量同步；重装重登后
// pull 回来的 manualHealth 记录直接回填此处（UserDefaults），即可恢复展示。
import Foundation
import WidgetKit

final class ManualHealthStore {
    nonisolated static let shared = ManualHealthStore()

    private let calendar = Calendar.current
    private let defaults = UserDefaults.standard

    /// 录入变更时触发（由 AppDelegate 注入，内部走 CloudSyncManager 防抖同步）。
    /// 未登录时不触发（跨重装恢复需登录态，与本地表分区策略一致）。
    var syncTrigger: (() -> Void)?

    private init() {
        // 清理旧的全局 key：旧版本把手动值存在单一全局 key 里，跨天不会归零，
        // 导致用户看到「昨天的数据」。升级后按日期存，旧 key 不再使用。
        defaults.removeObject(forKey: "aia.stepsCurrentManual")
        defaults.removeObject(forKey: "aia.sleepHoursCurrentManual")
        defaults.removeObject(forKey: "aia.exerciseMinCurrentManual")
    }

    /// 数据来源：手动录入 or HealthKit 自动获取。
    enum HealthSource: String {
        case manual
        case healthKit
    }

    private func key(_ metric: String, date: Date, source: HealthSource = .manual) -> String {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        // HealthKit 自动槽位加 .hk 后缀，与手动槽位物理隔离，同一天互不覆盖。
        return "aia.manualHealth.\(metric).\(ts)\(source == .manual ? "" : ".hk")"
    }

    /// 每日快照的「最后修改时间」键（用于增量同步筛选）。
    private func metaKey(dayTs: Int) -> String {
        "aia.manualHealth._meta.\(dayTs)"
    }

    private func notifyChanged() {
        syncTrigger?()
        // 手动记健康数据后，补偿刷新桌面 widget（避免回前台那一刻写入的是旧值/空态）。
        WidgetSnapshot.refreshAfterWrite()
    }

    // MARK: - 导出 / 导入（云同步用）
    struct ManualHealthSnapshot {
        let dayTs: Int
        let id: UUID
        let updatedAt: Date
        let steps: Int?
        let sleep: Double?
        let exercise: Int?
        let calories: Int?
        let heartRate: Int?
    }

    func syncId(forDayTs dayTs: Int) -> UUID {
        // 基于日期派生确定性 UUID（云端按 id upsert 幂等）。格式为合法 UUID 字符串：
        // 固定命名空间前缀 + 秒级时间戳（正值，12 位 hex 足够），跨设备同日稳定一致。
        let s = String(format: "A1B2C3D4-E5F6-4789-8ABC-%012X", UInt(dayTs))
        return UUID(uuidString: s) ?? UUID()
    }

    /// 返回自 since 以来有变动的每日快照（最近 120 天窗口）。
    func exportModified(since: Date) -> [ManualHealthSnapshot] {
        var result: [ManualHealthSnapshot] = []
        let now = Date()
        for offset in 0..<120 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let dayStart = calendar.startOfDay(for: day)
            let dayTs = Int(dayStart.timeIntervalSince1970)
            let upd = defaults.double(forKey: metaKey(dayTs: dayTs))
            guard upd > since.timeIntervalSince1970 else { continue }
            let steps = defaults.integer(forKey: key("steps", date: dayStart))
            let sleep = defaults.double(forKey: key("sleep", date: dayStart))
            let ex = defaults.integer(forKey: key("exercise", date: dayStart))
            let cal = defaults.integer(forKey: key("activeCalories", date: dayStart))
            let hr = defaults.integer(forKey: key("heartRate", date: dayStart))
            guard steps > 0 || sleep > 0 || ex > 0 || cal > 0 || hr > 0 else { continue }
            result.append(ManualHealthSnapshot(
                dayTs: dayTs,
                id: syncId(forDayTs: dayTs),
                updatedAt: Date(timeIntervalSince1970: upd),
                steps: steps > 0 ? steps : nil,
                sleep: sleep > 0 ? sleep : nil,
                exercise: ex > 0 ? ex : nil,
                calories: cal > 0 ? cal : nil,
                heartRate: hr > 0 ? hr : nil
            ))
        }
        return result
    }

    /// 把云端快照写回本地（重装恢复）。直接写 UserDefaults，不调 setX，
    /// 因此不更新 updatedAt、也不触发同步，避免拉回的数据被当成脏数据再次推送。
    func importSnapshot(_ s: ManualHealthSnapshot) {
        let day = Date(timeIntervalSince1970: TimeInterval(s.dayTs))
        if let v = s.steps { defaults.set(v, forKey: key("steps", date: day)) }
        if let v = s.sleep { defaults.set(v, forKey: key("sleep", date: day)) }
        if let v = s.exercise { defaults.set(v, forKey: key("exercise", date: day)) }
        if let v = s.calories { defaults.set(v, forKey: key("activeCalories", date: day)) }
        if let v = s.heartRate { defaults.set(v, forKey: key("heartRate", date: day)) }
    }

    func clearDay(_ dayTs: Int) {
        let day = Date(timeIntervalSince1970: TimeInterval(dayTs))
        defaults.removeObject(forKey: key("steps", date: day))
        defaults.removeObject(forKey: key("sleep", date: day))
        defaults.removeObject(forKey: key("exercise", date: day))
        defaults.removeObject(forKey: key("activeCalories", date: day))
        defaults.removeObject(forKey: key("heartRate", date: day))
        defaults.removeObject(forKey: metaKey(dayTs: dayTs))
    }

    // MARK: - HealthKit 自动槽位（.hk 后缀，物理隔离手动数据）

    /// 把 HealthKit 拉取到的历史值落库到「.hk」槽位（覆盖式，幂等）。
    /// 不触发云同步（exportModified 只遍历手动 key，天然排除 .hk）。
    func setHealthKitValue(_ value: Double, metric: String, for date: Date) {
        defaults.set(value, forKey: key(metric, date: date, source: .healthKit))
    }

    /// 读取某天的 HealthKit 自动值（无则返回 0）。
    func healthKitValue(_ metric: String, for date: Date) -> Double {
        return defaults.double(forKey: key(metric, date: date, source: .healthKit))
    }

    /// 清空全部手动健康数据（账户删除 / 注销时调用）。
    /// 直接遍历所有以 `aia.manualHealth.` 为前缀的 UserDefaults 键删除，
    /// 避免按日期逐个 clearDay 遗漏更早的历史快照。
    func clearAll() {
        let prefix = "aia.manualHealth."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        WidgetSnapshot.refreshAfterWrite()
    }

    // MARK: - 步数
    func steps(for date: Date) -> Int {
        defaults.integer(forKey: key("steps", date: date))
    }
    func setSteps(_ value: Int, for date: Date) {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        defaults.set(value, forKey: key("steps", date: day))
        defaults.set(Date().timeIntervalSince1970, forKey: metaKey(dayTs: ts))
        notifyChanged()
    }
    func addSteps(_ delta: Int, for date: Date) {
        setSteps(steps(for: date) + delta, for: date)
    }

    // MARK: - 睡眠（小时）
    func sleepHours(for date: Date) -> Double {
        defaults.double(forKey: key("sleep", date: date))
    }
    func setSleepHours(_ value: Double, for date: Date) {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        defaults.set(value, forKey: key("sleep", date: day))
        defaults.set(Date().timeIntervalSince1970, forKey: metaKey(dayTs: ts))
        notifyChanged()
    }
    func addSleepHours(_ delta: Double, for date: Date) {
        setSleepHours(sleepHours(for: date) + delta, for: date)
    }

    // MARK: - 运动时长（分钟）
    func exerciseMinutes(for date: Date) -> Int {
        defaults.integer(forKey: key("exercise", date: date))
    }
    func setExerciseMinutes(_ value: Int, for date: Date) {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        defaults.set(value, forKey: key("exercise", date: day))
        defaults.set(Date().timeIntervalSince1970, forKey: metaKey(dayTs: ts))
        notifyChanged()
    }
    func addExerciseMinutes(_ delta: Int, for date: Date) {
        setExerciseMinutes(exerciseMinutes(for: date) + delta, for: date)
    }

    // MARK: - 活动热量（kcal，未授权 HealthKit 时手动补录 TDEE 实际达成）
    func activeCalories(for date: Date) -> Int {
        defaults.integer(forKey: key("activeCalories", date: date))
    }
    func setActiveCalories(_ value: Int, for date: Date) {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        defaults.set(value, forKey: key("activeCalories", date: day))
        defaults.set(Date().timeIntervalSince1970, forKey: metaKey(dayTs: ts))
        notifyChanged()
    }
    func addActiveCalories(_ delta: Int, for date: Date) {
        setActiveCalories(activeCalories(for: date) + delta, for: date)
    }

    // MARK: - 静息心率（bpm，手动记录模式）
    func restingHeartRate(for date: Date) -> Int {
        defaults.integer(forKey: key("heartRate", date: date))
    }
    func setRestingHeartRate(_ bpm: Int, for date: Date) {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        defaults.set(bpm, forKey: key("heartRate", date: day))
        defaults.set(Date().timeIntervalSince1970, forKey: metaKey(dayTs: ts))
        notifyChanged()
    }
}
