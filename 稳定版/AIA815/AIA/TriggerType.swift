// TriggerType.swift
// 触发方式共享模型：用于自动截屏识别设置页和新人引导的快捷指令配置页。
import SwiftUI

// MARK: - 可配置项
// 做好的「好记AI自动记账、记待办、记饮食」快捷指令的托管链接，填在这里即可在 App 内一键跳转安装。
// 支持两种形式：
// 1) .shortcut 文件直链 → 用 "shortcuts://import-shortcut?url=..." 打开；
// 2) iCloud 共享链接  → 直接用 "https://www.icloud.com/shortcuts/..." 打开。
// 若为空，则「去添加」按钮会提示先填入托管链接。
let kShortcutFileURL: String = "https://www.icloud.com/shortcuts/c0dc9c80f294447a8fa1d5a562e58141"

/// 自动截屏识别的触发方式
enum TriggerType: String, CaseIterable, Identifiable {
    case assistiveTouch = "辅助触控（小白点）自动识别、记录"
    case backTap = "轻敲手机背面自动识别、记录"
    case actionButton = "操作按钮自动识别、记录"
    case controlCenter = "控制中心自动识别、记录"

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
    /// 对应触发方式在系统「设置」的入口路径（`App-Prefs:` scheme）。
    /// iOS 26 上 `prefs:` 精确子页面路径会被系统拦截（`canOpenURL` 直接返回 false），
    /// 因此所有触发方式统一跳到系统「设置」首页，由用户再自行点进对应子页面。
    /// 兜底顺序见 `openTriggerSystemSettings`：设置首页 → 本 App 设置页。
    var settingsDeepPath: String {
        return "App-Prefs:"
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
    /// 可选：对应触发方式的图文/视频教程网页 URL；配置后「查看视频教程」会优先在 App 内打开该网页。
    var articleURL: URL? {
        switch self {
        case .assistiveTouch:
            return URL(string: "https://mp.weixin.qq.com/s/W9renb06av1Tv9GII3b_VA")
        case .backTap:
            return URL(string: "https://mp.weixin.qq.com/s/5Vu2HgcyN5RdV9YuPrDCoQ")
        case .actionButton:
            return URL(string: "https://mp.weixin.qq.com/s/vZNDAn1pBOiqCOXvrLoMNg")
        default:
            return nil
        }
    }
    var steps: [String] {
        switch self {
        case .assistiveTouch:
            return [
                "打开手机「设置」→「辅助功能」→「触控」→「辅助触控」。",
                "打开「辅助触控」开关。",
                "在「自定操作」里选择「单点 / 轻点两下 / 长按」作为触发方式，并选择「好记AI自动记账、记待办、记饮食」。",
                "设置完毕，付款或收到通知时，点/敲下白点，自动识别并记录账单、待办。"
            ]
        case .backTap:
            return [
                "打开手机「设置」→「辅助功能」→「触控」→「轻点背面」。",
                "选择「轻点两下」或「轻点三下」。",
                "在列表里找到并选择「好记AI自动记账、记待办、记饮食」。",
                "设置完毕，付款或收到通知时，轻拍手机背面，自动识别并记录账单、待办。"
            ]
        case .actionButton:
            return [
                "iPhone 15 Pro及后续机型打开手机「设置」→「操作按钮」。",
                "把操作按钮功能滑动到「快捷指令」。",
                "选择「好记AI自动记账、记待办、记饮食」。",
                "设置完毕，付款或收到通知时，按住左侧「操作按钮」，自动识别并记录账单、待办。"
            ]
        case .controlCenter:
            return [
                "打开手机「设置」→「控制中心」。",
                "在「更多控制」里找到「快捷指令」并点击绿色「+」添加。",
                "从屏幕右上角下滑打开控制中心，长按「快捷指令」图标。",
                "选择「好记AI自动记账、记待办、记饮食」即可运行；也可在快捷指令 App 里把它设成控制中心专用指令。"
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

/// 打开触发方式对应的系统设置页。
/// 两级兜底：① 先跳系统「设置」首页（App-Prefs:）；
/// ② 仍打不开再退回本 App 的设置页（UIApplication.openSettingsURLString）。
/// 注：iOS 26 上 `prefs:` 精确子页面路径会被拦截，故统一用 `App-Prefs:` scheme。
@MainActor
func openTriggerSystemSettings(_ trigger: TriggerType, fallbackToast: @escaping (_ message: String) -> Void = { _ in }) {
    // 第一层：系统「设置」首页
    if let deepURL = URL(string: trigger.settingsDeepPath), UIApplication.shared.canOpenURL(deepURL) {
        UIApplication.shared.open(deepURL) { opened in
            if opened {
                return
            }
            // 第二层：本 App 设置页
            openTriggerAppSettingsFallback(fallbackToast)
        }
        return
    }
    // 第一层 URL 不合法时直接进入第二层
    openTriggerAppSettingsFallback(fallbackToast)
}

/// 第二层（兜底）：打开本 App 在「设置」里的页面（即设置 → 好记）。
@MainActor
private func openTriggerAppSettingsFallback(_ fallbackToast: @escaping (_ message: String) -> Void) {
    let url = URL(string: UIApplication.openSettingsURLString)
    UIApplication.shared.open(url ?? URL(string: "prefs:root")!) { opened in
        if !opened {
            fallbackToast("无法打开系统设置，请在「设置」中手动进入")
        }
    }
}
