// GlobalConfigStore.swift
// 全局配置（智能问答开关 + AI 模型）。
// 权威来源在云端 aia_config 集合：开发者在「开发者中心」切换后写入云端，
// 所有用户启动时 / 回到前台拉取并自动跟随（生命周期驱动，不常驻轮询），普通用户无入口也无法自行切换。
// 本地 UserDefaults 仅作缓存，GlobalConfigStore 负责与云端同步。
import Foundation
import Combine

@MainActor
final class GlobalConfigStore: ObservableObject {
    static let shared = GlobalConfigStore()

    // 发布属性 setter 公开：视图可用自定义 Binding 做「即时本地更新 + 写云端」副作用。
    // 真正落库（UserDefaults + 云端）统一走 applyToLocal / saveConfig，避免别处误写。
    @Published var agentEnabled: Bool
    @Published var modelProvider: String
    @Published var visionModelProvider: String

    // —— 免费额度（付费墙）配置，开发者中心读写 ——
    @Published var freeQuotaEnabled: Bool
    @Published var freeQuotaPerMonth: Int
    /// 各云功能消耗权重；缺省按 1。键为 PaidFeature.rawValue。
    @Published var freeQuotaWeights: [String: Int]
    @Published var freeQuotaDailyCap: Int
    /// 全局月度总额度（成本熔断）；0 表示不熔断。
    @Published var freeQuotaGlobalMonthly: Int
    /// 全平台本月已用次数（来自 aia_quota_usage GLOBAL:yyyyMM）。
    @Published var freeQuotaGlobalUsed: Int
    /// 全平台本月剩余次数；-1 表示未设全局上限。
    @Published var freeQuotaGlobalRemaining: Int

    // —— 免费试用天数（全局下发，所有用户跟随；开发者中心读写）——
    @Published var trialDays: Int

    // —— 应用内公告（开发者中心群发，所有用户打开 App 时拉取并展示）——
    @Published var announcement: AnnouncementPayload?

    // —— 协议链接（云端下发，AppURLs 带本地兜底）——
    @Published var privacyPolicyUrl: URL?
    @Published var userAgreementUrl: URL?
    // 首页顶栏「App 功能介绍」灯泡按钮链接（云端下发，普通用户无入口，留空=App 内置默认）
    @Published var featureIntroUrl: URL?

    private let agentKey = "aia.agentEnabled"
    private let modelKey = "aia.modelProvider"
    private let visionKey = "aia.visionModelProvider"
    private let fqEnabledKey = "aia.freeQuotaEnabled"
    private let fqPerMonthKey = "aia.freeQuotaPerMonth"
    private let fqWeightsKey = "aia.freeQuotaWeights"
    private let fqDailyCapKey = "aia.freeQuotaDailyCap"
    private let fqGlobalKey = "aia.freeQuotaGlobalMonthly"
    private let fqGlobalUsedKey = "aia.freeQuotaGlobalUsed"
    private let fqGlobalRemainKey = "aia.freeQuotaGlobalRemaining"
    private let trialDaysKey = "aia.trialDays"
    private let announcementKey = "aia.announcement"
    private let privacyKey = "aia.privacyPolicyUrl"
    private let agreementKey = "aia.userAgreementUrl"
    private let featureIntroKey = "aia.featureIntroUrl"

    private init() {
        let ud = UserDefaults.standard
        self.agentEnabled = ud.bool(forKey: agentKey)
        self.modelProvider = ud.string(forKey: modelKey) ?? "glm"
        self.visionModelProvider = ud.string(forKey: visionKey) ?? "glm"
        self.freeQuotaEnabled = ud.bool(forKey: fqEnabledKey)
        self.freeQuotaPerMonth = ud.integer(forKey: fqPerMonthKey)
        self.freeQuotaWeights = (ud.dictionary(forKey: fqWeightsKey) as? [String: Int]) ?? [:]
        self.freeQuotaDailyCap = ud.integer(forKey: fqDailyCapKey)
        self.freeQuotaGlobalMonthly = ud.integer(forKey: fqGlobalKey)
        self.freeQuotaGlobalUsed = ud.integer(forKey: fqGlobalUsedKey)
        self.freeQuotaGlobalRemaining = ud.object(forKey: fqGlobalRemainKey) == nil ? -1 : ud.integer(forKey: fqGlobalRemainKey)
        // 试用天数：本地缓存优先；未设置过时默认 7（云端未下发前 7 天体验生效）
        self.trialDays = ud.object(forKey: trialDaysKey) == nil ? 7 : ud.integer(forKey: trialDaysKey)
        self.announcement = AnnouncementPayload.load(from: ud, key: announcementKey)
        self.privacyPolicyUrl = ud.string(forKey: privacyKey).flatMap { URL(string: $0) }
        self.userAgreementUrl = ud.string(forKey: agreementKey).flatMap { URL(string: $0) }
        self.featureIntroUrl = ud.string(forKey: featureIntroKey).flatMap { URL(string: $0) }
    }

