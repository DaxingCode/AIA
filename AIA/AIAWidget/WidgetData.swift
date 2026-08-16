//
//  WidgetData.swift
//  AIAWidgetExtension
//
//  Shared data-layer for widgets. Provides WidgetStore (the data API the
//  widget providers call) plus the TimelineEntry structs used by each widget.
//  Uses AIAKit's read-only SwiftData container.
//

import Foundation
import SwiftData
import WidgetKit
import AIAKit

// MARK: - Entry 模型

public struct SummaryEntry: TimelineEntry {
    public let date: Date
    /// 今日摄入热量 kcal
    public let calories: Int
    /// 今日饮水 ml
    public let water: Int
    /// 今日步数
    public let steps: Int
    /// 今日支出 ¥
    public let expense: Double
}

public struct UpcomingEntry: TimelineEntry {
    public let date: Date
    public let todos: [Reminder]
}

// MARK: - 四个宫格独立 Widget 的 Entry

public struct BillEntry: TimelineEntry {
    public let date: Date
    public let isEmpty: Bool
    public let hidden: Bool
    public let todayExpense: Double
    public let monthIncome: Double
    public let monthExpense: Double
    public let monthlyBudget: Double
    public let monthBalance: Double
}

public struct TodoEntry: TimelineEntry {
    public let date: Date
    public let isEmpty: Bool
    public let recent: [Reminder]
}

public struct DietEntry: TimelineEntry {
    public let date: Date
    public let isEmpty: Bool
    public let todayCount: Int
    public let calories: Int
    public let calorieGoal: Double
    public let water: Int
}

public struct HealthEntry: TimelineEntry {
    public let date: Date
    public let isEmpty: Bool
    public let steps: Int
    public let stepGoal: Int
    public let exerciseMin: Double
    public let energyBurned: Double
    public let sleepText: String
}

// MARK: - 数据层

public enum WidgetStore {

    /// 每个调用内部自建只读上下文（Widget 进程不应参与迁移）。
    private static func withContext(_ block: (ModelContext) -> Void) {
        let container = AppPersistence.makeReadOnlyContainer()
        let context = ModelContext(container)
        block(context)
    }

