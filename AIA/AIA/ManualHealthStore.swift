// ManualHealthStore.swift
// 未接入 HealthKit 时，手动健康指标（步数/睡眠/运动时长）按日期存储，
// 每天 0 点自然归零，避免昨天的手动值一直带到今天。
import Foundation

final class ManualHealthStore {
    static let shared = ManualHealthStore()
    private let calendar = Calendar.current
    private let defaults = UserDefaults.standard

    private init() {
        // 清理旧的全局 key：旧版本把手动值存在单一全局 key 里，跨天不会归零，
        // 导致用户看到「昨天的数据」。升级后按日期存，旧 key 不再使用。
        defaults.removeObject(forKey: "aia.stepsCurrentManual")
        defaults.removeObject(forKey: "aia.sleepHoursCurrentManual")
        defaults.removeObject(forKey: "aia.exerciseMinCurrentManual")
    }

    private func key(_ metric: String, date: Date) -> String {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        return "aia.manualHealth.\(metric).\(ts)"
    }

    // MARK: - 步数
    func steps(for date: Date) -> Int {
        defaults.integer(forKey: key("steps", date: date))
    }
    func setSteps(_ value: Int, for date: Date) {
        defaults.set(value, forKey: key("steps", date: date))
    }
    func addSteps(_ delta: Int, for date: Date) {
        setSteps(steps(for: date) + delta, for: date)
    }

    // MARK: - 睡眠（小时）
    func sleepHours(for date: Date) -> Double {
        defaults.double(forKey: key("sleep", date: date))
    }
    func setSleepHours(_ value: Double, for date: Date) {
        defaults.set(value, forKey: key("sleep", date: date))
    }
    func addSleepHours(_ delta: Double, for date: Date) {
        setSleepHours(sleepHours(for: date) + delta, for: date)
    }

    // MARK: - 运动时长（分钟）
    func exerciseMinutes(for date: Date) -> Int {
        defaults.integer(forKey: key("exercise", date: date))
    }
    func setExerciseMinutes(_ value: Int, for date: Date) {
        defaults.set(value, forKey: key("exercise", date: date))
    }
    func addExerciseMinutes(_ delta: Int, for date: Date) {
        setExerciseMinutes(exerciseMinutes(for: date) + delta, for: date)
    }

    // MARK: - 活动热量（kcal，未授权 HealthKit 时手动补录 TDEE 实际达成）
    func activeCalories(for date: Date) -> Int {
        defaults.integer(forKey: key("activeCalories", date: date))
    }
    func setActiveCalories(_ value: Int, for date: Date) {
        defaults.set(value, forKey: key("activeCalories", date: date))
    }
    func addActiveCalories(_ delta: Int, for date: Date) {
        setActiveCalories(activeCalories(for: date) + delta, for: date)
    }
}
