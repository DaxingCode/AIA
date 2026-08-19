// CloudSyncManager.swift
// 云同步：把本地 SwiftData 的四条记录上传到 CloudBase，并拉取其它设备的变更。
// 设计要点：
// - 每条记录靠 syncId(UUID) 做跨设备 upsert；冲突按 syncUpdatedAt 后写胜出。
// - 同步账号(syncUserId)默认是设备随机 UUID（存 UserDefaults）；多台设备填同一个值即可共享同一份数据。
// - 云函数 /sync 不鉴权（靠 userId 的不可猜性），属 MVP 简化，详见 README 安全说明。
import Foundation
import SwiftData
import Combine
import CryptoKit

/// 一次同步的增量统计，供设置页「同步状态」卡片展示。
struct SyncStats: Equatable {
    let localTotal: Int      // 本地各类型记录总条数
    let uploaded: Int        // 本次增量发送条数（决定云端 doc.get 读调用量）
    let cloudWritten: Int    // 云端实际落库条数（≤ uploaded，陈旧记录被跳过）
    let pulled: Int          // 从云端拉回的增量条数
    let skipped: Int         // 因未变更被跳过的本地条数 = localTotal - uploaded
    let at: Date
}

    @MainActor
final class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()

    // 订阅权益阀门：免费版体验模式开关变化时，强制本对象发出 objectWillChange，
    // 使 status（计算属性，含免费版禁用文案）的消费者能实时刷新。
    private var entCancellable: AnyObject?

    private init() {
        let ent = EntitlementManager.shared
        entCancellable = ent.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
    }

    /// 内部原始同步文案（由 sync() 写入）。
    @Published private(set) var rawStatus: String = "未同步"
    /// 对外展示的同步状态文案。
    /// 「免费版体验模式」开启时恒定显示禁用提示，优先级高于任何同步结果，
    /// 因此开关一变化 `objectWillChange` 即触发、所有消费方实时刷新。
    var status: String {
        if EntitlementManager.shared.simulateFree {
            return "免费版体验模式：云同步已禁用"
        }
        return rawStatus
    }
    @Published var lastSyncAt: Date? = UserDefaults.standard.object(forKey: "aia_last_sync") as? Date
    @Published var isSyncing: Bool = false
    /// 上一次同步的增量对比数据；初始为 nil（尚未同步过）。
    @Published var lastSyncStats: SyncStats? = nil

    // MARK: - 同步账号（多设备共享同值 = 同一份数据）
    /// 已登录时绑定到登录账号（aia.userId），实现「同账号登录 = 同一份云数据」；
    /// 未登录时回退到设备级随机账号（aia_sync_user_id），仅本机使用。
    /// 只访问 UserDefaults（线程安全）。
    nonisolated static var userId: String {
        get {
            // 1) 已绑定小程序：直接用小程序共享码（"wx_<openid>"）作为同步分区键，
            //    使 App 与小程序落到 aia_records 的同一分区，实现数据互通。
            if let bound = UserDefaults.standard.string(forKey: "aia_bound_user_id"), !bound.isEmpty {
                return bound
            }
            // 2) 已登录：绑定到登录账号（aia.userId），实现「同账号登录 = 同一份云数据」。
            if UserDefaults.standard.bool(forKey: "aia.isLoggedIn"),
               let authId = UserDefaults.standard.string(forKey: "aia.userId"), !authId.isEmpty {
                return authId
            }
            // 3) 设备级随机账号，仅本机使用。
            if let saved = UserDefaults.standard.string(forKey: "aia_sync_user_id"), !saved.isEmpty {
                return saved
            }
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: "aia_sync_user_id")
            return new
        }
        set {
            // 只覆写设备级 fallback 账号；登录状态下实际同步账号仍由 aia.userId 决定。
            UserDefaults.standard.set(newValue.isEmpty ? UUID().uuidString : newValue, forKey: "aia_sync_user_id")
        }
    }

    /// 当前已绑定的小程序同步码（"wx_<openid>"）；未绑定为 nil。
    static var boundMiniProgramCode: String? {
        let v = UserDefaults.standard.string(forKey: "aia_bound_user_id")
        return (v?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? v : nil
    }

    /// 轻量校验同步码格式：小程序 getOpenid 返回 "wx_<openid>"，一律以 "wx_" 开头且长度合理。
    /// 仅本地格式校验，真正可用性由绑定后首次同步能否拉到数据来验证。
    static func validateSharedCode(_ code: String) -> Bool {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.hasPrefix("wx_") && c.count >= 12
    }

    /// 绑定小程序：把同步分区切到 sharedCode，与小程序 aia_records 同一分区合并。
    /// 绑定后清空同步锚点并触发一次全量重同步（先推后拉，不要求 App 登录），
    /// 本地历史数据按 syncId 幂等合并进小程序分区。
    /// - Returns: 格式是否合法（合法即发起绑定；实际合并结果看 sync.status）。
    @discardableResult
    func bindMiniProgram(code: String, context: ModelContext) -> Bool {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validateSharedCode(c) else { return false }
        UserDefaults.standard.set(c, forKey: "aia_bound_user_id")
        print("[sync] 绑定小程序 sharedCode=\(c)，重置 lastSyncAt 触发全量重同步")
        // 把身份资料（昵称+绑定码）冗余备份到「登录账号分区」，供重装后重登同一账号时自动恢复
        // （UserDefaults 会因删 App 被清除，但 Keychain 登录态可恢复，届时即可拉到该备份）。
        Self.backupIdentityProfile()
        lastSyncAt = nil
        UserDefaults.standard.removeObject(forKey: "aia_last_sync")
        Task { @MainActor in
            await self.sync(context: context)
        }
        return true
    }

    /// 解绑小程序：清掉 aia_bound_user_id，回到登录态/设备级账号分区，并触发全量重同步拉回原分区数据。
    func unbindMiniProgram(context: ModelContext) {
        UserDefaults.standard.removeObject(forKey: "aia_bound_user_id")
        // 重新备份身份资料（绑定码清空）到登录分区 + 清除本地 pending，避免重装后误自动重绑。
        Self.backupIdentityProfile()
        UserDefaults.standard.removeObject(forKey: "aia_pending_mini_bind_code")
        print("[sync] 解绑小程序，重置 lastSyncAt 触发全量重同步")
        lastSyncAt = nil
        UserDefaults.standard.removeObject(forKey: "aia_last_sync")
        Task { @MainActor in
            await self.sync(context: context)
        }
    }

    /// 把身份资料（昵称 + 小程序绑定码）冗余备份到「登录账号分区」的 profile 记录，
    /// 供重装后重登同一账号自动恢复（UserDefaults 会因删 App 被清空，但 Keychain 登录态可恢复）。
    /// 关键：必须用**登录账号** userId 写入（而非 Self.userId，否则绑小程序后备份会进小程序分区，
    /// 重装重登前读不到）。昵称与绑定码合并进同一条 profile，避免分区分裂导致任意一项丢失。
    /// 仅已登录时有意义（未登录无「跨重装稳定的分区」可存，跳过）。
    /// 受自动同步开关 + 会员权益双重控制：任一不满足时不备份（昵称/绑定码不碰云端）。
    static func backupIdentityProfile() {
        guard Self.canPerformCloudSync else {
            print("[sync] backupIdentityProfile 跳过：云同步未放行（开关关闭或会员权益不足）")
            return
        }
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn"),
              let loginId = UserDefaults.standard.string(forKey: "aia.userId"), !loginId.isEmpty else {
            return
        }
        let nick = UserDefaults.standard.string(forKey: "userNickname") ?? ""
        let bound = UserDefaults.standard.string(forKey: "aia_bound_user_id") ?? ""
        let body: [String: Any] = [
            "action": "push",
            "userId": loginId,
            "records": [[
                "id": profileRecordId.uuidString,
                "type": "profile",
                "updatedAt": Date().timeIntervalSince1970,
                "deleted": false,
                "payload": ["nickname": nick, "miniBindCode": bound]
            ]]
        ]
        Task {
            do {
                _ = try await postJSON(body)
                print("[sync] 已备份身份资料（昵称+绑定码）到登录分区")
            } catch {
                print("[sync] 备份身份资料失败：\(error.localizedDescription)")
            }
        }
    }

    /// 自动同步开关：默认关闭，需用户手动开启。
    static var autoSync: Bool {
        get {
            if UserDefaults.standard.object(forKey: "aia_auto_sync") != nil {
                return UserDefaults.standard.bool(forKey: "aia_auto_sync")
            }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: "aia_auto_sync") }
    }

    /// 云同步是否放行：综合「自动同步开关」与「会员权益」两个条件。
    /// - 自动同步开关关闭：默认关闭，满足注重信息安全、不希望数据上云的用户需求。
    /// - 会员权益不足（到期 / 纯免费档 / 免费额度不覆盖云同步）：按彻底关闭标准，完全停掉同步。
    /// 两者任一不满足即不放行，数据完全留本地，不碰云端。
    static var canPerformCloudSync: Bool {
        autoSync && EntitlementManager.shared.can(.cloudSyncPush)
    }

    private nonisolated static let syncEndpoint: URL = {
        let base = "https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/recognize"
        let url = base.replacingOccurrences(of: "/recognize", with: "/sync")
        return URL(string: url)!
    }()

    /// 昵称走 aia_records 的 type:"profile" 通道。云端 push 以 {id, userId} 唯一、pull 按 userId 过滤，
    /// 因此用固定 id 即可（同用户多次 push 都 upsert 同一条文档，不会每人新建一条）。
    private static let profileRecordId = UUID(uuidString: "9F2B4C7E-3A1D-4E8B-9C6F-2D5A8B1E0F33")!

    /// 用户目标设置（目标热量/健康目标/饮食偏好/体重目标）走 aia_records type:"setting"。
    /// doc id 由当前同步账号(userId) 派生确定性 UUID，确保同一用户（App 绑定后与小程序同分区）落到同一条文档，
    /// 且不同用户互不冲突（避免全局固定 id 被 userId 冻结导致跨端 pull 不到）。
    /// 算法须与小程序 saveData/loadData 的 settingDocId（MD5 of "wx_"+openid+":setting"）保持一致。
    private nonisolated static func settingRecordId(for userId: String) -> UUID {
        let input = Data((userId + ":setting").utf8)
        let digest = Insecure.MD5.hash(data: input)
        let b = Array(digest)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// 健康目标（身高/体重/年龄/性别/活动水平/目标身高/步数/睡眠/运动）走 aia_records type:"profile"，
    /// 与「昵称 + 小程序绑定码」备份（profileRecordId，固定全局 UUID）**分属不同 doc id**——
    /// 因为云端 push 对 payload 是整文档覆盖（非字段级合并），若共用 id 二者会互相清空对方字段。
    /// 此处按当前同步账号 userId 派生确定性 UUID，与 settingRecordId 同策略：同账号跨设备落到同一文档、不同账号互不冲突。
    /// 仅含健康目标字段，weightGoalKg 已由 setting 通道覆盖，避免双通道重复责任。
    private nonisolated static func profileHealthRecordId(for userId: String) -> UUID {
        let input = Data((userId + ":profileHealth").utf8)
        let digest = Insecure.MD5.hash(data: input)
        let b = Array(digest)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // >>> CHANGE-[2026-08-19 20:55:27]-试用天数云端化 开始
    // 原因: 试用起点/锁定天数上云(方案X完整版), 换设备恢复; 同账号跨设备落同一 doc, 不同账号互不冲突
    // 回退: 删除本函数 + push 里 trial 记录段 + applyProfile 里 trial 回填段
    private nonisolated static func trialRecordId(for userId: String) -> UUID {
        let input = Data((userId + ":trial").utf8)
        let digest = Insecure.MD5.hash(data: input)
        let b = Array(digest)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
    // <<< CHANGE-[2026-08-19 20:55:27]-试用天数云端化 结束

    // MARK: - 自动同步触发（登录后 / 前后台 / 数据变更）
    private var changeSyncWorkItem: DispatchWorkItem?

    /// 登录成功后调用：重置同步锚点并全量拉取云端数据到本地，确保新设备/新登录拿到完整数据。
    /// 受自动同步开关 + 会员权益双重控制：任一不满足则彻底不拉（数据完全留本地）。
    /// 关键：登录/重装场景下**先拉后推**，避免本地空数据覆盖云端已有数据。
    func syncAfterLogin(context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else {
            print("[sync] syncAfterLogin 跳过：未登录")
            return
        }
        guard Self.canPerformCloudSync else {
            print("[sync] syncAfterLogin 跳过：云同步未放行（开关关闭或会员权益不足）")
            return
        }
        let uid = Self.userId
        print("[sync] syncAfterLogin 开始，userId=\(uid)，重置 lastSyncAt 触发全量重同步")
        lastSyncAt = nil
        // push/pull 已静态化并从 UserDefaults 读取增量游标，这里必须同步清掉该键，
        // 否则后台 push 会读到旧游标导致本次只做增量而非全量。
        UserDefaults.standard.removeObject(forKey: "aia_last_sync")
        Task { @MainActor in
            // 0) 冷静期恢复：若本账号处于「已申请注销但未超 N 天」状态，先撤销待删标记，
            //    随后下面的全量同步会把云端保留的数据拉回（= 自动反悔，无感恢复）。
            await Self.cancelPendingDelete()
            await sync(context: context, isFullSync: true)
            // 登录后自动恢复小程序绑定（重装后重登 Apple/微信 场景）：
            // pull 时已把云端备份的绑定码写入 aia_pending_mini_bind_code，这里消费并完成重绑 + 全量重同步。
            if let pending = UserDefaults.standard.string(forKey: "aia_pending_mini_bind_code"),
               !pending.isEmpty, Self.boundMiniProgramCode == nil {
                UserDefaults.standard.removeObject(forKey: "aia_pending_mini_bind_code")
                _ = bindMiniProgram(code: pending, context: context)
                print("[sync] 已自动恢复小程序绑定：\(pending)")
            }
        }
    }

    /// 应用进入前台 / 进入后台时调用：已开启自动同步且已登录，则增量同步（先推本地、再拉云端）。
    func autoSyncIfEnabled(context: ModelContext) {
        guard Self.autoSync,
              UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return }
        Task { await sync(context: context) }
    }

    /// 本地数据发生变更后调用（带 3 秒防抖）：确保记录后能尽快上传到云端，降低删除 App 前未同步的风险。
    /// 受自动同步开关 + 会员权益双重控制：任一不满足则彻底不传（数据完全留本地）。
    func syncAfterLocalChange(context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return }
        guard Self.canPerformCloudSync else {
            print("[sync] syncAfterLocalChange 跳过：云同步未放行（开关关闭或会员权益不足）")
            return
        }
        changeSyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                print("[sync] 本地数据变更触发防抖同步")
                await self.sync(context: context)
            }
        }
        changeSyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - 主流程：先推后拉
    /// 全量首拉（登录/重装后）的"放行 UI"超时：超过该时长仍未同步完就放弃本次全量，
    /// 让首页/恢复条放行，剩余数据靠后续 `autoSyncIfEnabled`（回前台/进后台）增量补全。
    /// 避免网络差/数据量大时首屏一直挂在"同步中"、首页空很久。
    private static let fullSyncTimeoutSeconds: Double = 20

    func sync(context: ModelContext, isFullSync: Bool = false) async {
        guard !isSyncing else { return }
        // 中心化兜底：任何入口（含手动触发）都先检查「开关 + 会员权益」，未放行则不碰云端。
        guard Self.canPerformCloudSync else {
            rawStatus = EntitlementManager.shared.can(.cloudSyncPush)
                ? "自动同步已关闭" : "会员已过期，云同步不可用"
            isSyncing = false
            return
        }
        // 免费版体验模式：云同步（push/pull）一律不可用，与真实免费档一致。
        if EntitlementManager.shared.simulateFree {
            rawStatus = "免费版体验模式：云同步已禁用"
            isSyncing = false
            return
        }
        isSyncing = true
        rawStatus = "同步中…"
        let uid = Self.userId
        print("[sync] 开始同步 userId=\(uid)\(isFullSync ? "（全量）" : "")")
        do {
            // 在后台 ModelContext 上完成全部 fetch/insert/网络，避免主线程被 416+ 条记录
            // 的逐条 fetch + insert 占满，导致界面完全卡死（触摸事件排不进主线程）。
            // 后台一次性 save 后，主上下文因 automaticallyMergesChangesFromParent=true 自动合并，
            // @Query 只重渲一次，不再每条插入触发一次重渲。
            let container = AppDelegate.sharedContainer
            let (pushed, pulled) = try await Self.runSyncOnBackground(container: container, isFullSync: isFullSync)
            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: "aia_last_sync")
            lastSyncStats = SyncStats(
                localTotal: pushed.localTotal,
                uploaded: pushed.sent,
                cloudWritten: pushed.upserted,
                pulled: pulled,
                skipped: max(0, pushed.localTotal - pushed.sent),
                at: now
            )
            rawStatus = "已同步 · 上传 \(pushed.upserted) 条 / 更新 \(pulled) 条"
            print("[sync] 同步完成 · 上传对比 → 发送 \(pushed.sent) 条 / 云端实际写入 \(pushed.upserted) 条 | 拉取 \(pulled) 条, userId=\(uid)")
        } catch {
            // 全量同步超时被放行：不算"失败"级别的错误，文案区分开，避免用户以为同步坏了。
            if let timeout = error as? SyncTimeoutError {
                rawStatus = timeout.message
                print("[sync] 全量同步超时放行：\(timeout.message)，剩余数据将由后续增量同步补全")
            } else {
                rawStatus = "同步失败：\(error.localizedDescription)"
                print("[sync] 同步失败：\(error.localizedDescription), userId=\(uid)")
            }
        }
        isSyncing = false
    }

    /// 一次同步的返回结果类型。
    private typealias SyncResult = (pushed: (sent: Int, upserted: Int, localTotal: Int), pulled: Int)

    /// 在后台 ModelContext 上执行 push+pull。`isFullSync` 时套一层"超时放行"：
    /// 超过 `fullSyncTimeoutSeconds` 秒则抛 `SyncTimeoutError`，中断本次全量（后台 Task 被取消，
    /// 已 insert 的部分因 syncId 幂等、下次增量补全，无副作用）。
    private static func runSyncOnBackground(
        container: ModelContainer?,
        isFullSync: Bool
    ) async throws -> SyncResult {
        // 同步主体：在后台 ModelContext 上完成全部 fetch/insert/网络，避免主线程被大量记录
        // 的逐条 fetch + insert 占满，导致界面完全卡死（触摸事件排不进主线程）。
        let work: () async throws -> SyncResult = {
            guard let container = container else { return ((sent: 0, upserted: 0, localTotal: 0), 0) }
            let bg = ModelContext(container)
            bg.autosaveEnabled = false
            let pushed = try await Self.push(context: bg)
            let pulled = try await Self.pull(context: bg)
            // 清理本地已同步删除的墓碑（cloud 已收到 deleted=true）。
            // 涵盖 Bill / FoodEntry / Reminder / HealthMetric / RecognitionRecord /
            // ChatMessage / MerchantMeta / WaterLog / RecurringRule 等所有通过 buildPushItems 同步的类型。
            Self.cleanupSyncedTombstones(context: bg)
            try bg.save()
            return (pushed, pulled)
        }

        // 仅全量同步才加超时放行；增量同步（autoSync）保持原样，不做超时打断。
        guard isFullSync else {
            return try await Task.detached(priority: .userInitiated) { () -> SyncResult in
                try await work()
            }.value
        }

        // 全量：用 task group 同时起「同步工作」与「超时计时」，同步先完成则返回结果，
        // 超时先到则整个 group 取消并抛 SyncTimeoutError，让外层放行 UI。
        return try await withThrowingTaskGroup(of: SyncResult.self) { group in
            group.addTask {
                try await Task.detached(priority: .userInitiated) { () -> SyncResult in
                    try await work()
                }.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.fullSyncTimeoutSeconds * 1_000_000_000))
                throw SyncTimeoutError()
            }
            // 等待第一个完成的子任务；若它成功返回结果，取消剩余子任务并返回。
            let first = try await group.next()
            group.cancelAll()
            if let result = first {
                return result
            }
            // 理论上不会走到：group 至少有一个子任务；兜底抛通用错误。
            throw NSError(domain: "Sync", code: -9, userInfo: [NSLocalizedDescriptionKey: "同步未返回结果"])
        }
    }

    /// 全量同步超时的专用错误，携带对用户友好的文案。
    private struct SyncTimeoutError: LocalizedError {
        var message: String { "同步较慢，已放行；数据将继续后台补全" }
        var errorDescription: String? { message }
    }

    // MARK: - 上传
    /// 返回 (sent: 本次增量发送的记录条数, upserted: 云端实际落库的条数, localTotal: 本地各类型总条数)。
    private static nonisolated func push(context: ModelContext) async throws -> (sent: Int, upserted: Int, localTotal: Int) {
        let since = (UserDefaults.standard.object(forKey: "aia_last_sync") as? Date)?.timeIntervalSince1970
        let result = buildPushItems(context: context, since: since)
        let items = result.items
        print("[sync] push 准备上传 items 数量 = \(items.count)（增量 since=\(String(describing: since))），userId = \(Self.userId)")
        guard !items.isEmpty else { return (sent: 0, upserted: 0, localTotal: result.localTotal) }

        // 分批发送：避免一次性 POST 超大请求体触发云函数 HTTP 触发的 413（请求体过大）。
        // 每批 50 条独立请求，云端按 {id,userId} upsert 幂等，分批中途失败重发安全。
        let batchSize = 50
        var totalUpserted = 0
        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let end = min(batchStart + batchSize, items.count)
            let batch = Array(items[batchStart..<end])
            let body: [String: Any] = [
                "action": "push",
                "userId": Self.userId,
                "records": batch
            ]
            let resp = try await postJSON(body)
            let upserted = (resp["upserted"] as? NSNumber)?.intValue ?? batch.count
            totalUpserted += upserted
            print("[sync] push 分批上传 [\(batchStart)..<\(end)] 云端返回 upserted=\(upserted)")
        }
        return (sent: items.count, upserted: totalUpserted, localTotal: result.localTotal)
    }

    /// 只上传「上次同步后有变动」的记录（syncUpdatedAt > since），把 push 从全量上传改为增量上传，
    /// 直接削减云端按记录粒度的 doc.get 调用（每次 /sync 的数据库读次数 ≈ 本端发出的记录条数）。
    /// - since == nil 表示首次/登录后全量同步，发送全部本地记录（与 pull 的 since=0 对齐）。
    /// - 软删记录（syncDeleted == true）在本地删除时会同步刷新 syncUpdatedAt，因此仍会被纳入本次上传，
    ///   确保云端收到 deleted=true 墓碑；push 成功后才由 cleanupSyncedTombstones 清本地墓碑。
    /// 返回 (items: 增量筛选后的上传记录, localTotal: 本地各类型记录总条数）。
    private static nonisolated func buildPushItems(context: ModelContext, since: Double?) -> (items: [[String: Any]], localTotal: Int) {
        // 注意：payload 故意不包含 imageName —— 识别原图仅存本地（Documents/attachments），
        // 绝不上云。新增字段时请勿把 imageName 加进任何 payload。
        var items: [[String: Any]] = []
        // 增量边界：since == nil（首次/登录后）时取 0，timeIntervalSince1970 恒为正，等价"全量发送"。
        let sinceTime = since ?? 0
        // P2：把增量边界转成 Date，用于 SwiftData #Predicate 在本地 SQLite 层只捞脏记录（省内存）。
        let sinceDate = Date(timeIntervalSince1970: sinceTime)
        // 本地各类型总条数（用于打印"增量上传省了多少"）。
        var totalFetched = 0

        if let bills = try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<Bill>())) ?? 0
            print("[sync] 本地 bills 增量(脏) = \(bills.count)")
            for b in bills {
                items.append(item(id: b.syncId, type: "bill", updatedAt: b.syncUpdatedAt,
                                  deleted: b.syncDeleted,                                   payload: [
                                    "merchant": b.merchant,
                                    "amount": b.amount,
                                    "currency": b.currency,
                                    "category": b.category,
                                    "time": b.time.timeIntervalSince1970,
                                    "note": b.note,
                                    "confirmed": b.confirmed,
                                    "isIncome": b.isIncome
                                  ]))
            }
        }
        if let reminders = try? context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<Reminder>())) ?? 0
            print("[sync] 本地 reminders 增量(脏) = \(reminders.count)")
            for r in reminders {
                items.append(item(id: r.syncId, type: "reminder", updatedAt: r.syncUpdatedAt,
                                  deleted: r.syncDeleted, payload: [
                                    "title": r.title,
                                    "due": r.due?.timeIntervalSince1970 ?? 0,
                                    "dueNil": r.due == nil,
                                    "remindAt": r.remindAt?.timeIntervalSince1970 ?? 0,
                                    "remindAtNil": r.remindAt == nil,
                                    "repeatRule": r.repeatRule,
                                    "priority": r.priority,
                                    "done": r.done
                                  ]))
            }
        }
        if let foods = try? context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<FoodEntry>())) ?? 0
            print("[sync] 本地 foods 增量(脏) = \(foods.count)")
            for f in foods {
                items.append(item(id: f.syncId, type: "food", updatedAt: f.syncUpdatedAt,
                                  deleted: f.syncDeleted,                                   payload: [
                                    "name": f.name,
                                    "waterIntake": f.waterIntake,
                                    "calories": f.calories,
                                    "protein": f.protein,
                                    "carbs": f.carbs,
                                    "fat": f.fat,
                                    "fiber": f.fiber as Any,
                                    "sugar": f.sugar as Any,
                                    "sodium": f.sodium as Any,
                                    "portion": f.portion,
                                    "meal": f.meal,
                                    "date": f.date.timeIntervalSince1970,
                                    "weightGram": f.weightGram as Any,
                                    "baseCalories": f.baseCalories as Any,
                                    "baseProtein": f.baseProtein as Any,
                                    "baseCarbs": f.baseCarbs as Any,
                                    "baseFat": f.baseFat as Any,
                                    "baseFiber": f.baseFiber as Any,
                                    "baseSugar": f.baseSugar as Any,
                                    "baseSodium": f.baseSodium as Any
                                  ]))
            }
        }
        if let healths = try? context.fetch(FetchDescriptor<HealthMetric>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<HealthMetric>())) ?? 0
            print("[sync] 本地 healths 增量(脏) = \(healths.count)")
            for h in healths {
                items.append(item(id: h.syncId, type: "health", updatedAt: h.syncUpdatedAt,
                                  deleted: h.syncDeleted, payload: [
                                    "metric": h.metric,
                                    "value": h.value,
                                    "unit": h.unit,
                                    "date": h.date.timeIntervalSince1970
                                  ]))
            }
        }
        // 手动健康数据（步数/睡眠/运动/活动热量）：独立 type="manualHealth"，不进 HealthMetric 表
        // 以免污染健康记录列表；按天快照增量上传，重装后 pull 回填 ManualHealthStore。
        for s in ManualHealthStore.shared.exportModified(since: sinceDate) {
            var payload: [String: Any] = ["date": Double(s.dayTs)]
            if let v = s.steps { payload["steps"] = v }
            if let v = s.sleep { payload["sleep"] = v }
            if let v = s.exercise { payload["exercise"] = v }
            if let v = s.calories { payload["calories"] = v }
            if let v = s.heartRate { payload["heartRate"] = v }
            items.append(item(id: s.id, type: "manualHealth", updatedAt: s.updatedAt, deleted: false, payload: payload))
        }
        if let recognitions = try? context.fetch(FetchDescriptor<RecognitionRecord>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<RecognitionRecord>())) ?? 0
            print("[sync] 本地 recognitions 增量(脏) = \(recognitions.count)")
            for r in recognitions {
                items.append(item(id: r.syncId, type: "recognition", updatedAt: r.syncUpdatedAt,
                                  deleted: r.syncDeleted, payload: [
                                    "recognizedAt": r.recognizedAt.timeIntervalSince1970,
                                    "rawText": r.rawText,
                                    "types": r.types
                                    // 注意：imageName 故意不推云端
                                  ]))
            }
        }
        if let metas = try? context.fetch(FetchDescriptor<MerchantMeta>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<MerchantMeta>())) ?? 0
            print("[sync] 本地 merchantMetas 增量(脏) = \(metas.count)")
            for m in metas {
                items.append(item(id: m.syncId, type: "merchant_meta", updatedAt: m.syncUpdatedAt,
                                  deleted: m.syncDeleted, payload: [
                                    "merchant": m.merchant,
                                    "category": m.category,
                                    "isIncome": m.isIncome,
                                    "hitCount": m.hitCount,
                                    "lastSeen": m.lastSeen.timeIntervalSince1970
                                  ]))
            }
        }
        if let chats = try? context.fetch(FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<ChatMessage>())) ?? 0
            print("[sync] 本地 chats 增量(脏) = \(chats.count)")
            for c in chats {
                items.append(item(id: c.syncId, type: "chat", updatedAt: c.syncUpdatedAt,
                                  deleted: c.syncDeleted, payload: [
                                    "role": c.roleRaw,
                                    "text": c.text,
                                    "createdAt": c.createdAt.timeIntervalSince1970
                                  ]))
            }
        }
        // 饮水（WaterLog）—— 让好记AI可经云端管理
        if let waters = try? context.fetch(FetchDescriptor<WaterLog>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<WaterLog>())) ?? 0
            print("[sync] 本地 waters 增量(脏) = \(waters.count)")
            for w in waters {
                items.append(item(id: w.syncId, type: "water", updatedAt: w.syncUpdatedAt,
                                  deleted: w.syncDeleted, payload: [
                                    "amount": w.amount,
                                    "date": w.date.timeIntervalSince1970
                                  ]))
            }
        }
        // 睡眠（SleepSession）—— 手动入睡/醒来记录，自动记时长，让好记AI可经云端管理
        if let sleeps = try? context.fetch(FetchDescriptor<SleepSession>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<SleepSession>())) ?? 0
            print("[sync] 本地 sleeps 增量(脏) = \(sleeps.count)")
            for s in sleeps {
                let payload: [String: Any] = [
                    "sleepStart": s.sleepStart.timeIntervalSince1970,
                    "wakeAt": s.wakeAt.map { $0.timeIntervalSince1970 } ?? 0,
                    "wakeAtNil": s.wakeAt == nil,
                    "durationSeconds": s.durationSeconds.map { $0 } ?? 0,
                    "durationNil": s.durationSeconds == nil,
                    "createdAt": s.syncUpdatedAt.timeIntervalSince1970
                ]
                items.append(item(id: s.syncId, type: "sleep", updatedAt: s.syncUpdatedAt,
                                  deleted: s.syncDeleted, payload: payload))
            }
        }
        // 周期排程（RecurringRule）—— 让好记AI可经云端管理
        if let rules = try? context.fetch(FetchDescriptor<RecurringRule>(predicate: #Predicate { $0.syncUpdatedAt > sinceDate })) {
            totalFetched += (try? context.fetchCount(FetchDescriptor<RecurringRule>())) ?? 0
            print("[sync] 本地 rules 增量(脏) = \(rules.count)")
            for r in rules {
                items.append(item(id: r.syncId, type: "recurring_rule", updatedAt: r.syncUpdatedAt,
                                  deleted: r.syncDeleted, payload: [
                                    "merchant": r.merchant,
                                    "amount": r.amount,
                                    "category": r.category,
                                    "note": r.note,
                                    "isIncome": r.isIncome,
                                    "dayOfMonth": r.dayOfMonth,
                                    "startDate": r.startDate.timeIntervalSince1970,
                                    "lastGeneratedAt": r.lastGeneratedAt?.timeIntervalSince1970 ?? 0,
                                    "cycleRaw": r.cycleRaw ?? "monthly",
                                    "customValue": r.customValue,
                                    "customUnitRaw": r.customUnitRaw ?? "month"
                                  ]))
            }
        }
        // 用户目标设置（setting）：仅在本地修改过（userSettingUpdatedAt 超过增量边界）时上传，
        // 走 aia_records type:"setting" 通道，与小程序 userSettings 同格式，绑定后自动合并。
        let settingUpdated = UserDefaults.standard.double(forKey: "userSettingUpdatedAt")
        if settingUpdated > sinceTime {
            let payload: [String: Any] = [
                "targetCalories": UserDefaults.standard.double(forKey: "aia.calorieGoalOverride"),
                "healthGoal": UserDefaults.standard.string(forKey: "aia.healthGoal") ?? "",
                "dietPreference": UserDefaults.standard.string(forKey: "aia.dietPreference") ?? "",
                "weightGoal": UserDefaults.standard.double(forKey: "aia.weightGoalKg")
            ]
            items.append(item(id: Self.settingRecordId(for: Self.userId),
                              type: "setting",
                              updatedAt: Date(timeIntervalSince1970: settingUpdated),
                              deleted: false,
                              payload: payload))
        }

        // 健康目标（profile.health）：身高/体重/年龄/性别/活动水平/目标身高/步数/睡眠/运动。
        // 不含 weightGoalKg（已随 setting 通道同步）。与昵称备份（profileRecordId）分属不同 doc id，
        // 避免各自全量 payload 互相覆盖；type 同为 "profile"，pull 统一由 applyProfile 处理。
        let profileUpdated = UserDefaults.standard.double(forKey: "userProfileUpdatedAt")
        if profileUpdated > sinceTime {
            let payload: [String: Any] = [
                "heightCm":       UserDefaults.standard.double(forKey: "aia.heightCm"),
                "weightKg":       UserDefaults.standard.double(forKey: "aia.weightKg"),
                "age":            UserDefaults.standard.integer(forKey: "aia.age"),
                "bioSex":         UserDefaults.standard.integer(forKey: "aia.bioSex"),
                "activityLevel":  UserDefaults.standard.integer(forKey: "aia.activityLevel"),
                "targetHeightCm": UserDefaults.standard.double(forKey: "aia.targetHeightCm"),
                "stepGoal":       UserDefaults.standard.integer(forKey: "aia.stepGoal"),
                "sleepGoalHours": UserDefaults.standard.double(forKey: "aia.sleepGoalHours"),
                "exerciseGoalMin":UserDefaults.standard.double(forKey: "aia.exerciseGoalMin"),
                "fitnessGoal":    UserDefaults.standard.string(forKey: "aia.fitnessGoal") ?? "maintain"
            ]
            items.append(item(id: Self.profileHealthRecordId(for: Self.userId),
                              type: "profile",
                              updatedAt: Date(timeIntervalSince1970: profileUpdated),
                              deleted: false,
                              payload: payload))
        }

        // >>> CHANGE-[2026-08-19 20:55:27]-试用天数云端化 开始
        // 原因: 试用起点/锁定天数上云(方案X完整版), 换设备恢复; 锚点 trialDirtyAt 仅本地变更后增量上传
        // 回退: 删除本段
        let trialDirty = UserDefaults.standard.double(forKey: "aia.trialDirtyAt")
        if trialDirty > sinceTime,
           let trialStartStr = KeychainHelper.get(KeychainHelper.kTrialStartAt),
           let trialStart = Double(trialStartStr), trialStart > 0 {
            let lockedDays = Int(KeychainHelper.get(KeychainHelper.kTrialStartDays) ?? "") ?? 0
            items.append(item(id: Self.trialRecordId(for: Self.userId),
                              type: "profile",
                              updatedAt: Date(timeIntervalSince1970: trialDirty),
                              deleted: false,
                              payload: [
                                "trialStartAt": trialStart,
                                "trialStartDays": lockedDays
                              ]))
        }
        // <<< CHANGE-[2026-08-19 20:55:27]-试用天数云端化 结束

        print("[sync] push 本地共 \(totalFetched) 条，增量筛选后上传 \(items.count) 条（跳过未变更 \(totalFetched - items.count) 条）")
        return (items: items, localTotal: totalFetched)
    }

    private static nonisolated func item(id: UUID, type: String, updatedAt: Date, deleted: Bool, payload: [String: Any]) -> [String: Any] {
        return [
            "id": id.uuidString,
            "type": type,
            "updatedAt": updatedAt.timeIntervalSince1970,
            "deleted": deleted,
            "payload": payload
        ]
    }

    // MARK: - 拉取并合并
    private static nonisolated func pull(context: ModelContext) async throws -> Int {
        let since = (UserDefaults.standard.object(forKey: "aia_last_sync") as? Date)?.timeIntervalSince1970 ?? 0
        let body: [String: Any] = [
            "action": "pull",
            "userId": Self.userId,
            "since": since
        ]
        let resp = try await postJSON(body)
        guard let records = resp["records"] as? [[String: Any]] else { return 0 }

        var merged = 0
        for rec in records {
            // 兼容 CloudBase 可能返回 _id / id 两种字段名
            let idStr = (rec["id"] as? String) ?? (rec["_id"] as? String)
            guard let idStr,
                  let id = UUID(uuidString: idStr),
                  let type = rec["type"] as? String,
                  let updatedAt = rec["updatedAt"] as? Double,
                  let payload = rec["payload"] as? [String: Any] else { continue }

            let remoteDate = Date(timeIntervalSince1970: updatedAt)
            let deleted = rec["deleted"] as? Bool ?? false

            switch type {
            case "bill":
                merged += applyBill(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "reminder":
                merged += applyReminder(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "food":
                merged += applyFood(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "health":
                merged += applyHealth(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "recognition":
                merged += applyRecognition(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "merchant_meta":
                merged += applyMerchantMeta(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "chat":
                merged += applyChat(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "water":
                merged += applyWater(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "sleep":
                merged += applySleep(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "recurring_rule":
                merged += applyRecurring(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            case "profile":
                merged += applyProfile(remoteDate: remoteDate, payload: payload)
            case "setting":
                merged += applySetting(remoteDate: remoteDate, payload: payload)
            case "manualHealth":
                merged += applyManualHealth(id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            default:
                break
            }
        }
        // >>> CHANGE-[2026-08-19 20:55:27]-试用天数云端化 开始
        // 原因: 本轮云端试用数据拉取完成标记——换设备时序: ensureTrialStart 等该标记后才写本地 now
        // 回退: 删除本行
        EntitlementManager.trialCloudRestored = true
        // <<< CHANGE-[2026-08-19 20:55:27]-试用天数云端化 结束
        return merged
    }

    private static nonisolated func applyMerchantMeta(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        let merchant = (payload["merchant"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !merchant.isEmpty else { return 0 }

        // 商户名是业务唯一键：先按 syncId 找，再按 merchant 找，避免同一商户出现两条记录。
        let byId = try? context.fetch(FetchDescriptor<MerchantMeta>(predicate: #Predicate { $0.syncId == id })).first
        let byMerchant = try? context.fetch(FetchDescriptor<MerchantMeta>(predicate: #Predicate { $0.merchant == merchant })).first
        if let existing = byId ?? byMerchant {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.category = payload["category"] as? String ?? existing.category
            existing.isIncome = payload["isIncome"] as? Bool ?? existing.isIncome
            existing.hitCount = payload["hitCount"] as? Int ?? existing.hitCount
            existing.lastSeen = Date(timeIntervalSince1970: payload["lastSeen"] as? Double ?? existing.lastSeen.timeIntervalSince1970)
            existing.syncUpdatedAt = remoteDate
            // 若按 merchant 找到但 syncId 不同，以云端 syncId 为准，保证后续同步一致。
            existing.syncId = id
            return 1
        } else {
            if deleted { return 0 }
            let m = MerchantMeta(
                merchant: merchant,
                category: payload["category"] as? String ?? "其他",
                isIncome: payload["isIncome"] as? Bool ?? false,
                hitCount: payload["hitCount"] as? Int ?? 1,
                lastSeen: Date(timeIntervalSince1970: payload["lastSeen"] as? Double ?? Date().timeIntervalSince1970),
                syncId: id, syncUpdatedAt: remoteDate, syncDeleted: false)
            context.insert(m)
            return 1
        }
    }

    private static nonisolated func applyBill(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.merchant = payload["merchant"] as? String ?? existing.merchant
            existing.amount = payload["amount"] as? Double ?? existing.amount
            existing.currency = payload["currency"] as? String ?? existing.currency
            existing.category = payload["category"] as? String ?? existing.category
            existing.time = Date(timeIntervalSince1970: payload["time"] as? Double ?? existing.time.timeIntervalSince1970)
            existing.note = payload["note"] as? String ?? ""
            existing.confirmed = payload["confirmed"] as? Bool ?? existing.confirmed
            existing.isIncome = payload["isIncome"] as? Bool ?? existing.isIncome
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let b = Bill(merchant: payload["merchant"] as? String ?? "",
                         amount: payload["amount"] as? Double ?? 0,
                         currency: payload["currency"] as? String ?? "CNY",
                         category: payload["category"] as? String ?? "其他",
                         time: Date(timeIntervalSince1970: payload["time"] as? Double ?? Date().timeIntervalSince1970),
                         note: payload["note"] as? String ?? "",
                         confirmed: payload["confirmed"] as? Bool ?? false,
                         isIncome: payload["isIncome"] as? Bool ?? false,
                         syncId: id, syncUpdatedAt: remoteDate)
            context.insert(b)
            return 1
        }
    }

    private static nonisolated func applyReminder(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.title = payload["title"] as? String ?? existing.title
            if (payload["dueNil"] as? Bool) == true { existing.due = nil }
            else { existing.due = Date(timeIntervalSince1970: payload["due"] as? Double ?? Date().timeIntervalSince1970) }
            if (payload["remindAtNil"] as? Bool) == true { existing.remindAt = nil }
            else if payload.keys.contains("remindAt") {
                existing.remindAt = Date(timeIntervalSince1970: payload["remindAt"] as? Double ?? existing.remindAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
            }
            existing.repeatRule = payload["repeatRule"] as? String ?? existing.repeatRule
            existing.priority = payload["priority"] as? String ?? existing.priority
            existing.done = payload["done"] as? Bool ?? existing.done
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let due: Date? = (payload["dueNil"] as? Bool) == true ? nil
                : Date(timeIntervalSince1970: payload["due"] as? Double ?? Date().timeIntervalSince1970)
            let remindAt: Date? = (payload["remindAtNil"] as? Bool) == true ? nil
                : Date(timeIntervalSince1970: payload["remindAt"] as? Double ?? Date().timeIntervalSince1970)
            let r = Reminder(title: payload["title"] as? String ?? "",
                             due: due,
                             remindAt: remindAt,
                             repeatRule: payload["repeatRule"] as? String ?? "none",
                             priority: payload["priority"] as? String ?? "medium",
                             done: payload["done"] as? Bool ?? false,
                             syncId: id, syncUpdatedAt: remoteDate)
            context.insert(r)
            ReminderNotificationManager.schedule(r)
            return 1
        }
    }

    private static nonisolated func applyFood(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        let name = payload["name"] as? String ?? ""
        let calories = payload["calories"] as? Double ?? 0
        let protein = payload["protein"] as? Double ?? 0
        let carbs = payload["carbs"] as? Double ?? 0
        let fat = payload["fat"] as? Double ?? 0
        let fiber = payload["fiber"] as? Double ?? 0
        let sugar = payload["sugar"] as? Double ?? 0
        let sodium = payload["sodium"] as? Double ?? 0
        let waterIntake = payload["waterIntake"] as? Double ?? 0
        let portion = payload["portion"] as? String ?? ""
        let meal = payload["meal"] as? String ?? "午餐"
        let date = Date(timeIntervalSince1970: payload["date"] as? Double ?? Date().timeIntervalSince1970)
        let weightGram = payload["weightGram"] as? Double
        let baseCalories = payload["baseCalories"] as? Double
        let baseProtein = payload["baseProtein"] as? Double
        let baseCarbs = payload["baseCarbs"] as? Double
        let baseFat = payload["baseFat"] as? Double
        let baseFiber = payload["baseFiber"] as? Double
        let baseSugar = payload["baseSugar"] as? Double
        let baseSodium = payload["baseSodium"] as? Double

        // 防御：云端可能把 base/weight 传成字面 0（而非缺失）。0 视为「未提供」，
        // 优先用「总量 ÷ 有效重量 ×100」反推每100g基准；重量 0 则从 portion 推算。
        // 否则每次同步都会把已纠正的基准覆盖回 0，编辑页永远显示 0。
        func resolveWeight(_ incoming: Double?, _ existing: Double?) -> Double {
            let inW = incoming ?? 0
            let exW = existing ?? 0
            if inW > 0 { return inW }
            if exW > 0 { return exW }
            return RecognitionSaver.weightFromPortion(portion) ?? 100
        }
        func resolveBase(_ incoming: Double?, _ total: Double, _ w: Double, _ existing: Double?) -> Double? {
            if let b = incoming, b > 0 { return b }
            if total > 0, w > 0 { return total / w * 100 }
            return existing
        }

        func fill(_ target: FoodEntry) {
            target.name = name.isEmpty ? target.name : name
            target.calories = calories
            target.protein = protein
            target.carbs = carbs
            target.fat = fat
            target.fiber = fiber
            target.sugar = sugar
            target.sodium = sodium
            target.waterIntake = waterIntake
            target.portion = portion
            target.meal = meal
            target.date = date
            let w = resolveWeight(weightGram, target.weightGram)
            target.weightGram = w
            target.baseCalories = resolveBase(baseCalories, calories, w, target.baseCalories)
            target.baseProtein  = resolveBase(baseProtein,  protein,  w, target.baseProtein)
            target.baseCarbs    = resolveBase(baseCarbs,    carbs,    w, target.baseCarbs)
            target.baseFat      = resolveBase(baseFat,      fat,      w, target.baseFat)
            target.baseFiber    = resolveBase(baseFiber,    fiber,    w, target.baseFiber)
            target.baseSugar    = resolveBase(baseSugar,    sugar,    w, target.baseSugar)
            target.baseSodium   = resolveBase(baseSodium,   sodium,   w, target.baseSodium)
            target.syncUpdatedAt = remoteDate
        }

        // 1) 按 syncId 精确 upsert
        if let existing = (try? context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            fill(existing)
            return 1
        }

        // 2) syncId 未命中时按业务键 fallback 去重（小程序/App syncId 不一致导致重复）
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        let normName = name.lowercased().trimmingCharacters(in: .whitespaces)
        let normPortion = portion.trimmingCharacters(in: .whitespaces)
        let byContent = (try? context.fetch(FetchDescriptor<FoodEntry>(
            predicate: #Predicate { !$0.syncDeleted && $0.meal == meal && $0.date >= dayStart && $0.date < dayEnd }
        )))?.first { f in
            f.name.lowercased().trimmingCharacters(in: .whitespaces) == normName &&
            f.portion.trimmingCharacters(in: .whitespaces) == normPortion
        }

        if let existing = byContent {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            let oldSyncId = existing.syncId
            existing.syncId = id
            fill(existing)
            if let existingSource = (try? context.fetch(FetchDescriptor<FoodSource>(predicate: #Predicate { $0.foodSyncId == oldSyncId })))?.first {
                existingSource.foodSyncId = id
            } else {
                context.insert(FoodSource(foodSyncId: id, origin: "miniprogram"))
            }
            return 1
        }

        // 3) 全新记录
        if deleted { return 0 }
        let w = resolveWeight(weightGram, nil)
        let f = FoodEntry(name: name,
                          calories: calories,
                          protein: protein,
                          carbs: carbs,
                          fat: fat,
                          fiber: fiber,
                          sugar: sugar,
                          sodium: sodium,
                          waterIntake: waterIntake,
                          portion: portion,
                          meal: meal,
                          date: date,
                          weightGram: w,
                          baseCalories: resolveBase(baseCalories, calories, w, nil),
                          baseProtein: resolveBase(baseProtein, protein, w, nil),
                          baseCarbs: resolveBase(baseCarbs, carbs, w, nil),
                          baseFat: resolveBase(baseFat, fat, w, nil),
                          baseFiber: resolveBase(baseFiber, fiber, w, nil),
                          baseSugar: resolveBase(baseSugar, sugar, w, nil),
                          baseSodium: resolveBase(baseSodium, sodium, w, nil),
                          syncId: id, syncUpdatedAt: remoteDate)
        context.insert(f)
        context.insert(FoodSource(foodSyncId: id, origin: "miniprogram"))
        return 1
    }

    private static nonisolated func applyWater(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<WaterLog>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.amount = (payload["amount"] as? Double) ?? existing.amount
            if let d = payload["date"] as? Double { existing.date = Date(timeIntervalSince1970: d) }
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let amount = (payload["amount"] as? Double) ?? 0
            let date = (payload["date"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let w = WaterLog(date: date, amount: amount, syncId: id, syncUpdatedAt: remoteDate)
            context.insert(w)
            return 1
        }
    }

    private static nonisolated func applySleep(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<SleepSession>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            if let v = payload["sleepStart"] as? Double { existing.sleepStart = Date(timeIntervalSince1970: v) }
            if (payload["wakeAtNil"] as? Bool) == true {
                existing.wakeAt = nil
            } else if let v = payload["wakeAt"] as? Double {
                existing.wakeAt = Date(timeIntervalSince1970: v)
            }
            if (payload["durationNil"] as? Bool) == true {
                existing.durationSeconds = nil
            } else if let v = payload["durationSeconds"] as? Double {
                existing.durationSeconds = v
            }
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let sleepStart = (payload["sleepStart"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let wakeAt = (payload["wakeAt"] as? Double).flatMap { (payload["wakeAtNil"] as? Bool) == true ? nil : Date(timeIntervalSince1970: $0) }
            let durationSeconds = (payload["durationSeconds"] as? Double).flatMap { (payload["durationNil"] as? Bool) == true ? nil : $0 }
            let s = SleepSession(sleepStart: sleepStart, wakeAt: wakeAt, durationSeconds: durationSeconds,
                                 syncId: id, syncUpdatedAt: remoteDate)
            context.insert(s)
            return 1
        }
    }

    private static nonisolated func applyRecurring(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<RecurringRule>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.merchant = (payload["merchant"] as? String) ?? existing.merchant
            existing.amount = (payload["amount"] as? Double) ?? existing.amount
            existing.category = (payload["category"] as? String) ?? existing.category
            existing.note = (payload["note"] as? String) ?? existing.note
            existing.isIncome = (payload["isIncome"] as? Bool) ?? existing.isIncome
            existing.dayOfMonth = (payload["dayOfMonth"] as? Int) ?? existing.dayOfMonth
            if let sd = payload["startDate"] as? Double { existing.startDate = Date(timeIntervalSince1970: sd) }
            if let lg = payload["lastGeneratedAt"] as? Double, lg > 0 { existing.lastGeneratedAt = Date(timeIntervalSince1970: lg) }
            existing.cycleRaw = (payload["cycleRaw"] as? String) ?? existing.cycleRaw
            existing.customValue = (payload["customValue"] as? Int) ?? existing.customValue
            existing.customUnitRaw = (payload["customUnitRaw"] as? String) ?? existing.customUnitRaw
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let lg = payload["lastGeneratedAt"] as? Double
            let lastGen: Date? = (lg != nil && lg! > 0) ? Date(timeIntervalSince1970: lg!) : nil
            let r = RecurringRule(
                merchant: (payload["merchant"] as? String) ?? "",
                amount: (payload["amount"] as? Double) ?? 0,
                category: (payload["category"] as? String) ?? "",
                note: (payload["note"] as? String) ?? "",
                isIncome: (payload["isIncome"] as? Bool) ?? false,
                dayOfMonth: (payload["dayOfMonth"] as? Int) ?? 1,
                startDate: (payload["startDate"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date(),
                lastGeneratedAt: lastGen,
                cycleRaw: (payload["cycleRaw"] as? String) ?? "monthly",
                customValue: (payload["customValue"] as? Int) ?? 1,
                customUnitRaw: (payload["customUnitRaw"] as? String) ?? "month",
                syncId: id, syncUpdatedAt: remoteDate
            )
            context.insert(r)
            return 1
        }
    }

    private static nonisolated func applyHealth(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<HealthMetric>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.metric = payload["metric"] as? String ?? existing.metric
            existing.value = payload["value"] as? String ?? existing.value
            existing.unit = payload["unit"] as? String ?? existing.unit
            existing.date = Date(timeIntervalSince1970: payload["date"] as? Double ?? existing.date.timeIntervalSince1970)
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let h = HealthMetric()
            h.metric = payload["metric"] as? String ?? ""
            h.value = payload["value"] as? String ?? ""
            h.unit = payload["unit"] as? String ?? ""
            h.date = Date(timeIntervalSince1970: payload["date"] as? Double ?? Date().timeIntervalSince1970)
            h.syncId = id
            h.syncUpdatedAt = remoteDate
            context.insert(h)
            return 1
        }
    }

    /// 手动健康数据（type="manualHealth"）：直接回填 ManualHealthStore（UserDefaults），
    /// 不写 SwiftData，因此不会污染健康记录列表。云端按天快照存储，本地按日期还原。
    private static nonisolated func applyManualHealth(id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        guard let dayTs = payload["date"] as? Double else { return 0 }
        if deleted {
            ManualHealthStore.shared.clearDay(Int(dayTs))
            return 1
        }
        ManualHealthStore.shared.importSnapshot(ManualHealthStore.ManualHealthSnapshot(
            dayTs: Int(dayTs),
            id: id,
            updatedAt: remoteDate,
            steps: payload["steps"] as? Int,
            sleep: payload["sleep"] as? Double,
            exercise: payload["exercise"] as? Int,
            calories: payload["calories"] as? Int,
            heartRate: payload["heartRate"] as? Int
        ))
        return 1
    }

    private static nonisolated func applyRecognition(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<RecognitionRecord>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.recognizedAt = Date(timeIntervalSince1970: payload["recognizedAt"] as? Double ?? existing.recognizedAt.timeIntervalSince1970)
            existing.rawText = payload["rawText"] as? String ?? existing.rawText
            existing.types = payload["types"] as? String ?? existing.types
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let r = RecognitionRecord(
                recognizedAt: Date(timeIntervalSince1970: payload["recognizedAt"] as? Double ?? Date().timeIntervalSince1970),
                rawText: payload["rawText"] as? String ?? "",
                types: (payload["types"] as? String)?.split(separator: ",").map(String.init) ?? [],
                syncId: id, syncUpdatedAt: remoteDate)
            context.insert(r)
            return 1
        }
    }

    // MARK: - 昵称（profile）
    /// 把云端昵称写回本地 userNickname。仅当云端更新时间晚于本地时才覆盖（后写胜出），
    /// 避免把本次登录刚拉到的旧值又写回、或覆盖本地更新的编辑。
    private static nonisolated func applyProfile(remoteDate: Date, payload: [String: Any]) -> Int {
        var merged = 0
        // 昵称：云端更新时间晚于本地才覆盖（后写胜出）。
        if let nick = payload["nickname"] as? String, !nick.isEmpty {
            let localUpdated = UserDefaults.standard.double(forKey: "userNicknameUpdatedAt")
            if remoteDate.timeIntervalSince1970 > localUpdated {
                UserDefaults.standard.set(nick, forKey: "userNickname")
                UserDefaults.standard.set(remoteDate.timeIntervalSince1970, forKey: "userNicknameUpdatedAt")
                merged += 1
            }
        }
        // 自动恢复小程序绑定：云端备份了绑定码且本地尚未绑定时，写入 pending 待登录流程消费。
        // 备份只写在登录账号分区，因此重装后重登同一账号拉到后才会触发；
        // 解绑时的墓碑备份 miniBindCode 为空串，不会写 pending。
        if let code = payload["miniBindCode"] as? String, !code.isEmpty,
           UserDefaults.standard.string(forKey: "aia_bound_user_id") == nil {
            UserDefaults.standard.set(code, forKey: "aia_pending_mini_bind_code")
            print("[sync] 检测到云端备份的小程序绑定码，待登录流程自动重绑")
        }
        // 健康目标：云端更新时间晚于本地整组锚点才覆盖（后写胜出），避免覆盖本地更新的编辑。
        if remoteDate.timeIntervalSince1970 > UserDefaults.standard.double(forKey: "userProfileUpdatedAt") {
            if let v = payload["heightCm"]        as? Double { UserDefaults.standard.set(v, forKey: "aia.heightCm") }
            if let v = payload["weightKg"]        as? Double { UserDefaults.standard.set(v, forKey: "aia.weightKg") }
            if let v = payload["age"]             as? Int    { UserDefaults.standard.set(v, forKey: "aia.age") }
            if let v = payload["bioSex"]          as? Int    { UserDefaults.standard.set(v, forKey: "aia.bioSex") }
            if let v = payload["activityLevel"]   as? Int    { UserDefaults.standard.set(v, forKey: "aia.activityLevel") }
            if let v = payload["targetHeightCm"]  as? Double { UserDefaults.standard.set(v, forKey: "aia.targetHeightCm") }
            if let v = payload["stepGoal"]        as? Int    { UserDefaults.standard.set(v, forKey: "aia.stepGoal") }
            if let v = payload["sleepGoalHours"]  as? Double { UserDefaults.standard.set(v, forKey: "aia.sleepGoalHours") }
            if let v = payload["exerciseGoalMin"] as? Double { UserDefaults.standard.set(v, forKey: "aia.exerciseGoalMin") }
            if let v = payload["fitnessGoal"]     as? String { UserDefaults.standard.set(v, forKey: "aia.fitnessGoal") }
            UserDefaults.standard.set(remoteDate.timeIntervalSince1970, forKey: "userProfileUpdatedAt")
            merged += 1
        }
        // >>> CHANGE-[2026-08-19 20:55:27]-试用天数云端化 开始
        // 原因: 换设备恢复试用起点/锁定天数; 云端更新时间晚于本地 dirty 才覆盖(后写胜出),
        //       避免本地调试 setTrialStart 被旧云端值覆盖、以及新设备本地 now 覆盖云端旧起点
        // 回退: 删除本段
        if let t = payload["trialStartAt"] as? Double, t > 0 {
            let localDirty = UserDefaults.standard.double(forKey: "aia.trialDirtyAt")
            if remoteDate.timeIntervalSince1970 > localDirty {
                KeychainHelper.set(String(Int(t)), for: KeychainHelper.kTrialStartAt)
                if let d = payload["trialStartDays"] as? Int, d > 0 {
                    KeychainHelper.set(String(d), for: KeychainHelper.kTrialStartDays)
                }
                UserDefaults.standard.set(remoteDate.timeIntervalSince1970, forKey: "aia.trialDirtyAt")
                merged += 1
            }
        }
        // <<< CHANGE-[2026-08-19 20:55:27]-试用天数云端化 结束
        return merged
    }

    // MARK: - 用户目标设置（setting）
    /// 把云端设置写回本地 UserDefaults。仅当云端更新时间晚于本地时才覆盖（后写胜出），
    /// 避免把本次刚拉到的旧值又写回、或覆盖本地更新的编辑。
    private static nonisolated func applySetting(remoteDate: Date, payload: [String: Any]) -> Int {
        let localUpdated = UserDefaults.standard.double(forKey: "userSettingUpdatedAt")
        guard remoteDate.timeIntervalSince1970 > localUpdated else { return 0 }
        // 目标热量：>0 视为自定义并写入；0/未设置标记为自动（不覆盖本地 override 数值）。
        if let tc = payload["targetCalories"] as? Double, tc > 0 {
            UserDefaults.standard.set(tc, forKey: "aia.calorieGoalOverride")
            UserDefaults.standard.set(true, forKey: "aia.calorieGoalIsCustom")
        } else if payload["targetCalories"] is Double {
            UserDefaults.standard.set(false, forKey: "aia.calorieGoalIsCustom")
        }
        if let hg = payload["healthGoal"] as? String, !hg.isEmpty {
            UserDefaults.standard.set(hg, forKey: "aia.healthGoal")
        }
        if let dp = payload["dietPreference"] as? String, !dp.isEmpty {
            UserDefaults.standard.set(dp, forKey: "aia.dietPreference")
        }
        if let wg = payload["weightGoal"] as? Double {
            UserDefaults.standard.set(wg, forKey: "aia.weightGoalKg")
        }
        UserDefaults.standard.set(remoteDate.timeIntervalSince1970, forKey: "userSettingUpdatedAt")
        return 1
    }

    private static nonisolated func applyChat(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.roleRaw = payload["role"] as? String ?? existing.roleRaw
            existing.text = payload["text"] as? String ?? existing.text
            existing.createdAt = Date(timeIntervalSince1970: payload["createdAt"] as? Double ?? existing.createdAt.timeIntervalSince1970)
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let roleRaw = payload["role"] as? String ?? "ai"
            let text = payload["text"] as? String ?? ""
            let createdAt = Date(timeIntervalSince1970: payload["createdAt"] as? Double ?? Date().timeIntervalSince1970)
            let c = ChatMessage(role: ChatMessage.Role(rawValue: roleRaw) ?? .ai,
                                text: text, createdAt: createdAt,
                                syncId: id, syncUpdatedAt: remoteDate)
            context.insert(c)
            return 1
        }
    }

    // MARK: - 本地墓碑清理
    /// 删除所有已成功推送到云端的软删记录（syncDeleted == true）。
    /// 在 push 成功后调用——云端已收到 deleted=true 标志，后续 pull 不会返回这些记录。
    /// 覆盖所有通过 buildPushItems 同步的模型类型。
    private static nonisolated func cleanupSyncedTombstones(context: ModelContext) {
        var total = 0

        if let bills = try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.syncDeleted == true })) {
            for b in bills { context.delete(b); total += 1 }
        }
        if let foods = try? context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.syncDeleted == true })) {
            for f in foods { context.delete(f); total += 1 }
        }
        if let reminders = try? context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.syncDeleted == true })) {
            for r in reminders { context.delete(r); total += 1 }
        }
        if let healths = try? context.fetch(FetchDescriptor<HealthMetric>(predicate: #Predicate { $0.syncDeleted == true })) {
            for h in healths { context.delete(h); total += 1 }
        }
        if let records = try? context.fetch(FetchDescriptor<RecognitionRecord>(predicate: #Predicate { $0.syncDeleted == true })) {
            for r in records { context.delete(r); total += 1 }
        }
        if let chats = try? context.fetch(FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.syncDeleted == true })) {
            for c in chats { context.delete(c); total += 1 }
        }
        if let metas = try? context.fetch(FetchDescriptor<MerchantMeta>(predicate: #Predicate { $0.syncDeleted == true })) {
            for m in metas { context.delete(m); total += 1 }
        }
        if let waters = try? context.fetch(FetchDescriptor<WaterLog>(predicate: #Predicate { $0.syncDeleted == true })) {
            for w in waters { context.delete(w); total += 1 }
        }
        if let sleeps = try? context.fetch(FetchDescriptor<SleepSession>(predicate: #Predicate { $0.syncDeleted == true })) {
            for s in sleeps { context.delete(s); total += 1 }
        }
        if let rules = try? context.fetch(FetchDescriptor<RecurringRule>(predicate: #Predicate { $0.syncDeleted == true })) {
            for r in rules { context.delete(r); total += 1 }
        }

        if total > 0 { print("[sync] 清理本地墓碑 \(total) 条") }
    }

    // MARK: - 网络
    private static nonisolated func postJSON(_ body: [String: Any]) async throws -> [String: Any] {
        // 注入付费墙身份锚点与订阅/试用状态（push 由服务端按此判定是否放行；pull 不受影响）。
        let snap = await MainActor.run { EntitlementManager.shared.snapshot() }
        var merged = body
        merged["isPaid"] = snap.isPaid
        merged["trialActive"] = snap.trialActive
        merged["deviceId"] = snap.deviceId

        var req = URLRequest(url: Self.syncEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: merged)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw NSError(domain: "Sync", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "请求失败 (HTTP \(status))"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Sync", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "返回格式异常"])
        }
        guard (json["ok"] as? Bool) != false else {
            // 付费墙：push 被拦截（试用/订阅到期，免费额度不覆盖 push）→ 抛出可识别错误，调用方停止重试。
            if let code = json["code"] as? String, code == "sync_push_blocked" {
                throw AIAEntitlementError(code: code)
            }
            throw NSError(domain: "Sync", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: json["error"] as? String ?? "同步失败"])
        }
        return json
    }

    // MARK: - Phase 2 账号关联（跨身份提供方合并：手机号 / Apple / 微信同步码）

    /// 解析某原始 userId 对应的「主账号」userId。
    /// 已关联则返回主账号；未关联/出错/离线则回落为该 userId 自身，保证登录必然可用。
    static func resolvePrimary(_ rawUserId: String) async -> String {
        let body: [String: Any] = ["action": "resolve", "userId": rawUserId]
        do {
            let resp = try await postJSON(body)
            if let pid = resp["primaryUserId"] as? String, !pid.isEmpty {
                return pid
            }
        } catch {
            print("[sync] resolvePrimary 失败，回落原始 userId: \(error.localizedDescription)")
        }
        return rawUserId
    }

    /// 关联：把 secondary 账号的云数据并入 primary 账号分区。成功后返回主账号 userId。
    /// 调用方（UI）应在成功后：把 AuthManager.userId 设为返回的 primaryUserId，并触发一次全量 syncAfterLogin。
    static func linkAccounts(primary: String, secondary: String) async -> String? {
        let body: [String: Any] = [
            "action": "link",
            "primaryUserId": primary,
            "secondaryUserId": secondary
        ]
        do {
            let resp = try await postJSON(body)
            guard (resp["ok"] as? Bool) == true else {
                print("[sync] link 失败: \(resp["error"] as? String ?? "未知")")
                return nil
            }
            return resp["primaryUserId"] as? String
        } catch {
            print("[sync] link 失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 解除关联（仅删映射；已并入主账号的数据不会自动回退，MVP 已知限制）。
    static func unlinkAccount(secondary: String) async -> Bool {
        let body: [String: Any] = ["action": "unlink", "secondaryUserId": secondary]
        do {
            let resp = try await postJSON(body)
            return (resp["ok"] as? Bool) == true
        } catch {
            print("[sync] unlink 失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 列出已关联到指定主账号的所有 secondary 身份（不含主账号自身）。
    /// 用于「账号关联」页展示「已关联的方式」列表。
    static func listLinkedAccounts(primary: String) async -> [String] {
        let body: [String: Any] = ["action": "resolve", "userId": primary]
        do {
            let resp = try await postJSON(body)
            return (resp["linkedMethods"] as? [String]) ?? []
        } catch {
            print("[sync] listLinkedAccounts 失败: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 应用内账户删除（苹果 Guideline 5.1.1(v) 强制）
    /// 永久注销当前账号：云端删除该登录账号分区全部数据 → 本地全量清空 → 登出回登录页。
    /// - 若绑定了小程序，仅清本地绑定码（不触发同步），避免把数据误推到小程序分区；
    ///   小程序原生分区数据由小程序侧管理，不连带删除。
    /// - 订阅需由用户在系统「设置 → Apple ID → 订阅」中先行取消，App 内无法代取消。
    func deleteAccount(context: ModelContext) async {
        let loginId = AuthManager.shared.userId
        // 1) 解绑小程序（仅清本地绑定码，避免触发 sync 误推数据到小程序分区）
        if Self.boundMiniProgramCode != nil {
            UserDefaults.standard.removeObject(forKey: "aia_bound_user_id")
            UserDefaults.standard.removeObject(forKey: "aia_pending_mini_bind_code")
        }
        // 2) 云端删除该登录账号分区全部数据（含关联映射 / 设备 / 额度）
        let body: [String: Any] = ["action": "deleteAccount", "userId": loginId]
        if let _ = try? await Self.postJSON(body) {
            print("[sync] 云端账户删除成功 userId=\(loginId)")
        } else {
            print("[sync] 云端账户删除失败（仍继续本地清空）userId=\(loginId)")
        }
        // 3) 本地全量清空
        if let container = AppDelegate.sharedContainer {
            await Self.clearLocalAll(container: container)
        }
        UserDefaults.standard.removeObject(forKey: "aia_last_sync")
        ManualHealthStore.shared.clearAll()
        // 4) 清 Keychain 登录态并回登录页
        AuthManager.shared.logout()
    }

    /// 撤销待删（冷静期内重新登录时调用）：若云端有本账号的待删登记且未超期，撤销之，
    /// 业务数据自然保留，随后 `syncAfterLogin` 的全量同步会把云端数据拉回（= 自动反悔、无感恢复）。
    /// 若已超期则云端顺手真删；若无待删记录则正常同步即可。返回是否成功恢复数据。
    /// 云端语义变更见 `云函数/aia-sync/index.js` 的 `handleDeleteAccount`/`handleCancelDelete`：
    /// 删除账户已改为「标记待删 + N 天冷静期」，不再即时真删。
    @discardableResult
    static func cancelPendingDelete() async -> Bool {
        let loginId = AuthManager.shared.userId
        guard !loginId.isEmpty else { return false }
        let body: [String: Any] = ["action": "cancelDelete", "userId": loginId]
        guard let resp = try? await Self.postJSON(body),
              let ok = resp["ok"] as? Bool, ok else {
            print("[sync] 撤销待删请求失败（忽略，正常同步）")
            return false
        }
        let restored = (resp["restored"] as? Bool) == true
        if restored {
            // 仅主线程可更新 @MainActor 的 ToastCenter。
            Task { @MainActor in
                ToastCenter.shared.showImportant(
                    "检测到你曾申请注销账户，已为你保留全部数据（冷静期内）。如需彻底注销，请到设置重新申请。",
                    icon: "🛡️",
                    accent: AIATheme.bill
                )
            }
        }
        return restored
    }

    /// 后台 ModelContext 全量删除所有业务模型（不阻塞主线程）。
    private static func clearLocalAll(container: ModelContainer) async {
        await Task.detached(priority: .userInitiated) {
            let bg = ModelContext(container)
            bg.autosaveEnabled = false
            do {
                let bills = try bg.fetch(FetchDescriptor<Bill>()); bills.forEach { bg.delete($0) }
                let foods = try bg.fetch(FetchDescriptor<FoodEntry>()); foods.forEach { bg.delete($0) }
                let reminders = try bg.fetch(FetchDescriptor<Reminder>()); reminders.forEach { bg.delete($0) }
                let healths = try bg.fetch(FetchDescriptor<HealthMetric>()); healths.forEach { bg.delete($0) }
                let recs = try bg.fetch(FetchDescriptor<RecognitionRecord>()); recs.forEach { bg.delete($0) }
                let chats = try bg.fetch(FetchDescriptor<ChatMessage>()); chats.forEach { bg.delete($0) }
                let metas = try bg.fetch(FetchDescriptor<MerchantMeta>()); metas.forEach { bg.delete($0) }
                let waters = try bg.fetch(FetchDescriptor<WaterLog>()); waters.forEach { bg.delete($0) }
                let sleeps = try bg.fetch(FetchDescriptor<SleepSession>()); sleeps.forEach { bg.delete($0) }
                let rules = try bg.fetch(FetchDescriptor<RecurringRule>()); rules.forEach { bg.delete($0) }
                let sources = try bg.fetch(FetchDescriptor<FoodSource>()); sources.forEach { bg.delete($0) }
                try bg.save()
                print("[sync] 本地全量清空完成")
            } catch {
                print("[sync] 本地全量清空失败：\(error.localizedDescription)")
            }
        }.value
    }
}
