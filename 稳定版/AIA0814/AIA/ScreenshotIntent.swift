// ScreenshotIntent.swift
// 无感截屏识别的核心：用 App Intents 暴露一个「好记AI自动记账、记待办、记饮食」系统动作。
// 用户在「快捷指令」里建「截屏」个人自动化，动作选「运行 好记AI自动记账、记待办、记饮食」，
// 并关掉「运行前询问」→ 截屏后后台自动跑这个 Intent，无需打开 App。
//
// 两种触发方式：
//  1) 快捷指令里用「获取最新截屏」动作把图片传给本意图（最稳，推荐）；
//  2) 直接运行本意图且不传图时，自动从相册读取最近一张截屏（需相册权限）。
import AppIntents
import UserNotifications
import Photos
import UIKit
import AIAKit
import SwiftData

@available(iOS 16, *)
struct ProcessScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "好记AI自动记账、记待办、记饮食"
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
        // 免费版发「视觉专属场景」时识别会抛 AIAEntitlementError（付费墙拦截）。
        // 此时不像对话页那样能立刻回插升级气泡，但也不能让后台直接失败丢数据——
        // 而是存一条带付费墙标记的 pending，等主 App 打开时回插「升级 Pro」引导气泡（与对话页做法对齐）。
        //
        // ⚠️ 后台 Intent 可能在 App 完成 entitlement 刷新前就触发，此时 plan 还是 .unknown，
        // 若直接判「无云端视觉权限」会误把已开通 Pro 的用户也拦成付费墙。
        // 因此先 refresh 一次，确保执行识别时 plan 最新；刷新失败也以本地兜底，不误伤真实用户。
        await EntitlementManager.shared.refresh()

        let output: (result: RecognitionResult, rawText: String, source: RecognitionSource)
        do {
            if let container = AppDelegate.sharedContainer {
                output = try await RecognizeService.recognizeWithLocalPriority(imageData: imageData, in: ModelContext(container))
            } else {
                let cloud = try await RecognizeService.recognizeResilient(imageData: imageData)
                output = (cloud.result, cloud.rawText, .cloud)
            }
        } catch {
            // 仅「付费墙拦截」错误才走升级 Pro 引导：这是明确由权益判定触发，与对话页做法对齐。
            if error is AIAEntitlementError {
                ScreenshotStore.savePaywallBlocked(imageData: imageData)
                notifyPaywallBlocked()
                return .result()
            }
            // 其它错误（本地 OCR/解析失败、网络超时、云端 5xx 等非权益问题）：
            // 绝不提示「升级 Pro」（会误伤已开通用户），也不把生硬错误码抛给快捷指令。
            // 统一存一条普通失败 pending，主 App 打开时回插友好提示，避免后台静默丢数据。
            ScreenshotStore.saveRecognizeFailed(imageData: imageData)
            notifyRecognizeFailed()
            return .result()
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
        // 点通知时让 AppDelegate 路由到「截图待处理」流程（按设置分流 + 跳对话页）。
        // 通知带 SCREENSHOT_RECOGNITION category → 系统显示「保存 / 查看」两个 Action 按钮
        // （category 在 AppDelegate.didFinishLaunching 注册一次）。
        // userInfo["route"]=screenshotRecognition：点横幅/锁屏=按设置分流；
        // 点「保存」Action → AppDelegate 改发 route=screenshotRecognition:save，本次强制自动入库，
        // 即便用户在设置里选的是「确认后再保存」，也能在通知上一键存，无需进 App。
        content.userInfo["route"] = "screenshotRecognition"
        content.categoryIdentifier = "SCREENSHOT_RECOGNITION"
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// 付费墙拦截通知：后台识别被拦截（免费版无云端视觉）时，提醒用户进 App 看升级引导。
    /// route 复用 screenshotRecognition，主 App 打开时 checkScreenshotPending 会识别到付费墙标记并回插升级气泡。
    private func notifyPaywallBlocked() {
        let content = UNMutableNotificationContent()
        content.title = "识别遇到限制"
        content.body = "这张图片需要 Pro 会员才能识别，点开详情可查看并升级解锁。"
        content.userInfo["route"] = "screenshotRecognition"
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// 普通识别失败通知（非权益类：本地解析/网络/云端异常）。
    /// 文案不提「升级 Pro」，避免已开通会员用户被误导。进 App 后回插友好提示即可。
    private func notifyRecognizeFailed() {
        let content = UNMutableNotificationContent()
        content.title = "识别未能完成"
        content.body = "这张图片暂时没能识别成功，点开可重试或手动记录。"
        content.userInfo["route"] = "screenshotRecognition"
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
// 让「好记AI自动记账、记待办、记饮食」动作随 App 安装即自动出现在「快捷指令」App 里，
// 用户建「截屏」自动化时，动作区顶部直接就有它，无需手动搜索/搭建。
// 也支持对 Siri 说「好记AI 自动记账记待办」直接触发。
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
            shortTitle: "快速记录",
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
