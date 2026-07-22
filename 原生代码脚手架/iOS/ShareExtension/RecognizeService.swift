// RecognizeService.swift
// 调用云端「识别」云函数。App 只跟自己的云函数说话，不直接碰大模型 Key。
import UIKit

struct RecognizeService {
    // ↓↓↓ 替换成你在 CloudBase 控制台拿到的「HTTP 触发」地址
    static let endpoint = URL(string: "https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/recognize")!

    // 把 UIImage 压缩成 jpeg base64 后发送。
    // 先限制最长边 512px、JPEG 0.5；若仍超过 100KB 则继续降低质量，
    // 直到 < 100KB 或质量低于 0.3，避免触发 CloudBase 413 网关限制。
    static func recognize(image: UIImage) async throws -> RecognitionResult {
        let maxSide: CGFloat = 512
        let resized = image.preparingThumbnail(of: CGSize(width: maxSide, height: maxSide)) ?? image
        var quality: CGFloat = 0.5
        guard var data = resized.jpegData(compressionQuality: quality) else {
            throw NSError(domain: "Recognize", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "图片压缩失败"])
        }

        // 自适应压缩：目标二进制 < 100KB，给 base64 留出余量
        while data.count > 100 * 1024 && quality > 0.3 {
            quality -= 0.05
            guard let d = resized.jpegData(compressionQuality: quality) else { break }
            data = d
        }

        let base64 = data.base64EncodedString()
        print("[图片大小] \(data.count / 1024) KB, base64 \(base64.count / 1024) KB")
        print("[base64 前 80 字符] \(base64.prefix(80))")
        return try await recognize(base64: base64)
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