    /// 从云端拉取全局配置，写回本地缓存。公开接口，所有用户均可调用。
    func fetchConfig() async {
        do {
            let resp = try await postAdsJSON(["action": "getConfig"])
            guard resp["ok"] as? Bool == true else {
                print("[GlobalConfig] getConfig 返回 ok != true: \(resp)")
                return
            }
            let agent = (resp["agentEnabled"] as? Bool) ?? false
            let model = (resp["modelProvider"] as? String)?.nonEmpty ?? "glm"
            let vision = (resp["visionModelProvider"] as? String)?.nonEmpty ?? "glm"
            // 防清零：云端 resp 缺字段时保持本地现有值，绝不被默认值覆盖。
            let fqEnabled = resp.keys.contains("freeQuotaEnabled") ? (resp["freeQuotaEnabled"] as? Bool ?? false) : self.freeQuotaEnabled
            let fqPerMonth = resp.keys.contains("freeQuotaPerMonth") ? (resp["freeQuotaPerMonth"] as? Int ?? 0) : self.freeQuotaPerMonth
            let fqWeights = resp.keys.contains("freeQuotaWeights") ? (resp["freeQuotaWeights"] as? [String: Int] ?? [:]) : self.freeQuotaWeights
            let fqDailyCap = resp.keys.contains("freeQuotaDailyCap") ? (resp["freeQuotaDailyCap"] as? Int ?? 0) : self.freeQuotaDailyCap
            let fqGlobal = resp.keys.contains("freeQuotaGlobalMonthly") ? (resp["freeQuotaGlobalMonthly"] as? Int ?? 0) : self.freeQuotaGlobalMonthly
            let fqGlobalUsed = resp.keys.contains("freeQuotaGlobalUsed") ? (resp["freeQuotaGlobalUsed"] as? Int ?? 0) : self.freeQuotaGlobalUsed
            let fqGlobalRemain = resp.keys.contains("freeQuotaGlobalRemaining") ? (resp["freeQuotaGlobalRemaining"] as? Int ?? -1) : self.freeQuotaGlobalRemaining
            // 试用天数：云端缺字段时保持本地现有值（防清零）。
            let trialDays = resp.keys.contains("trialDays") ? (resp["trialDays"] as? Int ?? 7) : self.trialDays
            // 公告：云端缺字段时保持本地现有值（防清零）。announcement 可为 null（已撤销）。
            let ann: AnnouncementPayload? = resp.keys.contains("announcement")
                ? AnnouncementPayload.parse(resp["announcement"]) : self.announcement
            // 协议链接：云端缺字段时保持本地现有值（防清零）。
            let privacy = resp.keys.contains("privacyPolicyUrl")
                ? (resp["privacyPolicyUrl"] as? String).flatMap { URL(string: $0) } ?? self.privacyPolicyUrl
                : self.privacyPolicyUrl
            let agreement = resp.keys.contains("userAgreementUrl")
                ? (resp["userAgreementUrl"] as? String).flatMap { URL(string: $0) } ?? self.userAgreementUrl
                : self.userAgreementUrl
            // 灯泡功能介绍链接，云端缺字段时保持本地值（防清零）。
            let featureIntro = resp.keys.contains("featureIntroUrl")
                ? (resp["featureIntroUrl"] as? String).flatMap { URL(string: $0) } ?? self.featureIntroUrl
                : self.featureIntroUrl
            // 仅当配置真正变化时才打印，避免每次拉取都刷日志（启动/回前台拉取为常态）。
            if applyToLocal(agentEnabled: agent, modelProvider: model, visionModelProvider: vision,
                            freeQuotaEnabled: fqEnabled, freeQuotaPerMonth: fqPerMonth, freeQuotaWeights: fqWeights,
                            freeQuotaDailyCap: fqDailyCap, freeQuotaGlobalMonthly: fqGlobal,
                            freeQuotaGlobalUsed: fqGlobalUsed, freeQuotaGlobalRemaining: fqGlobalRemain,
                            trialDays: trialDays,
                            announcement: ann, privacyPolicyUrl: privacy, userAgreementUrl: agreement,
                            featureIntroUrl: featureIntro) {
                print("[GlobalConfig] 已同步云端配置 agent=\(agent) model=\(model) vision=\(vision) freeQuota=\(fqEnabled)/\(fqPerMonth) trialDays=\(trialDays)")
            }
        } catch {
            print("[GlobalConfig] fetchConfig 失败: \(error)")
        }
    }

