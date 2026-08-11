// TriggerType.swift
// 触发方式共享模型：用于自动截屏识别设置页和新人引导的快捷指令配置页。
import SwiftUI

// MARK: - 可配置项
// 做好的「小记自动记账、记待办、记饮食」快捷指令的托管链接，填在这里即可在 App 内一键跳转安装。
// 支持两种形式：
// 1) .shortcut 文件直链 → 用 "shortcuts://import-shortcut?url=..." 打开；
// 2) iCloud 共享链接  → 直接用 "https://www.icloud.com/shortcuts/..." 打开。
// 若为空，则「去添加」按钮会提示先填入托管链接。
let kShortcutFileURL: String = "https://www.icloud.com/shortcuts/c0dc9c80f294447a8fa1d5a562e58141"

/// 自动截屏识别的触发方式
enum TriggerType: String, CaseIterable, Identifiable {
    case assistiveTouch = "辅助触控（小白点）"
    case backTap = "轻敲手机背面"
    case actionButton = "操作按钮（15Pro及更新机型支持）"
    case controlCenter = "控制中心"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .assistiveTouch: return "circle.dotted.circle"
        case .backTap: return "hand.tap.fill"
        case .actionButton: return "button.horizontal.top.press.fill"
        case .controlCenter: return "switch.2"
        }
    }
    var rotation: Double {
        switch self {
        case .actionButton: return -90
        default: return 0
        }
    }
    /// 对应 iOS 系统设置页的私有 URL scheme（不一定在所有版本有效）
    var systemSettingsPath: String {
        switch self {
        case .assistiveTouch:
            return "App-Prefs:root=ACCESSIBILITY&path=TOUCH_REACHABILITY/AIR_TOUCH_TITLE"
        case .backTap:
            return "App-Prefs:root=ACCESSIBILITY&path=TOUCH_REACHABILITY/BACK_TAP_TITLE"
        case .actionButton:
            return "App-Prefs:root=ACCESSIBILITY&path=ACTION_BUTTON_TITLE"
        case .controlCenter:
            return "App-Prefs:root=ControlCenter"
        }
    }
    /// 可选：对应触发方式的视频教程 URL；配置后教程页会播放该视频，否则展示步骤引导占位图。
    var videoURL: URL? {
        switch self {
        case .assistiveTouch:
            // 把辅助触控的教程视频链接填在这里，例如：
            // return URL(string: "https://example.com/tutorial-assistive-touch.mp4")
            return nil
        case .backTap:
            // return URL(string: "https://example.com/tutorial-back-tap.mp4")
            return nil
        case .actionButton:
            // return URL(string: "https://example.com/tutorial-action-button.mp4")
            return nil
        case .controlCenter:
            // return URL(string: "https://example.com/tutorial-control-center.mp4")
            return nil
        }
    }
    var steps: [String] {
        switch self {
        case .assistiveTouch:
            return [
                "打开手机「设置」→「辅助功能」→「触控」→「辅助触控」。",
                "打开「辅助触控」开关。",
                "在「自定操作」里选择「单点 / 轻点两下 / 长按」作为触发方式，并选择「小记自动记账、记待办、记饮食」。",
                "设置完毕，付款或截屏后，点/敲小白点即可自动识别。"
            ]
        case .backTap:
            return [
                "打开手机「设置」→「辅助功能」→「触控」→「轻点背面」。",
                "选择「轻点两下」或「轻点三下」。",
                "在列表里找到并选择「小记自动记账、记待办、记饮食」。",
                "设置完毕，截屏后轻敲手机背面即可触发识别。"
            ]
        case .actionButton:
            return [
                "打开手机「设置」→「操作按钮」。",
                "把操作按钮功能滑动到「快捷指令」。",
                "选择「小记自动记账、记待办、记饮食」。",
                "设置完毕，长按侧边操作按钮即可触发识别。"
            ]
        case .controlCenter:
            return [
                "打开手机「设置」→「控制中心」。",
                "在「更多控制」里找到「快捷指令」并点击绿色「+」添加。",
                "从屏幕右上角下滑打开控制中心，长按「快捷指令」图标。",
                "选择「小记自动记账、记待办、记饮食」即可运行；也可在快捷指令 App 里把它设成控制中心专用指令。"
            ]
        }
    }
}

// MARK: - 共享跳转方法
/// 打开快捷指令托管安装页（iCloud 共享链接或 .shortcut 直链）
@MainActor
func openShortcutImport(completion: @escaping (_ fallbackToShortcutsApp: Bool, _ toastMessage: String?) -> Void = { _, _ in }) {
    guard !kShortcutFileURL.isEmpty else {
        if let url = URL(string: "shortcuts://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        completion(true, "请先在代码里填入托管的快捷指令链接")
        return
    }

    // iCloud 共享链接：直接打开「添加快捷指令」页
    if kShortcutFileURL.contains("icloud.com/shortcuts/"), let url = URL(string: kShortcutFileURL) {
        UIApplication.shared.open(url)
        completion(false, nil)
        return
    }

    // .shortcut 文件直链：用 shortcuts://import-shortcut?url=... 打开
    if let encoded = kShortcutFileURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
       let url = URL(string: "shortcuts://import-shortcut?url=\(encoded)") {
        UIApplication.shared.open(url)
        completion(false, nil)
        return
    }

    if let url = URL(string: "shortcuts://"), UIApplication.shared.canOpenURL(url) {
        UIApplication.shared.open(url)
    }
    completion(true, "无法打开快捷指令链接")
}

/// 打开对应系统设置页（精确页失败则回退到辅助功能首页）
@MainActor
func openTriggerSystemSettings(_ trigger: TriggerType, fallbackToast: @escaping (_ message: String) -> Void = { _ in }) {
    guard let url = URL(string: trigger.systemSettingsPath) else { return }
    UIApplication.shared.open(url) { opened in
        if !opened {
            if let fallback = URL(string: "App-Prefs:root=ACCESSIBILITY") {
                UIApplication.shared.open(fallback)
            }
            fallbackToast("已跳转至「辅助功能」，请继续进入对应设置项")
        }
    }
}
