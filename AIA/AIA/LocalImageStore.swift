// LocalImageStore.swift
// 本地图片存储：把识别用的原图保存到 App 沙盒 Documents/attachments 目录。
// 只存本地，绝不进入云同步 payload（模型只保存文件名 imageName）。
import UIKit
import SwiftUI

enum LocalImageStore {
    /// 附件目录：Documents/attachments
    static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 保存图片，返回文件名（仅文件名，不含路径）。失败返回 nil。
    static func save(_ image: UIImage?) -> String? {
        guard let image else { return nil }
        // 压缩到合理大小，避免占用过多空间
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let name = "\(UUID().uuidString).jpg"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            print("[LocalImageStore] save failed: \(error)")
            return nil
        }
    }

    /// 按文件名读取图片。
    static func load(_ name: String?) -> UIImage? {
        guard let name, !name.isEmpty else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 删除图片文件（记录被删除时调用，避免残留占空间）。
    static func delete(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 复用 UI：附件原图区块（缩略图 + 点击查看大图）
// 各详情页统一调用：AttachmentSection(imageName: entry.imageName)
// 传入 title: nil 可隐藏内部标题，由调用方在卡片外层统一提供 section 标题。
struct AttachmentSection: View {
    let imageName: String?
    let title: String?
    @State private var showFull = false

    init(imageName: String?, title: String? = "识别原图") {
        self.imageName = imageName
        self.title = title
    }

    var body: some View {
        if let img = LocalImageStore.load(imageName) {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title)
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(AIATheme.sub)
                }
                Button {
                    showFull = true
                } label: {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .bottomTrailing) {
                            Label("仅本地", systemImage: "lock.fill")
                                .font(AIATheme.Font.micro.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.45))
                                .clipShape(Capsule())
                                .padding(8)
                        }
                }
                .buttonStyle(.plain)
            }
            .fullScreenCover(isPresented: $showFull) {
                FullImageView(image: img)
            }
        }
    }
}

// 全屏查看大图（可缩放、双指平移、单击关闭、点保存按钮存相册）
struct FullImageView: View {
    let image: UIImage
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var toast: String?
    @State private var showSaveAlert = false
    @State private var saving = false
    // 强持有保存回调目标，避免 UIImageWriteToSavedPhotosAlbum（ObjC 弱持有）回调时目标已被 ARC 释放
    @State private var photoSaver: ImageSaveDelegate?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale = max(1, $0) }
                        .onEnded { _ in withAnimation { scale = max(1, min(scale, 4)) } }
                )
                // 单击关闭：与缩放手势同属交互手势，不冲突，不再与长按混排
                .onTapGesture { onDismiss?() ?? dismiss() }

            VStack {
                HStack {
                    // 保存按钮（实打实的 Button，不依赖手势识别，最稳）
                    Button {
                        showSaveAlert = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(AIATheme.Font.body.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(.white)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                    Spacer()
                    Button { onDismiss?() ?? dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(AIATheme.Font.body.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(.white)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)
                Spacer()
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 40)
                }
                .transition(.opacity)
                .allowsHitTesting(false)   // toast 永不挡住底层交互
            }
        }
        .alert("保存到相册", isPresented: $showSaveAlert) {
            Button("取消", role: .cancel) {}
            Button("保存") { saveToPhotos() }
        } message: {
            Text("将这张照片保存到系统相册？")
        }
    }

    private func saveToPhotos() {
        guard !saving else { return }
        saving = true
        let saver = ImageSaveDelegate { error in
            // 完成回调可能不在主线程，强制切回主线程再更新 SwiftUI 状态，避免跨线程操作 UI 导致卡死
            DispatchQueue.main.async {
                withAnimation {
                    toast = error == nil ? "已保存到相册" : "保存失败：\(error?.localizedDescription ?? "未知错误")"
                }
                saving = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { toast = nil }
                }
            }
        }
        photoSaver = saver // @State 强持有，保证回调目标存活到回调完成
        UIImageWriteToSavedPhotosAlbum(image, saver, #selector(ImageSaveDelegate.didFinishSaving(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    /// 保存相册的 Objective-C 回调代理
    final class ImageSaveDelegate: NSObject {
        let completion: (Error?) -> Void
        init(completion: @escaping (Error?) -> Void) {
            self.completion = completion
        }
        @objc func didFinishSaving(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
            completion(error)
        }
    }
}
