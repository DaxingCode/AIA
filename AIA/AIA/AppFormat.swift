// AppFormat.swift
// 全局统一日期/时间格式化：强制中文（zh_CN）+ 24 小时制，避免系统语言为英文时显示 Jul / 12 小时制。
import Foundation

enum AppFormat {
    /// "7月17日 16:46"（24 小时制，含具体时间）
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// "7月17日"（仅日期，无时间）
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    /// "16:46"（24 小时制，仅时间）
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "2026年7月"（日历月份标题）
    static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f
    }()
}
