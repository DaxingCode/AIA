// ScreenshotStore.swift
// 分享扩展与主 App 通过「App Group」共享数据。
// 作用：扩展里识别完的结果先存到这里，主 App 打开时立刻读到，保证「记了就能看到」。
//
// ⚠️ 与「主 App / AIA / ScreenshotStore.swift」保持结构完全一致：
//    主 App 的 loadPending 会先读 App Group 里的 PendingRecognition(JSON)，
//    再回退读主 App 自身的 Documents（无感截图来源）。两边用同一套 PendingRecognition 编解码。
// >>> CHANGE-[2026-08-21 10:00:00]-[分享扩展打通] 开始
import Foundation
import UIKit

enum AppGroup {
    static let id = "group.com.daxing.aia"
}

/// App Group 共享容器根目录（主 App 与扩展都指向同一处）。
private func appGroupContainer() -> URL {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
        ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

enum ScreenshotStore {
    // App Group 内 pending JSON 的 key（与旧版裸 RecognitionResult 的 key 区分，避免误读）。
    private static let pendingKeyV2 = "pendingRecognitionV2"
    private static let attachmentsDir = appGroupContainer().appendingPathComponent("attachments")

    // >>> CHANGE-[2026-10-02 11:30:00]-[截屏无感识别多张队列化] 开始
    /// 分享扩展：只把图片递给主 App，识别在主 App 对话页内进行（fromShareExtension=true）。
    /// 不调用云端识别，识别逻辑统一由主 App 的 runImageRecognition 复用拍照/相册那条链路。
    /// imageData 传原图二进制，主 App 打开后对话页展示原图并本地/云端识别。
    /// 连续分享多张时追加进 App Group 队列（不再覆盖先写项，修复只记录最后一张）。
    static func saveShareImage(_ imageData: Data?) {
        var imageName: String? = nil
        if let data = imageData, !data.isEmpty {
            try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
            imageName = UUID().uuidString + ".jpg"
            try? data.write(to: attachmentsDir.appendingPathComponent(imageName!))
        }
        let pending = PendingRecognition(result: RecognitionResult(types: ["none"]),
                                         rawText: "", imageName: imageName,
                                         source: .cloud, at: Date(),
                                         fromShareExtension: true)
        var queue = loadQueue()
        queue.append(pending)
        if let encoded = try? JSONEncoder().encode(queue) {
            UserDefaults(suiteName: AppGroup.id)?.set(encoded, forKey: pendingKeyV2)
        }
    }

    /// 读 App Group 队列（兼容旧版单对象 JSON 回退为 [x]）。
    private static func loadQueue() -> [PendingRecognition] {
        guard let data = UserDefaults(suiteName: AppGroup.id)?.data(forKey: pendingKeyV2) else { return [] }
        if let arr = try? JSONDecoder().decode([PendingRecognition].self, from: data) { return arr }
        if let single = try? JSONDecoder().decode(PendingRecognition.self, from: data) { return [single] }
        return []
    }

    /// 读取 App Group 里待主 App 消费的 pending（队首，at 最早）。
    static func loadPending() -> PendingRecognition? {
        loadQueue().min(by: { $0.at < $1.at })
    }

    /// 读取 pending 关联的原图（对话页展示用），从 App Group 共享容器读。
    static func loadPendingImage() -> UIImage? {
        guard let name = loadPending()?.imageName else { return nil }
        let url = attachmentsDir.appendingPathComponent(name)
        return UIImage(contentsOfFile: url.path)
    }

    /// 仅出队最早一条（不再整体清空，避免连续多张互清）。
    static func clearPending() {
        let name = loadPending()?.imageName
        var queue = loadQueue()
        if let earliest = queue.min(by: { $0.at < $1.at }),
           let idx = queue.firstIndex(where: { $0.id == earliest.id }) {
            queue.remove(at: idx)
        }
        let defaults = UserDefaults(suiteName: AppGroup.id)
        if queue.isEmpty {
            defaults?.removeObject(forKey: pendingKeyV2)
        } else if let encoded = try? JSONEncoder().encode(queue) {
            defaults?.set(encoded, forKey: pendingKeyV2)
        }
        if let name {
            try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(name))
        }
    }
    // <<< CHANGE-[2026-10-02 11:30:00]-[截屏无感识别多张队列化] 结束
}

/// 与主 App / AIA / ScreenshotStore.swift 的 PendingRecognition 字段完全一致。
struct PendingRecognition: Codable, Identifiable {
    let result: RecognitionResult
    let rawText: String
    let imageName: String?
    var source: RecognitionSource? = nil
    let at: Date
    var isPaywallBlocked: Bool = false
    var isRecognizeFailed: Bool = false
    var fromShareExtension: Bool = false
    var id: String { (imageName ?? "none") + "@" + at.timeIntervalSince1970.description }
}
// <<< CHANGE-[2026-08-21 10:00:00]-[分享扩展打通] 结束
