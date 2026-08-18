// LocalImageStore.swift
// 本地图片存储：把识别用的原图保存到 App 沙盒 Documents/attachments 目录。
// 只存本地，绝不进入云同步 payload（模型只保存文件名 imageName）。
import UIKit
import SwiftUI

enum LocalImageStore {
    /// 附件目录：Documents/attachments
    /// nonisolated：纯文件 I/O，不依赖主线程，可在后台/Task.detached 中调用
    /// （避免 Swift 6 下被推断为 main-actor 隔离而无法在并发上下文使用）。
    nonisolated static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 保存图片，返回文件名（仅文件名，不含路径）。失败返回 nil。
    nonisolated static func save(_ image: UIImage?) -> String? {
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
    nonisolated static func load(_ name: String?) -> UIImage? {
        guard let name, !name.isEmpty else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 删除图片文件（记录被删除时调用，避免残留占空间）。
    nonisolated static func delete(_ name: String?) {
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
    @State private var photoSaver = PhotoSaveHelper()

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

            // >>> CHANGE-[2026-08-17 19:40:00]-[大图查看顶部关闭保存按钮] 开始
            // 原因: 用户在大图查看页要求左上角"关闭"按钮、右上角"保存"按钮，替代之前被移除的顶部按钮。
            //       关闭走 onDismiss/dismiss，保存把当前图写入系统相册并 toast 提示结果。
            // 回退: 删除本 VStack（顶部按钮）整段即可恢复无顶部按钮状态。
            VStack {
                HStack {
                    Button {
                        onDismiss?() ?? dismiss()
                    } label: {
                        Text("关闭")
                            .font(AIATheme.Font.subhead.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background { Color.white.opacity(0.22) }
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Button {
                        photoSaver.save(image) { error in
                            toast = error == nil ? "已保存到相册" : "保存失败：\(error!.localizedDescription)"
                            hideToastAfterDelay()
                        }
                    } label: {
                        Text("保存")
                            .font(AIATheme.Font.subhead.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background { Color.white.opacity(0.22) }
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                Spacer()
            }
            // <<< CHANGE-[2026-08-17 19:40:00]-[大图查看顶部关闭保存按钮] 结束

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
        // >>> CHANGE-[2026-08-17 20:15:00]-[大图查看状态栏改现代API] 开始
        // 原因: .statusBar(hidden:) 在 iOS 17+ 已弃用，iOS 26 行为未定义（用户截图可见
        //       状态栏白胶囊仍浮在大图上方）。改 .statusBarHidden(true)（iOS 16+ 现代 API）。
        // 回退: 恢复 .statusBar(hidden: true) 并删除本行即可。
        .statusBarHidden(true)
        // <<< CHANGE-[2026-08-17 20:15:00]-[大图查看状态栏改现代API] 结束
    }

    private func hideToastAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            toast = nil
        }
    }
}

// 相册保存回调辅助类（须以 @State 持有，保证回调跑完前对象不释放）
private final class PhotoSaveHelper: NSObject {
    private var completion: ((Error?) -> Void)?

    func save(_ image: UIImage, completion: @escaping (Error?) -> Void) {
        self.completion = completion
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(saveCompleted(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func saveCompleted(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        completion?(error)
        completion = nil
    }
}
