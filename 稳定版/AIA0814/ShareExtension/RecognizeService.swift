// RecognizeService.swift
// 调用云端「识别」云函数。App 只跟自己的云函数说话，不直接碰大模型 Key。
// 压缩策略与主 App 完全一致：最大边 1024px、JPEG 质量 0.8、目标 < 120KB，
// 超限（413）时四级自动收紧，保证大截屏也能识别。
import UIKit

struct RecognizeService {
    // ↓↓↓ 替换成你在 CloudBase 控制台拿到的「HTTP 触发」地址
    static let endpoint = URL(string: "https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/recognize")!

    /// 把图片二进制压缩成可上传的 base64（最大边 1024、JPEG 质量 0.8、目标二进制 < 100KB）。
    /// 自适应压缩：从质量 0.8 起，若仍超 targetBytes 则逐级降到 0.2，给 JSON 包裹 + base64 留出余量。
    static func compressedBase64(from imageData: Data, maxSide: CGFloat = 1024, targetBytes: Int = 100 * 1024) -> String? {
        guard let image = UIImage(data: imageData) else { return nil }
        let resized = image.preparingThumbnail(of: CGSize(width: maxSide, height: maxSide)) ?? image
        var quality: CGFloat = 0.8
        guard var data = resized.jpegData(compressionQuality: quality) else { return nil }

        while data.count > targetBytes && quality > 0.2 {
            quality -= 0.05
            guard let d = resized.jpegData(compressionQuality: quality) else { break }
            data = d
        }

        let base64 = data.base64EncodedString()
        print("[图片大小] \(data.count / 1024) KB, base64 \(base64.count / 1024) KB")
        return base64
    }

    /// 带 413 自动重试的图片识别（对外仍返回 RecognitionResult，保持分享扩展调用方不变）。
    /// 四级档位：(1024, 120KB) → (1024, 80KB) → (768, 60KB) → (512, 40KB)。
    static func recognize(image: UIImage) async throws -> RecognitionResult {
        guard let data = image.jpegData(compressionQuality: 1) ?? image.pngData() else {
            throw NSError(domain: "Recognize", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "图片压缩失败"])
        }
        return try await recognizeResilient(imageData: data)
    }

    static func recognizeResilient(imageData: Data) async throws -> RecognitionResult {
        let attempts: [(CGFloat, Int)] = [
            (1024, 120 * 1024),
            (1024, 80 * 1024),
            (768, 60 * 1024),
            (512, 40 * 1024),
        ]
        var lastErr: Error?
        for (side, target) in attempts {
            guard let base64 = compressedBase64(from: imageData, maxSide: side, targetBytes: target) else { continue }
            do {
                return try await recognize(base64: base64)
            } catch {
                let desc = "\(error)"
                if desc.contains("413") || desc.contains("EXCEED_MAX_PAYLOAD") {
                    lastErr = error
                    continue
                }
                throw error
            }
        }
        throw lastErr ?? NSError(domain: "Recognize", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "图片压缩失败，无法上传"])
    }

    static func recognize(base64: String) async throws -> RecognitionResult {
        print("[发送 base64 长度] \(base64.count)")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let body: [String: Any] = ["imageBase64": base64, "provider": "qwen"]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[HTTP 状态码] \(status)")
        if let json = String(data: respData, encoding: .utf8) {
            print("[云端返回] \(json)")
        }

        // 如果 HTTP 状态码不是 2xx，说明请求被网关拦截（如 EXCEED_MAX_PAYLOAD_SIZE）
        guard (200...299).contains(status) else {
            throw NSError(domain: "Recognize", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "请求失败 (HTTP \(status))，请检查图片是否过大或云函数配置"])
        }

        let wrapper = try JSONDecoder().decode(CloudResponse.self, from: respData)
        guard wrapper.ok, let result = wrapper.result else {
            throw NSError(domain: "Recognize", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: wrapper.error ?? "识别失败"])
        }
        return result
    }

    // 云函数返回外层包裹：{ ok, result, error }
    private struct CloudResponse: Decodable, Sendable {
        let ok: Bool
        let result: RecognitionResult?
        let error: String?
    }
}
