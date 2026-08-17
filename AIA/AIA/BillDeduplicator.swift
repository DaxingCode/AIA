// BillDeduplicator.swift
// 一键清理「同一商户 + 同金额 + 同分类 + 时间紧邻」的重复账单。
// 设计：按时间升序扫描，以「上一个保留者」为锚，若与锚同组且间隔 ≤ 阈值则视为重复，软删（SafeDelete）。
//      同组定义：merchant / amount(±0.005) / category / isIncome 全部相同。
//      阈值默认 300 秒（5 分钟），既能在一次测试中紧邻产生的重复被清掉，又不会误删间隔较远的真实重复消费。
// 注意：清理只动账单（用户反馈的重复均为账单）。饮食/待办如需可后续扩展。
import SwiftData
import Foundation

enum BillDeduplicator {
    /// 扫描并清理重复账单。返回被清理的条数。
    /// - Parameters:
    ///   - context: 模型上下文。
    ///   - threshold: 同组记录之间允许的最大时间间隔（秒），默认 300。
    ///   - onProgress: 可选进度回调，用于 UI 提示（如「已清理 X 条重复账单」）。
    @MainActor
    static func cleanDuplicates(in context: ModelContext, threshold: TimeInterval = 300,
                                onProgress: ((Int) -> Void)? = nil) -> Int {
        // 只取未软删的账单参与去重，避免重复清理已标记删除的记录
        var desc = FetchDescriptor<Bill>(
            predicate: #Predicate { $0.syncDeleted == false },
            sortBy: [SortDescriptor(\.time, order: .forward)]
        )
        // 设置 fetchLimit 防止极端数据量下 OOM（假设单次清理上限 10000 条足够）
        desc.fetchLimit = 10000
        let all = (try? context.fetch(desc)) ?? []
        guard all.count > 1 else {
            onProgress?(0)
            return 0
        }

        var toDelete: [Bill] = []
        var lastKept = all[0]
        for i in 1..<all.count {
            let cand = all[i]
            let sameGroup = cand.merchant == lastKept.merchant
                && abs(cand.amount - lastKept.amount) < 0.005
                && cand.category == lastKept.category
                && cand.isIncome == lastKept.isIncome
            let within = cand.time.timeIntervalSince(lastKept.time) <= threshold
            if sameGroup && within {
                toDelete.append(cand)
            } else {
                lastKept = cand
            }
        }

        guard !toDelete.isEmpty else {
            onProgress?(0)
            return 0
        }

        // >>> CHANGE-[2026-08-17 11:20:00]-[临时对象失效崩溃] 开始
        // 原因：toDelete 里来自 fetFetch 的活对象在异步/列表刷新窗口下可能被释放或失效，
        //       直接传活对象进 SafeDelete.bill 的 DispatchQueue.main.async 闭包会在下一帧访问已失效对象 → fatalError。
        // 回退：恢复为 for b in toDelete { SafeDelete.bill(b, in: context) } 即可。
        for b in toDelete { SafeDelete.billByID(b.persistentModelID, in: context) }
        // <<< CHANGE-[2026-08-17 11:20:00]-[临时对象失效崩溃] 结束
        // 自动入库的防抖同步会由 autoSave 触发，此处额外触发确保去重结果尽快推送
        CloudSyncManager.shared.syncAfterLocalChange(context: context)
        onProgress?(toDelete.count)
        print("[BillDeduplicator] 已清理 \(toDelete.count) 条重复账单")
        return toDelete.count
    }
}
