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

enum ScreenshotStore {
    private static let docDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let pendingFile = docDir.appendingPathComponent("pendingRecognition.json")
    private static let attachmentsDir = docDir.appendingPathComponent("attachments")

    /// 后台识别完，把结果 + 原图（可选）落到主 App 沙盒。
    /// imageData 传原图二进制，主 App 打开时确认页可展示原图。
    static func save(_ result: RecognitionResult, rawText: String, imageData: Data?,
                     source: RecognizeService.RecognitionSource = .cloud) {
        var imageName: String? = nil
        if let data = imageData, !data.isEmpty {
            try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
            imageName = UUID().uuidString + ".jpg"
            try? data.write(to: attachmentsDir.appendingPathComponent(imageName!))
        }
        let pending = PendingRecognition(result: result, rawText: rawText,
                                         imageName: imageName, source: source, at: Date())
        try? JSONEncoder().encode(pending).write(to: pendingFile)
    }

    static func loadPending() -> PendingRecognition? {
        guard let data = try? Data(contentsOf: pendingFile) else { return nil }
        return try? JSONDecoder().decode(PendingRecognition.self, from: data)
    }

    /// 读取 pending 关联的原图（确认页展示用）。
    static func loadPendingImage() -> UIImage? {
        guard let name = loadPending()?.imageName else { return nil }
        let url = attachmentsDir.appendingPathComponent(name)
        return UIImage(contentsOfFile: url.path)
    }

    static func clearPending() {
        let name = loadPending()?.imageName
        try? FileManager.default.removeItem(at: pendingFile)
        if let name {
            try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(name))
        }
    }

    struct PendingRecognition: Codable, Identifiable {
        let result: RecognitionResult
        let rawText: String
        let imageName: String?
        /// 识别来源（本地 / 云端），无感截图后台识别后随结果一起暂存，供确认页展示标签。
        var source: RecognizeService.RecognitionSource? = nil
        let at: Date
        // 计算属性作 id，不进入 Codable，避免破坏 JSON 编解码。
        var id: String { (imageName ?? "none") + "@" + at.timeIntervalSince1970.description }
    }
}
