// AppStoreReviewManager.swift
// 五星好评引导：在合适时机弹出五星选择弹窗。
// 高分(4-5星) → 跳 App Store 写评价；低分(1-3星) → 引导应用内反馈，避免差评外流。
// 触发时机：登录≥3天 + 累计记录≥5条 + 未弹过(或距上次"稍后"≥30天)。
// 规则来源：用户 2026-08-28 拍板。
import Foundation
import SwiftUI
import Combine
import SwiftData
import AIAKit

/// 通知：请求「我的/设置」页弹出反馈邮件（复用 SettingsView 既有 MailComposer 通道）。
extension Notification.Name {
    static let openFeedbackMail = Notification.Name("aia.openFeedbackMail")
}

@MainActor
final class AppStoreReviewManager: ObservableObject {
    static let shared = AppStoreReviewManager()

    // MARK: - 持久化状态
    @AppStorage("aia.reviewPromptedAt") private var promptedAt: Double = 0   // 最近一次弹窗时间戳
    @AppStorage("aia.reviewLastChoice") private var lastChoice: Int = 0      // 上次选择星数（0=未选/稍后）
    @AppStorage("aia.loginAt") private var loginAt: Double = 0               // 登录时间戳（AuthManager.login 写入）

    // MARK: - 弹窗状态（驱动 SettingsView / ContentView 上的 overlay）
    /// 是否展示五星选择弹窗
    @Published var showStarPrompt: Bool = false
    /// 用户当前选中的星数（1-5），0=未选
    @Published var selectedStars: Int = 0

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

    /// 四类记录合计计数（账单/待办/饮食/健康），带 !syncDeleted 过滤，遵循项目铁律。
    /// 注：SwiftData #Predicate 闭包无法在泛型 T 上直接访问 syncDeleted，
    /// 故 fetch 全量后在内存过滤（用户本地数据量小，性能可接受）。
    private func recordCount() -> Int {
        guard let ctx = AppDelegate.sharedMainContext else { return 0 }
        let counts: [Int] = [
            countAll(Bill.self, in: ctx),
            countAll(Reminder.self, in: ctx),
            countAll(FoodEntry.self, in: ctx),
            countAll(HealthMetric.self, in: ctx)
        ]
        return counts.reduce(0, +)
    }

    private func countAll<T: PersistentModel>(_ type: T.Type, in ctx: ModelContext) -> Int {
        let all = (try? ctx.fetch(FetchDescriptor<T>())) ?? []
        return all.filter { !syncDeleted(of: $0) }.count
    }

    /// 从 PersistentModel 实例读取 syncDeleted（所有业务 @Model 均含此属性）。
    private func syncDeleted(of model: PersistentModel) -> Bool {
        let mirror = Mirror(reflecting: model)
        for child in mirror.children {
            if child.label == "syncDeleted", let v = child.value as? Bool {
                return v
            }
        }
        return false
    }

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
            // 低分：引导应用内反馈（发通知，由 SettingsView 弹 MailComposer）
            NotificationCenter.default.post(name: .openFeedbackMail, object: nil)
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

    // 为"hover 预览"提供本地高亮状态
    @State private var hovered: Int = 0

    private var highlighted: Int { hovered > 0 ? hovered : selected }

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
                        Image(systemName: star <= highlighted ? "star.fill" : "star")
                            .font(.title)
                            .foregroundStyle(star <= highlighted ? AIATheme.warning : AIATheme.muted)
                            .scaleEffect(star == highlighted ? 1.15 : 1.0)
                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: highlighted)
                            .onTapGesture { onChoose(star) }
                            .onLongPressGesture(minimumDuration: 0.01, pressing: { pressing in
                                hovered = pressing ? star : 0
                            }, perform: {})
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