    /// 开发者写入：推到云端并同步本地缓存。需口令，普通调用方拿不到 DeveloperGate.passcode。
    func saveConfig(agentEnabled: Bool, modelProvider: String, visionModelProvider: String) async {
        do {
            let resp = try await postAdsJSON([
                "action": "setConfig",
                "devToken": DeveloperGate.devToken ?? "",
                "agentEnabled": agentEnabled,
                "modelProvider": modelProvider,
                "visionModelProvider": visionModelProvider
            ])
            guard resp["ok"] as? Bool == true else {
                print("[GlobalConfig] setConfig 云端返回失败: \(resp)")
                return
            }
            _ = applyToLocal(agentEnabled: agentEnabled, modelProvider: modelProvider, visionModelProvider: visionModelProvider)
            print("[GlobalConfig] 已写入云端配置 agent=\(agentEnabled) model=\(modelProvider) vision=\(visionModelProvider)")
        } catch {
            print("[GlobalConfig] setConfig 失败: \(error)")
        }
    }

    /// 开发者写入免费额度配置（需口令，普通用户无入口）。返回是否成功。
    func saveFreeQuota(freeQuotaEnabled: Bool, freeQuotaPerMonth: Int, freeQuotaWeights: [String: Int],
                       freeQuotaDailyCap: Int, freeQuotaGlobalMonthly: Int) async -> Bool {
        do {
            let resp = try await postAdsJSON([
                "action": "setConfig",
                "devToken": DeveloperGate.devToken ?? "",
                "freeQuotaEnabled": freeQuotaEnabled,
                "freeQuotaPerMonth": freeQuotaPerMonth,
                "freeQuotaWeights": freeQuotaWeights,
                "freeQuotaDailyCap": freeQuotaDailyCap,
                "freeQuotaGlobalMonthly": freeQuotaGlobalMonthly
            ])
            guard resp["ok"] as? Bool == true else {
                NSLog("[GlobalConfig] saveFreeQuota 云端返回失败: \(resp)")
                return false
            }
            _ = applyToLocal(agentEnabled: self.agentEnabled, modelProvider: self.modelProvider, visionModelProvider: self.visionModelProvider,
                         freeQuotaEnabled: freeQuotaEnabled, freeQuotaPerMonth: freeQuotaPerMonth, freeQuotaWeights: freeQuotaWeights,
                         freeQuotaDailyCap: freeQuotaDailyCap, freeQuotaGlobalMonthly: freeQuotaGlobalMonthly,
                         freeQuotaGlobalUsed: self.freeQuotaGlobalUsed, freeQuotaGlobalRemaining: self.freeQuotaGlobalRemaining)
            NSLog("[GlobalConfig] 已写入免费额度配置 enabled=\(freeQuotaEnabled) perMonth=\(freeQuotaPerMonth) global=\(freeQuotaGlobalMonthly)")
            return true
        } catch {
            NSLog("[GlobalConfig] saveFreeQuota 失败: \(error)")
            return false
        }
    }

