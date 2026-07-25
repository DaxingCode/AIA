// ScreenshotIntent.swift
// 无感截屏识别的核心：用 App Intents 暴露一个「阿宝AI自动记账、记待办、记饮食」系统动作。
// 用户在「快捷指令」里建「截屏」个人自动化，动作选「运行 阿宝AI自动记账、记待办、记饮食」，
// 并关掉「运行前询问」→ 截屏后后台自动跑这个 Intent，无需打开 App。
//
// 两种触发方式：
//  1) 快捷指令里用「获取最新截屏」动作把图片传给本意图（最稳，推荐）；
//  2) 直接运行本意图且不传图时，自动从相册读取最近一张截屏（需相册权限）。
import AppIntents
import UserNotifications
import Photos
import UIKit
import SwiftData

@available(iOS 16, *)
struct ProcessScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "阿宝AI自动记账、记待办、记饮食"
    static var description = IntentDescription("处理最新截屏并识别内容，自动记账、记待办、记饮食到对应模块。")
    static var openAppWhenRun: Bool = false   // false = 后台静默运行，实现「无感」
    static var parameterSummary: some ParameterSummary {
        Summary("识别 \(\.$screenshot)")
    }

    // 截屏文件（可选）：从快捷指令「获取最新截屏」动作传入。
    @Parameter(title: "截屏", description: "要识别的截屏图片", default: nil)
    var screenshot: IntentFile?

    @MainActor
    func perform() async throws -> some IntentResult {
        // 1. 拿图片数据：优先用传入的，否则从相册取最新截屏
        let imageData: Data
        if let data = screenshot?.data {
            imageData = data
        } else if let data = await Self.latestScreenshotData() {
            imageData = data
        } else {
            throw IntentError.noImage
        }

        // 2. 本地优先识别：有容器才能查 MerchantMeta 经验库；OCR 始终本地跑，命中账单即跳过云端
        let output: (result: RecognitionResult, rawText: String, source: RecognizeService.RecognitionSource)
        if let container = AppDelegate.sharedContainer {
            output = try await RecognizeService.recognizeWithLocalPriority(imageData: imageData, in: ModelContext(container))
        } else {
            let cloud = try await RecognizeService.recognizeResilient(imageData: imageData)
            output = (cloud.result, cloud.rawText, .cloud)
        }
        let result = output.result

        // 3. 结果 + 原图存到主 App 沙盒（App 打开时弹确认页；免费账号也能用，不依赖 App Group）
        ScreenshotStore.save(result, rawText: output.rawText, imageData: imageData, source: output.source)

        // 5. 发本地通知提醒用户去确认（需通知权限）
        notify(result)

        return .result()
    }

    // 兜底：读取相册里最近一张「截屏」类型的照片
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
        let labels = (result.types ?? []).map { typeLabel($0) }
        let text = labels.isEmpty ? "内容" : labels.joined(separator: "、")
        content.body = "已记录\(text)，点击可修改、确认"
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// 类型路由 key → 中文标签（与识别记录/确认页保持一致）
    private func typeLabel(_ type: String) -> String {
        switch type {
        case "bill":   return "账单"
        case "todo":   return "待办"
        case "food":   return "饮食"
        case "health": return "健康"
        case "none":   return "其他"
        default:       return "其他"
        }
    }
}

// MARK: - App Shortcuts 自动注册
// 让「阿宝AI自动记账、记待办、记饮食」动作随 App 安装即自动出现在「快捷指令」App 里，
// 用户建「截屏」自动化时，动作区顶部直接就有它，无需手动搜索/搭建。
// 也支持对 Siri 说「阿宝AI管家 自动记账记待办」直接触发。
@available(iOS 17, *)
struct AIAAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ProcessScreenshotIntent(),
            phrases: [
                "\(.applicationName)自动记账记待办记饮食",
                "用\(.applicationName)记账记待办记饮食",
                "\(.applicationName)记账记待办记饮食"
            ],
            shortTitle: "自动记账、记待办、记饮食",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: TellAIAIntent(),
            phrases: [
                "用\(.applicationName)记",
                "\(.applicationName)记账",
                "跟\(.applicationName)记一笔",
                "记账用\(.applicationName)"
            ],
            shortTitle: "用阿宝记",
            systemImageName: "mic.fill"
        )
    }
}

enum IntentError: Error {
    case noImage
    case compressFailed
}

extension IntentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noImage:
            return "没有收到截屏，也没读到相册最新截屏。请在快捷指令里加「获取最新截屏」动作传给本意图，或授予相册权限。"
        case .compressFailed:
            return "图片压缩失败，无法上传识别。"
        }
    }
}
