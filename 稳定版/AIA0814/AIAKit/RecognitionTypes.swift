// RecognitionTypes.swift
// 共享领域枚举：识别来源。原定义在 RecognizeService 内（主 App 业务逻辑类），
// 因 SwiftData 模型 / Widget 都需要引用，抽到 AIAKit 共享层。
import Foundation

/// 识别来源：用于统计/调试，本地命中则不消耗云端 token。
public enum RecognitionSource: String, Sendable, Codable {
    case local
    case cloudText
    case cloud
}
