// UsageAnalytics.swift
// 使用行为埋点：把「本身不落数据的行为」（启动、登录、页面访问、识别发起、导出等）上报到
// 云端 aia_events 集合，配合 aia_records 里的业务数据，供开发者中心「数据统计与导出」跨用户分析。
//
// 设计要点：
// - fire-and-forget：任何失败一律忽略，绝不阻塞或影响主流程 UI。
// - 批量缓冲：事件先进内存队列并持久化到 UserDefaults，满 10 条 / 距上次 60s / 进后台 时才批量上报，
//   把云函数调用次数压到最低（用户在意云调用成本），离线时也不会丢。
// - 队列上限 300 条，超出丢弃最老的，避免长期离线撑爆 UserDefaults。
// - userId 复用 CloudSyncManager.userId（登录账号 / 小程序绑定码 / 设备级随机 UUID），
//   与业务数据同一分区键，统计时能把行为和数据对上。
import Foundation
import UIKit

enum UsageAnalytics {

    // MARK: - 配置

    /// 总开关（预留：将来做隐私设置时可关闭）。
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "aia.analytics.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "aia.analytics.enabled") }
    }

    private static let queueKey = "aia.analytics.pending"
    private static let maxPending = 300
    private static let flushThreshold = 10
    private static let flushInterval: TimeInterval = 60

    /// 串行队列保护 pending 读写（log 可能来自任意线程）。
    /// 标 nonisolated：flush()/log() 常从 Task.detached（非隔离上下文）访问，
    /// 避免 Swift 6 下「main actor-isolated 属性从外部访问」报错。
    nonisolated private static let lock = DispatchQueue(label: "aia.analytics.queue")
    // 这两个状态只在 lock 串行队列内读写，线程安全；用 nonisolated(unsafe) 绕过
    // 隔离检查，使 Task.detached（非隔离）上下文可访问，避免 Swift 6 下「main actor-isolated」报错。
    nonisolated(unsafe) private static var lastFlushAt: Date = .distantPast
    nonisolated(unsafe) private static var isFlushing = false

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    // MARK: - 记录

    /// 记录一次行为。可在任意线程调用，立即返回。
    /// - Parameters:
    ///   - event: 事件名。带维度时直接拼进名字（如 `record_add:bill`），云端统计表可读性更好。
    ///   - meta: 附加信息（可选），只允许 JSON 基本类型。
    static func log(_ event: String, meta: [String: Any]? = nil) {
        guard enabled, !event.isEmpty else { return }
        var item: [String: Any] = ["event": event, "ts": Date().timeIntervalSince1970]
        if let meta, !meta.isEmpty, JSONSerialization.isValidJSONObject(meta) {
            item["meta"] = meta
        }
        lock.async {
            var pending = loadPending()
            pending.append(item)
            if pending.count > maxPending { pending.removeFirst(pending.count - maxPending) }
            savePending(pending)
            let due = pending.count >= flushThreshold || Date().timeIntervalSince(lastFlushAt) > flushInterval
            if due { flushLocked() }
        }
    }

    /// 每天最多记一次（用于「日活」类事件，避免同一天重复上报）。
    static func logDaily(_ event: String, meta: [String: Any]? = nil) {
        let key = "aia.analytics.daily.\(event)"
        let today = dayString(Date())
        guard UserDefaults.standard.string(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        log(event, meta: meta)
    }

    /// 会话开始：距上次前台活动超过 30 分钟才算一次新会话（衡量真实打开频次）。
    static func logSessionStart() {
        let key = "aia.analytics.lastActiveAt"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: key)
        guard last <= 0 || now - last > 30 * 60 else { return }
        log("session_start")
    }

    /// 页面/功能访问。name 建议用稳定英文短名（diet / health / bill / todo / chat / report …）。
    static func logOpen(_ name: String) {
        log("feature_open:\(name)")
    }

    /// 新增一条业务记录（bill / food / health / todo / water）。
    static func logAdd(_ type: String, source: String? = nil) {
        log("record_add:\(type)", meta: source.map { ["source": $0] })
    }

    // MARK: - 上报

    /// 立刻把缓冲区里的事件送出（App 进后台、退出统计页时调用）。
    static func flush() {
        lock.async { flushLocked() }
    }

    /// 必须在 lock 队列内调用。
    private static func flushLocked() {
        guard enabled, !isFlushing else { return }
        let pending = loadPending()
        guard !pending.isEmpty else { return }
        let batch = Array(pending.prefix(100))
        isFlushing = true
        lastFlushAt = Date()

        let body: [String: Any] = [
            "action": "logEvent",
            "userId": CloudSyncManager.userId,
            "platform": "ios",
            "appVersion": appVersion,
            "events": batch
        ]
        Task.detached(priority: .background) {
            var ok = false
            do {
                let resp = try await postAdsJSON(body)
                ok = (resp["ok"] as? Bool) == true
            } catch {
                ok = false
            }
            lock.async {
                isFlushing = false
                guard ok else { return }   // 失败保留缓冲，下次再试
                var rest = loadPending()
                if rest.count >= batch.count { rest.removeFirst(batch.count) } else { rest = [] }
                savePending(rest)
            }
        }
    }

    // MARK: - 缓冲区持久化

    private static func loadPending() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: queueKey),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private static func savePending(_ items: [[String: Any]]) {
        guard JSONSerialization.isValidJSONObject(items),
              let data = try? JSONSerialization.data(withJSONObject: items) else { return }
        UserDefaults.standard.set(data, forKey: queueKey)
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: d)
    }
}

