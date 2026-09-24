// AppStoreReviewManager.swift
// 五星好评引导：在合适时机弹出五星选择弹窗。
// 高分(4-5星) → 跳 App Store 写评价；低分(1-3星) → 引导应用内反馈，避免差评外流。
// 触发时机：登录≥3天 + 累计记录≥5条 + 未弹过(或距上次"稍后"≥30天)。
// 规则来源：用户 2026-08-28 拍板。
import Foundation
import SwiftUI
import Combine
import SwiftData
import MessageUI
import AIAKit

// >>> CHANGE-[2026-09-24 10:33:41]-[低分反馈改根宿主直连] 开始
// 原此处定义了 Notification.Name.openFeedbackMail（供「设置页弹反馈邮件」）——
// 但低分星是在五星浮层上点的，浮层挂在根视图；设置页不在视图树时通知无人接收
// → 点 1-3 星「弹窗关闭、无任何反应」（2026-09-24 真机实测）。
// 现改为单例直接置 @Published 状态、由根视图的 StarReviewPromptHost 渲染，删除该通知通道。
// 回退：恢复本 extension + commitChoice 里的 post + SettingsView 的 .onReceive。
// <<< CHANGE-[2026-09-24 10:33:41]-[低分反馈改根宿主直连] 结束

@MainActor
final class AppStoreReviewManager: ObservableObject {
    static let shared = AppStoreReviewManager()

    // MARK: - 持久化状态
    @AppStorage("aia.reviewPromptedAt") private var promptedAt: Double = 0   // 最近一次弹窗时间戳
    @AppStorage("aia.reviewLastChoice") private var lastChoice: Int = 0      // 上次选择星数（0=未选/稍后）
    @AppStorage("aia.loginAt") private var loginAt: Double = 0               // 登录时间戳（AuthManager.login 写入）

    // MARK: - 弹窗状态（驱动 ContentView 根 ZStack 上的 StarReviewPromptHost）
    /// 是否展示五星选择弹窗
    @Published var showStarPrompt: Bool = false
    /// 用户当前选中的星数（1-5），0=未选
    @Published var selectedStars: Int = 0
    // >>> CHANGE-[2026-09-24 10:33:41]-[低分反馈改根宿主直连] 开始
    // showFeedbackComposer 已于 2026-09-24 10:51:57 废弃：SwiftUI sheet 在首页被吞，
    // 低分路径改为 UIKit 直接 present（见 presentFeedbackMail）。
    /// 设备未配置邮件账号时，改弹「邮件不可用」提示（含复制邮箱）
    @Published var showMailUnavailable: Bool = false
    // <<< CHANGE-[2026-09-24 10:33:41]-[低分反馈改根宿主直连] 结束

    private init() {}

    // MARK: - 触发入口（全局时机调用，如回前台）
    /// 满足时机条件时弹出五星弹窗；否则静默返回。
    func maybeRequestReview() {
        guard shouldPrompt() else { return }
        // 展示弹窗（首帧风暴已过，此处由 ContentView 回前台/onAppear 调用，安全）
        selectedStars = 0
        showStarPrompt = true
        promptedAt = Date().timeIntervalSince1970
    }

    private func shouldPrompt() -> Bool {
        guard AuthManager.shared.isLoggedIn else { return false }
        // 1) 登录≥3天
        let now = Date().timeIntervalSince1970
        let threeDays: Double = 3 * 86400
        if loginAt <= 0 || (now - loginAt) < threeDays { return false }
        // 2) 累计记录≥5条（四类合计），用一次轻量 fetch 计数
        guard recordCount() >= 5 else { return false }
        // 3) 未弹过，或距上次弹窗≥30天
        let thirtyDays: Double = 30 * 86400
        if promptedAt > 0 && (now - promptedAt) < thirtyDays { return false }
        return true
    }

    // >>> CHANGE-[2026-09-24 10:15:03]-[记录计数改 fetchCount 早退] 开始
    // 原因：判定只需要「四类合计 ≥5 条」。旧实现递归 fetch 四张全表、再用 Mirror 逐行反射过滤
    //       syncDeleted，对重度用户（几千条记录）会在回前台 1.5s 时卡主线程一下；
    //       而且旧代码因「登录≥3天」恒 false 从未真正执行过，修好条件后才会第一次跑起来。
    // 现改为逐类 fetchCount（走 SQL count、不反序列化整表），累计到 5 立即早退；
    // 具体类型可以写 #Predicate（泛型里写会崩，这正是旧版绕用 Mirror 的原因），符合项目铁律。
    // 回退：恢复上方 countAll + Mirror 版本。
    private func recordCount() -> Int {
        guard let ctx = AppDelegate.sharedMainContext else { return 0 }
        let threshold = 5
        var total = 0
        total += billCount(in: ctx);      if total >= threshold { return total }
        total += reminderCount(in: ctx);  if total >= threshold { return total }
        total += foodCount(in: ctx);      if total >= threshold { return total }
        total += healthCount(in: ctx)
        return total
    }

