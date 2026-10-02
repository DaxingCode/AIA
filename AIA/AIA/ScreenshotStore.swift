// ScreenshotStore.swift
// 后台「无感截图识别」的结果暂存。
//
// ⚠️ 为什么不用 App Group：
//   免费 Personal Team 无法启用 App Group 能力，UserDefaults(suiteName:) 会返回 nil。
//   而 App Intents 后台运行时就在「主 App 沙盒」内执行，读写主 App 的 Documents 目录
//   一定能与主 App 共享。所以这里改用沙盒文件存储，免费账号即可工作。
//
// 结构：Documents/pendingRecognition.json 存结构化结果；
//       Documents/attachments/<uuid>.jpg 存原图（确认页展示用，不上云）。
import Foundation
import UIKit
import AIAKit

enum ScreenshotStore {
    // >>> CHANGE-[2026-08-21 10:00:00]-[分享扩展打通] 开始
    // 兼容读取：分享扩展把结果写进 App Group（pendingRecognitionV2），无感截图写主 App Documents。
    // 主 App 启动时先读 App Group，再回退读 Documents，两条来源互不干扰。
    private static let appGroupId = "group.com.daxing.aia"
    private static let appGroupPendingKey = "pendingRecognitionV2"
    private static let appGroupContainer: URL = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()
    private static let appGroupAttachmentsDir = appGroupContainer.appendingPathComponent("attachments")
    // <<< CHANGE-[2026-08-21 10:00:00]-[分享扩展打通] 结束

    private static let docDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let pendingFile = docDir.appendingPathComponent("pendingRecognition.json")
    private static let attachmentsDir = docDir.appendingPathComponent("attachments")

    // >>> CHANGE-[2026-10-02 11:30:00]-[截屏无感识别多张队列化] 开始
    // MARK: - 队列化原语（修复：连续多张截图/分享只记录最后一张）
    // 单槽 → 有序队列。两份物理存储：
    //   - 主 App 无感截图写在 Documents/pendingRecognition.json（数组）；
    //   - 分享扩展写在 App Group pendingRecognitionV2（数组）。
    // 读取层「跨源取 at 最早」统一消费顺序；出队只移除最早一条，互不清另一来源。

    /// 存原图到指定附件目录，返回文件名（无图返回 nil）。
    private static func storeImage(_ imageData: Data?, in dir: URL) -> String? {
        guard let data = imageData, !data.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        try? data.write(to: dir.appendingPathComponent(name))
        return name
    }

    /// 读主 App Documents 队列（兼容旧版单对象 JSON 回退为 [x]）。
    private static func loadDocumentsQueue() -> [PendingRecognition] {
        guard let data = try? Data(contentsOf: pendingFile) else { return [] }
        if let arr = try? JSONDecoder().decode([PendingRecognition].self, from: data) { return arr }
        if let single = try? JSONDecoder().decode(PendingRecognition.self, from: data) { return [single] }
        return []
    }

