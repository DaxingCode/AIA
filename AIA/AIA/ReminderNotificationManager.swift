// ReminderNotificationManager.swift
// 待办本地通知调度：申请权限、按 remindAt 排程、完成/删除时取消。
import Foundation
import UserNotifications
import SwiftData

enum ReminderOption: String, CaseIterable, Identifiable {
    case none = "none"
    case atTime = "atTime"
    case before15 = "before15"
    case before30 = "before30"
    case before1Hour = "before1Hour"
    case before1Day = "before1Day"
    case before1Week = "before1Week"
    case custom = "custom"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:        return "不提醒"
        case .atTime:      return "准时"
        case .before15:    return "提前15分钟"
        case .before30:    return "提前30分钟"
        case .before1Hour: return "提前1小时"
        case .before1Day:  return "提前1天"
        case .before1Week: return "提前1周"
        case .custom:      return "自定义时间"
        }
    }

    var shortLabel: String {
        switch self {
        case .none:        return "不提醒"
        case .atTime:      return "准时"
        case .before15:    return "15分"
        case .before30:    return "30分"
        case .before1Hour: return "1小时"
        case .before1Day:  return "1天"
        case .before1Week: return "1周"
        case .custom:      return "自定义"
        }
    }

    /// 根据 remindAt 与 due 反推当前选项（用于 UI 回显）
    static func from(remindAt: Date?, due: Date?) -> ReminderOption {
        guard let remindAt = remindAt, let due = due else { return .none }
        let diff = due.timeIntervalSince(remindAt)
        let weekLower = 6 * 24 * 3600 - 1800.0
        let weekUpper = 7 * 24 * 3600 + 1800.0
        switch diff {
        case -30...30:                 return .atTime
        case 14*60 - 30...15*60 + 30: return .before15
        case 29*60 - 30...30*60 + 30: return .before30
        case 59*60 - 30...60*60 + 30: return .before1Hour
        case 23*3600 - 30...24*3600 + 30: return .before1Day
        case weekLower...weekUpper: return .before1Week
        default:                       return .custom
        }
    }

    /// 根据 due 与选项计算 remindAt
    static func remindAt(for due: Date?, option: ReminderOption, custom: Date? = nil) -> Date? {
        guard let due, option != .none else { return nil }
        let cal = Calendar.current
        switch option {
        case .atTime:      return due
        case .before15:    return cal.date(byAdding: .minute, value: -15, to: due)
        case .before30:    return cal.date(byAdding: .minute, value: -30, to: due)
        case .before1Hour: return cal.date(byAdding: .hour, value: -1, to: due)
        case .before1Day:  return cal.date(byAdding: .day, value: -1, to: due)
        case .before1Week: return cal.date(byAdding: .day, value: -7, to: due)
        case .custom:       return custom ?? due
        case .none:        return nil
        }
    }
}

enum ReminderNotificationManager {
    private static let center = UNUserNotificationCenter.current()

    /// 首次启动时申请通知权限（已被拒绝/已授权时调用无不良影响）
    static func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[通知] 授权失败: \(error)")
            } else {
                print("[通知] 授权结果: \(granted)")
            }
        }
    }

    /// 为某条待办排程本地通知；按 remindTimes 中所有时间点（默认 4 个：提前一周/一天/30分钟/准时）分别发送。
    /// 若时间已过去或已完成则自动跳过。
    @discardableResult
    nonisolated static func schedule(_ reminder: Reminder) -> Bool {
        cancel(reminder)
        let times = reminder.remindTimes.isEmpty ? (reminder.remindAt.map { [$0] } ?? []) : reminder.remindTimes
        guard !reminder.done else { return false }
        let futureTimes = times.filter { $0 > Date() }
        guard !futureTimes.isEmpty else { return false }

        for (index, time) in futureTimes.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "待办提醒"
            content.body = reminder.title
            content.sound = .default
            content.badge = 1
            content.userInfo = ["route": "todo"]  // 点击通知跳转到待办页

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: time)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: "reminder-\(reminder.syncId.uuidString)-\(index)",
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error { print("[通知] 排程失败: \(error)") }
            }
        }
        return true
    }

    /// 取消某条待办的所有 pending 通知（覆盖所有时间点，循环上限放宽到 8 以兼容 4 个默认提醒）
    static func cancel(_ reminder: Reminder) {
        var ids = ["reminder-\(reminder.syncId.uuidString)"] // 旧版单通知 id
        for i in 0..<8 { ids.append("reminder-\(reminder.syncId.uuidString)-\(i)") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 发送一条测试通知（延迟 seconds 秒），用于验证授权与横幅弹出是否正常。
    /// completion 回调在主线程返回是否成功排程（false 表示未授权，需去系统设置手动开启）。
    static func sendTest(after seconds: TimeInterval = 5, completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard authorized else {
                // 未授权时主动再申请一次；若仍失败则回调 false
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted {
                        scheduleTest(after: seconds, completion: completion)
                    } else {
                        DispatchQueue.main.async { completion(false) }
                    }
                }
                return
            }
            scheduleTest(after: seconds, completion: completion)
        }
    }

    private static func scheduleTest(after seconds: TimeInterval, completion: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "测试通知"
        content.body = "如果你看到这条通知，说明提醒功能正常 🎉"
        content.sound = .default
        content.badge = 1

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: "test-notification-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            DispatchQueue.main.async {
                if let error {
                    print("[通知] 测试通知排程失败: \(error)")
                    completion(false)
                } else {
                    completion(true)
                }
            }
        }
    }
}

