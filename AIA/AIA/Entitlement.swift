// Entitlement.swift
// 付费墙（免费体验 30 天）iOS 端模型与判定。
//
// 判定权威在服务端（aia-sync 的 entitlement 动作）：白名单 → 订阅 → 试用 → 免费额度(权重计费) → 全局熔断 → 过期。
// 本类做两件事：
//   1) 为每次云请求注入身份锚点（userId/deviceId/userPhone）与订阅/试用状态，供服务端校验/计费；
//   2) 在 RecognizeService.postJSON 出口识别「付费墙拒绝」并抛出 AIAEntitlementError，调用方据此走本地降级。
//   3) 启动时拉取服务端权益快照（plan / 剩余额度）用于 UI 展示与本地预判定（can(_:)）。
import Foundation
import Combine
import AIAKit

// MARK: - 受付费墙管控的云功能
enum PaidFeature: String, CaseIterable, Sendable {
    case cloudVision      // 图片视觉识别
    case cloudTextParse   // 纯文本意图解析
    case cloudChat        // 云端对话
    case cloudFoodQuery   // 云端食物营养查询
    case cloudAgent       // 智能问答 Agent
    case cloudSyncPush    // 云同步上传
}

// MARK: - 权益档位
enum EntitlementPlan: String, Sendable {
    case tester    // 测试白名单（全功能）
    case paid      // 已订阅
    case trial     // 试用期内
    case freeQuota // 免费额度（每月 N 次，权重计费）
    case expired   // 已过期（未付费且额度耗尽）
    case free      // 纯本地功能（不受限）
    case unknown
}

// MARK: - 付费墙拒绝错误（调用方据此走本地降级，OCR + 端侧模型仍可用）
struct AIAEntitlementError: LocalizedError {
    let code: String
    var errorDescription: String? { "entitlement_denied:\(code)" }
}

@MainActor
final class EntitlementManager: ObservableObject {
    static let shared = EntitlementManager()

    // 服务端返回的权益快照（UI 展示 + 本地预判定）
    @Published private(set) var plan: EntitlementPlan = .unknown
    /// 服务端真实剩余额度（-1 = 不限/未知）。仅非体验模式使用；体验模式由 `freeQuotaRemaining` computed 接管。
    @Published private(set) var serverFreeQuotaRemaining: Int = -1   // -1 = 不限/未知
    @Published private(set) var lastRefreshAt: Date?

    // MARK: - 免费版体验模式本地模拟额度
    // simulateFree 本机模拟纯免费档：剩余次数 = perMonth - 本地已用次数（按月重置，跨月自动清零）。
    private let kSimulateFreeUsed = "aia.simulateFree.used"       // 当月已用次数
    private let kSimulateFreeUsedMonth = "aia.simulateFree.usedMonth"  // 记录 used 归属的 "yyyy-MM"

    /// 体验模式当月已用次数（跨月自动重置为 0）。
    private var simulateFreeUsedThisMonth: Int {
        get {
            if ud.string(forKey: kSimulateFreeUsedMonth) != Self.monthKey() {
                ud.set(0, forKey: kSimulateFreeUsed)
                ud.set(Self.monthKey(), forKey: kSimulateFreeUsedMonth)
                return 0
            }
            return ud.integer(forKey: kSimulateFreeUsed)
        }
        set {
            ud.set(newValue, forKey: kSimulateFreeUsed)
            ud.set(Self.monthKey(), forKey: kSimulateFreeUsedMonth)
        }
    }

    /// 展示用剩余次数：
    /// - 体验模式开启：返回本地模拟额度（perMonth - 已用），与真实免费用户同款胶囊。
    /// - 其它：返回服务端真实 remaining（-1 表示不限/未知）。
    var freeQuotaRemaining: Int {
        if simulateFree {
            let per = GlobalConfigStore.shared.freeQuotaPerMonth
            return max(0, per - simulateFreeUsedThisMonth)
        }
        return serverFreeQuotaRemaining
    }

