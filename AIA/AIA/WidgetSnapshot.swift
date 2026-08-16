//
//  WidgetSnapshot.swift
//  主 App 进程内聚合首页四宫格所需的全部数据，写入 App Group 共享 UserDefaults，
//  供四个独立小 Widget（aia.bill/todo/diet/health）读取。
//
//  根因：Widget 跨进程既读不到 HealthKit 实时值，也读不到 ManualHealthStore（UserDefaults 内存单例，
//  且不写 SwiftData 的 HealthMetric 表）。宫格在主 App 用 HealthKit + ManualHealthStore + SwiftData 三源，
//  Widget 直接查 SwiftData 必然与宫格不一致。正解：主 App 在回前台 / 任意数据写入后，把聚合结果
//  预写进 App Group UserDefaults（与 Widget 共享同一个 App Group），Widget 只读这份缓存，口径完全一致。
//
//  调用点：AppDelegate.applicationDidBecomeActive（回前台）、SafeDelete.notifyWidgetReload()（任意写入）。

import Foundation
import SwiftData
import WidgetKit
import AIAKit

enum WidgetSnapshot {
    /// 写摘要用的 App Group（与 Widget 只读容器同源）
    private static let group = "group.com.daxing.aia"
    private static let ud: UserDefaults? = UserDefaults(suiteName: group)

    // MARK: - 对外键
    enum Key {
        static let steps            = "aia.widget.stepsToday"
        static let exerciseMin      = "aia.widget.exerciseMin"
        static let energyBurned     = "aia.widget.energyBurned"
        static let sleepHours       = "aia.widget.sleepHours"
        static let calorieGoal      = "aia.widget.calorieGoal"
        static let todayCalories    = "aia.widget.todayCalories"
        static let todayFoodCount    = "aia.widget.todayFoodCount"
        static let water            = "aia.widget.water"
        static let todayExpense     = "aia.widget.todayExpense"
        static let monthIncome      = "aia.widget.monthIncome"
        static let monthExpense     = "aia.widget.monthExpense"
        static let monthlyBudget    = "aia.widget.monthlyBudget"
        static let billHidden       = "aia.widget.billHidden"
        static let todayTodoCount   = "aia.widget.todayTodoCount"
        static let billTotalCount   = "aia.widget.billTotalCount"
        static let foodTotalCount   = "aia.widget.foodTotalCount"
        static let snapshotDate     = "aia.widget.snapshotDate"
        // 健康目标（与 @AppStorage("aia.stepGoal") 等 standard suite 同源，供 widget 兜底）
        static let stepGoal         = "aia.widget.stepGoal"
        static let sleepGoal        = "aia.widget.sleepGoal"
        static let exerciseGoal     = "aia.widget.exerciseGoal"
    }