// MARK: - 每天使用提醒（每晚定时汇总记账/饮食/健康/待办）
extension ReminderNotificationManager {
    static let dailyCheckinID = "daily-checkin"
    static let dailyCheckinCategory = "dailyCheckin"
    static let dailyEnabledKey = "dailyCheckinReminderEnabled"
    static let dailyHourKey = "dailyCheckinReminderHour"
    static let dailyMinuteKey = "dailyCheckinReminderMinute"

    /// 注册带 4 个操作按钮的通知 category（didFinishLaunching 调一次）
    static func registerDailyCheckinCategory() {
        let actions = [
            UNNotificationAction(identifier: "route:bill",   title: "记账",   options: .foreground),
            UNNotificationAction(identifier: "route:diet",   title: "记饮食", options: .foreground),
            UNNotificationAction(identifier: "route:health", title: "记健康", options: .foreground),
            UNNotificationAction(identifier: "route:todo",   title: "看待办", options: .foreground),
        ]
        let category = UNNotificationCategory(
            identifier: dailyCheckinCategory, actions: actions,
            intentIdentifiers: [], options: [])
        // 累加注册：读取已有 categories 再插入，避免覆盖掉「截图识别」等其它 category。
        center.getNotificationCategories { existing in
            var set = existing
            set.insert(category)
            center.setNotificationCategories(set)
        }
    }

    static func cancelDailyCheckin() {
        center.removePendingNotificationRequests(withIdentifiers: [dailyCheckinID])
    }

    /// 用最新时间 + 当天数据重排程（identifier 固定 → 幂等覆盖，不会累积多条）
    static func rescheduleDailyCheckin(context: ModelContext, hour: Int, minute: Int) {
        cancelDailyCheckin()
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = dailyCheckinTitle()                 // 标题轮换，避免每天雷同
        content.body = buildDailyCheckinBody(context: context)
        content.sound = .default
        content.categoryIdentifier = dailyCheckinCategory
        // 点正文 → 进 App 后弹「每日小结」弹窗（route=dailySummary，ContentView 拦截）
        content.userInfo = ["route": "dailySummary"]

        let request = UNNotificationRequest(identifier: dailyCheckinID,
                                            content: content, trigger: trigger)
        center.add(request) { error in
            if let error { print("[通知] 每日打卡排程失败: \(error)") }
        }
    }

    /// 标题轮换，提升新鲜感（用户点开不像被打卡机催）
    private static func dailyCheckinTitle() -> String {
        let pool = ["今日小结", "晚安小结", "今天过得怎样", "每日回顾", "今日小账本"]
        return pool.randomElement() ?? "每天使用提醒"
    }

    /// 动态文案：采用用户给定话术（正向、轻邀请、无压力）
    /// 注：「待办」口径 = 今日到期且未完成（不含 due=nil 的未安排事项）
    private static func buildDailyCheckinBody(context: ModelContext) -> String {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let pFood   = #Predicate<FoodEntry>    { !$0.syncDeleted && $0.date >= dayStart && $0.date < dayEnd }
        let pBill   = #Predicate<Bill>         { !$0.syncDeleted && $0.time >= dayStart && $0.time < dayEnd }
        let pHealth = #Predicate<HealthMetric> { !$0.syncDeleted && $0.date >= dayStart && $0.date < dayEnd }
        // 今日待办：今天到期（due 落在当天区间）且未完成
        let pTodoToday = #Predicate<Reminder> {
            !$0.syncDeleted && !$0.done && $0.due != nil && $0.due! >= dayStart && $0.due! < dayEnd
        }

