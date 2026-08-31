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

    /// 分享扩展：只把图片递给主 App，识别在主 App 对话页内进行（fromShareExtension=true）。
    /// 不调用云端识别，识别逻辑统一由主 App 的 runImageRecognition 复用拍照/相册那条链路。
    /// imageData 传原图二进制，主 App 打开后对话页展示原图并本地/云端识别。
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
        if let encoded = try? JSONEncoder().encode(pending) {
            UserDefaults(suiteName: AppGroup.id)?.set(encoded, forKey: pendingKeyV2)
        }
    }

    /// 读取 App Group 里待主 App 消费的 pending。
    static func loadPending() -> PendingRecognition? {
        guard let data = UserDefaults(suiteName: AppGroup.id)?.data(forKey: pendingKeyV2) else { return nil }
        return try? JSONDecoder().decode(PendingRecognition.self, from: data)
    }

    /// 读取 pending 关联的原图（对话页展示用），从 App Group 共享容器读。
    static func loadPendingImage() -> UIImage? {
        guard let name = loadPending()?.imageName else { return nil }
        let url = attachmentsDir.appendingPathComponent(name)
        return UIImage(contentsOfFile: url.path)
    }

    static func clearPending() {
        let name = loadPending()?.imageName
        let defaults = UserDefaults(suiteName: AppGroup.id)
        defaults?.removeObject(forKey: pendingKeyV2)
        defaults?.removeObject(forKey: pendingKeyV2 + "At")
        if let name {
            try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(name))
        }
    }
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