// MARK: - 统计结果模型

/// 云端聚合出的总体概览。
struct UsageStatsSummary: Equatable {
    var totalUsers: Int = 0
    var activeUsers7d: Int = 0
    var activeUsers30d: Int = 0
    var totalRecords: Int = 0
    var totalEvents: Int = 0
    var topFeature: String = "-"
    var topFeatureUsers: Int = 0
    var dateSpanStart: String = ""
    var dateSpanEnd: String = ""

    init() {}

    init(json: [String: Any]) {
        totalUsers = (json["totalUsers"] as? NSNumber)?.intValue ?? 0
        activeUsers7d = (json["activeUsers7d"] as? NSNumber)?.intValue ?? 0
        activeUsers30d = (json["activeUsers30d"] as? NSNumber)?.intValue ?? 0
        totalRecords = (json["totalRecords"] as? NSNumber)?.intValue ?? 0
        totalEvents = (json["totalEvents"] as? NSNumber)?.intValue ?? 0
        topFeature = json["topFeature"] as? String ?? "-"
        topFeatureUsers = (json["topFeatureUsers"] as? NSNumber)?.intValue ?? 0
        dateSpanStart = json["dateSpanStart"] as? String ?? ""
        dateSpanEnd = json["dateSpanEnd"] as? String ?? ""
    }
}

/// 一张可导出的统计表。
struct UsageStatsTable: Identifiable, Equatable {
    let id = UUID()
    /// 文件名，如 `3_功能渗透率.csv`
    let fileName: String
    /// 完整 CSV 文本（云端已加 BOM，Excel 打开中文不乱码）
    let csv: String

    /// 去掉序号前缀和扩展名后的展示标题。
    var title: String {
        var s = fileName
        if let dot = s.range(of: ".csv") { s = String(s[s.startIndex..<dot.lowerBound]) }
        if let us = s.firstIndex(of: "_"), s[s.startIndex..<us].allSatisfy({ $0.isNumber }) {
            s = String(s[s.index(after: us)...])
        }
        return s
    }

    /// 数据行数（不含表头）。
    var rowCount: Int {
        max(0, csv.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
    }

    /// 预览用的前若干行（已拆成单元格）。
    func previewRows(limit: Int = 8) -> [[String]] {
        let clean = csv.hasPrefix("\u{FEFF}") ? String(csv.dropFirst()) : csv
        return clean.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(limit)
            .map { parseCSVLine(String($0)) }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if inQuote {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" { cur.append("\""); i = next }
                    else { inQuote = false }
                } else { cur.append(c) }
            } else {
                if c == "\"" { inQuote = true }
                else if c == "," { out.append(cur); cur = "" }
                else { cur.append(c) }
            }
            i = line.index(after: i)
        }
        out.append(cur)
        return out
    }
}

struct UsageStatsResult {
    var summary: UsageStatsSummary
    var tables: [UsageStatsTable]
}

extension UsageAnalytics {

    /// 拉取跨用户使用统计（开发者专用，需口令）。
    static func fetchStats(days: Int = 90) async throws -> UsageStatsResult {
        let body: [String: Any] = [
            "action": "stats",
            "passcode": DeveloperGate.passcode,
            "days": days
        ]
        let json = try await postAdsJSON(body)
        guard (json["ok"] as? Bool) == true else {
            let msg = json["error"] as? String ?? "统计接口返回失败"
            throw NSError(domain: "stats", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let summary = UsageStatsSummary(json: json["summary"] as? [String: Any] ?? [:])
        let raw = json["csvs"] as? [String: String] ?? [:]
        let tables = raw.keys.sorted().map { UsageStatsTable(fileName: $0, csv: raw[$0] ?? "") }
        return UsageStatsResult(summary: summary, tables: tables)
    }

    /// 把若干张表写到临时目录，返回文件 URL 列表（供 ShareSheet 分享）。
    static func writeTempFiles(_ tables: [UsageStatsTable]) -> [URL] {
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmm"
            return f.string(from: Date())
        }()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIA使用统计-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for t in tables {
            let url = dir.appendingPathComponent(t.fileName)
            if (try? t.csv.write(to: url, atomically: true, encoding: .utf8)) != nil {
                urls.append(url)
            }
        }
        return urls
    }
}
