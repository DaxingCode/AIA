// CloudSyncManager.swift
// 云同步：把本地 SwiftData 的四条记录上传到 CloudBase，并拉取其它设备的变更。
// 设计要点：
// - 每条记录靠 syncId(UUID) 做跨设备 upsert；冲突按 syncUpdatedAt 后写胜出。
// - 同步账号(syncUserId)默认是设备随机 UUID（存 UserDefaults）；多台设备填同一个值即可共享同一份数据。
// - 云函数 /sync 不鉴权（靠 userId 的不可猜性），属 MVP 简化，详见 README 安全说明。
import Foundation
import SwiftData
import Combine

final class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()

    @Published var status: String = "未同步"
    @Published var lastSyncAt: Date? = UserDefaults.standard.object(forKey: "aia_last_sync") as? Date
    @Published var isSyncing: Bool = false

    // MARK: - 同步账号（多设备共享同值 = 同一份数据）
    static var userId: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "aia_sync_user_id"), !saved.isEmpty {
                return saved
            }
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: "aia_sync_user_id")
            return new
        }
        set { UserDefaults.standard.set(newValue.isEmpty ? UUID().uuidString : newValue, forKey: "aia_sync_user_id") }
    }

    static var autoSync: Bool {
        get { UserDefaults.standard.bool(forKey: "aia_auto_sync") }
        set { UserDefaults.standard.set(newValue, forKey: "aia_auto_sync") }
    }

    private static let syncEndpoint: URL = {
        let base = RecognizeService.endpoint.absoluteString
        let url = base.replacingOccurrences(of: "/recognize", with: "/sync")
        return URL(string: url)!
    }()

    // MARK: - 主流程：先推后拉
    @MainActor
    func sync(context: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        status = "同步中…"
        do {
            let pushed = try await push(context: context)
            let pulled = try await pull(context: context)
            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: "aia_last_sync")
            status = "已同步 · 上传 \(pushed) 条 / 更新 \(pulled) 条"
        } catch {
            status = "同步失败：\(error.localizedDescription)"
        }
        isSyncing = false
    }

    // MARK: - 上传
    @MainActor
    private func push(context: ModelContext) async throws -> Int {
        let items = buildPushItems(context: context)
        guard !items.isEmpty else { return 0 }

        let body: [String: Any] = [
            "action": "push",
            "userId": Self.userId,
            "records": items
        ]
        let resp = try await postJSON(body)
        return (resp["upserted"] as? Int) ?? items.count
    }

    @MainActor
    private func buildPushItems(context: ModelContext) -> [[String: Any]] {
        var items: [[String: Any]] = []

        if let bills = try? context.fetch(FetchDescriptor<Bill>()) {
            for b in bills {
                items.append(item(id: b.syncId, type: "bill", updatedAt: b.syncUpdatedAt,
                                  deleted: b.syncDeleted, payload: [
                                    "merchant": b.merchant,
                                    "amount": b.amount,
                                    "currency": b.currency,
                                    "category": b.category,
                                    "time": b.time.timeIntervalSince1970,
                                    "note": b.note,
                                    "confirmed": b.confirmed
                                  ]))
            }
        }
        if let reminders = try? context.fetch(FetchDescriptor<Reminder>()) {
            for r in reminders {
                items.append(item(id: r.syncId, type: "reminder", updatedAt: r.syncUpdatedAt,
                                  deleted: r.syncDeleted, payload: [
                                    "title": r.title,
                                    "due": r.due?.timeIntervalSince1970 ?? 0,
                                    "dueNil": r.due == nil,
                                    "repeatRule": r.repeatRule,
                                    "priority": r.priority,
                                    "done": r.done
                                  ]))
            }
        }
        if let foods = try? context.fetch(FetchDescriptor<FoodEntry>()) {
            for f in foods {
                items.append(item(id: f.syncId, type: "food", updatedAt: f.syncUpdatedAt,
                                  deleted: f.syncDeleted, payload: [
                                    "name": f.name,
                                    "calories": f.calories,
                                    "protein": f.protein,
                                    "carbs": f.carbs,
                                    "fat": f.fat,
                                    "portion": f.portion,
                                    "meal": f.meal,
                                    "date": f.date.timeIntervalSince1970
                                  ]))
            }
        }
        if let healths = try? context.fetch(FetchDescriptor<HealthMetric>()) {
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
        return items
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
    @MainActor
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
            guard let idStr = rec["id"] as? String,
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
            default:
                break
            }
        }
        return merged
    }

    @MainActor
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
                         syncId: id, syncUpdatedAt: remoteDate)
            context.insert(b)
            return 1
        }
    }

    @MainActor
    private func applyReminder(context: ModelContext, id: UUID, remoteDate: Date, deleted: Bool, payload: [String: Any]) -> Int {
        if let existing = (try? context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.syncId == id })))?.first {
            if deleted { context.delete(existing); return 1 }
            guard existing.syncUpdatedAt < remoteDate else { return 0 }
            existing.title = payload["title"] as? String ?? existing.title
            if (payload["dueNil"] as? Bool) == true { existing.due = nil }
            else { existing.due = Date(timeIntervalSince1970: payload["due"] as? Double ?? Date().timeIntervalSince1970) }
            existing.repeatRule = payload["repeatRule"] as? String ?? existing.repeatRule
            existing.priority = payload["priority"] as? String ?? existing.priority
            existing.done = payload["done"] as? Bool ?? existing.done
            existing.syncUpdatedAt = remoteDate
            return 1
        } else {
            if deleted { return 0 }
            let due: Date? = (payload["dueNil"] as? Bool) == true ? nil
                : Date(timeIntervalSince1970: payload["due"] as? Double ?? Date().timeIntervalSince1970)
            let r = Reminder(title: payload["title"] as? String ?? "",
                             due: due,
                             repeatRule: payload["repeatRule"] as? String ?? "none",
                             priority: payload["priority"] as? String ?? "medium",
                             done: payload["done"] as? Bool ?? false,
                             syncId: id, syncUpdatedAt: remoteDate)
            context.insert(r)
            return 1
        }
    }

    @MainActor
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
                              syncId: id, syncUpdatedAt: remoteDate)
            context.insert(f)
            return 1
        }
    }

    @MainActor
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
