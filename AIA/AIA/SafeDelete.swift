import SwiftData
import Foundation

/// 安全删除工具。
///
/// 根因：四个详情页（待办/账单/饮食/健康）的记录对象本身就是 `NavigationLink` 的目标。
/// 旧逻辑在 `dismiss()` 返回动画仍在进行时直接 `context.delete(obj)`，把对象变成 fault，
/// 动画尾声 SwiftUI 还在读 `obj.xxx` 属性 → 崩溃（SwiftData fault / 访问已删除对象）。
///
/// 修复：先「软删除」——标记 `syncDeleted = true` 并保存，所有按 `!syncDeleted` 过滤的
/// `@Query` 会立即把该记录从列表隐藏；等返回动画结束（1 秒后）再真正从 SwiftData 硬删。
/// 软删除期间对象仍是有效实体，详情页在动画中读属性不会触发 fault。
///
/// **关键**：软删时不显式 `context.save()`——让 SwiftData autosave 处理（autosaveEnabled=true）。
/// 显式同步 save 与 `dismiss()` 触发的 NavigationStack 路径变化 + `@Query` 重新 fetch 三者
/// 在主线程叠加会造成 UI 卡死（用户 13:59 反馈「点详情页删除卡住不动」即此因）。
///
/// ---
///
/// **修复 2026-07-30：消除与 CloudSyncManager 的时间竞争**
///
/// 问题：`scheduleHardDelete` 在软删 1 秒后硬删记录，但 CloudSyncManager 的
/// `syncAfterLocalChange` 使用 3 秒防抖才推送。硬删后 `buildPushItems` 读不到记录，
/// `deleted=true` 标志无法到达云端，后续 pull 把记录重新插入本地。
///
/// 方案：移除 `scheduleHardDelete`，仅保留软删。软删记录（`syncDeleted=true`）通过
/// `buildPushItems`（无 `!syncDeleted` 过滤）正常推送到云端，云端标记 deleted=true 后
/// 不会在 pull 中返回。本地墓碑由 CloudSyncManager 在 push 成功后统一清理。
enum SafeDelete {

    static func reminder(_ r: Reminder, in context: ModelContext) {
        // 把所有操作推到下一帧执行，避免与父页面的 @Query 重 fetch / 转场动画
        // 在主线程同步竞争（用户多次反馈删除最后一条后卡死）。
        DispatchQueue.main.async {
            ReminderNotificationManager.cancel(r)
            LocalImageStore.delete(r.imageName)
            r.syncDeleted = true
            r.syncUpdatedAt = Date()
        }
    }

    static func bill(_ b: Bill, in context: ModelContext) {
        DispatchQueue.main.async {
            LocalImageStore.delete(b.imageName)
            b.syncDeleted = true
            b.syncUpdatedAt = Date()
        }
    }

    static func food(_ f: FoodEntry, in context: ModelContext) {
        let targetSyncId = f.syncId
        DispatchQueue.main.async {
            LocalImageStore.delete(f.imageName)
            // 清理来源标记，避免 FoodSource 残留挂空。
            if let fs = (try? context.fetch(FetchDescriptor<FoodSource>(predicate: #Predicate { $0.foodSyncId == targetSyncId })))?.first {
                context.delete(fs)
            }
            f.syncDeleted = true
            f.syncUpdatedAt = Date()
        }
    }

    static func health(_ h: HealthMetric, in context: ModelContext) {
        DispatchQueue.main.async {
            LocalImageStore.delete(h.imageName)
            h.syncDeleted = true
            h.syncUpdatedAt = Date()
        }
    }

    static func recognitionRecord(_ r: RecognitionRecord, in context: ModelContext) {
        DispatchQueue.main.async {
            LocalImageStore.delete(r.imageName)
            r.syncDeleted = true
            r.syncUpdatedAt = Date()
        }
    }

    static func waterLog(_ w: WaterLog, in context: ModelContext) {
        DispatchQueue.main.async {
            w.syncDeleted = true
            w.syncUpdatedAt = Date()
        }
    }

    static func chatMessage(_ m: ChatMessage, in context: ModelContext) {
        DispatchQueue.main.async {
            m.syncDeleted = true
            m.syncUpdatedAt = Date()
        }
    }

    static func merchantMeta(_ m: MerchantMeta, in context: ModelContext) {
        DispatchQueue.main.async {
            m.syncDeleted = true
            m.syncUpdatedAt = Date()
        }
    }

    // MARK: - ID 版本（避免捕获已 fault 的对象）
    /// 详情页 pop 后若没有任何视图再引用该对象，SwiftData 可能把它标记为 fault。
    /// 此时若直接访问传入对象的属性会触发 fault 异常并闪退。
    /// ID 版本在真正执行时通过 context.model(for:) 重新取活对象，避免该问题。
    static func reminderByID(_ id: PersistentIdentifier, in context: ModelContext) {
        guard let r = context.model(for: id) as? Reminder else { return }
        reminder(r, in: context)
    }

    static func billByID(_ id: PersistentIdentifier, in context: ModelContext) {
        guard let b = context.model(for: id) as? Bill else { return }
        bill(b, in: context)
    }

    static func foodByID(_ id: PersistentIdentifier, in context: ModelContext) {
        guard let f = context.model(for: id) as? FoodEntry else { return }
        food(f, in: context)
    }

    static func healthByID(_ id: PersistentIdentifier, in context: ModelContext) {
        guard let h = context.model(for: id) as? HealthMetric else { return }
        health(h, in: context)
    }

    static func recognitionRecordByID(_ id: PersistentIdentifier, in context: ModelContext) {
        guard let r = context.model(for: id) as? RecognitionRecord else { return }
        recognitionRecord(r, in: context)
    }

    static func waterLogByID(_ id: PersistentIdentifier, in context: ModelContext) {
        guard let w = context.model(for: id) as? WaterLog else { return }
        waterLog(w, in: context)
    }

    static func chatMessageByID(_ id: PersistentIdentifier, in context: ModelContext) {
        guard let m = context.model(for: id) as? ChatMessage else { return }
        chatMessage(m, in: context)
    }

    static func merchantMetaByID(_ id: PersistentIdentifier, in context: ModelContext) {
        guard let m = context.model(for: id) as? MerchantMeta else { return }
        merchantMeta(m, in: context)
    }
}

/// 需要支持软删除的模型统一遵循此协议（所有 @Model 均已拥有 syncDeleted / syncUpdatedAt 字段）。
protocol SyncDeletable {
    var syncDeleted: Bool { get set }
    var syncUpdatedAt: Date { get set }
}

extension Reminder: SyncDeletable {}
extension Bill: SyncDeletable {}
extension FoodEntry: SyncDeletable {}
extension HealthMetric: SyncDeletable {}
extension RecognitionRecord: SyncDeletable {}
extension ChatMessage: SyncDeletable {}
extension MerchantMeta: SyncDeletable {}
extension WaterLog: SyncDeletable {}
