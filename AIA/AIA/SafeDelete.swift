import SwiftData
import Foundation
import WidgetKit

/// 数据变更后通知桌面小组件刷新（延后主线程，避免与 UI 动画叠加）。
/// 先预写四宫格共享摘要（Widget 跨进程读不到 HealthKit/ManualHealthStore），再刷新时间线。
private func notifyWidgetReload() {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            WidgetSnapshot.writeShared()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

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

    /// 删除某记录的本地原图前，先确认「还有没有其他存活记录也引用同一张图」。
    /// 仅当没有其他记录引用（即该图的所有引用记录都已被软删）时才真正删文件，
    /// 修复「一张图被多条账单共用（如一张截图里的多笔账单），删其中一条把整张图也删掉」的问题。
    /// 调用方需先把自己标记为 `syncDeleted = true`，这样查询时本记录不计入。
    private static func deleteImageIfOrphaned<T: PersistentModel & SyncDeletable & ImageNameHaving>(
        _ model: T, in context: ModelContext
    ) {
        let name = model.imageName
        guard let name, !name.isEmpty else { return }
        let alive = (try? context.fetch(FetchDescriptor<T>(
            predicate: #Predicate { $0.imageName == name && !$0.syncDeleted }
        )))?.count ?? 0
        if alive == 0 {
            LocalImageStore.delete(name)
        }
    }

    static func reminder(_ r: Reminder, in context: ModelContext) {
        // 把所有操作推到下一帧执行，避免与父页面的 @Query 重 fetch / 转场动画
        // 在主线程同步竞争（用户多次反馈删除最后一条后卡死）。
        DispatchQueue.main.async {
            ReminderNotificationManager.cancel(r)
            r.syncDeleted = true
            r.syncUpdatedAt = Date()
            deleteImageIfOrphaned(r, in: context)
        }
    }

    static func bill(_ b: Bill, in context: ModelContext) {
        DispatchQueue.main.async {
            b.syncDeleted = true
            b.syncUpdatedAt = Date()
            deleteImageIfOrphaned(b, in: context)
        }
    }

    static func food(_ f: FoodEntry, in context: ModelContext) {
        let targetSyncId = f.syncId
        DispatchQueue.main.async {
            f.syncDeleted = true
            f.syncUpdatedAt = Date()
            deleteImageIfOrphaned(f, in: context)
            // 清理来源标记，避免 FoodSource 残留挂空。
            if let fs = (try? context.fetch(FetchDescriptor<FoodSource>(predicate: #Predicate { $0.foodSyncId == targetSyncId })))?.first {
                context.delete(fs)
            }
        }
    }

    static func health(_ h: HealthMetric, in context: ModelContext) {
        DispatchQueue.main.async {
            h.syncDeleted = true
            h.syncUpdatedAt = Date()
            deleteImageIfOrphaned(h, in: context)
        }
    }

    static func recognitionRecord(_ r: RecognitionRecord, in context: ModelContext) {
        DispatchQueue.main.async {
            r.syncDeleted = true
            r.syncUpdatedAt = Date()
            deleteImageIfOrphaned(r, in: context)
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
    // >>> CHANGE-[2026-08-21 14:00:30]-[byID闭包内按ID现取统一根治] 开始
    // 原因：与 foodByID 同源隐患——旧实现在闭包外取活对象并捕获进 async 闭包，release 下对象可能已 fault。
    // 修复：notify/sync 移闭包外，闭包内按 id 现取活对象，不捕获外部引用。
    // 回退：恢复为 guard let x = context.model(for: id) ...; xxx(x, in: context)
    static func reminderByID(_ id: PersistentIdentifier, in context: ModelContext) {
        notifyWidgetReload()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        DispatchQueue.main.async {
            guard let r = context.model(for: id) as? Reminder else { return }
            r.syncDeleted = true
            r.syncUpdatedAt = Date()
            deleteImageIfOrphaned(r, in: context)
        }
    }

    static func billByID(_ id: PersistentIdentifier, in context: ModelContext) {
        notifyWidgetReload()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        DispatchQueue.main.async {
            guard let b = context.model(for: id) as? Bill else { return }
            b.syncDeleted = true
            b.syncUpdatedAt = Date()
            deleteImageIfOrphaned(b, in: context)
        }
    }
    // <<< CHANGE-[2026-08-21 14:00:30]-[byID闭包内按ID现取统一根治] 结束

    // >>> CHANGE-[2026-08-21 14:00:00]-[foodByID闭包内按ID现取根治fault] 开始
    // 原因：旧 foodByID 在闭包外用 context.model(for:) 取活对象后传给 food()，但 food() 把 f 捕获进
    //       DispatchQueue.main.async 闭包；图片识别记录(有 imageName)在闭包执行时若已无视图引用，
    //       SwiftData 会把它标 fault → 访问 f.syncDeleted/imageName 闪退。手动记录 imageName==nil 提前
    //       return 故不崩，表现为"仅图片识别记录闪退、手动添加不闪退"，且 debug 不优化不崩、release 必崩。
    // 修复：把 notifyWidgetReload / syncAfterLocalChange 移到闭包外(不依赖 f)，闭包内按 id 现取活对象，
    //       不再捕获任何外部对象引用，从根上消除 fault。
    // 回退：恢复为 guard let f = context.model(for: id) ...; food(f, in: context)
    static func foodByID(_ id: PersistentIdentifier, in context: ModelContext) {
        notifyWidgetReload()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        DispatchQueue.main.async {
            guard let f = context.model(for: id) as? FoodEntry else { return }
            // 先同步读出需要的值，再置软删标记，避免任何后续访问触发 fault
            let targetSyncId = f.syncId
            f.syncDeleted = true
            f.syncUpdatedAt = Date()
            // 图片孤儿清理：图片记录有 imageName 才会进来；手动记录 imageName==nil 直接跳过
            let name = f.imageName
            if let name, !name.isEmpty {
                let alive = (try? context.fetch(FetchDescriptor<FoodEntry>(
                    predicate: #Predicate { $0.imageName == name && !$0.syncDeleted }
                )))?.count ?? 0
                if alive == 0 { LocalImageStore.delete(name) }
            }
            // 清理来源标记，避免 FoodSource 残留挂空
            if let fs = (try? context.fetch(FetchDescriptor<FoodSource>(
                    predicate: #Predicate { $0.foodSyncId == targetSyncId }
               )))?.first {
                context.delete(fs)
            }
        }
    }
    // <<< CHANGE-[2026-08-21 14:00:00]-[foodByID闭包内按ID现取根治fault] 结束

    static func healthByID(_ id: PersistentIdentifier, in context: ModelContext) {
        notifyWidgetReload()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        DispatchQueue.main.async {
            guard let h = context.model(for: id) as? HealthMetric else { return }
            h.syncDeleted = true
            h.syncUpdatedAt = Date()
            deleteImageIfOrphaned(h, in: context)
        }
    }

    static func recognitionRecordByID(_ id: PersistentIdentifier, in context: ModelContext) {
        notifyWidgetReload()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        DispatchQueue.main.async {
            guard let r = context.model(for: id) as? RecognitionRecord else { return }
            r.syncDeleted = true
            r.syncUpdatedAt = Date()
            deleteImageIfOrphaned(r, in: context)
        }
    }

    static func waterLogByID(_ id: PersistentIdentifier, in context: ModelContext) {
        notifyWidgetReload()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        DispatchQueue.main.async {
            guard let w = context.model(for: id) as? WaterLog else { return }
            w.syncDeleted = true
            w.syncUpdatedAt = Date()
        }
    }

    static func chatMessageByID(_ id: PersistentIdentifier, in context: ModelContext) {
        notifyWidgetReload()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        DispatchQueue.main.async {
            guard let m = context.model(for: id) as? ChatMessage else { return }
            m.syncDeleted = true
            m.syncUpdatedAt = Date()
        }
    }

    static func merchantMetaByID(_ id: PersistentIdentifier, in context: ModelContext) {
        notifyWidgetReload()
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        DispatchQueue.main.async {
            guard let m = context.model(for: id) as? MerchantMeta else { return }
            m.syncDeleted = true
            m.syncUpdatedAt = Date()
        }
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

/// 拥有本地原图文件名的模型统一遵循，用于共享图引用判定。
protocol ImageNameHaving {
    var imageName: String? { get }
}

/// 这些模型的 imageName 字段即本地识别原图文件名，供 SafeDelete 做共享图引用判定。
extension Bill: ImageNameHaving {}
extension Reminder: ImageNameHaving {}
extension FoodEntry: ImageNameHaving {}
extension HealthMetric: ImageNameHaving {}
extension RecognitionRecord: ImageNameHaving {}
