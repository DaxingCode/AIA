// DailyHealthStore.swift
// 每日健康指标快照的正式数据库读写层（替代旧 ManualHealthStore 的 UserDefaults 方案）。
//
// 把每天手动录入 / HealthKit 自动拉取的健康指标（步数/睡眠/运动/活动热量/静息心率）
// 存进 SwiftData（App Group 共享 store）的 DailyHealthMetric 表。
// 每个 (dayTs, source) 一条记录；source = "manual" | "hk"，与旧 .hk 后缀槽位语义一致，
// 同一天手动 + 自动互不覆盖。
//
// 好处：
// 1. Widget 是独立进程，直接读同一份 SQLite 即可，不再依赖 App 进程 buildSnapshot 中转；
// 2. 数据随 App Group store 走，不受 UserDefaults 跨进程读取限制（旧方案 Widget 实际读不到）。
//
// 说明：HealthKit 值不进云同步（exportModified 只遍历手动 source 行，天然排除 "hk"）。
// 本文件只做读写，云同步组装仍由 CloudSyncManager 调 exportModified / importSnapshot。
import Foundation
import SwiftData
import AIAKit
import WidgetKit

/// 每日健康指标快照的 SwiftData 读写封装。
/// 通过 AppDelegate.sharedMainContext 访问 App Group 共享 store（与主 App / Widget 同一份库）。
final class DailyHealthStore {

    static let shared = DailyHealthStore()

    private let calendar = Calendar.current

    /// 录入变更时触发（由 AppDelegate 注入，内部走 CloudSyncManager 防抖同步）。
    var syncTrigger: (() -> Void)?

    private init() {}

    // MARK: - 上下文获取

    private var context: ModelContext? { AppDelegate.sharedMainContext }

    // MARK: - 行读取 / 写入

    /// 取某天某来源的快照行（不存在返回 nil，不自动创建）。
    private func row(dayTs: Int, source: String) -> DailyHealthMetric? {
        guard let ctx = context else { return nil }
        let source = source
        let pred = #Predicate<DailyHealthMetric> { $0.dayTs == dayTs && $0.source == source && !$0.syncDeleted }
        let descriptor = FetchDescriptor<DailyHealthMetric>(predicate: pred)
        return (try? ctx.fetch(descriptor))?.first
    }

    /// 取或建某天某来源的快照行（写入前用，自动 insert 新行）。
    @discardableResult
    private func rowOrCreate(dayTs: Int, source: String) -> DailyHealthMetric {
        if let existing = row(dayTs: dayTs, source: source) { return existing }
        let m = DailyHealthMetric(dayTs: dayTs, source: source, syncId: syncId(forDayTs: dayTs, source: source))
        context?.insert(m)
        return m
    }

    /// 派生确定性 UUID（云端按 id upsert 幂等）。dayTs + source 一起派生，
    /// 保证手动 / hk 两行 id 不同、互不覆盖。
    private func syncId(forDayTs dayTs: Int, source: String) -> UUID {
        let suffix = source == "hk" ? "HK" : "MN"
        let s = String(format: "A1B2C3D4-E5F6-4789-8ABC-%@%08X", suffix, UInt(dayTs) & 0xFFFFFFFF)
        return UUID(uuidString: s) ?? UUID()
    }

    private func notifyChanged() {
        syncTrigger?()
        // 手动记健康数据后，补偿刷新桌面 widget。
        WidgetSnapshot.refreshAfterWrite()
    }

    /// 写入单个指标字段（覆盖式，幂等）。touchesUpdatedAt=true 时刷新 syncUpdatedAt + 触发同步。
    private func write(metric: String, value: Double, dayTs: Int, source: String, touchesUpdatedAt: Bool) {
        guard let ctx = context else { return }
        let m = rowOrCreate(dayTs: dayTs, source: source)
        switch metric {
        case "steps":        m.steps = Int(value)
        case "sleep":        m.sleep = value
        case "exercise":     m.exercise = Int(value)
        case "activeCalories": m.calories = Int(value)
        case "heartRate":    m.heartRate = Int(value)
        default: break
        }
        if touchesUpdatedAt {
            m.syncUpdatedAt = .now
        }
        do { try ctx.save() } catch { print("[DailyHealth] ❌ 写入失败:", error) }
    }