    /// 主 App 回前台 / 任意本地写入后调用：聚合四宫格数据写 App Group。
    /// 必须在主线程、容器就绪后调用（AppDelegate.applicationDidBecomeActive 满足）。
    @MainActor
    static func writeShared() {
        guard let ctx = AppDelegate.sharedMainContext else { return }
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!

        // 账单
        let billsAll = (try? ctx.fetch(FetchDescriptor<Bill>(predicate: #Predicate<Bill> { !$0.syncDeleted }))) ?? []
        let bills = billsAll.filter { $0.time >= monthStart && $0.time < monthEnd }
        let todayBills = bills.filter { !$0.isIncome && $0.time >= todayStart && $0.time < todayEnd }
        let todayExpense = todayBills.reduce(0) { $0 + $1.amount }
        let monthIncome = bills.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
        let monthExpense = bills.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
        let monthlyBudget = UserDefaults.standard.double(forKey: "aia.monthlyBudget")
        let billHidden = UserDefaults.standard.bool(forKey: "billHidden")

        // 待办
        let reminders = (try? ctx.fetch(FetchDescriptor<Reminder>(
            predicate: #Predicate<Reminder> { r in !r.syncDeleted && !r.done && r.due != nil && r.due! >= todayStart && r.due! < todayEnd }
        ))) ?? []
        let todayTodoCount = reminders.count

        // 饮食
        let foodsAll = (try? ctx.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate<FoodEntry> { !$0.syncDeleted }))) ?? []
        let foods = foodsAll.filter { $0.date >= todayStart && $0.date < todayEnd }
        let todayCalories = foods.reduce(0) { $0 + $1.calories }
        let foodsAllCount = foodsAll.count
        let water = (try? ctx.fetch(FetchDescriptor<WaterLog>(
            predicate: #Predicate<WaterLog> { w in !w.syncDeleted && w.date >= todayStart && w.date < todayEnd }
        ))) ?? []
        let waterMl = water.reduce(0) { $0 + $1.amount }

        // 热量目标：与宫格口径一致（自定义优先，否则 tdee = mifflinBMR × 活动系数）
        let calOverride = UserDefaults.standard.double(forKey: "aia.calorieGoalOverride")
        let calIsCustom = UserDefaults.standard.bool(forKey: "aia.calorieGoalIsCustom")
        let calorieGoal: Double
        if calIsCustom, calOverride > 0 {
            calorieGoal = calOverride
        } else {
            let weight = UserDefaults.standard.double(forKey: "aia.weightKg")
            let height = UserDefaults.standard.double(forKey: "aia.heightCm")
            let age = UserDefaults.standard.integer(forKey: "aia.age")
            let isMale = UserDefaults.standard.integer(forKey: "aia.bioSex") == 1
            let activity = UserDefaults.standard.integer(forKey: "aia.activityLevel")
            if let bmr = mifflinBMR(weightKg: weight, heightCm: height, age: age, isMale: isMale) {
                calorieGoal = bmr * activityMultiplier(activity)
            } else {
                calorieGoal = 2000
            }
        }

        // 健康三件套 + 睡眠：与宫格同源（HealthKit 自动 + ManualHealthStore 手动回落）
        let health = HealthManager.shared
        let hkUsable = health.authorized && health.isAvailable && health.hasHealthKitData
        let stepsSrc = HealthSourceMode(rawValue: UserDefaults.standard.string(forKey: HealthMetricKind.steps.sourceKey) ?? "") ?? .auto
        let exSrc = HealthSourceMode(rawValue: UserDefaults.standard.string(forKey: HealthMetricKind.exercise.sourceKey) ?? "") ?? .auto
        let tdeeSrc = HealthSourceMode(rawValue: UserDefaults.standard.string(forKey: HealthMetricKind.tdee.sourceKey) ?? "") ?? .auto
        let sleepSrc = HealthSourceMode(rawValue: UserDefaults.standard.string(forKey: HealthMetricKind.sleep.sourceKey) ?? "") ?? .auto

        let steps: Int = (stepsSrc == .auto && hkUsable) ? Int(ManualHealthStore.shared.healthKitValue("steps", for: now)) : ManualHealthStore.shared.steps(for: now)
        let exercise: Double = (exSrc == .auto && hkUsable) ? ManualHealthStore.shared.healthKitValue("exercise", for: now) : Double(ManualHealthStore.shared.exerciseMinutes(for: now))
        let energy: Double = (tdeeSrc == .auto && hkUsable) ? (ManualHealthStore.shared.healthKitValue("activeCalories", for: now) + ManualHealthStore.shared.healthKitValue("restingCalories", for: now)) : Double(ManualHealthStore.shared.activeCalories(for: now))

        // 睡眠：与首页宫格、健康管理页睡眠圆环保持同源——
        // 自动 → healths「睡眠」单一事实源；手动 → manualSleepTotalHours（历史残留 + 圆环点击累加 + 当天已醒 SleepSession 累计）。
        // 关键：手动分支必须按「醒来的那天」过滤 SleepSession，否则会把历史所有已醒会话累加爆成 25h+。
        // 复用 manualSleepTotalHours 而非自己 reduce，杜绝两端算法漂移（此前 widget 独自用无过滤 reduce 导致数值偏大）。
        let healths = (try? ctx.fetch(FetchDescriptor<HealthMetric>(
            predicate: #Predicate<HealthMetric> { h in !h.syncDeleted && h.metric.contains("睡眠") }
        ))) ?? []
        let sleeps = (try? ctx.fetch(FetchDescriptor<SleepSession>(predicate: #Predicate<SleepSession> { !$0.syncDeleted }))) ?? []
        let sleepHours: Double
        if sleepSrc == .auto {
            // 自动模式读 HealthKit 落库值（.hk 槽位，已持久化）；兼容旧 HealthMetric 体检记录兜底。
            let hk = ManualHealthStore.shared.healthKitValue("sleep", for: now)
            sleepHours = hk > 0 ? hk : (healths.first(where: { $0.metric.contains("睡眠") }).flatMap { Double($0.value) } ?? 0)
        } else {
            sleepHours = manualSleepTotalHours(sleeps: sleeps, healths: healths, on: now)
        }

        // 写入 App Group
        guard let ud else { return }
        ud.set(Int(steps), forKey: Key.steps)
        ud.set(exercise, forKey: Key.exerciseMin)
        ud.set(energy, forKey: Key.energyBurned)
        ud.set(sleepHours, forKey: Key.sleepHours)
        ud.set(calorieGoal, forKey: Key.calorieGoal)
        ud.set(Int(todayCalories), forKey: Key.todayCalories)
        ud.set(foods.count, forKey: Key.todayFoodCount)
        ud.set(Int(waterMl), forKey: Key.water)
        ud.set(todayExpense, forKey: Key.todayExpense)
        ud.set(monthIncome, forKey: Key.monthIncome)
        ud.set(monthExpense, forKey: Key.monthExpense)
        ud.set(monthlyBudget > 0 ? monthlyBudget : 5000, forKey: Key.monthlyBudget)
        ud.set(billHidden, forKey: Key.billHidden)
        ud.set(todayTodoCount, forKey: Key.todayTodoCount)
        ud.set(billsAll.count, forKey: Key.billTotalCount)
        ud.set(foodsAllCount, forKey: Key.foodTotalCount)
        ud.set(now, forKey: Key.snapshotDate)

        // 健康目标：standard suite 与 App Group 不同源，主 App 从未同步 → widget 永远回退默认。
        // 这里把 @AppStorage("aia.stepGoal") 等源头值同步进 App Group，供 widget 兜底。
        let stepGoalStd = UserDefaults.standard.integer(forKey: "aia.stepGoal")
        let sleepGoalStd = UserDefaults.standard.double(forKey: "aia.sleepGoalHours")
        let exerciseGoalStd = UserDefaults.standard.double(forKey: "aia.exerciseGoalMin")
        ud.set(stepGoalStd > 0 ? stepGoalStd : 10000, forKey: Key.stepGoal)
        ud.set(sleepGoalStd > 0 ? sleepGoalStd : 8, forKey: Key.sleepGoal)
        ud.set(exerciseGoalStd > 0 ? exerciseGoalStd : 30, forKey: Key.exerciseGoal)
    }

    /// 任意本地写入（新增/修改）后调用，刷新桌面小组件。
    /// 比 writeShared 多一步：主动让 WidgetKit 重排时间线，避免 widget 停在旧快照/空态。
    static func refreshAfterWrite() {
        MainActor.assumeIsolated {
            writeShared()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
