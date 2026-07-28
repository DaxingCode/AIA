// ImageAutoRecogSettingsView.swift
// 图片自动识别的「按类别」行为设置：自动保存 / 自动弹出确认页。
//
// 设计要点：
//  - 仅存本机 UserDefaults（不走云同步），换机后回到默认值。
//  - 默认值 = 当前线上体验：账单/待办/健康 自动保存=开，饮食 自动保存=关；四类 自动弹出=开。
//    因此老用户升级后行为零变化，只有主动关"自动弹出"才会进入静默保存路径。
//  - 行为矩阵（RecognitionSaver.processRecognition 消费）：
//      有类别弹出=开            → 弹确认页（自动保存=开 的类别先预存，关的点「存入」再插）
//      全部弹出=关 且 有保存=开 → 静默入库 + toast 引导去对应页面修改
//      全部弹出=关 且 全保存=关 → 什么都不做（丢弃本次识别）
//  - 静默路径撞上疑似重复图片时会升级为弹确认页警告，防止无感重复入库。

import SwiftUI
import Combine

// MARK: - 配置读写（单一真源：默认值只定义在这里）

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

    // 默认值：饮食自动保存=关，其余=开；四类自动弹出=开。
    static func defaultAutoSave(for type: String) -> Bool { type != "food" }
    static func defaultAutoPopup(for type: String) -> Bool { true }

    private static func saveKey(_ type: String) -> String { "imageAutoRecog.autoSave.\(type)" }
    private static func popupKey(_ type: String) -> String { "imageAutoRecog.autoPopup.\(type)" }

    static func autoSave(for type: String) -> Bool {
        UserDefaults.standard.object(forKey: saveKey(type)) as? Bool ?? defaultAutoSave(for: type)
    }
    static func autoPopup(for type: String) -> Bool {
        UserDefaults.standard.object(forKey: popupKey(type)) as? Bool ?? defaultAutoPopup(for: type)
    }
    static func setAutoSave(_ v: Bool, for type: String) {
        UserDefaults.standard.set(v, forKey: saveKey(type))
    }
    static func setAutoPopup(_ v: Bool, for type: String) {
        UserDefaults.standard.set(v, forKey: popupKey(type))
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
                headerCard
                ForEach(ImageAutoRecogSettings.categories) { cat in
                    categoryCard(cat)
                }
                Text("以上设置仅对本机生效，不随账号云同步。识别完成的系统通知不受影响，照常发送。")
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
        .navigationTitle("图片自动识别")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.checkmark")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("识别后的处理方式")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("截屏无感识别、拍照 / 相册识别后，按类别决定：是否自动保存记录、是否弹出确认页。关闭弹出且开启自动保存时，会静默保存并提示你可去对应页面修改。两者都关闭时，该类别的识别结果将被丢弃。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func categoryCard(_ cat: ImageAutoRecogSettings.Category) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: cat.icon)
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(cat.tint)
                Text(cat.title)
                    .font(AIATheme.Font.subhead.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Toggle(isOn: binding(get: { ImageAutoRecogSettings.autoSave(for: cat.type) },
                                 set: { ImageAutoRecogSettings.setAutoSave($0, for: cat.type) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动保存")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(.primary)
                    Text("识别完成后直接保存记录，无需手动点「存入」")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .tint(cat.tint)

            Divider()

            Toggle(isOn: binding(get: { ImageAutoRecogSettings.autoPopup(for: cat.type) },
                                 set: { ImageAutoRecogSettings.setAutoPopup($0, for: cat.type) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动弹出确认页")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(.primary)
                    Text("识别完成后打开 App 时弹出结果确认页")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
            }
            .tint(cat.tint)

            if let hint = statusHint(for: cat) {
                Text(hint.text)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(hint.warning ? AIATheme.warning : AIATheme.muted)
                    .lineSpacing(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((hint.warning ? AIATheme.warning : AIATheme.muted).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
        }
        .padding(14)
        .card()
    }

    /// 当前组合的行为说明；「双关」给 warning 色提醒结果会被丢弃。
    private func statusHint(for cat: ImageAutoRecogSettings.Category) -> (text: String, warning: Bool)? {
        let save = ImageAutoRecogSettings.autoSave(for: cat.type)
        let popup = ImageAutoRecogSettings.autoPopup(for: cat.type)
        if save && !popup {
            return ("当前：静默保存，不弹确认页。保存后可在「\(cat.page)」中查看和修改。", false)
        }
        if !save && !popup {
            return ("当前：识别到\(cat.title)时不保存也不弹出，结果将被丢弃。", true)
        }
        return nil
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

/// 单例消息中心：任何链路（首页截图 pending / 聊天 / 相册相机）静默保存后调用 show(_:)，
/// 由挂在 ContentView 根部的 GlobalToastOverlay 统一呈现，自动消失。
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, duration: TimeInterval = 3.2) {
        message = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

/// 顶部胶囊提示条：黑底白字，自动消失，不拦截点击。
/// 挂在首页 NavigationStack 的 overlay 上，push 进来的页面（聊天页等）也能看到。
struct GlobalToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack {
            if let msg = center.message {
                Text(msg)
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
            }
            Spacer()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.message)
        .allowsHitTesting(false)
    }
}