    // >>> CHANGE-[2026-08-19 20:55:27]-试用天数云端化 开始
    // 原因: 全局试用天数改为云端下发(GlobalConfigStore), 本地无值时默认 7; 方案X 上限=max(锁定,当前全局)
    // 回退: 恢复 static let trialDays: Int = 30 + 删除 trialDaysLimit/trialStartDays 相关
    /// 当前全局免费体验天数（云端下发，本地缓存兜底；未配置默认 7）。
    static var trialDays: Int {
        let v = GlobalConfigStore.shared.trialDays
        return v > 0 ? v : 7
    }

    /// 方案X：当前用户可用试用上限天数 = max(开始时锁定的天数, 当前全局天数)。
    /// 只延长不缩短：全局调大 → 已体验用户也延长；全局调小 → 已开始用户不受影响。
    var trialDaysLimit: Int {
        max(trialStartDays, Self.trialDays)
    }

    /// 用户开始体验时锁定的全局试用天数（Keychain 跨重装保留 + 云端备份换设备恢复）。
    var trialStartDays: Int {
        guard let s = KeychainHelper.get(KeychainHelper.kTrialStartDays), let d = Int(s), d > 0 else { return 0 }
        return d
    }

    private func setTrialStartDays(_ days: Int) {
        KeychainHelper.set(String(max(1, days)), for: KeychainHelper.kTrialStartDays)
    }

