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
/// 1s 后硬删时再 save——此时详情页已 dismiss、@Query 无视图引用，主线程 save 不会卡。
enum SafeDelete {

    static func reminder(_ r: Reminder, in context: ModelContext) {
        // 把所有操作推到下一帧执行，避免与父页面的 @Query 重 fetch / 转场动画
        // 在主线程同步竞争（用户多次反馈删除最后一条后卡死）。
        DispatchQueue.main.async {
            ReminderNotificationManager.cancel(r)
            LocalImageStore.delete(r.imageName)
            r.syncDeleted = true
            r.syncUpdatedAt = Date()
            scheduleHardDelete(id: r.persistentModelID, in: context)
        }
    }

    static func bill(_ b: Bill, in context: ModelContext) {
        DispatchQueue.main.async {
            LocalImageStore.delete(b.imageName)
            b.syncDeleted = true
            b.syncUpdatedAt = Date()
            scheduleHardDelete(id: b.persistentModelID, in: context)
        }
    }

    static func food(_ f: FoodEntry, in context: ModelContext) {
        DispatchQueue.main.async {
            LocalImageStore.delete(f.imageName)
            f.syncDeleted = true
            f.syncUpdatedAt = Date()
            scheduleHardDelete(id: f.persistentModelID, in: context)
        }
    }

    static func health(_ h: HealthMetric, in context: ModelContext) {
        DispatchQueue.main.async {
            LocalImageStore.delete(h.imageName)
            h.syncDeleted = true
            h.syncUpdatedAt = Date()
            scheduleHardDelete(id: h.persistentModelID, in: context)
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

    /// 用 persistentModelID 重新取活对象并二次确认仍是软删除状态，避免误删。
    /// **不显式 `context.save()`**——`context.delete(live)` 是同步非阻塞；SwiftData
    /// autosaveEnabled=true 会在合适时机（contextWillSave 通知、process termination、
    /// 视图状态变化）自动持久化。显式 save 会阻塞主线程等异步写盘，删除最后一条记录时
    /// 1s 后突然冻结 UI（用户 14:56 反馈）。1s 时 detail view 早已 dismiss、@Query 无引用，
    /// 主线程 save 完全没必要。
    private static func scheduleHardDelete(id: PersistentIdentifier, in context: ModelContext) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [context] in
            guard let live = context.model(for: id) as? any PersistentModel,
                  (live as? SyncDeletable)?.syncDeleted == true else { return }
            context.delete(live)
            // 不调 try? context.save()，依赖 autosave（autosaveEnabled=true）
        }
    }
}

/// 需要支持软删除的模型统一遵循此协议（四个 @Model 均已拥有 syncDeleted / syncUpdatedAt 字段）。
protocol SyncDeletable {
    var syncDeleted: Bool { get set }
    var syncUpdatedAt: Date { get set }
}

extension Reminder: SyncDeletable {}
extension Bill: SyncDeletable {}
extension FoodEntry: SyncDeletable {}
extension HealthMetric: SyncDeletable {}
