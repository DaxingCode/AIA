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
        self.path.append(.chat)
    }
}
