// AgentChatRequest.swift
// ============================================================================
// Agent 模式（mode:"agent"）的请求体封装。
// 把请求字段类型化，避免手写字典拼错 key；在 RecognizeService.chat 里用它编码 body。
// 设计：与云端 { mode, text, context, userId, provider } 保持一致。
// ============================================================================
import Foundation

struct AgentChatRequest {
    /// 用户唯一ID，必须来自 CloudSyncManager.userId，不得编造。
    let userId: String
    /// 固定为 "agent"，走云端 Agent 分支（带工具调用的智能助理）。
    let mode: String
    /// 用户本轮输入文本。
    let text: String
    /// 客户端本地数据摘要（降级兜底上下文）。
    let context: [String: Any]
    /// 文本模型 provider，Agent 用商汤 sensechat-turbo（sensenovaText）。
    let provider: String

    /// 默认 userId 取自 CloudSyncManager，provider 用 sensenovaText；如需测试可显式传入。
    init(text: String,
         context: [String: Any],
         userId: String = CloudSyncManager.userId,
         provider: String = "sensenovaText") {
        self.text = text
        self.context = context
        self.userId = userId
        self.mode = "agent"
        self.provider = provider
    }

    /// 转为云函数可接收的 JSON 字典（用于 JSONSerialization 编码请求体）。
    func toDictionary() -> [String: Any] {
        return [
            "mode": mode,
            "text": text,
            "context": context,
            "userId": userId,
            "provider": provider,
        ]
    }
}
