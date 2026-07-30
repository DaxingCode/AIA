// DeveloperCenterView.swift
// 开发者中心：解锁后展示的高级功能入口页。广告管理、Agent、AI 模型等高级功能从这里进入，便于后续扩展。
import SwiftUI

struct DeveloperCenterView: View {
    @Environment(\.dismiss) private var dismiss

    // 全局配置改为云端权威：开发者切换后写入云端，所有用户自动跟随。
    // 不再用 @AppStorage 直写本地，统一走 GlobalConfigStore（写云端 + 本地缓存）。
    @ObservedObject private var global = GlobalConfigStore.shared

    // 智能问答开关（写云端）
    private var agentBinding: Binding<Bool> {
        Binding(get: { global.agentEnabled },
                set: { nv in
                    global.agentEnabled = nv
                    Task { await global.saveConfig(agentEnabled: nv, modelProvider: global.modelProvider, visionModelProvider: global.visionModelProvider) }
                })
    }
    // 问答 / Agent 文本模型（写云端）
    private var modelBinding: Binding<String> {
        Binding(get: { global.modelProvider },
                set: { nv in
                    global.modelProvider = nv
                    Task { await global.saveConfig(agentEnabled: global.agentEnabled, modelProvider: nv, visionModelProvider: global.visionModelProvider) }
                })
    }
    // 截图识别视觉模型（写云端）
    private var visionBinding: Binding<String> {
        Binding(get: { global.visionModelProvider },
                set: { nv in
                    global.visionModelProvider = nv
                    Task { await global.saveConfig(agentEnabled: global.agentEnabled, modelProvider: global.modelProvider, visionModelProvider: nv) }
                })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                adManagerEntry
                agentCard
                modelProviderCard
                testNotifyCard
                // 后续新增开发者功能在这里加卡片即可
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(AIATheme.fillSoft)
        .navigationTitle("开发者中心")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 测试通知
    private var testNotifyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("通知测试")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                Text("发送测试通知")
            }
            .font(AIATheme.Font.subhead.weight(.medium))
            .foregroundStyle(AIATheme.blue)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(AIATheme.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .contentShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .onTapGesture {
                ReminderNotificationManager.sendTest(after: 5) { ok in
                    if ok {
                        ToastCenter.shared.show("测试通知已安排，5 秒后弹出")
                    } else {
                        ToastCenter.shared.show("未开启通知权限，请到系统设置开启")
                    }
                }
            }
            Text("点击后 5 秒弹出一条本地通知。可切到后台或锁屏查看效果；若无反应，请到 iPhone「设置 → 通知 → 阿宝AI管家」确认已允许通知。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 广告管理入口
    private var adManagerEntry: some View {
        Button {
            NavigationRouter.shared.navigate(.adManager)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .fill(AIATheme.purple.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.purple)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("广告管理")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("配置首页轮播广告位")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(14)
            .background(AIATheme.surface)
        }
        .buttonStyle(.plain)
        .card()
    }

    // MARK: - 智能问答 Agent（可单独开关）
    private var agentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("智能问答 Agent")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("智能问答 Agent", isOn: agentBinding)
                    .labelsHidden()
            }
            Text("开启后，对话页的问答由 AI 基于你的记录智能回答（只读，不会改动任何数据）。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 模型供应商选择（文本 / 视觉独立切换，零污染云端）
    private var modelProviderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("AI 模型")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("问答与截图识别可分别选择模型（默认均为智谱 GLM）。需在云端对应环境变量已配置该供应商 Key。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
            // 文本模型（问答 / Agent）
            VStack(alignment: .leading, spacing: 4) {
                Text("问答 / Agent 模型")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                Picker("问答模型", selection: modelBinding) {
                    ForEach(AIAModelProvider.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(AIATheme.blue)
            }
            // 视觉模型（截图识别）。仅展示支持视觉的 provider，过滤掉 DeepSeek（仅文字）。
            VStack(alignment: .leading, spacing: 4) {
                Text("截图识别模型")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                Picker("识别模型", selection: visionBinding) {
                    ForEach(AIAModelProvider.visionCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(AIATheme.blue)
            }
            Text("DeepSeek 仅支持文字，对话体验更好但不能用于截图识别（视觉 Picker 已自动隐藏）。Agent 模式推荐用 DeepSeek，function-calling 准确度高于其他。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }
}
