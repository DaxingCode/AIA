// ImageAutoRecogSettingsView.swift
// 图片自动识别的「按类别」行为设置：自动保存 / 自动弹出确认页。
//
// 设计要点：
//  - 仅存本机 UserDefaults（不走云同步），换机后回到默认值。
//  - 默认值（来源相关）：
//      图片源：饮食记录默认待确认（进对话气泡），其余自动保存（与线上体验一致）。
//      文字/语音源：四类默认全部自动保存，记录以「已保存态气泡」留在对话页。
//    老用户升级后行为零变化（已存 UserDefaults 优先）；仅全新安装按此默认。
//  - 行为矩阵（RecognitionSaver.processRecognition 消费）：
//      有类别弹出=开            → 弹确认页（自动保存=开 的类别先预存，关的点「存入」再插）
//      全部弹出=关 且 有保存=开 → 静默入库 + toast 引导去对应页面修改
//      全部弹出=关 且 全保存=关 → 什么都不做（本次识别无有效类别）
//  - 静默路径撞上疑似重复图片时会升级为弹确认页警告，防止无感重复入库。

import SwiftUI
import Combine

// MARK: - 配置读写（单一真源：默认值只定义在这里）

/// 识别结果的「处理方式」两档：自动保存 / 确认后再保存。
enum RecognitionAutoMode: String, CaseIterable {
    case autoSave = "autoSave"   // 识别后直接入库
    case pending  = "pending"    // 进对话气泡，由用户确认后再入库

    var title: String {
        switch self {
        case .autoSave: return "自动保存"
        case .pending:  return "确认后再保存"
        }
    }
    var hint: String {
        switch self {
        case .autoSave: return "识别完成后直接保存记录，无需手动确认"
        case .pending:  return "进入对话气泡，由你确认后再保存"
        }
    }
}

enum ImageAutoRecogSettings {
    struct Category: Identifiable {
        let type: String     // 与 RecognitionResult.types 对齐：bill / todo / food / health
        let title: String    // 类别显示名
        let page: String     // 对应管理页面名（toast 引导文案用）
        let icon: String
        let tint: Color
        var id: String { type }
    }

    /// 顺序即 toast / 设置页展示顺序。
    static let categories: [Category] = [
        .init(type: "bill",   title: "账单",     page: "账单管理", icon: "creditcard",        tint: AIATheme.bill),
        .init(type: "todo",   title: "待办",     page: "待办提醒", icon: "checklist",          tint: AIATheme.todo),
        .init(type: "food",   title: "饮食记录", page: "饮食记录", icon: "fork.knife",         tint: AIATheme.food),
        .init(type: "health", title: "健康数据", page: "健康管理", icon: "heart.text.square",  tint: AIATheme.health)
    ]

    static let knownTypes: [String] = categories.map { $0.type }

    // 默认值：来源相关。
    //  图片源：饮食记录待确认（进对话气泡），其余自动保存（与线上体验一致）。
    //  文字/语音源：四类默认全部自动保存，记录以「已保存态气泡」留在对话页。
    static func defaultMode(for type: String, source: String = "image") -> RecognitionAutoMode {
        if source == "text" { return .autoSave }
        return type == "food" ? .pending : .autoSave
    }
    /// 旧两布尔默认值（兼容老接口语义，默认图片源）。
    static func defaultAutoSave(for type: String) -> Bool { defaultMode(for: type, source: "image") == .autoSave }
    static func defaultAutoPopup(for type: String) -> Bool { defaultMode(for: type, source: "image") == .pending }

    /// 设置二维：来源（文字/语音 vs 图片）× 类别。
    static let sourceGroups: [(key: String, title: String, subtitle: String)] = [
        ("image", "图片",        "截屏无感、拍照、相册识别"),
        ("text",  "文字 / 语音", "聊天输入、语音记录、Siri 快捷指令识别")
    ]

    private static func modeKey(_ type: String, source: String) -> String {
        "imageAutoRecog.mode.\(source).\(type)"
    }

    /// 按「来源 × 类别」查询处理方式；缺省回落到默认值（升级零变化）。
    /// 历史遗留的「丢弃」档位已下线，统一归一到「确认后再保存」，避免旧设置静默丢数据。
    static func mode(for type: String, source: String) -> RecognitionAutoMode {
        guard let raw = UserDefaults.standard.string(forKey: modeKey(type, source: source)) else {
            return defaultMode(for: type, source: source)
        }
        if raw == "discard" { return .pending }
        return RecognitionAutoMode(rawValue: raw) ?? defaultMode(for: type, source: source)
    }
    static func setMode(_ m: RecognitionAutoMode, for type: String, source: String) {
        UserDefaults.standard.set(m.rawValue, forKey: modeKey(type, source: source))
    }

    // MARK: 兼容旧接口（默认图片源）
    static func autoSave(for type: String) -> Bool { mode(for: type, source: "image") == .autoSave }
    static func autoPopup(for type: String) -> Bool { mode(for: type, source: "image") == .pending }
    static func autoSave(for type: String, source: String) -> Bool { mode(for: type, source: source) == .autoSave }
    static func autoPopup(for type: String, source: String) -> Bool { mode(for: type, source: source) == .pending }
    static func setAutoSave(_ v: Bool, for type: String) {
        setMode(v ? .autoSave : .pending, for: type, source: "image")
    }
    static func setAutoPopup(_ v: Bool, for type: String) {
        setMode(v ? .pending : .autoSave, for: type, source: "image")
    }

    static func category(for type: String) -> Category? {
        categories.first { $0.type == type }
    }