    private func read(metric: String, dayTs: Int, source: String) -> Double {
        guard let m = row(dayTs: dayTs, source: source) else { return 0 }
        let v: Int?
        switch metric {
        case "steps":        v = m.steps
        case "exercise":     v = m.exercise
        case "activeCalories": v = m.calories
        case "heartRate":    v = m.heartRate
        default:             v = nil
        }
        if let v { return Double(v) }
        if metric == "sleep" { return m.sleep ?? 0 }
        return 0
    }

    // MARK: - HealthKit 自动槽位（source = "hk"，物理隔离手动数据）

    func setHealthKitValue(_ value: Double, metric: String, for date: Date) {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        write(metric: metric, value: value, dayTs: ts, source: "hk", touchesUpdatedAt: false)
    }

    func healthKitValue(_ metric: String, for date: Date) -> Double {
        let day = calendar.startOfDay(for: date)
        let ts = Int(day.timeIntervalSince1970)
        return read(metric: metric, dayTs: ts, source: "hk")
    }

    // MARK: - 手动录入（source = "manual"）

    func steps(for date: Date) -> Int {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        return Int(read(metric: "steps", dayTs: ts, source: "manual"))
    }
    func setSteps(_ value: Int, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        write(metric: "steps", value: Double(value), dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
    }

    func sleepHours(for date: Date) -> Double {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        return read(metric: "sleep", dayTs: ts, source: "manual")
    }
    func setSleepHours(_ value: Double, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        write(metric: "sleep", value: value, dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
    }

    func exerciseMinutes(for date: Date) -> Int {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        return Int(read(metric: "exercise", dayTs: ts, source: "manual"))
    }
    func setExerciseMinutes(_ value: Int, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        write(metric: "exercise", value: Double(value), dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
    }

    func activeCalories(for date: Date) -> Int {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        return Int(read(metric: "activeCalories", dayTs: ts, source: "manual"))
    }
    func setActiveCalories(_ value: Int, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        write(metric: "activeCalories", value: Double(value), dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
    }

    func restingHeartRate(for date: Date) -> Int {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        return Int(read(metric: "heartRate", dayTs: ts, source: "manual"))
    }
    func setRestingHeartRate(_ bpm: Int, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        write(metric: "heartRate", value: Double(bpm), dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
    }

    // MARK: - 自增（点击圆环 +N）

    func addSteps(_ delta: Int, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        let newVal = max(0, Int(read(metric: "steps", dayTs: ts, source: "manual")) + delta)
        write(metric: "steps", value: Double(newVal), dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
    }

    func addSleepHours(_ delta: Double, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        let newVal = max(0, read(metric: "sleep", dayTs: ts, source: "manual") + delta)
        write(metric: "sleep", value: newVal, dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
    }

    func addExerciseMinutes(_ delta: Int, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        let newVal = max(0, Int(read(metric: "exercise", dayTs: ts, source: "manual")) + delta)
        write(metric: "exercise", value: Double(newVal), dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
    }

    func addActiveCalories(_ delta: Int, for date: Date) {
        let ts = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        let newVal = max(0, Int(read(metric: "activeCalories", dayTs: ts, source: "manual")) + delta)
        write(metric: "activeCalories", value: Double(newVal), dayTs: ts, source: "manual", touchesUpdatedAt: true)
        notifyChanged()
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

    /// 返回自 since 以来有变动的每日手动快照（最近 120 天窗口）。
    func exportModified(since: Date) -> [ManualHealthSnapshot] {
        guard let ctx = context else { return [] }
        let minTs = Int(calendar.startOfDay(for: Date()).addingTimeInterval(-119 * 86400).timeIntervalSince1970)
        let pred = #Predicate<DailyHealthMetric> {
            $0.source == "manual" && !$0.syncDeleted && $0.dayTs >= minTs && $0.syncUpdatedAt > since
        }
        let desc = FetchDescriptor<DailyHealthMetric>(predicate: pred)
        guard let rows = try? ctx.fetch(desc) else { return [] }
        return rows.map { m in
            ManualHealthSnapshot(
                dayTs: m.dayTs,
                id: m.syncId,
                updatedAt: m.syncUpdatedAt,
                steps: m.steps,
                sleep: m.sleep,
                exercise: m.exercise,
                calories: m.calories,
                heartRate: m.heartRate
            )
        }
    }

    /// 把云端快照写回本地（重装恢复）。直接 upsert 手动行，不刷新 updatedAt、不触发同步，
    /// 避免拉回的数据被当成脏数据再次推送。
    func importSnapshot(_ s: ManualHealthSnapshot) {
        guard let ctx = context else { return }
        let m = rowOrCreate(dayTs: s.dayTs, source: "manual")
        m.syncId = s.id
        m.steps = s.steps
        m.sleep = s.sleep
        m.exercise = s.exercise
        m.calories = s.calories
        m.heartRate = s.heartRate
        // 不写 syncUpdatedAt（保持云端原值），不触发同步
        do { try ctx.save() } catch { print("[DailyHealth] ❌ 导入失败:", error) }
    }

    func clearDay(_ dayTs: Int) {
        guard let ctx = context else { return }
        let pred = #Predicate<DailyHealthMetric> { $0.dayTs == dayTs }
        let desc = FetchDescriptor<DailyHealthMetric>(predicate: pred)
        guard let rows = try? ctx.fetch(desc) else { return }
        for r in rows { ctx.delete(r) }
        do { try ctx.save() } catch { print("[DailyHealth] ❌ 清空当天失败:", error) }
    }

    func clearAll() {
        guard let ctx = context else { return }
        let pred = #Predicate<DailyHealthMetric> { _ in true }
        let desc = FetchDescriptor<DailyHealthMetric>(predicate: pred)
        guard let rows = try? ctx.fetch(desc) else { return }
        for r in rows { ctx.delete(r) }
        do { try ctx.save() } catch { print("[DailyHealth] ❌ 清空全部失败:", error) }
        WidgetSnapshot.refreshAfterWrite()
    }

    // MARK: - 旧 UserDefaults 数据一次性迁移

    /// 把旧 ManualHealthStore 的 UserDefaults 数据搬到 SwiftData（仅执行一次）。
    /// 旧 key 形如 `aia.manualHealth.{metric}.{ts}`（手动）与 `.hk` 后缀（HealthKit）。
    func migrateFromUserDefaultsIfNeeded() {
        let ud = UserDefaults.standard
        let marker = "aia.manualHealth._migratedToSwiftData"
        guard !ud.bool(forKey: marker) else { return }
        defer { ud.set(true, forKey: marker) }

        let metrics = ["steps": "steps", "sleep": "sleep", "exercise": "exercise",
                       "activeCalories": "activeCalories", "heartRate": "heartRate"]
        let manualPrefix = "aia.manualHealth."
        var touched = false
        for (oldKey, metric) in metrics {
            // 手动源
            for key in ud.dictionaryRepresentation().keys where key.hasPrefix(manualPrefix + oldKey + ".") && !key.hasSuffix(".hk") {
                let tsStr = key.dropFirst((manualPrefix + oldKey + ".").count)
                guard let ts = Int(tsStr), tsStr == String(ts) else { continue }
                let v = ud.double(forKey: key)
                if v > 0 {
                    write(metric: metric, value: v, dayTs: ts, source: "manual", touchesUpdatedAt: false)
                    touched = true
                }
                ud.removeObject(forKey: key)
            }
            // HealthKit 源
            for key in ud.dictionaryRepresentation().keys where key.hasSuffix(".hk") && key.contains(manualPrefix + oldKey + ".") {
                let core = key.dropLast(3) // 去掉 .hk
                let tsStr = core.dropFirst((manualPrefix + oldKey + ".").count)
                guard let ts = Int(tsStr), tsStr == String(ts) else { continue }
                let v = ud.double(forKey: key)
                if v > 0 {
                    write(metric: metric, value: v, dayTs: ts, source: "hk", touchesUpdatedAt: false)
                    touched = true
                }
                ud.removeObject(forKey: key)
            }
        }
        // 清掉 meta key
        for key in ud.dictionaryRepresentation().keys where key.hasPrefix("aia.manualHealth._meta.") {
            ud.removeObject(forKey: key)
        }
        if touched {
            print("[DailyHealth] ✅ 旧 UserDefaults 健康数据已迁移到 SwiftData")
        }
    }
}
