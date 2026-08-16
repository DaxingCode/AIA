// AppFormat.swift
// 通用格式工具，主 App 与 Widget Extension 共享。
import Foundation

// MARK: - 日期格式化（统一 ISO8601，禁止裸用 ISO8601DateFormatter()）
public enum AppFormat {
    public static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public         static let isoDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        // 纯日期串必须按上海时区生成/解析，不能留默认 UTC。
        // 否则每日上海 0:00–8:00（清晨）的绝对时间被 UTC 格式化成「前一天」，
        // 导致 Siri/聊天记「早餐」这类无时刻语句掉到昨天（见 2026-08-11 修复）。
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
        }()

    public static let isoLocal: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    // 不带毫秒/微秒的 ISO 解析器。
    // 云端视觉模型（如通义千问）返回的时间通常是 `2026-08-12T14:43:43+08:00`，
    // `iso`/`isoLocal` 因带 `.withFractionalSeconds` 反而解析失败 → 返回 nil → 账单时间 fallback 到 0:00。
    public static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static let isoLocalNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    // MARK: - 显示用（带本地化）
    public static let yearMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    public static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    public static let monthDayWeek: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEE"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    public static let hourMinute: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    public static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    public static let fullDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    public static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    public static let yearMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    // MARK: - 金额格式化
    public static func money(_ value: Double) -> String {
        let absVal = abs(value)
        let formatted: String
        if absVal.truncatingRemainder(dividingBy: 1) == 0 {
            formatted = String(format: "%.0f", absVal)
        } else {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.minimumFractionDigits = 2
            nf.maximumFractionDigits = 2
            formatted = nf.string(from: NSNumber(value: absVal)) ?? String(format: "%.2f", absVal)
        }
        let sign = value < 0 ? "-" : ""
        return "\(sign)¥\(formatted)"
    }

    public static func moneyPlain(_ value: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 2
        return "¥" + (nf.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }

    public static func signedMoney(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "-"
        return "\(sign)\(moneyPlain(abs(value)))"
    }
}

// MARK: - 数字/文本小工具
public enum AppText {
    /// 把 12345 之类的数字转成「1.2万」中文紧凑显示。
    public static func compact(_ n: Int) -> String {
        if n < 10000 { return "\(n)" }
        let wan = Double(n) / 10000.0
        return String(format: wan.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f万" : "%.1f万", wan)
    }

    public static func percent(_ value: Double) -> String {
        let clamped = max(0, min(1, value))
        return "\(Int(round(clamped * 100)))%"
    }
}
