// QuickActionRouter.swift
// 桌面 3D Touch / 长按 App 图标快捷操作：把系统回调的 shortcut 类型转发给 SwiftUI 界面。
import Foundation
import Combine

/// 桌面图标快捷操作类型，与 Info.plist 中 UIApplicationShortcutItemType 一一对应
enum QuickAction: String {
    case camera = "com.aia.shortcut.camera"   // 拍照记录
    case voice  = "com.aia.shortcut.voice"    // 语音记录
    case chat   = "com.aia.shortcut.chat"     // 问阿宝AI
    case todo   = "com.aia.shortcut.todo"     // 查待办
}

/// 跨层中转：AppDelegate 收到快捷操作后写入 pending，ContentView 消费并重置。
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()

    /// 待处理的快捷操作；消费后置 nil。
    @Published var pending: QuickAction?

    private init() {}
}

/// 首页全局导航栈中转：所有需要跳转到对话/各模块页的入口（四宫格、底部栏、快捷操作）
/// 统一走这一条 path，避免 NavigationLink(destination:) 与 .navigationDestination(for:) 混用
/// 导致 path 程序化推送的目的地不触发（表现为 path 已设置但 ChatView 等不出现）。
final class NavigationRouter: ObservableObject {
    static let shared = NavigationRouter()

    @Published var path: [HomeRoute] = []
    /// 跳转到对话页时携带的预填充文本；ChatView 进入后消费并自动发送。
    @Published var chatPrefill: String?
    /// 进入聊天页的来源描述（home / voice / todoReminder），传给 ChatView.entrySource
    @Published var chatEntrySource: String = "home"

    private init() {}

    /// 跳转文字对话页；`prefill` 会填入输入框并自动发送（用于各模块空态 CTA）。
    func navigateToChat(prefill: String? = nil) {
        self.chatPrefill = prefill
        if prefill?.contains("提醒") == true || prefill?.contains("提醒") == true {
            self.chatEntrySource = "todoReminder"
        } else {
            self.chatEntrySource = "home"
        }
        self.navigate(.chat)
    }

    // MARK: - 帧合并导航
    /// 修复 "Update NavigationRequestObserver tried to update multiple times per frame"。
    /// 根因：多个入口（四宫格 Button、底部栏、滚动气泡 .onTapGesture、autoSetup、快捷操作）以及
    /// 各页面的 pop（如 AutoRecognitionSetupView 的「完成」）都在主线程改写 `path`，
    /// 若同一渲染帧内发生两次 path 变更（例如某次异步 flush 与一次同步 removeLast 并发），
    /// SwiftUI 的 _NavigationRequestObserver 会在同一帧被更新两次而断言失败。
    /// 这里把同帧内的所有跳转 / pop 请求合并为「仅最后一次」，在下一个 runloop turn 用一次 path
    /// 变更统一提交，保证任何情况下每帧至多一次 path 改写。
    private enum NavOp {
        case push(HomeRoute)
        case replace(HomeRoute)
        case pop
    }
    private var pendingOp: NavOp?
    private var flushScheduled = false

    /// 追加式跳转（首页四宫格、底部栏、气泡、autoSetup 等常用）。
    func navigate(_ route: HomeRoute) {
        enqueue(.push(route))
    }

    /// 替换式跳转（冷启动快捷操作 / 通知：需把整条 path 重置为目标路由）。
    func replaceWith(_ route: HomeRoute) {
        enqueue(.replace(route))
    }

    /// 出栈一次（AutoRecognitionSetupView「完成」等，替代直接 router.path.removeLast()）。
    func pop() {
        enqueue(.pop)
    }

    /// 同帧内无论 navigate / replaceWith / pop 调用多少次，只排一个主线程 flush，
    /// 下一 turn 统一提交一次 path 变更，从机制上杜绝同帧多次 update。
    private func enqueue(_ op: NavOp) {
        pendingOp = op
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard let op = self.pendingOp else { return }
            self.pendingOp = nil
            switch op {
            case .push(let r):    if self.path.last != r { self.path.append(r) }
            case .replace(let r): self.path = [r]
            case .pop:            if !self.path.isEmpty { self.path.removeLast() }
            }
        }
    }
}
