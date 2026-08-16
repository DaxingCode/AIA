// ImageHasher.swift
// 图片感知哈希：主指纹用差异哈希 dHash（对亮度/对比度/gamma 免疫，鲁棒性远强于 aHash），
// 哈希前先裁掉状态栏/底部安全区以剔除「时间/信号」等噪声源。保留 aHash 作参考实现。
// 适合判断「同一张截图是否被重复识别」。纯 Core Graphics 实现，无第三方依赖。
import UIKit

enum ImageHasher {
    /// 计算图片的平均哈希指纹。失败（无 cgImage 等）返回 nil。
    static func aHash(_ image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }
        let size = 8
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil,
                                  width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let buf = data.bindMemory(to: UInt8.self, capacity: size * size)

        // 读取 64 个灰度字节
        var pixels = [UInt8](repeating: 0, count: size * size)
        for i in 0..<size * size { pixels[i] = buf[i] }

        // 均值
        let sum = pixels.reduce(0) { $0 + Int($1) }
        let avg = sum / pixels.count

        // 逐像素与均值比较 → 4 bit 一组拼成 hex
        var hex = ""
        for i in stride(from: 0, to: size * size, by: 4) {
            var nibble = 0
            for j in 0..<4 {
                let bit = pixels[i + j] >= avg ? 1 : 0
                nibble = (nibble << 1) | bit
            }
            hex += String(format: "%X", nibble)
        }
        return hex  // 16 个字符
    }

    // MARK: - 主指纹 dHash

    /// 主指纹：先按固定比例裁剪状态栏/底部噪声，再做 dHash。
    /// 返回 (hash, ratio)；hash 为 16 位 hex（64 bit），ratio 为 宽/高 供 match 比例校验。失败返回 nil。
    static func fingerprint(_ image: UIImage) -> (hash: String, ratio: CGFloat)? {
        guard let cropped = cropNoise(image) else { return nil }
        guard let h = dHash(cropped) else { return nil }
        let ratio = CGFloat(image.size.width) / CGFloat(image.size.height)
        return (h, ratio.isFinite && ratio > 0 ? ratio : 1)
    }

    /// 差异哈希（dHash）：比较相邻像素梯度，对亮度/对比度/gamma 完全免疫，鲁棒性远强于 aHash。
    /// 标准 9×8 → 64 bit（16 位 hex）。失败返回 nil。
    static func dHash(_ image: UIImage, size: Int = 9, height: Int = 8) -> String? {
        guard let cg = image.cgImage else { return nil }
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil,
                                  width: size, height: height,
                                  bitsPerComponent: 8, bytesPerRow: size,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: height))
        guard let data = ctx.data else { return nil }
        let buf = data.bindMemory(to: UInt8.self, capacity: size * height)

        var bits: UInt64 = 0
        var bit = 0
        for row in 0..<height {
            for col in 0..<(size - 1) {
                let left = buf[row * size + col]
                let right = buf[row * size + col + 1]
                if right > left { bits |= (UInt64(1) << UInt64(bit)) }
                bit += 1
            }
        }
        // 64 bits → 16 个 hex 字符
        var hex = ""
        for i in stride(from: 0, to: 64, by: 4) {
            var nibble = 0
            for j in 0..<4 { nibble = (nibble << 1) | Int((bits >> (i + j)) & 1) }
            hex += String(format: "%X", nibble)
        }
        return hex
    }

    /// 裁剪状态栏（顶部）与底部安全区/白边，剔除同图重识别最大噪声源（时间/信号）。
    /// 按固定比例裁剪，保证同一张图两次识别裁剪结果一致。
    private static func cropNoise(_ image: UIImage,
                                  top: CGFloat = 0.10, bottom: CGFloat = 0.04,
                                  side: CGFloat = 0.0) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 1, h > 1 else { return nil }
        let dx = w * side
        let dy = h * top
        let cw = max(1, w * (1 - side * 2))
        let ch = max(1, h * (1 - top - bottom))
        let rect = CGRect(x: dx, y: dy, width: cw, height: ch)
        guard let sub = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: sub, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 两枚指纹（16 位 hex）的汉明距离（不同 bit 数）。长度不符返回 Int.max。
    static func hammingDistance(_ a: String, _ b: String) -> Int {
        guard a.count == 16, b.count == 16 else { return Int.max }
        var dist = 0
        for (ca, cb) in zip(a, b) {
            guard let va = Int(String(ca), radix: 16),
                  let vb = Int(String(cb), radix: 16) else { return Int.max }
            dist += (va ^ vb).nonzeroBitCount
        }
        return dist
    }
}
