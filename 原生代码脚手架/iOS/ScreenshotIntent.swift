// ScreenshotIntent.swift
// 无感截图识别的核心：用 App Intents 暴露一个「识别截图」系统动作。
// 用户在「快捷指令」里建「截屏」个人自动化，动作选「运行 识别截图」，
// 并关掉「运行前询问」→ 截图后后台自动跑这个 Intent，无需打开 App。
//
// 两种触发方式：
//  1) 快捷指令里用「获取最新截图」动作把图片传给本意图（最稳，推荐）；
//  2) 直接运行本意图且不传图时，自动从相册读取最近一张截图（需相册权限）。
import AppIntents
import UserNotifications
import Photos
import UIKit

@available(iOS 16, *)
struct ProcessScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "识别截图"
    static var description = IntentDescription("处理最新截图并识别内容，自动归类到对应模块。")
    static var openAppWhenRun: Bool = false   // false = 后台静默运行，实现「无感」
    static var parameterSummary: some ParameterSummary {
        Summary("识别 \(\.$screenshot)")
    }

    // 截图文件（可选）：从快捷指令「获取最新截图」动作传入。
    @Parameter(title: "截图", description: "要识别的截图图片", default: nil)
    var screenshot: IntentFile?

    @MainActor
    func perform() async throws -> some IntentResult {
        // 1. 拿图片数据：优先用传入的，否则从相册取最新截图
        let imageData: Data
        if let data = screenshot?.data {
            imageData = data
        } else if let data = await Self.latestScreenshotData() {
            imageData = data
        } else {
            throw IntentError.noImage
        }

        let base64 = imageData.base64EncodedString()

        // 2. 调云端识别
        let result = try await RecognizeService.recognize(base64: base64)

        // 3. 结果存入 App Group（主 App 打开时立刻读到）
        ScreenshotStore.save(result)

        // 4. 发本地通知提醒用户去确认（需通知权限）
        notify(result)

        return .result()
    }

    // 兜底：读取相册里最近一张「截图」类型的照片
    private static func latestScreenshotData() async -> Data? {
        // 无相册权限时直接返回，避免弹窗打断后台流程
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized ||
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            return nil
        }
        let options = PHFetchOptions()
        options.fetchLimit = 1
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let predicate = NSPredicate(
            format: "mediaType = %d AND (mediaSubtypes & %d) != 0",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        options.predicate = predicate
        guard let asset = PHAsset.fetchAssets(with: options).firstObject else { return nil }

        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: nil) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }
    }

    private func notify(_ result: RecognitionResult) {
        let content = UNMutableNotificationContent()
        content.title = "识别完成"
        content.body = "已识别为：\(result.types?.joined(separator: "、") ?? "其他")，点开确认"
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

enum IntentError: Error {
    case noImage
}

extension IntentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noImage:
            return "没有收到截图，也没读到相册最新截图。请在快捷指令里加「获取最新截图」动作传给本意图，或授予相册权限。"
        }
    }
}
