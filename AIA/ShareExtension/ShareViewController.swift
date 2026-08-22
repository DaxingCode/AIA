// ShareViewController.swift
// 分享扩展入口：用户在系统「分享」面板选「好记」→ 读取图片/文件 → 把原图存进 App Group。
// 主 App 打开后在对话页展示「你发的图」，并由主 App 在对话页内完成识别（见 runImageRecognition）。
// 扩展只负责「把图片递给 App」，识别逻辑统一复用拍照/相册那条成熟链路，避免两端各写一份。
// >>> CHANGE-[2026-08-21 10:00:00]-[分享扩展打通] 开始
import UIKit
import UniformTypeIdentifiers

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

    // 关闭扩展并唤起主 App 进对话页：
    // 先 open(aia://chat) 主动唤起主 App（正式签名包下可靠，系统分享流程会据此拉起宿主）；
    // 无论 open 成败都在回调里 completeRequest 关掉扩展，避免扩展卡在"正在打开"界面。
    // 主 App 启动后由 checkScreenshotPending 检测到 App Group 里的分享图并自动进对话页识别。
    private func finishAndOpenApp(success: Bool) {
        let url = URL(string: "aia://chat")!
        let context = extensionContext
        context?.open(url) { _ in
            context?.completeRequest(returningItems: nil)
        }
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