    // >>> CHANGE-[2026-08-19 20:55:27]-试用天数云端化 开始
    // 原因: 开发者中心可云端改全局试用天数, 所有用户下次拉取跟随(方案X)
    // 回退: 删除本方法 + fetchConfig 里 trialDays 分支
    /// 开发者写入全局试用天数（需口令）。写入成功后所有用户下次拉取 getConfig 生效。返回是否成功。
    func saveTrialDays(_ days: Int) async -> Bool {
        let clamped = max(1, min(days, 365))
        do {
            let resp = try await postAdsJSON([
                "action": "setConfig",
                "devToken": DeveloperGate.devToken ?? "",
                "trialDays": clamped
            ])
            guard resp["ok"] as? Bool == true else {
                NSLog("[GlobalConfig] saveTrialDays 云端返回失败: \(resp)")
                return false
            }
            _ = applyToLocal(agentEnabled: self.agentEnabled, modelProvider: self.modelProvider, visionModelProvider: self.visionModelProvider,
                             freeQuotaEnabled: self.freeQuotaEnabled, freeQuotaPerMonth: self.freeQuotaPerMonth,
                             freeQuotaWeights: self.freeQuotaWeights, freeQuotaDailyCap: self.freeQuotaDailyCap,
                             freeQuotaGlobalMonthly: self.freeQuotaGlobalMonthly,
                             freeQuotaGlobalUsed: self.freeQuotaGlobalUsed, freeQuotaGlobalRemaining: self.freeQuotaGlobalRemaining,
                             trialDays: clamped)
            NSLog("[GlobalConfig] 已写入全局试用天数: \(clamped)")
            return true
        } catch {
            NSLog("[GlobalConfig] saveTrialDays 失败: \(error)")
            return false
        }
    }
    // <<< CHANGE-[2026-08-19 20:55:27]-试用天数云端化 结束

    /// 开发者写入应用内公告（需口令）。announcement=nil 表示撤销当前公告。返回是否成功。
    func saveAnnouncement(_ announcement: AnnouncementPayload?) async -> Bool {
        do {
            var payload: [String: Any] = [
                "action": "setConfig",
                "devToken": DeveloperGate.devToken ?? "",
            ]
            if let a = announcement {
                payload["announcement"] = a.toCloudDict()
            } else {
                payload["announcement"] = NSNull()
            }
            let resp = try await postAdsJSON(payload)
            guard resp["ok"] as? Bool == true else {
                NSLog("[GlobalConfig] saveAnnouncement 云端返回失败: \(resp)")
                return false
            }
            _ = applyToLocal(agentEnabled: self.agentEnabled, modelProvider: self.modelProvider, visionModelProvider: self.visionModelProvider,
                             freeQuotaEnabled: self.freeQuotaEnabled, freeQuotaPerMonth: self.freeQuotaPerMonth,
                             freeQuotaWeights: self.freeQuotaWeights, freeQuotaDailyCap: self.freeQuotaDailyCap,
                             freeQuotaGlobalMonthly: self.freeQuotaGlobalMonthly,
                             freeQuotaGlobalUsed: self.freeQuotaGlobalUsed, freeQuotaGlobalRemaining: self.freeQuotaGlobalRemaining,
                             announcement: announcement)
            NSLog("[GlobalConfig] 已写入公告: \(announcement?.id ?? "nil(撤销)")")
            return true
        } catch {
            NSLog("[GlobalConfig] saveAnnouncement 失败: \(error)")
            return false
        }
    }

    /// 开发者写入协议链接（需口令）。空串表示撤销（沿用 App 端兜底默认值）。返回是否成功。
    func saveAgreementUrls(privacyPolicyUrl: String, userAgreementUrl: String) async -> Bool {
        do {
            let resp = try await postAdsJSON([
                "action": "setConfig",
                "devToken": DeveloperGate.devToken ?? "",
                "privacyPolicyUrl": privacyPolicyUrl,
                "userAgreementUrl": userAgreementUrl
            ])
            guard resp["ok"] as? Bool == true else {
                NSLog("[GlobalConfig] saveAgreementUrls 云端返回失败: \(resp)")
                return false
            }
            let privacy = privacyPolicyUrl.nonEmpty.flatMap { URL(string: $0) }
            let agreement = userAgreementUrl.nonEmpty.flatMap { URL(string: $0) }
            _ = applyToLocal(agentEnabled: self.agentEnabled, modelProvider: self.modelProvider, visionModelProvider: self.visionModelProvider,
                             freeQuotaEnabled: self.freeQuotaEnabled, freeQuotaPerMonth: self.freeQuotaPerMonth,
                             freeQuotaWeights: self.freeQuotaWeights, freeQuotaDailyCap: self.freeQuotaDailyCap,
                             freeQuotaGlobalMonthly: self.freeQuotaGlobalMonthly,
                             freeQuotaGlobalUsed: self.freeQuotaGlobalUsed, freeQuotaGlobalRemaining: self.freeQuotaGlobalRemaining,
                             announcement: self.announcement, privacyPolicyUrl: privacy, userAgreementUrl: agreement)
            NSLog("[GlobalConfig] 已写入协议链接 privacy=\(privacyPolicyUrl) agreement=\(userAgreementUrl)")
            return true
        } catch {
            NSLog("[GlobalConfig] saveAgreementUrls 失败: \(error)")
            return false
        }
    }