    private static func fetch<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) -> [T] {
        var result: [T] = []
        withContext { ctx in
            result = (try? ctx.fetch(descriptor)) ?? []
        }
        return result
    }

    // App Group 共享摘要读取（主 App 预写，详见主 App WidgetSnapshot.swift）
    private static let group = "group.com.daxing.aia"
    private static var ud: UserDefaults? { UserDefaults(suiteName: group) }
    private static func gInt(_ key: String) -> Int {
        let ud = UserDefaults(suiteName: group)
        let v = ud?.integer(forKey: key) ?? 0
        print("[AIAWidget] gInt \(key) = \(v), suite=\(ud != nil)")
        return v
    }
    private static func gDouble(_ key: String) -> Double { ud?.double(forKey: key) ?? 0 }
    private static func gBool(_ key: String) -> Bool { ud?.bool(forKey: key) ?? false }

    /// 未完成待办数（含无截止）
    public static func todoCount() -> Int {
        fetch(FetchDescriptor<Reminder>(
            predicate: #Predicate<Reminder> { r in !r.syncDeleted && !r.done }
        )).count
    }

    /// 今日已确认但未标记完成的账单数（用于「未记账」口径）
    public static func unbilledCount() -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        return fetch(FetchDescriptor<Bill>(
            predicate: #Predicate<Bill> { b in
                !b.syncDeleted && b.confirmed && b.time >= start
            }
        )).count
    }

    /// 最新一条健康记录
    public static func latestHealth() -> HealthMetric? {
        fetch(FetchDescriptor<HealthMetric>(
            predicate: #Predicate<HealthMetric> { h in !h.syncDeleted },
            sortBy: [SortDescriptor<HealthMetric>(\.date, order: .reverse)]
        )).first
    }

    /// 临近待办 Top N
    public static func upcomingTodos(limit: Int = 5) -> [Reminder] {
        let now = Date()
        // 注意：SwiftData #Predicate 宏内不允许强制解包（r.due! 非法），
        // 故只拉「未完成 + 未软删」，可空比较放到 Swift 里做。
        let all = fetch(FetchDescriptor<Reminder>(
            predicate: #Predicate<Reminder> { r in
                !r.syncDeleted && !r.done
            }
        ))
        // 语义：未完成 + (无截止 或 截止未到) 一律算「临近」；
        // due=nil 排在所有有截止的待办之后。
        let live = all.filter { r in
            guard let due = r.due else { return true }
            return due >= now
        }
        let sorted = live.sorted { a, b in
            switch (a.due, b.due) {
            case (nil, nil):  return false
            case (nil, _):    return false   // nil 在后
            case (_, nil):    return true
            case let (l?, r?): return l < r
            }
        }
        return Array(sorted.prefix(limit))
    }

    // MARK: - 四个宫格 Widget 专用聚合
    // 全部读 App Group 共享摘要（主 App 预写），确保与宫格口径一致。
    // Widget 跨进程读不到 HealthKit 实时值，也读不到 ManualHealthStore 内存单例，
    // 故健康三项由主 App 聚合后写入；账单/待办/饮食聚合口径也与宫格逐字对齐。

    /// 账单隐私遮罩开关（主 App 预写，与原 @AppStorage("billHidden") 同源）
    public static func billHidden() -> Bool {
        gBool("aia.widget.billHidden")
    }

    /// 本月预算（主 App 预写）
    public static func monthlyBudget() -> Double {
        let v = gDouble("aia.widget.monthlyBudget")
        return v > 0 ? v : 5000
    }

    /// 本月收入（主 App 预写）
    public static func monthIncome() -> Double {
        gDouble("aia.widget.monthIncome")
    }

    /// 本月支出（主 App 预写）
    public static func monthExpense() -> Double {
        gDouble("aia.widget.monthExpense")
    }

    /// 今日支出（主 App 预写）
    public static func todayExpense() -> Double {
        gDouble("aia.widget.todayExpense")
    }

    /// 全量账单数（用于空态，与宫格 bills.isEmpty 一致）
    public static func billCount() -> Int {
        gInt("aia.widget.billTotalCount")
    }

    /// 今日待办数（有 due 且今天，主 App 预写）
    public static func todayTodoCount() -> Int {
        gInt("aia.widget.todayTodoCount")
    }

    /// 未完成待办前 N 条（!done）—— Widget 仍需读 SwiftData 取标题/时间文本
    public static func recentTodos(limit: Int = 5) -> [Reminder] {
        let list = fetch(FetchDescriptor<Reminder>(
            predicate: #Predicate<Reminder> { r in !r.syncDeleted && !r.done }
        ))
        return Array(list.sorted {
            ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture)
        }.prefix(limit))
    }

    /// 今日饮食热量（主 App 预写）
    public static func todayCalories() -> Int {
        gInt("aia.widget.todayCalories")
    }

    /// 今日饮食条数（主 App 预写）
    public static func todayFoodCount() -> Int {
        gInt("aia.widget.todayFoodCount")
    }

    /// 全量饮食数（空态，与宫格 foods.isEmpty 一致）
    public static func foodCount() -> Int {
        gInt("aia.widget.foodTotalCount")
    }

    // MARK: - 直接读 SwiftData 的聚合（绕过 App Group 快照，供 Widget 独立进程使用）
    // 前提：store 已迁到 App Group 共享容器（AppPersistence.storeURL），
    // 否则 Widget 进程读的是自己沙盒里的空库。

    /// 全量账单数（直接读 SwiftData）
    public static func billTotalCountDirect() -> Int {
        fetch(FetchDescriptor<Bill>(predicate: #Predicate<Bill> { !$0.syncDeleted })).count
    }

    /// 全量饮食数（直接读 SwiftData）
    public static func foodTotalCountDirect() -> Int {
        fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate<FoodEntry> { !$0.syncDeleted })).count
    }

    /// 今日支出（直接读 SwiftData）
    public static func todayExpenseDirect() -> Double {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let list = fetch(FetchDescriptor<Bill>(predicate: #Predicate<Bill> { b in
            !b.syncDeleted && !b.isIncome && b.time >= start && b.time < end
        }))
        return list.reduce(0.0) { $0 + $1.amount }
    }

    /// 本月收入（直接读 SwiftData）
    public static func monthIncomeDirect() -> Double {
        let now = Date()
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now))!
        let end = Calendar.current.date(byAdding: .month, value: 1, to: start)!
        let list = fetch(FetchDescriptor<Bill>(predicate: #Predicate<Bill> { b in
            !b.syncDeleted && b.isIncome && b.time >= start && b.time < end
        }))
        return list.reduce(0.0) { $0 + $1.amount }
    }

    /// 本月支出（直接读 SwiftData）
    public static func monthExpenseDirect() -> Double {
        let now = Date()
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now))!
        let end = Calendar.current.date(byAdding: .month, value: 1, to: start)!
        let list = fetch(FetchDescriptor<Bill>(predicate: #Predicate<Bill> { b in
            !b.syncDeleted && !b.isIncome && b.time >= start && b.time < end
        }))
        return list.reduce(0.0) { $0 + $1.amount }
    }

    /// 今日饮食热量（直接读 SwiftData）
    public static func todayCaloriesDirect() -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let list = fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate<FoodEntry> { f in
            !f.syncDeleted && f.date >= start && f.date < end
        }))
        return list.reduce(0) { $0 + Int($1.calories) }
    }

    /// 今日饮水 ml（直接读 SwiftData，WaterLog 表）
    public static func todayWaterDirect() -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let list = fetch(FetchDescriptor<WaterLog>(predicate: #Predicate<WaterLog> { w in
            !w.syncDeleted && w.date >= start && w.date < end
        }))
        return list.reduce(0) { $0 + Int($1.amount) }
    }

    /// 今日饮水 ml（主 App 预写）
    public static func todayWater() -> Int {
        gInt("aia.widget.water")
    }

    /// 热量目标（主 App 预写，已含 tdee 计算）
    public static func calorieGoal() -> Double {
        let v = gDouble("aia.widget.calorieGoal")
        return v > 0 ? v : 2000
    }

    /// 步数目标（读主 App 写入 App Group 的同源值；standard suite 的 aia.stepGoal 不跨进程）
    public static func stepGoal() -> Int {
        let v = gInt("aia.widget.stepGoal")
        return v > 0 ? v : 10000
    }

    /// 今日步数（主 App 预写，已含 HealthKit/ManualHealthStore 回落）
    public static func widgetSteps() -> Int {
        gInt("aia.widget.stepsToday")
    }

    /// 今日运动时长（主 App 预写）
    public static func widgetExercise() -> Double {
        gDouble("aia.widget.exerciseMin")
    }

    /// 今日能量消耗（主 App 预写）
    public static func widgetEnergy() -> Double {
        gDouble("aia.widget.energyBurned")
    }

    /// 睡眠时长（小时，主 App 预写，已含自动/手动口径）
    public static func widgetSleepHours() -> Double {
        gDouble("aia.widget.sleepHours")
    }

    /// 睡眠时长文本
    public static func sleepLastNightText() -> String {
        let h = widgetSleepHours()
        guard h > 0 else { return "—" }
        let totalMin = Int(h * 60)
        let hh = totalMin / 60
        let mm = totalMin % 60
        return String(format: "%dh%dm", hh, mm)
    }
}
