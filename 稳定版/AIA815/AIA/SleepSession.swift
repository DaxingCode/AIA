// SleepSession.swift
// 手动睡眠记录：点击「入睡」开始、点击「醒来」结束，自动落库睡眠时长。
//
// 注意：SleepSession 模型定义已移到 AIAKit/Models.swift（@Model public final class），
// 与 Bill/Reminder 等模型同模块，以便 AIAMigrationPlan 的 SchemaVersion 引用。
// 本文件只保留共享的切换/计算函数，SleepSession 类型经由 `import AIAKit` 引用。
// 归属规则（用户 2026-08-01 定，2026-08-01 修正）：按「醒来的那天」归属，即 startOfDay(wakeAt)；
// 跨天熟睡（如 1 号 23:00 入睡、2 号 07:00 醒来 8h）算到醒来当天（2 号）的圆环，
// 对应「2 号总共睡了 8 小时」。活跃会话（wakeAt == nil）尚无归属日，按天聚合时不计入，
// 待用户醒来写入 wakeAt 后，才会并入对应那天的累计。
// 「正在睡」判定只看 wakeAt == nil，与归属日解耦，跨天也能正确显示状态。
import SwiftData
import Foundation
import UIKit

// MARK: - 共享入口：HealthListView 与首页 ContentView 共用，保证口径不漂移

/// 找出「当前正在睡」的会话：按 sleepStart 倒序后取首条且 wakeAt == nil。
/// 不能用 `first(where: { $0.wakeAt == nil })`——更早可能存在孤儿会话（旧数据未正常醒来），
/// 会让按钮误判为在睡并把「入睡」错误执行成「醒来旧会话」。与 HealthListView 此前定下的口径一致。
func currentActiveSleepSession(in sleeps: [SleepSession]) -> SleepSession? {
    guard let latest = sleeps.first, latest.wakeAt == nil else { return nil }
    return latest
}

/// 单条睡眠时长（秒）：在会=实时（now - sleepStart），已醒=记录值 durationSeconds。
/// 与健康管理页「最近睡眠」卡、首页「昨晚睡眠」共用，防两端算法漂移。
func sleepSessionDuration(_ s: SleepSession) -> TimeInterval {
    if let w = s.wakeAt { return s.durationSeconds ?? w.timeIntervalSince(s.sleepStart) }
    return Date().timeIntervalSince(s.sleepStart)
}

/// 归属日：醒来的那天 = startOfDay(wakeAt ?? sleepStart)。
/// 用于按天聚合睡眠时长（如健康管理页睡眠圆环）：活跃会话（wakeAt == nil）用 sleepStart 占位，
/// 但按天聚合时一般不计（调用方先过滤 wakeAt != nil），醒来后才落入对应那天的累计。
func sleepSessionAttributedDay(_ s: SleepSession, calendar: Calendar = .current) -> Date {
    calendar.startOfDay(for: s.wakeAt ?? s.sleepStart)
}

/// 手动模式睡眠「总数值」（小时）：与圆环完成数据、首页「昨晚睡眠」宫格保持同源——
/// = 历史残留(stored) + 圆环点击累加(ManualHealthStore) + 当天所有「已醒」会话的累计时长
/// （按醒来的那天归属；活跃会话 wakeAt==nil 未醒不计，醒来后对应当天的累计）。
/// 自动模式不调用此函数（单一事实源走 HealthKit，避免双计）。
/// `includeStored` 控制是否并「睡眠」度量残留：今天(true，与健康页/首页一致) 与历史日期(false，避免旧日期被今天的残留污染) 分流。
func manualSleepTotalHours(sleeps: [SleepSession], healths: [HealthMetric], on date: Date = .init(), includeStored: Bool = true) -> Double {
    let stored = includeStored ? (healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0) : 0
    let manualClicks = ManualHealthStore.shared.sleepHours(for: date)
    let sessionHours = sleeps
        .filter { $0.wakeAt != nil }
        .filter { Calendar.current.isDate($0.wakeAt!, inSameDayAs: date) }
        .reduce(0.0) { $0 + sleepSessionDuration($1) / 3600 }
    return stored + manualClicks + sessionHours
}

/// 切换睡眠状态：空闲→入睡（新增 wakeAt=nil 的 SleepSession）；在睡→醒来（写入 wakeAt + durationSeconds）。
/// 切完自动触发震动反馈 + 增量同步（CloudSyncManager.syncAfterLocalChange）。
/// 调用方：首页 ContentView 的 titleTrailing 小图标、健康管理页的 SleepToggleButton。
/// 返回值 = 切换后的真实结果：nil=当前不在睡（刚醒来/空闲），非 nil=当前在睡（刚入睡返回新会话）。
/// 注意：不能返回后再用调用方传入的 `sleeps` 快照查询——@Query 尚未刷新，新建会话不在数组里，
/// 会误判为 nil。直接返回刚创建/刚结束的会话对象，让调用方据此同步刷新遮罩。
@discardableResult
func toggleSleepSession(in context: ModelContext, sleeps: [SleepSession]) -> SleepSession? {
    if let active = currentActiveSleepSession(in: sleeps) {
        let now = Date()
        active.wakeAt = now
        active.durationSeconds = now.timeIntervalSince(active.sleepStart)
        active.syncUpdatedAt = now
        do {
            try context.save()   // 醒来状态需立即落盘：杀 App 重开也要恢复正确态
            print("[Sleep] ✅ 醒来保存成功, id=\(active.syncId)")
        } catch {
            print("[Sleep] ❌ 醒来保存失败:", error)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        return nil   // 刚醒来：当前不在睡
    } else {
        let new = SleepSession(sleepStart: .now)
        context.insert(new)
        print("[Sleep] 📝 插入新会话, id=\(new.syncId)")
        do {
            try context.save()   // 睡眠会话需跨进程存活：杀 App 重开要能恢复，必须显式落盘
            print("[Sleep] ✅ 入睡保存成功, id=\(new.syncId)")
        } catch {
            print("[Sleep] ❌ 入睡保存失败:", error)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        return new   // 刚入睡：直接返回新建会话（@Query 此刻尚未刷新，不能用 sleeps 再查）
    }
}

// MARK: - 睡眠遮罩「先用一下 App」收起记忆（进程内共享）

/// 用户主动收起睡眠遮罩（点「先用一下 App」）的那次会话 syncId。
/// 首页 ContentView 与健康页 HealthListView 共用此值：同一次睡眠内，任一页面收起后，
/// 两个页面都不再自动盖回遮罩（避免「首页刚收起、进健康页又被盖」的反复打扰）。
/// 故意不持久化到 UserDefaults：杀 App 重开时进程内值天然重置为 nil，
/// 满足「只要没点醒来，每次开 App 都盖着」的产品语义。
var sharedSleepMaskDismissedSessionID: UUID?
