// >>> CHANGE-[2026-08-30 14:06:01]-[版本更新弹窗] 开始
// 建议更新版本比对工具：本地版本 vs 云端 latestVersion，命中则提示。
// 纯函数 + 读 UserDefaults，不碰 SwiftData/网络/副作用。
import Foundation

enum VersionUpdateChecker {
    /// 本地 App 版本号，如 "1.0.1"。取不到时返回空串（不会触发更新提示）。
    static func currentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// 点分版本号逐段比较：a 是否严格旧于 b。
    /// 例：isOlder("1.0.1", than: "1.0.2") == true；isOlder("1.10", than: "1.9") == false（字符串比会错，此处正确）。
    static func isOlder(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        guard !pa.isEmpty, !pb.isEmpty else { return false }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// 用户已「暂不」忽略的版本号（存 UserDefaults，云端 latestVersion 变大后才会重新弹）。
    /// 注意：本工具是纯 Swift 类型，不能用 SwiftUI 的 @AppStorage，直接读 UserDefaults。
    private static let skipVersionKey = "aia.updateSkipVersion"
    private static var skipVersion: String {
        get { UserDefaults.standard.string(forKey: skipVersionKey) ?? "" }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: skipVersionKey) }
    }

    /// 是否应该弹「建议更新」弹窗。
    static func shouldSuggestUpdate() -> Bool {
        guard let latest = GlobalConfigStore.shared.latestVersion, !latest.isEmpty else { return false }
        let cur = currentVersion()
        guard !cur.isEmpty else { return false }
        guard isOlder(cur, than: latest) else { return false }   // 本地已是最新/更高
        return skipVersion != latest                              // 已忽略过的版本不重复弹
    }

    /// 用户点「暂不」/点遮罩关闭时调用，记录当前 latestVersion 为已忽略。
    static func markSkipped() {
        skipVersion = GlobalConfigStore.shared.latestVersion ?? ""
    }
}
// <<< CHANGE-[2026-08-30 14:06:01]-[版本更新弹窗] 结束