    /// 写主 App Documents 队列（空则删文件；写盘用 .atomic 防半截 JSON 损坏整队列）。
    private static func writeDocuments(_ queue: [PendingRecognition]) {
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: pendingFile)
            return
        }
        try? JSONEncoder().encode(queue).write(to: pendingFile, options: .atomic)
    }

    /// 读 App Group 队列（兼容旧版单对象 JSON 回退为 [x]）。
    private static func loadAppGroupQueue() -> [PendingRecognition] {
        guard let data = UserDefaults(suiteName: appGroupId)?.data(forKey: appGroupPendingKey) else { return [] }
        if let arr = try? JSONDecoder().decode([PendingRecognition].self, from: data) { return arr }
        if let single = try? JSONDecoder().decode(PendingRecognition.self, from: data) { return [single] }
        return []
    }

    /// 写 App Group 队列（空则移除 key；写盘用 .atomic）。
    private static func writeAppGroup(_ queue: [PendingRecognition]) {
        let defaults = UserDefaults(suiteName: appGroupId)
        if queue.isEmpty {
            defaults?.removeObject(forKey: appGroupPendingKey)
        } else if let encoded = try? JSONEncoder().encode(queue) {
            defaults?.set(encoded, forKey: appGroupPendingKey)
        }
    }

    /// 跨两份来源取 at 最早者（公开 loadPending 委托此）。
    private static func peekEarliest() -> PendingRecognition? {
        let all = loadDocumentsQueue() + loadAppGroupQueue()
        return all.min(by: { $0.at < $1.at })
    }

    /// 仅出队最早一条（按 id 定位所属来源、删对应附件）；不影响另一条来源的待处理项。
    private static func dequeueEarliest() {
        let docs = loadDocumentsQueue()
        let ag = loadAppGroupQueue()
        let all = docs + ag
        guard let earliest = all.min(by: { $0.at < $1.at }) else { return }
        if let idx = docs.firstIndex(where: { $0.id == earliest.id }) {
            var q = docs
            let removed = q.remove(at: idx)
            writeDocuments(q)
            if let name = removed.imageName {
                try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(name))
            }
        } else if let idx = ag.firstIndex(where: { $0.id == earliest.id }) {
            var q = ag
            let removed = q.remove(at: idx)
            writeAppGroup(q)
            if let name = removed.imageName {
                try? FileManager.default.removeItem(at: appGroupAttachmentsDir.appendingPathComponent(name))
            }
        }
    }

    /// 后台识别完，把结果 + 原图（可选）落到主 App 沙盒（追加进队列，不再覆盖先写项）。
    /// imageData 传原图二进制，主 App 打开时确认页可展示原图。
    static func save(_ result: RecognitionResult, rawText: String, imageData: Data?,
                     source: RecognitionSource = .cloud) {
        let imageName = storeImage(imageData, in: attachmentsDir)
        var queue = loadDocumentsQueue()
        queue.append(PendingRecognition(result: result, rawText: rawText,
                                        imageName: imageName, source: source, at: Date()))
        writeDocuments(queue)
    }

    /// 后台识别被付费墙拦截（免费版无云端视觉 + 本地覆盖不到）时，只存原图 + 付费墙标记，
    /// 不存识别结果。主 App 打开时据此回插「升级 Pro」引导气泡，与对话页付费墙做法对齐。
    static func savePaywallBlocked(imageData: Data?) {
        let imageName = storeImage(imageData, in: attachmentsDir)
        var queue = loadDocumentsQueue()
        queue.append(PendingRecognition(result: RecognitionResult(types: ["none"], confidence: nil,
                                                                   bill: nil, bills: nil, food: nil, foods: nil,
                                                                   todo: nil, todos: nil, health: nil, healths: nil),
                                         rawText: "", imageName: imageName,
                                         source: .cloud, at: Date(),
                                         isPaywallBlocked: true))
        writeDocuments(queue)
    }

    /// 后台识别因「非权益类错误」失败（本地解析/网络超时/云端 5xx 等）时，只存原图 + 失败标记，
    /// 不存识别结果、也不标记付费墙。主 App 打开时据此回插友好提示（不误导已开通 Pro 用户去升级）。
    static func saveRecognizeFailed(imageData: Data?) {
        let imageName = storeImage(imageData, in: attachmentsDir)
        var queue = loadDocumentsQueue()
        queue.append(PendingRecognition(result: RecognitionResult(types: ["none"], confidence: nil,
                                                                   bill: nil, bills: nil, food: nil, foods: nil,
                                                                   todo: nil, todos: nil, health: nil, healths: nil),
                                         rawText: "", imageName: imageName,
                                         source: .cloud, at: Date(),
                                         isRecognizeFailed: true))
        writeDocuments(queue)
    }

    static func loadPending() -> PendingRecognition? {
        peekEarliest()
    }

    /// 读取 pending 关联的原图（确认页展示用）。App Group 与 Documents 两个位置都试。
    static func loadPendingImage() -> UIImage? {
        guard let name = loadPending()?.imageName else { return nil }
        if let img = UIImage(contentsOfFile: appGroupAttachmentsDir.appendingPathComponent(name).path) {
            return img
        }
        let url = attachmentsDir.appendingPathComponent(name)
        return UIImage(contentsOfFile: url.path)
    }

    /// 仅出队最早一条（不再整体清空，避免跨源/多张互清）。
    static func clearPending() {
        dequeueEarliest()
    }
    // <<< CHANGE-[2026-10-02 11:30:00]-[截屏无感识别多张队列化] 结束

    struct PendingRecognition: Codable, Identifiable {
        let result: RecognitionResult
        let rawText: String
        let imageName: String?
        /// 识别来源（本地 / 云端），无感截图后台识别后随结果一起暂存，供确认页展示标签。
        var source: RecognitionSource? = nil
        let at: Date
        /// 付费墙拦截标记：后台识别被拦截（免费版无云端视觉 + 本地覆盖不到）时为 true，
        /// 此时 result 为空占位，主 App 打开时据此回插「升级 Pro」引导气泡，不当作普通识别结果处理。
        var isPaywallBlocked: Bool = false
        /// 普通识别失败标记（非权益类：本地解析/网络/云端异常），主 App 打开时回插友好提示，
        /// 不误导已开通 Pro 的用户去升级。
        var isRecognizeFailed: Bool = false
        /// 来自相册分享扩展：图片已存好，但识别不在扩展端做，交给主 App 对话页内 runImageRecognition 完成。
        /// checkScreenshotPending 看到此标记时，不读 result、而是把图交给对话页识别链路。
        var fromShareExtension: Bool = false
        // 计算属性作 id，不进入 Codable，避免破坏 JSON 编解码。
        var id: String { (imageName ?? "none") + "@" + at.timeIntervalSince1970.description }
    }
}
