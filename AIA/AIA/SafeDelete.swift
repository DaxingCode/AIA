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
    // >>> CHANGE-[2026-08-31 12:23:50]-[删除带图记录崩溃修复] 开始
    // 原因：原实现是泛型 `deleteImageIfOrphaned<T: PersistentModel & SyncDeletable & ImageNameHaving>`，
    //       内部查库用 `#Predicate { $0.imageName == name && !$0.syncDeleted }`。
    //       $0 是泛类型 T，imageName / syncDeleted 取的是 ImageNameHaving / SyncDeletable
    //       **协议声明的 keypath**，SwiftData 拿它去映射数据表的列时查不到 →
    //       Schema.KeyPathCache.validateAndCache → _assertionFailure → EXC_BREAKPOINT(SIGTRAP)。
    //       崩溃栈（TestFlight 好记AI 1.0.1 (5)，2026-08-31 12:11:25）：
    //         SafeDelete.swift:52 deleteImageIfOrphaned ← SafeDelete.swift:144 reminderByID
    //       仅当 imageName 非空才走到 fetch，所以「手动添加（无图）的记录」删除不受影响，
    //       表现为「截图/拍照识别出来的记录一删就崩」。
    // 修复：拆成 5 个具体类型重载，#Predicate 的 $0 是具体模型类，keypath 能正确映射到列。
    //       调用点（`deleteImageIfOrphaned(r, in: context)`）凭参数类型自动匹配，一行都不用改。
    // 回退：git revert 本 commit（恢复为泛型版本）。
    private static func deleteImageIfOrphaned(_ model: Reminder, in context: ModelContext) {
        let name = model.imageName
        guard let name, !name.isEmpty else { return }
        let alive = (try? context.fetch(FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.imageName == name && !$0.syncDeleted }
        )))?.count ?? 0
        if alive == 0 {
            LocalImageStore.delete(name)
        }
    }

    private static func deleteImageIfOrphaned(_ model: Bill, in context: ModelContext) {
        let name = model.imageName
        guard let name, !name.isEmpty else { return }
        let alive = (try? context.fetch(FetchDescriptor<Bill>(
            predicate: #Predicate { $0.imageName == name && !$0.syncDeleted }
        )))?.count ?? 0
        if alive == 0 {
            LocalImageStore.delete(name)
        }
    }

    private static func deleteImageIfOrphaned(_ model: FoodEntry, in context: ModelContext) {
        let name = model.imageName
        guard let name, !name.isEmpty else { return }
        let alive = (try? context.fetch(FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.imageName == name && !$0.syncDeleted }
        )))?.count ?? 0
        if alive == 0 {
            LocalImageStore.delete(name)
        }
    }

    private static func deleteImageIfOrphaned(_ model: HealthMetric, in context: ModelContext) {
        let name = model.imageName
        guard let name, !name.isEmpty else { return }
        let alive = (try? context.fetch(FetchDescriptor<HealthMetric>(
            predicate: #Predicate { $0.imageName == name && !$0.syncDeleted }
        )))?.count ?? 0
        if alive == 0 {
            LocalImageStore.delete(name)
        }
    }

    private static func deleteImageIfOrphaned(_ model: RecognitionRecord, in context: ModelContext) {
        let name = model.imageName
        guard let name, !name.isEmpty else { return }
        let alive = (try? context.fetch(FetchDescriptor<RecognitionRecord>(
            predicate: #Predicate { $0.imageName == name && !$0.syncDeleted }
        )))?.count ?? 0
        if alive == 0 {
            LocalImageStore.delete(name)
        }
    }
    // <<< CHANGE-[2026-08-31 12:23:50]-[删除带图记录崩溃修复] 结束

    static func reminder(_ r: Reminder, in context: ModelContext) {
        // 把所有操作推到下一帧执行，避免与父页面的 @Query 重 fetch / 转场动画
        // 在主线程同步竞争（用户多次反馈删除最后一条后卡死）。
        DispatchQueue.main.async {
            // >>> CHANGE-[2026-09-02 14:43:11]-[删除待办取消提醒通知] 开始
            // 同步段先取 syncId 字符串再用 bySyncId 重载，避免闭包内对象 fault 取错 id。
            ReminderNotificationManager.cancel(bySyncId: r.syncId.uuidString)
            // <<< CHANGE-[2026-09-02 14:43:11]-[删除待办取消提醒通知] 结束
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
            // >>> CHANGE-[2026-09-02 14:43:11]-[删除待办取消提醒通知] 开始
            // 原因：删除只置 syncDeleted，未撤销系统里已排程的本地通知 → 删掉的待办到点仍弹提醒。
            //      本应走 SafeDelete.reminder(_:)（那版带 cancel），但 08-17 防崩溃改造把所有删除
            //      切到 reminderByID 时漏掉了 cancel 这一行，导致 8 个删除入口全不撤通知。
            //      同步段先取 syncId 字符串再用 bySyncId 重载，避免闭包内对象 fault 取错 id。
            // 回退：删除下面两行。
            let targetSyncId = r.syncId.uuidString
            ReminderNotificationManager.cancel(bySyncId: targetSyncId)
            // <<< CHANGE-[2026-09-02 14:43:11]-[删除待办取消提醒通知] 结束
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
            // 图片孤儿清理：图片记录有 imageName 才会进来；手动记录 imageName==nil 直接跳过。
            // >>> CHANGE-[2026-08-31 12:23:50]-[删除带图记录崩溃修复] 开始
            // 原因：这里原本内联了一份 FoodEntry 的孤儿图查询（2026-08-21 为了绕开泛型 #Predicate
            //       崩溃而手写）。现在泛型版已拆为具体类型重载，内联副本可安全复用统一实现。
            //       注意：必须在标记 syncDeleted 之后调用——谓词带 !syncDeleted，自己不计入存活引用。
            // 回退：恢复为上方的内联 FetchDescriptor<FoodEntry> 写法。
            deleteImageIfOrphaned(f, in: context)
            // <<< CHANGE-[2026-08-31 12:23:50]-[删除带图记录崩溃修复] 结束
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
        // >>> CHANGE-[2026-08-22 08:33:31]-[删除消息立即生效] 开始
        // 原因：原 DispatchQueue.main.async 把标记软删延后，与 @Query 响应式刷新竞态，
        //       点一次删除时 @Query 尚未刷新、消息仍显示，表现为"点了没反应、要点第二次"。
        //       改为同步标记，@Query 同一轮 diff 即过滤该消息，一次点击立即消失。
        // 注：旧防崩补丁（fetchMessages 重拉释放引用）的前提已不存在——当前列表全走 @Query，
        //       context.model(for:) 取的是活对象，标记 syncDeleted 仅隐藏、不释放。
        // 回退：改回 DispatchQueue.main.async { guard let m = context.model(for: id)... }
        guard let m = context.model(for: id) as? ChatMessage else { return }
        m.syncDeleted = true
        m.syncUpdatedAt = Date()
        // save 让 SwiftData 落库并触发 @Query 结果集刷新（关键；不 save 则当前页缓存不更新，消息要退出重进才消失）
        try? context.save()
        // <<< CHANGE-[2026-08-22 08:33:31]-[删除消息立即生效] 结束
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
