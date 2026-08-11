// ShareViewController.swift
// 分享扩展入口：用户在系统「分享」面板选「好记」→ 读取图片/文件 → 云端识别 → 存 App Group。
// 主 App 下次打开会读到这个结果并弹出确认页（见 ContentView.checkPending()）。
// 这是「无感截图」之外的手动导入兜底：任何 App 里看到截图都能分享进来识别。
import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
public class ShareViewController: UIViewController {

    public override func viewDidLoad() {
        super.viewDidLoad()
        // 先用极简 UI 确认扩展本身能正常挂载（不依赖任何外部依赖，排除「加载即崩」导致系统把它从分享面板移除）
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "好记扩展测试中"
        label.textAlignment = .center
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.extensionContext?.completeRequest(returningItems: nil)
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
