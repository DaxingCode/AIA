// ImageHasher.swift
// 图片感知哈希（平均哈希 aHash）：把图片降采样到 8x8 灰度，按每个像素与均值比较，
// 生成 64 位指纹（16 位 hex 串）。对缩放、轻微像素差异（如同屏仅状态栏时间不同）鲁棒，
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

    /// 两枚 aHash（16 位 hex）的汉明距离（不同 bit 数）。长度不符返回 Int.max。
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