    /// 开发者写入「App 功能介绍」灯泡按钮链接（需口令）。空串=沿用 App 端兜底默认值。返回是否成功。
    func saveFeatureIntroUrl(_ url: String) async -> Bool {
        do {
            let resp = try await postAdsJSON([
                "action": "setConfig",
                "devToken": DeveloperGate.devToken ?? "",
                "featureIntroUrl": url
            ])
            guard resp["ok"] as? Bool == true else {
                NSLog("[GlobalConfig] saveFeatureIntroUrl 云端返回失败: \(resp)")
                return false
            }
            let newUrl = url.nonEmpty.flatMap { URL(string: $0) }
            _ = applyToLocal(agentEnabled: self.agentEnabled, modelProvider: self.modelProvider, visionModelProvider: self.visionModelProvider,
                             freeQuotaEnabled: self.freeQuotaEnabled, freeQuotaPerMonth: self.freeQuotaPerMonth,
                             freeQuotaWeights: self.freeQuotaWeights, freeQuotaDailyCap: self.freeQuotaDailyCap,
                             freeQuotaGlobalMonthly: self.freeQuotaGlobalMonthly,
                             freeQuotaGlobalUsed: self.freeQuotaGlobalUsed, freeQuotaGlobalRemaining: self.freeQuotaGlobalRemaining,
                             announcement: self.announcement, privacyPolicyUrl: self.privacyPolicyUrl,
                             userAgreementUrl: self.userAgreementUrl, featureIntroUrl: newUrl)
            NSLog("[GlobalConfig] 已写入功能介绍链接: \(url)")
            return true
        } catch {
            NSLog("[GlobalConfig] saveFeatureIntroUrl 失败: \(error)")
            return false
        }
    }

