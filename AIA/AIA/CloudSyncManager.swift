// CloudSyncManager.swift
// 云同步：把本地 SwiftData 的四条记录上传到 CloudBase，并拉取其它设备的变更。
// 设计要点：
// - 每条记录靠 syncId(UUID) 做跨设备 upsert；冲突按 syncUpdatedAt 后写胜出。
// - 同步账号(syncUserId)默认是设备随机 UUID（存 UserDefaults）；多台设备填同一个值即可共享同一份数据。
// - 云函数 /sync 不鉴权（靠 userId 的不可猜性），属 MVP 简化，详见 README 安全说明。
import Foundation
import SwiftData
import Combine

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

    @Published var status: String = "未同步"
    @Published var lastSyncAt: Date? = UserDefaults.standard.object(forKey: "aia_last_sync") as? Date
    @Published var isSyncing: Bool = false
    /// 上一次同步的增量对比数据；初始为 nil（尚未同步过）。
    @Published var lastSyncStats: SyncStats? = nil

    // MARK: - 同步账号（多设备共享同值 = 同一份数据）
    /// 已登录时绑定到登录账号（aia.userId），实现「同账号登录 = 同一份云数据」；
    /// 未登录时回退到设备级随机账号（aia_sync_user_id），仅本机使用。
    /// 只访问 UserDefaults（线程安全）。
    static var userId: String {
        get {
            if UserDefaults.standard.bool(forKey: "aia.isLoggedIn"),
               let authId = UserDefaults.standard.string(forKey: "aia.userId"), !authId.isEmpty {
                return authId
            }
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

    /// 自动同步开关：默认开启（用户要求「开通自动同步功能」）。
    static var autoSync: Bool {
        get {
            if UserDefaults.standard.object(forKey: "aia_auto_sync") != nil {
                return UserDefaults.standard.bool(forKey: "aia_auto_sync")
            }
            return true
        }
        set { UserDefaults.standard.set(newValue, forKey: "aia_auto_sync") }
    }

    private static let syncEndpoint: URL = {
        let base = RecognizeService.endpoint.absoluteString
        let url = base.replacingOccurrences(of: "/recognize", with: "/sync")
        return URL(string: url)!
    }()

    // MARK: - 自动同步触发（登录后 / 前后台 / 数据变更）
    private var changeSyncWorkItem: DispatchWorkItem?

    /// 登录成功后调用：重置同步锚点并全量拉取云端数据到本地，确保新设备/新登录拿到完整数据。
    /// 仅要求「已登录」，不要求自动同步开关（登录即视为要同步）。
    /// 关键：登录/重装场景下**先拉后推**，避免本地空数据覆盖云端已有数据。
    func syncAfterLogin(context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else {
            print("[sync] syncAfterLogin 跳过：未登录")
            return
        }
        let uid = Self.userId
        print("[sync] syncAfterLogin 开始，userId=\(uid)，重置 lastSyncAt")
        lastSyncAt = nil
        Task {
            // 1) 先全量拉取云端（since=0），把历史数据写回本地
            do {
                let pulled = try await pull(context: context)
                print("[sync] login 首次拉取完成，pulled=\(pulled)")
            } catch {
                print("[sync] login 首次拉取失败：\(error.localizedDescription)")
            }
            // 2) 再把本地数据推上去（此时本地已含云端数据，不会丢）
            await sync(context: context)
        }
    }

    /// 应用进入前台 / 进入后台时调用：已开启自动同步且已登录，则增量同步（先推本地、再拉云端）。
    func autoSyncIfEnabled(context: ModelContext) {
        guard Self.autoSync,
              UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return }
        Task { await sync(context: context) }
    }

    /// 本地数据发生变更后调用（带 3 秒防抖）：确保记录后能尽快上传到云端，降低删除 App 前未同步的风险。
    /// 不依赖自动同步开关；即使开关关闭，也会在设置页显示「待同步」状态（后续可扩展）。
    func syncAfterLocalChange(context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "aia.isLoggedIn") else { return }
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
    func sync(context: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        status = "同步中…"
        let uid = Self.userId
        print("[sync] 开始同步 userId=\(uid)")
        do {
            let pushed = try await push(context: context)
            let pulled = try await pull(context: context)
            // 清理本地已同步删除的墓碑（cloud 已收到 deleted=true）。
            // 涵盖 Bill / FoodEntry / Reminder / HealthMetric / RecognitionRecord /
            // ChatMessage / MerchantMeta / WaterLog / RecurringRule 等所有通过 buildPushItems 同步的类型。
            cleanupSyncedTombstones(context: context)
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
            status = "已同步 · 上传 \(pushed.upserted) 条 / 更新 \(pulled) 条"
            print("[sync] 同步完成 · 上传对比 → 发送 \(pushed.sent) 条 / 云端实际写入 \(pushed.upserted) 条 | 拉取 \(pulled) 条, userId=\(uid)")
        } catch {
            status = "同步失败：\(error.localizedDescription)"
            print("[sync] 同步失败：\(error.localizedDescription), userId=\(uid)")
        }
        isSyncing = false
    }

    // MARK: - 上传
    /// 返回 (sent: 本次增量发送的记录条数, upserted: 云端实际落库的条数, localTotal: 本地各类型总条数)。
    private func push(context: ModelContext) async throws -> (sent: Int, upserted: Int, localTotal: Int) {
        let since = lastSyncAt?.timeIntervalSince1970
        let result = buildPushItems(context: context, since: since)
        let items = result.items
        print("[sync] push 准备上传 items 数量 = \(items.count)（增量 since=\(String(describing: since))），userId = \(Self.userId)")
        guard !items.isEmpty else { return (sent: 0, upserted: 0, localTotal: result.localTotal) }

        let body: [String: Any] = [
            "action": "push",
            "userId": Self.userId,
            "records": items
        ]
        let resp = try await postJSON(body)
        let upserted = (resp["upserted"] as? NSNumber)?.intValue
        print("[sync] push 云端返回 = \(resp)，解析 upserted = \(String(describing: upserted))")
        return (sent: items.count, upserted: upserted ?? items.count, localTotal: result.localTotal)
    }

    /// 只上传「上次同步后有变动」的记录（syncUpdatedAt > since），把 push 从全量上传改为增量上传，
    /// 直接削减云端按记录粒度的 doc.get 调用（每次 /sync 的数据库读次数 ≈ 本端发出的记录条数）。
    /// - since == nil 表示首次/登录后全量同步，发送全部本地记录（与 pull 的 since=0 对齐）。
    /// - 软删记录（syncDeleted == true）在本地删除时会同步刷新 syncUpdatedAt，因此仍会被纳入本次上传，
    ///   确保云端收到 deleted=true 墓碑；push 成功后才由 cleanupSyncedTombstones 清本地墓碑。
    /// 返回 (items: 增量筛选后的上传记录, localTotal: 本地各类型记录总条数）。
    private func buildPushItems(context: ModelContext, since: Double?) -> (items: [[String: Any]], localTotal: Int) {
        // 注意：payload 故意不包含 imageName —— 识别原图仅存本地（Documents/attachments），
        // 绝不上云。新增字段时请勿把 imageName 加进任何 payload。
        var items: [[String: Any]] = []
        // 增量边界：since == nil（首次/登录后）时取 0，timeIntervalSince1970 恒为正，等价"全量发送"。
        let sinceTime = since ?? 0
        // 本地各类型总条数（用于打印"增量上传省了多少"）。
        var totalFetched = 0

        if let bills = try? context.fetch(FetchDescriptor<Bill>()) {
            print("[sync] 本地 bills 数量 = \(bills.count)")
            totalFetched += bills.count
            for b in bills {
                guard b.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
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
        if let reminders = try? context.fetch(FetchDescriptor<Reminder>()) {
            print("[sync] 本地 reminders 数量 = \(reminders.count)")
            totalFetched += reminders.count
            for r in reminders {
                guard r.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
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
        if let foods = try? context.fetch(FetchDescriptor<FoodEntry>()) {
            print("[sync] 本地 foods 数量 = \(foods.count)")
            totalFetched += foods.count
            for f in foods {
                guard f.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
                items.append(item(id: f.syncId, type: "food", updatedAt: f.syncUpdatedAt,
                                  deleted: f.syncDeleted, payload: [
                                    "name": f.name,
                                    "calories": f.calories,
                                    "protein": f.protein,
                                    "carbs": f.carbs,
                                    "fat": f.fat,
                                    "portion": f.portion,
                                    "meal": f.meal,
                                    "date": f.date.timeIntervalSince1970,
                                    "weightGram": f.weightGram as Any,
                                    "baseCalories": f.baseCalories as Any,
                                    "baseProtein": f.baseProtein as Any,
                                    "baseCarbs": f.baseCarbs as Any,
                                    "baseFat": f.baseFat as Any
                                  ]))
            }
        }
        if let healths = try? context.fetch(FetchDescriptor<HealthMetric>()) {
            print("[sync] 本地 healths 数量 = \(healths.count)")
            totalFetched += healths.count
            for h in healths {
                guard h.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
                items.append(item(id: h.syncId, type: "health", updatedAt: h.syncUpdatedAt,
                                  deleted: h.syncDeleted, payload: [
                                    "metric": h.metric,
                                    "value": h.value,
                                    "unit": h.unit,
                                    "date": h.date.timeIntervalSince1970
                                  ]))
            }
        }
        if let recognitions = try? context.fetch(FetchDescriptor<RecognitionRecord>()) {
            print("[sync] 本地 recognitions 数量 = \(recognitions.count)")
            totalFetched += recognitions.count
            for r in recognitions {
                guard r.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
                items.append(item(id: r.syncId, type: "recognition", updatedAt: r.syncUpdatedAt,
                                  deleted: r.syncDeleted, payload: [
                                    "recognizedAt": r.recognizedAt.timeIntervalSince1970,
                                    "rawText": r.rawText,
                                    "types": r.types
                                    // 注意：imageName 故意不推云端
                                  ]))
            }
        }
        if let metas = try? context.fetch(FetchDescriptor<MerchantMeta>()) {
            print("[sync] 本地 merchantMetas 数量 = \(metas.count)")
            totalFetched += metas.count
            for m in metas {
                guard m.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
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
        if let chats = try? context.fetch(FetchDescriptor<ChatMessage>()) {
            print("[sync] 本地 chats 数量 = \(chats.count)")
            totalFetched += chats.count
            for c in chats {
                guard c.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
                items.append(item(id: c.syncId, type: "chat", updatedAt: c.syncUpdatedAt,
                                  deleted: c.syncDeleted, payload: [
                                    "role": c.roleRaw,
                                    "text": c.text,
                                    "createdAt": c.createdAt.timeIntervalSince1970
                                  ]))
            }
        }
        // 饮水（WaterLog）—— 让阿宝可经云端管理
        if let waters = try? context.fetch(FetchDescriptor<WaterLog>()) {
            totalFetched += waters.count
            for w in waters {
                guard w.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
                items.append(item(id: w.syncId, type: "water", updatedAt: w.syncUpdatedAt,
                                  deleted: w.syncDeleted, payload: [
                                    "amount": w.amount,
                                    "date": w.date.timeIntervalSince1970
                                  ]))
            }
        }
        // 周期排程（RecurringRule）—— 让阿宝可经云端管理
        if let rules = try? context.fetch(FetchDescriptor<RecurringRule>()) {
            totalFetched += rules.count
            for r in rules {
                guard r.syncUpdatedAt.timeIntervalSince1970 > sinceTime else { continue }
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
        print("[sync] push 本地共 \(totalFetched) 条，增量筛选后上传 \(items.count) 条（跳过未变更 \(totalFetched - items.count) 条）")
        return (items: items, localTotal: totalFetched)
    }

    private func item(id: UUID, type: String, updatedAt: Date, deleted: Bool, payload: [String: Any]) -> [String: Any] {
        return [
            "id": id.uuidString,
            "type": type,
            "updatedAt": updatedAt.timeIntervalSince1970,
            "deleted": deleted,
            "payload": payload
        ]
    }

    // MARK: - 拉取并合并
    private func pull(context: ModelContext) async throws -> Int {
        let since = lastSyncAt?.timeIntervalSince1970 ?? 0
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
            case "recurring_rule":
                merged += applyRecurring(context: context, id: id, remoteDate: remoteDate, deleted: deleted, payload: payload)
            default:
                break
            }
        }
        return merged
    }

    private func applyMerchantMeta(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
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

    private func applyBill(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
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

    private func applyReminder(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
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

    private func applyFood(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.name = payload["name"] as? String ?? existing.name
            existing.calories = payload["calories"] as? Double ?? existing.calories
            existing.protein = payload["protein"] as? Double ?? existing.protein
            existing.carbs = payload["carbs"] as? Double ?? existing.carbs
            existing.fat = payload["fat"] as? Double ?? existing.fat
            existing.portion = payload["portion"] as? String ?? existing.portion
            existing.meal = payload["meal"] as? String ?? existing.meal
            existing.date = Date(timeIntervalSince1970: payload["date"] as? Double ?? existing.date.timeIntervalSince1970)
            existing.weightGram = payload["weightGram"] as? Double ?? existing.weightGram
            existing.baseCalories = payload["baseCalories"] as? Double ?? existing.baseCalories
            existing.baseProtein = payload["baseProtein"] as? Double ?? existing.baseProtein
            existing.baseCarbs = payload["baseCarbs"] as? Double ?? existing.baseCarbs
            existing.baseFat = payload["baseFat"] as? Double ?? existing.baseFat
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let f = FoodEntry(name: payload["name"] as? String ?? "",
                              calories: payload["calories"] as? Double ?? 0,
                              protein: payload["protein"] as? Double ?? 0,
                              carbs: payload["carbs"] as? Double ?? 0,
                              fat: payload["fat"] as? Double ?? 0,
                              portion: payload["portion"] as? String ?? "",
                              meal: payload["meal"] as? String ?? "午餐",
                              date: Date(timeIntervalSince1970: payload["date"] as? Double ?? Date().timeIntervalSince1970),
                              weightGram: payload["weightGram"] as? Double,
                              baseCalories: payload["baseCalories"] as? Double,
                              baseProtein: payload["baseProtein"] as? Double,
                              baseCarbs: payload["baseCarbs"] as? Double,
                              baseFat: payload["baseFat"] as? Double,
                              syncId: id, syncUpdatedAt: remoteDate)
            context.insert(f)
            return 1
        }
    }

    private func applyWater(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
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

    private func applyRecurring(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
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

    private func applyHealth(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
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
            let h = HealthMetric(metric: payload["metric"] as? String ?? "",
                                 value: payload["value"] as? String ?? "",
                                 unit: payload["unit"] as? String ?? "",
                                 date: Date(timeIntervalSince1970: payload["date"] as? Double ?? Date().timeIntervalSince1970),
                                 syncId: id, syncUpdatedAt: remoteDate)
            context.insert(h)
            return 1
        }
    }

    private func applyRecognition(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
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

    private func applyChat(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
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
    private func cleanupSyncedTombstones(context: ModelContext) {
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
        if let rules = try? context.fetch(FetchDescriptor<RecurringRule>(predicate: #Predicate { $0.syncDeleted == true })) {
            for r in rules { context.delete(r); total += 1 }
        }

        if total > 0 { print("[sync] 清理本地墓碑 \(total) 条") }
    }

    // MARK: - 网络
    private func postJSON(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: Self.syncEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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
            throw NSError(domain: "Sync", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: json["error"] as? String ?? "同步失败"])
        }
        return json
    }
}
