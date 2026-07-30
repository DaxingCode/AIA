// GlobalConfigStore.swift
// 全局配置（智能问答开关 + AI 模型）。
// 权威来源在云端 aia_config 集合：开发者在「开发者中心」切换后写入云端，
// 所有用户启动时 / 回到前台 / 定时拉取并自动跟随，普通用户无入口也无法自行切换。
// 本地 UserDefaults 仅作缓存，GlobalConfigStore 负责与云端同步。
import Foundation
import Combine

@MainActor
final class GlobalConfigStore: ObservableObject {
    static let shared = GlobalConfigStore()

    // 发布属性 setter 公开：视图可用自定义 Binding 做「即时本地更新 + 写云端」副作用。
    // 真正落库（UserDefaults + 云端）统一走 applyToLocal / saveConfig，避免别处误写。
    @Published var agentEnabled: Bool
    @Published var modelProvider: String
    @Published var visionModelProvider: String

    private let agentKey = "aia.agentEnabled"
    private let modelKey = "aia.modelProvider"
    private let visionKey = "aia.visionModelProvider"

    private init() {
        let ud = UserDefaults.standard
        self.agentEnabled = ud.bool(forKey: agentKey)
        self.modelProvider = ud.string(forKey: modelKey) ?? "glm"
        self.visionModelProvider = ud.string(forKey: visionKey) ?? "glm"
    }

    /// 从云端拉取全局配置，写回本地缓存。公开接口，所有用户均可调用。
    func fetchConfig() async {
        do {
            let resp = try await postAdsJSON(["action": "getConfig"])
            guard resp["ok"] as? Bool == true else {
                print("[GlobalConfig] getConfig 返回 ok != true: \(resp)")
                return
            }
            let agent = (resp["agentEnabled"] as? Bool) ?? false
            let model = (resp["modelProvider"] as? String)?.nonEmpty ?? "glm"
            let vision = (resp["visionModelProvider"] as? String)?.nonEmpty ?? "glm"
            applyToLocal(agentEnabled: agent, modelProvider: model, visionModelProvider: vision)
            print("[GlobalConfig] 已同步云端配置 agent=\(agent) model=\(model) vision=\(vision)")
        } catch {
            print("[GlobalConfig] fetchConfig 失败: \(error)")
        }
    }

    /// 开发者写入：推到云端并同步本地缓存。需口令，普通调用方拿不到 DeveloperGate.passcode。
    func saveConfig(agentEnabled: Bool, modelProvider: String, visionModelProvider: String) async {
        do {
            let resp = try await postAdsJSON([
                "action": "setConfig",
                "passcode": DeveloperGate.passcode,
                "agentEnabled": agentEnabled,
                "modelProvider": modelProvider,
                "visionModelProvider": visionModelProvider
            ])
            guard resp["ok"] as? Bool == true else {
                print("[GlobalConfig] setConfig 云端返回失败: \(resp)")
                return
            }
            applyToLocal(agentEnabled: agentEnabled, modelProvider: modelProvider, visionModelProvider: visionModelProvider)
            print("[GlobalConfig] 已写入云端配置 agent=\(agentEnabled) model=\(modelProvider) vision=\(visionModelProvider)")
        } catch {
            print("[GlobalConfig] setConfig 失败: \(error)")
        }
    }

    /// 写回本地缓存并刷新发布属性（供 @ObservedObject 视图即时响应）。
    private func applyToLocal(agentEnabled: Bool, modelProvider: String, visionModelProvider: String) {
        let ud = UserDefaults.standard
        ud.set(agentEnabled, forKey: agentKey)
        ud.set(modelProvider, forKey: modelKey)
        ud.set(visionModelProvider, forKey: visionKey)
        self.agentEnabled = agentEnabled
        self.modelProvider = modelProvider
        self.visionModelProvider = visionModelProvider
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
