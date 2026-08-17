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

            // >>> CHANGE-[2026-08-17 19:30:00]-[大图查看去掉顶部按钮] 开始
            // 原因: 大图查看页顶部两个白色圆按钮（保存/关闭）在亮色图片上像"白点/空白椭圆"，用户认为多余。
            //       关闭已可由"点击图片任意处"完成(.onTapGesture)，保存功能非必需，统一去掉顶部按钮。
            // 回退: 恢复被删除的 VStack{HStack{保存按钮 Spacer 关闭按钮}...} 整段即可。
            // <<< CHANGE-[2026-08-17 19:30:00]-[大图查看去掉顶部按钮] 结束

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
    }
}