        let hasFood   = (try? context.fetch(FetchDescriptor(predicate: pFood))).map { !$0.isEmpty }   ?? false
        let hasBill   = (try? context.fetch(FetchDescriptor(predicate: pBill))).map { !$0.isEmpty }   ?? false
        let hasHealth = (try? context.fetch(FetchDescriptor(predicate: pHealth))).map { !$0.isEmpty } ?? false
        let todoTodayCount = (try? context.fetch(FetchDescriptor(predicate: pTodoToday)))?.count       ?? 0

        var doneMods: [String] = []
        if hasBill   { doneMods.append("账单") }
        if hasFood   { doneMods.append("饮食") }
        if hasHealth { doneMods.append("健康") }

        // ① 全记齐 + 今日无待办：纯鼓励
        if doneMods.count == 3 && todoTodayCount == 0 {
            return "今天账单、饮食、健康、待办都ok啦，真棒 ✨ 进来复盘一下吗~"
        }

        // ② 记了一部分：已搞定模块点名 + 未记模块「翻牌」
        if !doneMods.isEmpty {
            let pendingMods = (["账单", "饮食", "健康"] as [String]).filter { !doneMods.contains($0) }
            var pendingText = pendingMods.joined(separator: "、")
            if todoTodayCount > 0 { pendingText += (pendingText.isEmpty ? "" : "、") + "待办" }
            return "叮咚～今天的「\(doneMods.joined(separator: "、"))」已搞定，\(pendingText)等着你翻牌 🌙"
        }

        // ③ 一条都没记：极轻柔
        if todoTodayCount > 0 {
            return "今天还没来得及记点什么？有空随手记一笔也挺好 📝 还有 \(todoTodayCount) 件待办在等你翻牌~"
        }
        return "今天还没来得及记点什么？有空随手记一笔也挺好 📝"
    }

    /// 从 UserDefaults 读取开关与时间；开启时用最新数据重排程。
    /// 供设置页开关/改时间与 App 进前台统一调用，避免重复逻辑、也避免外部直接持有 ModelContext。
    static func rescheduleFromStoredDefaults() {
        guard let container = AppDelegate.sharedContainer else { return }
        if UserDefaults.standard.bool(forKey: dailyEnabledKey) {
            let h = UserDefaults.standard.integer(forKey: dailyHourKey)
            let m = UserDefaults.standard.integer(forKey: dailyMinuteKey)
            rescheduleDailyCheckin(context: ModelContext(container), hour: h, minute: m)
        } else {
            cancelDailyCheckin()
        }
        // 健康目标提醒独立子开关，但排程需 ModelContext（这里统一处理取消/重排）。
        rescheduleHealthGoalReminder(context: ModelContext(container))
        // >>> CHANGE-[2026-08-18 18:28:46]-[睡眠提醒排程] 开始
        // 原因: 新增"睡觉提醒"独立功能，默认开+默认23:00，点通知进首页并开始记录睡眠。
        // 回退: 删除本段 + 删除文件末尾 sleepReminder extension 即可。
        rescheduleSleepReminder()
        // <<< CHANGE-[2026-08-18 18:28:46]-[睡眠提醒排程] 结束
        // >>> CHANGE-[2026-08-24 09:26:09]-[每天记录提醒排程] 开始
        // 原因: 新增"每天记录提醒"独立功能，默认开+默认9:00，点通知回首页宫格。
        // 回退: 删除本段 + 删除文件末尾 morningReminder extension 即可。
        rescheduleMorningReminder()
        // <<< CHANGE-[2026-08-24 09:26:09]-[每天记录提醒排程] 结束
    }
}

// >>> CHANGE-[2026-08-18 18:28:46]-[睡眠提醒扩展] 开始
// MARK: - 睡觉提醒（独立开关，默认开、默认 23:00）
// 到点发「睡眠时间到咯」提醒，点通知进首页并自动开始记录睡眠时间（弹睡眠遮罩）。
extension ReminderNotificationManager {
    static let sleepReminderID = "sleep-reminder"
    static let sleepEnabledKey = "sleepReminderEnabled"
    static let sleepHourKey = "sleepReminderHour"
    static let sleepMinuteKey = "sleepReminderMinute"

