// ShareViewController.swift
// 分享扩展入口：用户在系统「分享」面板选「好记」→ 读取图片/文件 → 把原图存进 App Group。
// 主 App 打开后在对话页展示「你发的图」，并由主 App 在对话页内完成识别（见 runImageRecognition）。
// 扩展只负责「把图片递给 App」，识别逻辑统一复用拍照/相册那条成熟链路，避免两端各写一份。
// >>> CHANGE-[2026-08-21 10:00:00]-[分享扩展打通] 开始
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@objc(ShareViewController)
public class ShareViewController: UIViewController {

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.text = "正在打开好记AI…"
        l.textAlignment = .center
        l.textColor = .secondaryLabel
        l.font = .systemFont(ofSize: 16, weight: .medium)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.hidesWhenStopped = true
        return s
    }()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(spinner)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
        ])
        spinner.startAnimating()

        Task { await passImageToApp() }
    }

    // 取图 → 存 App Group（只存图，识别交给主 App 对话页）→ 拉起主 App。
    private func passImageToApp() async {
        guard let image = await loadImage() else {
            statusLabel.text = "未能读取图片"
            finishAndOpenApp(success: false)
            return
        }

        let imageData = image.jpegData(compressionQuality: 0.9)
        // 只把原图交给主 App，fromShareExtension=true 让主 App 在对话页内识别。
        ScreenshotStore.saveShareImage(imageData)
        statusLabel.text = "已打开好记AI"
        finishAndOpenApp(success: true)
    }

    // 关掉扩展并兜底提醒用户（iOS 26 分享扩展的 extensionContext.open(url) 无法唤起宿主 App，
    // 已实测确诊：纯 open 只让扩展卡在界面、主 App 不启动）。
    // 改用本地通知兜底：存图后发一条通知，用户点通知横幅即唤起主 App 并跳对话页；
    // 即使不点通知，手动打开主 App 也会由 checkScreenshotPending 的 fromShareExtension 分支自动跳对话页。
    private func finishAndOpenApp(success: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "好记AI已收到你的图片"
        content.body = "点击查看AI识别结果"
        content.sound = .default
        content.userInfo = ["route": "chat"]
        let request = UNNotificationRequest(
            identifier: "shareExtension-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[ShareExt] 发通知失败: \(error)") }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    // 从分享上下文里取出图片（兼容 URL / Data / UIImage 三种返回形式，图片与文件分享都覆盖）
    private func loadImage() async -> UIImage? {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachment = item.attachments?.first else { return nil }

        // 优先按图片类型取
        let imageType = UTType.image.identifier
        if attachment.hasItemConformingToTypeIdentifier(imageType) {
            if let img = await loadItemAsImage(attachment, type: imageType) {
                return img
            }
        }

        // 文件分享进来的类型标识不一定是 image（可能是 public.jpeg/public.png/public.data），兜底再试一遍
        let dataTypes = [UTType.data.identifier, UTType.item.identifier, "public.jpeg", "public.png", "public.image", "public.file-url", "public.content"]
        for t in dataTypes {
            if attachment.hasItemConformingToTypeIdentifier(t),
               let img = await loadItemAsImage(attachment, type: t) {
                return img
            }
        }
        return nil
    }

    private func loadItemAsImage(_ attachment: NSItemProvider, type: String) async -> UIImage? {
        await withCheckedContinuation { cont in
            attachment.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let url = item as? URL {
                    // file:// 形式（相册/文件 App/备忘录导出的图片文件）
                    if let img = UIImage(contentsOfFile: url.path) {
                        cont.resume(returning: img)
                    } else if let data = try? Data(contentsOf: url) {
                        cont.resume(returning: UIImage(data: data))
                    } else {
                        cont.resume(returning: nil)
                    }
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
