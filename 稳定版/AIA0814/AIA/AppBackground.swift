// AppBackground.swift
// 自定义 App 背景图：用户本人从相册选图，本地存储，仅首页 / 聊天页应用。
// 图片只存本机 Documents，绝不上传；遮罩浓度自适应深浅色，保证文字可读。
import SwiftUI
import Foundation

extension Notification.Name {
    /// 背景图变更后广播，让已展示的 AppBackgroundView 刷新。
    static let aiaBackgroundChanged = Notification.Name("aiaBackgroundChanged")
}

@MainActor
final class AppBackgroundStore {
    static let shared = AppBackgroundStore()

    private let ud = UserDefaults.standard
    private let keyEnabled = "aia.customBackground"
    private let keyMask = "aia.backgroundMask"

    /// 自定义背景总开关。写入同时广播通知。
    var isEnabled: Bool {
        get { ud.bool(forKey: keyEnabled) }
        set {
            ud.set(newValue, forKey: keyEnabled)
            NotificationCenter.default.post(name: .aiaBackgroundChanged, object: nil)
        }
    }

    /// 遮罩浓度 0...1，默认 0.35，保证前景文字在任意背景图上可读。
    var maskOpacity: Double {
        get {
            let v = ud.object(forKey: keyMask) as? Double
            return v.map { max(0, min(1, $0)) } ?? 0.35
        }
        set {
            ud.set(max(0, min(1, newValue)), forKey: keyMask)
            NotificationCenter.default.post(name: .aiaBackgroundChanged, object: nil)
        }
    }

    private let fileManager = FileManager.default
    private var fileURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app_background.jpg")
    }

    private init() {}

    func loadImage() -> UIImage? {
        guard isEnabled else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    /// 保存用户选图：限制最大尺寸后压缩写入，并开启开关。
    func save(_ image: UIImage) {
        let resized = image.downscaledToFit(CGSize(width: 1280, height: 2560))
        guard let data = resized.jpegData(compressionQuality: 0.82) else { return }
        try? data.write(to: fileURL, options: .atomic)
        isEnabled = true
    }

    func reset() {
        try? fileManager.removeItem(at: fileURL)
        maskOpacity = 0.35
        isEnabled = false
    }
}

extension UIImage {
    /// 等比缩放，仅缩小不放大（避免大图撑爆存储）。
    func downscaledToFit(_ maxSize: CGSize) -> UIImage {
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        guard scale < 1 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// 全屏自适应背景：有图 → 缩放填充 + 自适应遮罩；无图 / 关 → 系统分组背景。
struct AppBackgroundView: View {
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                // 浅色叠白、深色叠黑，按浓度保可读性（默认 35%）。
                Color.adaptive(light: 0xffffff, dark: 0x000000)
                    .opacity(AppBackgroundStore.shared.maskOpacity)
                    .ignoresSafeArea()
            } else {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
            }
        }
        .onAppear { image = AppBackgroundStore.shared.loadImage() }
        .onReceive(NotificationCenter.default.publisher(for: .aiaBackgroundChanged)) { _ in
            image = AppBackgroundStore.shared.loadImage()
        }
    }
}