    /// 从 UserDefaults 读开关/时间，开启则排程、关闭则取消。identifier 固定 → 幂等覆盖。
    static func rescheduleSleepReminder() {
        guard UserDefaults.standard.bool(forKey: sleepEnabledKey) else {
            cancelSleepReminder()
            return
        }
        let h = UserDefaults.standard.integer(forKey: sleepHourKey)
        let m = UserDefaults.standard.integer(forKey: sleepMinuteKey)
        let content = UNMutableNotificationContent()
        content.title = "睡眠时间到咯"
        content.body = "快美美的睡上一觉吧，晚安😴"
        content.sound = .default
        // route=sleepReminder → ContentView.consumeNotificationRoute 拦截：
        // 回首页 + 自动开始一次睡眠记录 + 弹遮罩。
        content.userInfo = ["route": "sleepReminder"]
        let trigger = makeDailyTrigger(hour: h, minute: m)
        let request = UNNotificationRequest(identifier: sleepReminderID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[通知] 睡觉提醒排程失败: \(error)") }
        }
    }

    static func cancelSleepReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [sleepReminderID])
    }
}
// <<< CHANGE-[2026-08-18 18:28:46]-[睡眠提醒扩展] 结束

// >>> CHANGE-[2026-08-24 09:26:09]-[每天记录提醒扩展] 开始
// MARK: - 每天记录提醒（独立开关，默认开、默认 9:00）
// 早上发「美好的一天从好记开始」早安问候，点通知直接回首页宫格。
extension ReminderNotificationManager {
    static let morningReminderID = "morning-reminder"
    static let morningEnabledKey = "morningReminderEnabled"
    static let morningHourKey = "morningReminderHour"
    static let morningMinuteKey = "morningReminderMinute"

    /// 从 UserDefaults 读开关/时间，开启则排程、关闭则取消。identifier 固定 → 幂等覆盖。
    static func rescheduleMorningReminder() {
        guard UserDefaults.standard.bool(forKey: morningEnabledKey) else {
            cancelMorningReminder()
            return
        }
        let h = UserDefaults.standard.integer(forKey: morningHourKey)
        let m = UserDefaults.standard.integer(forKey: morningMinuteKey)
        let content = UNMutableNotificationContent()
        content.title = "美好的一天从「好记」开始"
        content.body = "账单、待办、饮食、健康都能帮你记☺️"
        content.sound = .default
        // route=home → ContentView.consumeNotificationRoute 已有拦截，弹回首页宫格主界面。
        content.userInfo = ["route": "home"]
        let trigger = makeDailyTrigger(hour: h, minute: m)
        let request = UNNotificationRequest(identifier: morningReminderID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[通知] 每天记录提醒排程失败: \(error)") }
        }
    }

    static func cancelMorningReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [morningReminderID])
    }
}
// <<< CHANGE-[2026-08-24 09:26:09]-[每天记录提醒扩展] 结束

// MARK: - 健康目标傍晚提醒
/// 傍晚（默认 19:00）发一条轻提醒，提示用户今天步数 / 饮水目标还没完成，
/// 动一动、喝口水。文案固定（不动态判断未达成，避免误报），与每日提醒共用总开关。
extension ReminderNotificationManager {
    static let healthGoalReminderID = "health-goal-reminder"
    static let healthGoalEnabledKey = "healthGoalReminderEnabled"
    static let healthGoalHourKey = "healthGoalReminderHour"
    static let healthGoalMinuteKey = "healthGoalReminderMinute"

    /// 排程傍晚健康目标提醒。开启条件：每日提醒总开关开启 + 健康目标子开关开启。
    static func rescheduleHealthGoalReminder(context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: healthGoalEnabledKey) else {
            cancelHealthGoalReminder()
            return
        }
        let h = UserDefaults.standard.integer(forKey: healthGoalHourKey)
        let m = UserDefaults.standard.integer(forKey: healthGoalMinuteKey)
        let content = UNMutableNotificationContent()
        content.title = "今日健康小目标"
        content.body = "今天步数 / 饮水目标还没完成，动一动、喝口水，让身体更舒服一点 💧"
        content.sound = .default
        content.userInfo = ["route": "health"]
        let trigger = makeDailyTrigger(hour: h, minute: m)
        let request = UNNotificationRequest(identifier: healthGoalReminderID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[通知] 健康目标提醒排程失败: \(error)") }
        }
    }

    static func cancelHealthGoalReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [healthGoalReminderID])
    }

    /// 由「时:分」构造本地每日重复触发器。
    private static func makeDailyTrigger(hour: Int, minute: Int) -> UNCalendarNotificationTrigger {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        return UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
    }
}