    /// 静默保存后的 toast 文案：点名保存了什么、去哪个页面修改。
    /// 单类别：已自动保存账单，可在「账单管理」中修改
    /// 多类别：已自动保存账单、健康数据，可分别在「账单管理」「健康管理」中修改
    static func silentSaveToast(savedTypes: [String]) -> String {
        let cats = savedTypes.compactMap { category(for: $0) }
        guard !cats.isEmpty else { return "已自动保存" }
        if cats.count == 1 {
            return "已自动保存\(cats[0].title)，可在「\(cats[0].page)」中修改"
        }
        let titles = cats.map { $0.title }.joined(separator: "、")
        let pages = cats.map { "「\($0.page)」" }.joined()
        return "已自动保存\(titles)，可分别在\(pages)中修改"
    }
}

// MARK: - 设置页

struct ImageAutoRecogSettingsView: View {
    /// UserDefaults 无法直接驱动视图刷新，用计数器在 Toggle 写回后触发重渲染。
    @State private var refreshTick = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(ImageAutoRecogSettings.sourceGroups, id: \.key) { group in
                    sourceGroupCard(group)
                }
                Text("以上设置仅对本机生效，不随账号云同步。识别完成后系统通知照常发送，结果统一进入对话气泡，可由你在对话中确认或编辑。")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(AIATheme.fillSoft)
        .navigationTitle("识别结果保存方式设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sourceGroupCard(_ group: (key: String, title: String, subtitle: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: group.key == "image" ? "photo" : "text.bubble")
                    .font(AIATheme.Font.headline.weight(.semibold))
                    .foregroundStyle(AIATheme.blue)
                    .frame(width: 30, height: 30)
                    .background(AIATheme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(group.title)
                            .font(AIATheme.Font.title3.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("识别结果保存方式")
                            .font(AIATheme.Font.title3.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                    Text(group.subtitle)
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer()
            }
            .padding(.bottom, 14)
            VStack(spacing: 14) {
                ForEach(ImageAutoRecogSettings.categories) { cat in
                    categoryRow(cat, source: group.key)
                }
            }
        }
        .padding(14)
        .card()
    }

    private func categoryRow(_ cat: ImageAutoRecogSettings.Category, source: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: cat.icon)
                .font(AIATheme.Font.callout.weight(.medium))
                .foregroundStyle(cat.tint)
            Text(cat.title)
                .font(AIATheme.Font.subhead.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Picker(selection: modeBinding(cat, source: source)) {
                ForEach(RecognitionAutoMode.allCases, id: \.self) { m in
                    Text(m.title).tag(m)
                }
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .frame(width: 196)
        }
    }

    /// UserDefaults 直读直写的 Binding，写回后 tick +1 触发刷新。
    private func modeBinding(_ cat: ImageAutoRecogSettings.Category, source: String) -> Binding<RecognitionAutoMode> {
        Binding(get: { ImageAutoRecogSettings.mode(for: cat.type, source: source) },
                set: { ImageAutoRecogSettings.setMode($0, for: cat.type, source: source); refreshTick &+= 1 })
    }

    /// UserDefaults 直读直写的 Binding，写回后 tick +1 触发刷新。
    private func binding(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: { v in
            set(v)
            refreshTick &+= 1
        })
    }
}

// MARK: - 全局轻量 Toast（静默保存提示等跨页面场景）

/// 单条提示载荷：普通提示走顶部黑胶囊；重要提示（如睡眠醒来）走居中大卡。
struct ToastPayload: Equatable {
    let text: String
    let icon: String?            // emoji，如 "🌙"
    let accent: Color?           // 主题强调色，描边用
    let important: Bool          // true=居中大卡；false=顶部黑胶囊
    let duration: TimeInterval
}

/// 单例消息中心：任何链路（首页截图 pending / 聊天 / 相册相机）静默保存后调用 show(_:)，
/// 由挂在 ContentView 根部的 GlobalToastOverlay 统一呈现，自动消失。
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var payload: ToastPayload?
    private var hideTask: Task<Void, Never>?

    /// 普通轻提示（顶部黑胶囊），维持原行为。
    func show(_ text: String, duration: TimeInterval = 3.2) {
        set(.init(text: text, icon: nil, accent: nil, important: false, duration: duration))
    }

    /// 重要提示（居中大卡 + 缩放弹出），默认 4.5s 给足阅读时间。
    func showImportant(_ text: String, icon: String? = nil, accent: Color? = nil, duration: TimeInterval = 4.5) {
        set(.init(text: text, icon: icon, accent: accent, important: true, duration: duration))
    }

    private func set(_ p: ToastPayload) {
        payload = p
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(p.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.payload = nil
        }
    }
}

/// 全局提示层：普通提示=顶部黑胶囊；重要提示=居中大卡（缩放弹出 + 强调描边）。
/// 挂在首页 NavigationStack 的 overlay 上，push 进来的页面（聊天页等）也能看到。
struct GlobalToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        ZStack {
            if let p = center.payload {
                if p.important {
                    // 居中大卡：图标 + 放大加粗 + 强调描边 + 阴影 + 缩放弹出。
                    VStack(spacing: 10) {
                        if let icon = p.icon {
                            Text(icon).font(.system(size: 40))
                        }
                        Text(p.text)
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(22)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.black.opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(p.accent ?? .white, lineWidth: 2.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                    .padding(.horizontal, 40)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    // 原顶部黑胶囊，行为不变。
                    VStack {
                        Text(p.text)
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.black.opacity(0.82))
                            )
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: center.payload)
        .allowsHitTesting(false)
    }
}