    /// 写回本地缓存并刷新发布属性（供 @ObservedObject 视图即时响应）。
    /// 返回值：配置是否相比本地发生变化（供调用方决定是否需要打印/广播）。
    private func applyToLocal(agentEnabled: Bool, modelProvider: String, visionModelProvider: String,
                              freeQuotaEnabled: Bool = false, freeQuotaPerMonth: Int = 0,
                              freeQuotaWeights: [String: Int] = [:], freeQuotaDailyCap: Int = 0,
                              freeQuotaGlobalMonthly: Int = 0,
                              freeQuotaGlobalUsed: Int = 0, freeQuotaGlobalRemaining: Int = -1,
                              trialDays: Int? = nil,
                              announcement: AnnouncementPayload? = nil,
                              privacyPolicyUrl: URL? = nil, userAgreementUrl: URL? = nil,
                              featureIntroUrl: URL? = nil) -> Bool {
        let changed = agentEnabled != self.agentEnabled
                    || modelProvider != self.modelProvider
                    || visionModelProvider != self.visionModelProvider
                    || freeQuotaEnabled != self.freeQuotaEnabled
                    || freeQuotaPerMonth != self.freeQuotaPerMonth
                    || freeQuotaDailyCap != self.freeQuotaDailyCap
                    || freeQuotaGlobalMonthly != self.freeQuotaGlobalMonthly
                    || freeQuotaGlobalUsed != self.freeQuotaGlobalUsed
                    || freeQuotaGlobalRemaining != self.freeQuotaGlobalRemaining
                    || (trialDays != nil && trialDays != self.trialDays)
                    || announcement?.id != self.announcement?.id
                    || privacyPolicyUrl != self.privacyPolicyUrl
                    || userAgreementUrl != self.userAgreementUrl
                    || featureIntroUrl != self.featureIntroUrl
        let ud = UserDefaults.standard
        ud.set(agentEnabled, forKey: agentKey)
        ud.set(modelProvider, forKey: modelKey)
        ud.set(visionModelProvider, forKey: visionKey)
        self.agentEnabled = agentEnabled
        self.modelProvider = modelProvider
        self.visionModelProvider = visionModelProvider
        ud.set(freeQuotaEnabled, forKey: fqEnabledKey)
        ud.set(freeQuotaPerMonth, forKey: fqPerMonthKey)
        ud.set(freeQuotaWeights, forKey: fqWeightsKey)
        ud.set(freeQuotaDailyCap, forKey: fqDailyCapKey)
        ud.set(freeQuotaGlobalMonthly, forKey: fqGlobalKey)
        ud.set(freeQuotaGlobalUsed, forKey: fqGlobalUsedKey)
        ud.set(freeQuotaGlobalRemaining, forKey: fqGlobalRemainKey)
        self.freeQuotaEnabled = freeQuotaEnabled
        self.freeQuotaPerMonth = freeQuotaPerMonth
        self.freeQuotaWeights = freeQuotaWeights
        self.freeQuotaDailyCap = freeQuotaDailyCap
        self.freeQuotaGlobalMonthly = freeQuotaGlobalMonthly
        self.freeQuotaGlobalUsed = freeQuotaGlobalUsed
        self.freeQuotaGlobalRemaining = freeQuotaGlobalRemaining
        if let td = trialDays {
            ud.set(td, forKey: trialDaysKey)
            self.trialDays = td
        }
        announcement?.save(to: ud, key: announcementKey) ?? ud.removeObject(forKey: announcementKey)
        self.announcement = announcement
        ud.set(privacyPolicyUrl?.absoluteString, forKey: privacyKey)
        ud.set(userAgreementUrl?.absoluteString, forKey: agreementKey)
        self.privacyPolicyUrl = privacyPolicyUrl
        self.userAgreementUrl = userAgreementUrl
        ud.set(featureIntroUrl?.absoluteString, forKey: featureIntroKey)
        self.featureIntroUrl = featureIntroUrl
        return changed
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// 应用内公告（开发者中心群发，所有用户打开 App 时拉取并展示）。
/// 云端 aia_config.announcement 为可空 Object；本地 UserDefaults 存为 JSON 字符串。
struct AnnouncementPayload: Identifiable, Codable, Hashable {
    var id: String            // 唯一标识，App 用 lastSeenAnnouncementID 去重已读
    var title: String
    var body: String
    var route: String?        // 可选跳转路由；空=仅进 App
    var link: String?         // 可选外部链接；空=不配链接（此时按 route 处理）
    var openMode: String?     // 链接打开方式："inApp"=App 内打开，"browser"=跳系统浏览器；nil 默认 "inApp"
    var startAt: TimeInterval // 生效开始（秒）；0=立即
    var endAt: TimeInterval   // 生效结束（秒）；0=长期
    var createdAt: TimeInterval

    /// 当前是否处于生效窗口内。
    var isEffective: Bool {
        let now = Date().timeIntervalSince1970
        let afterStart = startAt == 0 || now >= startAt
        let beforeEnd = endAt == 0 || now <= endAt
        return afterStart && beforeEnd
    }

    func toCloudDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "title": title, "body": body,
            "startAt": startAt, "endAt": endAt, "createdAt": createdAt
        ]
        if let r = route?.nonEmpty { d["route"] = r }
        if let l = link?.nonEmpty { d["link"] = l }
        if let m = openMode?.nonEmpty { d["openMode"] = m }
        return d
    }

    static func parse(_ any: Any?) -> AnnouncementPayload? {
        guard let d = any as? [String: Any] else { return nil }
        guard let id = d["id"] as? String, !id.isEmpty,
              let title = d["title"] as? String,
              let body = d["body"] as? String else { return nil }
        return AnnouncementPayload(
            id: id, title: title, body: body,
            route: d["route"] as? String,
            link: d["link"] as? String,
            openMode: d["openMode"] as? String,
            startAt: d["startAt"] as? TimeInterval ?? 0,
            endAt: d["endAt"] as? TimeInterval ?? 0,
            createdAt: d["createdAt"] as? TimeInterval ?? Date().timeIntervalSince1970
        )
    }

    func save(to ud: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self),
           let str = String(data: data, encoding: .utf8) {
            ud.set(str, forKey: key)
        }
    }

    static func load(from ud: UserDefaults, key: String) -> AnnouncementPayload? {
        guard let str = ud.string(forKey: key),
              let data = str.data(using: .utf8),
              let obj = try? JSONDecoder().decode(AnnouncementPayload.self, from: data) else { return nil }
        return obj
    }
}