    private func billCount(in ctx: ModelContext) -> Int {
        (try? ctx.fetchCount(FetchDescriptor<Bill>(predicate: #Predicate { !$0.syncDeleted }))) ?? 0
    }

    private func reminderCount(in ctx: ModelContext) -> Int {
        (try? ctx.fetchCount(FetchDescriptor<Reminder>(predicate: #Predicate { !$0.syncDeleted }))) ?? 0
    }

    private func foodCount(in ctx: ModelContext) -> Int {
        (try? ctx.fetchCount(FetchDescriptor<FoodEntry>(predicate: #Predicate { !$0.syncDeleted }))) ?? 0
    }

    private func healthCount(in ctx: ModelContext) -> Int {
        (try? ctx.fetchCount(FetchDescriptor<HealthMetric>(predicate: #Predicate { !$0.syncDeleted }))) ?? 0
    }
    // <<< CHANGE-[2026-09-24 10:15:03]-[记录计数改 fetchCount 早退] 结束

    // MARK: - 用户选择处理
    /// 用户点击某颗星后调用。
    func chooseStars(_ stars: Int) {
        selectedStars = stars
        lastChoice = stars
        // 延迟关闭，让用户看到选中高亮
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.showStarPrompt = false
            self?.commitChoice(stars)
        }
    }

    private func commitChoice(_ stars: Int) {
        if stars >= 4 {
            // 高分：跳 App Store 写评价
            UIApplication.shared.open(AppURLs.appStoreReview)
        } else {
            // >>> CHANGE-[2026-09-24 10:33:41]-[低分反馈改根宿主直连] 开始
            // 低分路径演进（2026-09-24 一天内两版）：
            //   v1 原实现 post(.openFeedbackMail) 依赖「设置页刚好在视图树里」，首页点星时没人接 → 无反应；
            //   v2 改置 @Published → 根视图 .sheet，真机实测「状态已置位但 sheet 完全不出现」；
            //   v3（当前）改为 UIKit 直接从顶层 VC present，见 presentFeedbackMail()。
            // >>> CHANGE-[2026-09-24 10:51:57]-[低分反馈改 UIKit 直接呈现] 开始
            // 原因：SwiftUI 首页 body 高频重算 + 多模态叠加会吞掉 sheet 呈现，与
            //       InAppSafariView.swift:37-53（presentInAppBrowser）记录的是同一问题，项目既有解法即 UIKit present。
            // 回退：改回「置 showFeedbackComposer = true + 宿主上的 .sheet」。
            presentFeedbackMail()
            // <<< CHANGE-[2026-09-24 10:51:57]-[低分反馈改 UIKit 直接呈现] 结束
            // <<< CHANGE-[2026-09-24 10:33:41]-[低分反馈改根宿主直连] 结束
        }
    }

    /// 用户在弹窗外点遮罩「稍后」处理：记一次 promptedAt 但不记录选择。
    func dismissPrompt() {
        showStarPrompt = false
        promptedAt = Date().timeIntervalSince1970
    }
}

/// 五星好评选择浮层：用户逐星点击，4-5 星跳商店写评价，1-3 星引导应用内反馈。
/// 视觉对齐 CenteredAlertCard（surface 圆角卡 + 阴影 + 半透明遮罩）。
struct StarReviewPrompt: View {
    @Binding var selected: Int
    let onChoose: (Int) -> Void
    let onDismiss: () -> Void

    // >>> CHANGE-[2026-09-24 10:15:03]-[星级改纯点击] 开始
    // 原 hovered / highlighted 仅服务"按住预览高亮"，已随 onLongPressGesture 一并移除，
    // 高亮直接跟随 selected（点选后有 0.25s 可见时间）。
    // <<< CHANGE-[2026-09-24 10:15:03]-[星级改纯点击] 结束

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 14) {
                Text("喜欢好记AI吗？")
                    .font(AIATheme.Font.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text("你的评价能帮我们做得更好")
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(AIATheme.muted)

                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= selected ? "star.fill" : "star")
                            .font(.title)
                            .foregroundStyle(star <= selected ? AIATheme.warning : AIATheme.muted)
                            .scaleEffect(star == selected ? 1.15 : 1.0)
                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: selected)
                            // 原因：原先另挂 .onLongPressGesture(minimumDuration: 0.01)（"按住预览高亮"），
                            //       0.01s 几乎按下即成立，与同视图的 onTapGesture 抢同一次 touch → 可能点不中星星。
                            //       iOS 无 hover 概念，该预览价值有限，故移除；只保留点击 + contentShape 撑满命中区。
                            // 回退：恢复 hovered/highlighted 与那段 onLongPressGesture。
                            .contentShape(Rectangle())
                            .onTapGesture { onChoose(star) }
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(22)
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            .padding(.horizontal, 36)
        }
    }
}

// >>> CHANGE-[2026-09-24 10:15:03]-[好评弹窗移到根视图] 开始
/// 五星好评浮层的宿主：挂在 ContentView 根 ZStack 上，保证「触发点在哪都能显示」。
/// 抽成独立 View 并局部 @ObservedObject 订阅，避免根视图 body 因该单例的 @Published 变化而整体重算
/// （同 HomeHealthData 的既有处理方式）。
/// 历史：2026-09-24 之前该浮层挂在 SettingsView 上，而触发点在首页 ContentView 的 didBecomeActive →
/// 触发瞬间本页不在视图树，弹窗从未真正出现过；且 promptedAt 已被写入 → 又白锁 30 天。
struct StarReviewPromptHost: View {
    @ObservedObject private var review = AppStoreReviewManager.shared

    var body: some View {
        Group {
            if review.showStarPrompt {
                StarReviewPrompt(
                    selected: $review.selectedStars,
                    onChoose: { stars in review.chooseStars(stars) },
                    onDismiss: { review.dismissPrompt() }
                )
            }
        }
        // >>> CHANGE-[2026-09-24 10:33:41]-[低分反馈改根宿主直连] 开始
        // 低分（1-3 星）→ 应用内反馈：此处原先挂 `.sheet(MailComposer)`，真机实测「状态置位但 sheet 不出现」
        // （SwiftUI 首页 body 高频重算 + 多模态叠加吞掉呈现，与 InAppSafariView.swift:37-53 同一问题）。
        // 2026-09-24 10:51:57 起改为 UIKit 直接从顶层 VC present（见文件末尾 presentFeedbackMail()），
        // 这里只保留「邮件不可用」提示——它是 overlay，不依赖 present 机制，一定可见。
        // 回退：恢复上方被删的 .sheet 段。
        .centeredAlert(isPresented: $review.showMailUnavailable,
                       title: NSLocalizedString("feedback.mailUnavailableTitle", comment: ""),
                       message: String(format: NSLocalizedString("feedback.mailUnavailableMessage", comment: ""), "754727942@qq.com"),
                       dismissTitle: "知道了",
                       secondaryTitle: NSLocalizedString("feedback.copyEmail", comment: ""),
                       onSecondary: {
                           UIPasteboard.general.string = "754727942@qq.com"
                       })
        // <<< CHANGE-[2026-09-24 10:33:41]-[低分反馈改根宿主直连] 结束
    }
}
// <<< CHANGE-[2026-09-24 10:15:03]-[好评弹窗移到根视图] 结束

// MARK: - 应用内反馈邮件（UIKit 直接呈现）

// >>> CHANGE-[2026-09-24 10:51:57]-[低分反馈改 UIKit 直接呈现] 开始
/// 用 UIKit 直接从顶层 VC present 系统写信界面，绕开 SwiftUI 首页 sheet 被吞的问题。
/// 取顶层 VC 的写法与 `presentInAppBrowser`（InAppSafariView.swift:39-54）完全一致；
/// 收件人/标题/正文与设置页「帮助与反馈」保持一致（正文同样附设备信息）。
/// 失败（未配邮箱 / 取不到 window / 目标 VC 不在窗口里）一律退化为「邮件不可用」overlay 提示——
/// 该提示是纯 overlay，不依赖 present 机制，保证「点了有反馈」，不会静默失败。
/// 回退：删除本段，并恢复 commitChoice 里的 `showFeedbackComposer = true` 与宿主上的 `.sheet`。
@MainActor
func presentFeedbackMail() {
    let canMail = MFMailComposeViewController.canSendMail()
    print("[StarReview] 低分分支 → presentFeedbackMail, canSendMail=\(canMail)")
    guard canMail else {
        AppStoreReviewManager.shared.showMailUnavailable = true
        return
    }
    guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
          let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
    else {
        AppStoreReviewManager.shared.showMailUnavailable = true
        return
    }
    // 找到最上层可 present 的 VC（跳过已 present 的层级；跳过系统 alert，避免叠在它上面）
    var top = root
    while let presented = top.presentedViewController,
          !(presented is UIAlertController) {
        top = presented
    }
    // 目标 VC 不在窗口里时 present 会无声失败 → 提前退化为可见提示
    guard top.viewIfLoaded?.window != nil else {
        AppStoreReviewManager.shared.showMailUnavailable = true
        return
    }
    let vc = MFMailComposeViewController()
    vc.setToRecipients(["754727942@qq.com"])
    vc.setSubject("好记AI 意见反馈")
    vc.setMessageBody("请描述您遇到的问题或建议：<br/><br/>" + feedbackDeviceInfoHTML(), isHTML: true)
    vc.mailComposeDelegate = FeedbackMailDelegate.shared
    top.present(vc, animated: true)
}

/// 写信界面的 delegate：单例强引用（否则用户点「取消/发送」后无人关闭界面）。
/// 与 MailComposer.Coordinator 职责相同但独立——MailComposer 仍是设置页走的 SwiftUI 通道，不动它。
final class FeedbackMailDelegate: NSObject, MFMailComposeViewControllerDelegate {
    static let shared = FeedbackMailDelegate()

    func mailComposeController(_ controller: MFMailComposeViewController,
                               didFinishWith result: MFMailComposeResult,
                               error: Error?) {
        controller.dismiss(animated: true)
    }
}
// <<< CHANGE-[2026-09-24 10:51:57]-[低分反馈改 UIKit 直接呈现] 结束