    /// 试用数据本地变更锚点（秒）：用于云同步增量上传 + pull 后写胜出判断。
    /// ensureTrialStart/setTrialStart/clearTrialStart 修改起点时刷新。
    private static let kTrialDirtyAt = "aia.trialDirtyAt"
    private func markTrialDirty() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.kTrialDirtyAt)
    }

    /// 本次安装内是否已完成首轮云端试用数据拉取（sync pull 成功后置 true）。
    /// 换设备恢复关键：已登录但未拉取前，ensureTrialStart 不写本地 now，避免覆盖云端旧起点。
    private static let kTrialCloudRestored = "aia.trialCloudRestored"
    /// nonisolated：供 CloudSyncManager(static nonisolated) 在 pull 完成后置位。
    nonisolated static var trialCloudRestored: Bool {
        get { UserDefaults.standard.bool(forKey: kTrialCloudRestored) }
        set { UserDefaults.standard.set(newValue, forKey: kTrialCloudRestored) }
    }
    // <<< CHANGE-[2026-08-19 20:55:27]-试用天数云端化 结束

    /// 付费墙拒绝原因（服务端 code）：在云请求出口统一识别为 AIAEntitlementError。
    static let entitlementDenialCodes: Set<String> = [
        "trial_expired",          // 试用到期且无额度
        "quota_exhausted",        // 本月免费额度耗尽
        "daily_cap",              // 触达单日上限
        "global_quota_exhausted", // 全局月度总额度熔断
        "sync_not_covered",       // 免费额度不覆盖云同步 push
        "sync_push_blocked"       // push 被付费墙拦截
    ]

    private let ud = UserDefaults.standard
    private let kIsPaid = "aia.isPaid"   // TODO: 接入 StoreKit 2 后由交易状态回写

    /// 免费版体验模式：仅本机模拟纯免费档，**真实 ent.plan / 订阅 / 试用判定链完全不受影响**。
    /// 开启后 performCloud 出口在发请求前直接抛付费墙拒绝，让所有云端功能走既有的本地降级分支。
    @Published var simulateFree: Bool = UserDefaults.standard.bool(forKey: "aia.simulateFree") {
        didSet { UserDefaults.standard.set(simulateFree, forKey: "aia.simulateFree") }
    }
    private let kSimulateFree = "aia.simulateFree"

    /// 30 天免费试用期从「试用中」翻到「已过期」时置 true，由首页监听弹出付费引导弹窗。
    @Published var presentTrialExpiredPrompt = false
    /// 「试用到期引导弹窗已提示过」持久化标记（30 天免费体验）：防止 App 每次冷启动（lastWasTrialActive 重置为 true）
    /// 把「试用中→已过期」翻转重新触发一次、导致每次都重复弹窗。用户重新开始试用（清 trialStartAt）后自然失效。
    private let kTrialExpiredPromptShown = "aia.trialExpiredPromptShown"
    /// 「试用到期引导弹窗已提示过」持久化标记（10 分钟 Pro 限时体验）：与 30 天体验独立，
    /// 保证开过 30 天体验的用户，之后开 Pro 限时结束仍会再弹一次（两类提示互不误拦）。
    /// 按日历月维度存储（形如 "2026-08"），跨月（用户又能开体验）后允许再弹一次，实现「每月都弹」。
    private let kProTrialPromptShownMonth = "aia.proTrial.promptShownMonth"

    /// 体验模式下的有效档位（供 UI 展示）：开启时恒为 .free；Pro 限时体验中恒为 .trial。
    var effectivePlan: EntitlementPlan {
        if simulateFree { return .free }
        if proTrialActive { return .trial }
        return plan
    }

    // MARK: - Pro 版限时体验（未付费用户每月一次，10 分钟）
    /// 体验时长（秒）。
    static let proTrialSeconds: TimeInterval = 600

    private let kProTrialUntil = "aia.proTrial.until"      // 体验截止时间戳（跨启动续期）
    private let kProTrialUsedMonth = "aia.proTrial.usedMonth"  // 形如 "2026-08"

    /// 体验截止时间（nil = 未在体验中）。开启时写 now+600s，到点自动清除。
    @Published var proTrialUntil: Date? = {
        let t = UserDefaults.standard.double(forKey: "aia.proTrial.until")
        guard t > 0 else { return nil }
        let d = Date(timeIntervalSince1970: t)
        return d.timeIntervalSinceNow > 0 ? d : nil
    }()

    /// 倒计时心跳（1Hz 自增，仅用于驱动 UI 刷新）。
    @Published private(set) var proTrialTick: Int = 0

    /// 体验是否仍在进行。
    var proTrialActive: Bool { (proTrialUntil?.timeIntervalSinceNow ?? 0) > 0 }

    /// 剩余秒数（UI 倒计时用）。
    var proTrialRemainingSeconds: Int {
        guard let u = proTrialUntil else { return 0 }
        return max(0, Int(ceil(u.timeIntervalSinceNow)))
    }

    /// 剩余时间 mm:ss 文案。
    var proTrialRemainingText: String {
        let s = proTrialRemainingSeconds
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 本月是否已用过体验（按日历月判定，跨月自动重置）。
    var proTrialUsedThisMonth: Bool { ud.string(forKey: kProTrialUsedMonth) == Self.monthKey() }

    /// 是否允许开启体验：本月未用过 + 未在体验中 + 未开免费版演示。所有用户（含已订阅/白名单）均可体验。
    var canStartProTrial: Bool {
        !simulateFree && !proTrialActive && !proTrialUsedThisMonth
    }

    /// 当前是否拥有临时 Pro 全功能（体验期生效，与真实 plan 无关；免费版演示模式优先级更高）。
    var isTempPro: Bool { proTrialActive && !simulateFree }

    private static func monthKey(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: d)
    }

    /// 开启体验。成功返回 true。
    @discardableResult
    func startProTrial() -> Bool {
        guard canStartProTrial else { return false }
        let until = Date().addingTimeInterval(Self.proTrialSeconds)
        proTrialUntil = until
        ud.set(until.timeIntervalSince1970, forKey: kProTrialUntil)
        ud.set(Self.monthKey(), forKey: kProTrialUsedMonth)
        startProTrialTickerIfNeeded()
        return true
    }

    /// 结束体验（到点自动或用户提前结束）。本月配额不返还。
    func endProTrial() {
        guard proTrialUntil != nil else { return }
        proTrialUntil = nil
        ud.removeObject(forKey: kProTrialUntil)
    }

    // MARK: - 1Hz 倒计时驱动
    private var proTrialTicker: Timer?
    /// 试用「活跃」状态的边缘标记：上次 tick 时是否仍处于试用中。
    /// 用于在试用自然到期的那一瞬间探测到翻转，主动触发一次 refresh()，让会员页档位立刻更正为已过期。
    private var lastWasTrialActive = true

    /// 启动倒计时心跳（幂等）。App 启动与开启体验时调用。
    func startProTrialTickerIfNeeded() {
        guard proTrialTicker == nil else { return }
        // 冷启动若截止时间已过，直接清理残留
        if proTrialUntil == nil, ud.double(forKey: kProTrialUntil) > 0 {
            ud.removeObject(forKey: kProTrialUntil)
        }
        // Timer 回调默认非隔离上下文，但 EntitlementManager 是 @MainActor 单例，
        // 这里不在 Timer 闭包捕获 self，而是交还给 @MainActor Task 处理，
        // 由 @MainActor Task 安全捕获 self（单例生命周期=App，强引用无害）。
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                if self.proTrialActive {
                    self.proTrialTick &+= 1
                } else if self.proTrialUntil != nil {
                    self.endProTrial()   // 自然到点：自动结束体验
                    ToastCenter.shared.showImportant(
                        "Pro 体验已结束，Pro版功能已关闭",
                        icon: "⏰",
                        accent: AIATheme.over
                    )
                    // 10 分钟 Pro 限时自然结束也弹订阅引导（与 30 天体验到期各走各的标记）。
                    self.fireTrialExpiredPromptIfNeeded(isProTrial: true)
                }
                self.trialEdgeTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        proTrialTicker = t
    }

    /// 试用到期边缘探测：当「试用中 → 已过期」翻转时，主动刷新一次权益快照，
    /// 让会员对比页的档位文案（trial → expired）无需等下一次云端请求就能更正。
    /// 驱动方：① Pro 限时体验的 1Hz 心跳；② AppDelegate 回前台/冷启动（applicationDidBecomeActive）。
    /// 30 天免费体验本身无 Timer，必须由②在 App 每次回到前台时主动探测，否则过期后弹窗永不出现。
    func trialEdgeTick() {
        let wasActive = lastWasTrialActive
        let isActive = trialActive
        lastWasTrialActive = isActive
        // 仅在「之前试用中、现在过期」的翻转瞬间触发一次，避免每 tick 重复请求
        if wasActive && !isActive {
            fireTrialExpiredPromptIfNeeded(isProTrial: false)
            Task { await refresh() }
        }
    }

    /// 统一「试用到期引导弹窗」触发：翻转到期的 30 天体验（`isProTrial:false`）、
    /// 自然到点的 10 分钟 Pro 体验（`isProTrial:true`）都走这里。
    /// 两类体验用**独立**持久化标记，保证各自只提示一次、互不误拦：
    /// - 30 天体验提示过，之后开 10 分钟 Pro 结束仍会再弹；反之亦然。
    func fireTrialExpiredPromptIfNeeded(isProTrial: Bool = false) {
        if isProTrial {
            // 10 分钟 Pro 限时体验：按月维度，本月没弹过才弹，跨月（用户又能开体验）后允许再弹。
            if ud.string(forKey: kProTrialPromptShownMonth) != Self.monthKey() {
                ud.set(Self.monthKey(), forKey: kProTrialPromptShownMonth)
                presentTrialExpiredPrompt = true
            }
        } else {
            // 30 天免费体验：终身只提示一次，防止每次冷启动重复弹窗。
            if !ud.bool(forKey: kTrialExpiredPromptShown) {
                ud.set(true, forKey: kTrialExpiredPromptShown)
                presentTrialExpiredPrompt = true
            }
        }
    }

    // MARK: - 身份锚点（注入每次云请求）
    var deviceId: String { KeychainHelper.deviceId }
    var userId: String { KeychainHelper.get(KeychainHelper.kUserId) ?? "" }
    var userPhone: String { KeychainHelper.get(KeychainHelper.kPhone) ?? "" }

    /// 已订阅（占位：StoreKit 落地前恒为 false；客户端断言，真实验证由 App Store 负责）。
    var isPaid: Bool { ud.bool(forKey: kIsPaid) }

    /// 试用中：首次启动起算 N 天（Keychain 跨重装保留），上限 = max(锁定天数, 当前全局天数)。
    var trialActive: Bool {
        guard let start = trialStartAt else { return false }
        let elapsed = Date().timeIntervalSince1970 - start
        return elapsed >= 0 && elapsed <= Double(trialDaysLimit) * 86400
    }

    var trialStartAt: TimeInterval? {
        guard let s = KeychainHelper.get(KeychainHelper.kTrialStartAt), let d = Double(s), d > 0 else { return nil }
        return d
    }

    /// 试用剩余天数（仅展示用）
    var trialRemainingDays: Int {
        guard let start = trialStartAt else { return trialDaysLimit }
        let left = Double(trialDaysLimit) * 86400 - (Date().timeIntervalSince1970 - start)
        return max(0, Int(ceil(left / 86400)))
    }

    // MARK: - 首次启动记录试用起点（跨重装保留 + 云端恢复 + 锁定开始天数）
    func ensureTrialStart() {
        // 已有起点：不重写（跨重装保留）。
        if KeychainHelper.get(KeychainHelper.kTrialStartAt) != nil { return }
        // 换设备恢复窗口：已登录但尚未完成首轮云端试用数据拉取时，等待 sync pull 回填云端旧起点，
        // 避免本机写入 now 覆盖云端值导致"换设备重算"。
        let isLoggedIn = UserDefaults.standard.bool(forKey: "aia.isLoggedIn")
        if isLoggedIn && !Self.trialCloudRestored { return }
        // 未登录 / 已确认云端无试用记录（真正的新用户）：本地起算，并锁定当前全局天数（方案X）。
        KeychainHelper.set(String(Int(Date().timeIntervalSince1970)), for: KeychainHelper.kTrialStartAt)
        setTrialStartDays(Self.trialDays)
        markTrialDirty()
    }

    // MARK: - 调试用：显式设置 / 清除试用起点（开发者中心专属，正常用户路径不调用）
    /// 把试用起点写为指定日期（默认「现在」），立即进入试用窗口；写完刷新权益快照。
    func setTrialStart(_ date: Date = Date()) {
        KeychainHelper.set(String(Int(date.timeIntervalSince1970)), for: KeychainHelper.kTrialStartAt)
        setTrialStartDays(Self.trialDays)
        markTrialDirty()
        Task { await refresh() }
    }

    /// 清除试用起点（模拟卸载重装后的首次启动重计）。
    /// 注意：不可走 `refresh()`，否则 `ensureTrialStart` 会因 Keychain 为空立刻把起点重写为 now，使清除失效。
    /// 仅删 Keychain 并手动把本地 plan 置 unknown，让 `trialActive`（读 nil 即 false）自然反映「未设置/已过期」；
    /// 用户下次冷启时 `ensureTrialStart` 才会重计 30 天。
    func clearTrialStart() {
        KeychainHelper.delete(KeychainHelper.kTrialStartAt)
        KeychainHelper.delete(KeychainHelper.kTrialStartDays)
        markTrialDirty()
        self.plan = .unknown
        self.objectWillChange.send()
    }

    // MARK: - 本地预判定（UX 用，服务端仍是最终权威）
    /// - 云同步 push：免费额度不覆盖，仅白名单/订阅/试用可用。
    /// - 其它云功能：白名单/订阅/试用直接可用；免费额度档需 remaining != 0。
    func can(_ feature: PaidFeature) -> Bool {
        if simulateFree { return false }   // 免费版体验模式：本机模拟纯免费档，所有 Pro 权益暂时失效
        if isTempPro { return true }   // Pro 限时体验：全功能放行
        switch feature {
        case .cloudSyncPush:
            return plan == .tester || plan == .paid || plan == .trial
        default:
            if plan == .tester || plan == .paid || plan == .trial { return true }
            if plan == .freeQuota { return freeQuotaRemaining != 0 }
            return false
        }
    }

    /// 是否处于「全功能可用」状态（白名单/订阅/试用），用于隐藏付费引导。
    /// 开启「免费版体验模式」时返回 false（本机模拟纯免费档，方便测试免费用户体验）。
    /// 注意：不含 Pro 限时体验（体验中仍应展示升级引导），需要含体验请用 `isTempPro || isFullAccess`。
    var isFullAccess: Bool {
        !simulateFree && (plan == .tester || plan == .paid || plan == .trial)
    }

    /// 任何形态 Pro（付费 / 永久 / 限时体验）均为 true，用于头像皇冠等身份标识。
    /// 开启「免费版体验模式」时返回 false（体验模式下不展示 Pro 身份，统一模拟免费用户）。
    var isPro: Bool {
        !simulateFree && (isFullAccess || isTempPro)
    }

    /// 跨 actor 快照（供 CloudSyncManager 等非主线程上下文安全读取身份锚点）。
    struct Snapshot: Sendable {
        let userId: String
        let deviceId: String
        let userPhone: String
        let isPaid: Bool
        let trialActive: Bool
    }

    @MainActor func snapshot() -> Snapshot {
        // Pro 限时体验期：向服务端声明试用中，使云端放行（体验不计费）。
        Snapshot(userId: userId, deviceId: deviceId, userPhone: userPhone,
                 isPaid: isPaid, trialActive: trialActive || isTempPro)
    }

    // MARK: - 启动/回前台：拉取服务端权益快照（dryRun 不计费）
    func refresh() async {
        ensureTrialStart()
        startProTrialTickerIfNeeded()   // 冷启动恢复未走完的 Pro 限时体验倒计时
        let body: [String: Any] = [
            "action": "entitlement",
            "feature": PaidFeature.cloudVision.rawValue,
            "dryRun": true,
            "userId": userId,
            "deviceId": deviceId,
            "userPhone": userPhone,
            "isPaid": isPaid,
            "trialActive": trialActive
        ]
        do {
            let resp = try await postAdsJSON(body)
            if let planStr = resp["plan"] as? String, let p = EntitlementPlan(rawValue: planStr) {
                self.plan = p
            } else {
                self.plan = .unknown
            }
            if let rem = resp["remaining"] as? Int {
                self.serverFreeQuotaRemaining = rem
            }
            self.plan = (self.plan == .unknown && self.trialActive) ? .trial : self.plan
            self.lastRefreshAt = Date()
        } catch {
            // 拉取失败不阻断：以本地 trialActive 兜底，避免误伤真实用户
            self.plan = self.trialActive ? .trial : .unknown
            print("[Entitlement] refresh 失败: \(error)")
        }
    }

    /// 云端每次消费成功后即时刷新本地剩余快照，让用户无需冷启就能在「本月福利」卡看到剩余变化。
    /// - 体验模式：本地已用 +1（剩余次数 = perMonth - 已用，随使用递减），并主动发通知刷新 UI。
    /// - 其它：直接写入服务端返回的真实 remaining（-1 表示不限/未知，不覆盖）。
    func setQuotaRemaining(_ remaining: Int) {
        if simulateFree {
            var used = simulateFreeUsedThisMonth
            used += 1
            simulateFreeUsedThisMonth = used
            objectWillChange.send()
            return
        }
        guard remaining >= 0 else { return }
        self.serverFreeQuotaRemaining = remaining
    }
}
