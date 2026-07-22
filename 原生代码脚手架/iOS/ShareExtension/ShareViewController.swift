// ShareViewController.swift
// 分享扩展入口：用户在系统「分享」面板选「AI 助理」→ 读取图片 → 云端识别 → 存 App Group。
// 主 App 下次打开会读到这个结果并弹出确认页（见 ContentView.checkPending()）。
// 这是「无感截图」之外的手动导入兜底：任何 App 里看到截图都能分享进来识别。
import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool {
        // 不需要输入文字，直接允许发送
        true
    }

    override func didSelectPost() {
        // 在后台跑识别，结束（无论成败）都关闭分享面板
        Task { await handlePost() }
    }

    override func configurationItems() -> [Any]! {
        []   // 不展示任何可配置项
    }

    private func handlePost() async {
        defer { self.extensionContext?.completeRequest(returningItems: nil) }

        guard let image = await loadImage() else { return }
        do {
            let result = try await RecognizeService.recognize(image: image)
            ScreenshotStore.save(result)
        } catch {
            // 扩展里不便弹错误，失败静默忽略；主 App 仍有「测试识别」兜底
            print("⚠️ 分享扩展识别失败：\(error.localizedDescription)")
        }
    }

    // 从分享上下文里取出图片（兼容 URL / Data / UIImage 三种返回形式）
    private func loadImage() async -> UIImage? {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachment = item.attachments?.first else { return nil }
        let type = UTType.image.identifier
        guard attachment.hasItemConformingToTypeIdentifier(type) else { return nil }
        return await withCheckedContinuation { cont in
            attachment.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: UIImage(contentsOfFile: url.path))
                } else if let data = item as? Data {
                    cont.resume(returning: UIImage(data: data))
                } else if let img = item as? UIImage {
                    cont.resume(returning: img)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
