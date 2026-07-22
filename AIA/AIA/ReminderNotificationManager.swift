// ReminderNotificationManager.swift
// 待办本地通知调度：申请权限、按 remindAt 排程、完成/删除时取消。
import Foundation
import UserNotifications

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
    static func schedule(_ reminder: Reminder) -> Bool {
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
