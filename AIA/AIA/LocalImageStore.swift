// LocalImageStore.swift
// 本地图片存储：把识别用的原图保存到 App 沙盒 Documents/attachments 目录。
// 只存本地，绝不进入云同步 payload（模型只保存文件名 imageName）。
import UIKit
import SwiftUI

enum LocalImageStore {
    /// 附件目录：Documents/attachments
    private static var dir: URL {
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
struct AttachmentSection: View {
    let imageName: String?
    @State private var showFull = false

    var body: some View {
        if let img = LocalImageStore.load(imageName) {
            VStack(alignment: .leading, spacing: 8) {
                Text("识别原图")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(AIATheme.sub)
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

// 全屏查看大图（可缩放、双指平移、单击关闭、长按保存）
struct FullImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var toast: String?
    @State private var showSaveAlert = false

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
                .onTapGesture { dismiss() }
                .onLongPressGesture(minimumDuration: 0.5) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showSaveAlert = true
                }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(AIATheme.Font.body.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(.white)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                }
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
        let saver = ImageSaveDelegate { error in
            withAnimation {
                toast = error == nil ? "已保存到相册" : "保存失败：\(error?.localizedDescription ?? "未知错误")"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { toast = nil }
            }
        }
        UIImageWriteToSavedPhotosAlbum(image, saver, #selector(ImageSaveDelegate.didFinishSaving(_:didFinishSavingWithError:contextInfo:)), nil)
        // 保持 saver 活到回调完成
        withAnimation {
            _ = saver
        }
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
