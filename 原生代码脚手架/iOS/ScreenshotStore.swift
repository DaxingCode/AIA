// ScreenshotStore.swift
// 截图 Extension / App Intent 与主 App 通过「App Group」共享数据。
// 作用：后台识别完的结果先存到这里，主 App 打开时立刻读到，保证「记了就能看到」。
// 注意：在 Xcode 的 Signing & Capabilities 里，给主 App 和扩展 target
//       都加上同一个 App Group（见 README）。
import Foundation

enum AppGroup {
    // ← 改成你自己的 App Group，格式一般是 group.<你的bundleid>.aia
    static let id = "group.com.daxing.aia"
}

struct ScreenshotStore {
    // 后台识别结果写这里
    static func save(_ result: RecognitionResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        let defaults = UserDefaults(suiteName: AppGroup.id)
        defaults?.set(data, forKey: "pendingRecognition")
        defaults?.set(Date(), forKey: "pendingRecognitionAt")
    }

    // 主 App 启动时读这里，有就弹「结果确认」页
    static func loadPending() -> RecognitionResult? {
        guard let data = UserDefaults(suiteName: AppGroup.id)?
                .data(forKey: "pendingRecognition") else { return nil }
        return try? JSONDecoder().decode(RecognitionResult.self, from: data)
    }

    static func clearPending() {
        let defaults = UserDefaults(suiteName: AppGroup.id)
        defaults?.removeObject(forKey: "pendingRecognition")
        defaults?.removeObject(forKey: "pendingRecognitionAt")
    }
}
