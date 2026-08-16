import ActivityKit
import Foundation

/// 灵动岛中枢：负责启 / 更 / 停 Live Activity，按 `kind` 路由多场景。
/// 主 App 单例；Widget Extension 不引用此类（扩展只负责 UI 渲染，数据经 ContentState 传入）。
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// 系统是否允许 Live Activity
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 启动一个 kind 的 Live Activity；若已存在同 kind 则改为 update。
    @discardableResult
    func start(kind: String, state: AIALiveAttributes.ContentState = AIALiveAttributes.ContentState.empty) -> Activity<AIALiveAttributes>? {
        guard isAvailable else {
            print("[LiveActivity] 未授权，无法启动 \(kind)")
            return nil
        }
        if let existing = Activity<AIALiveAttributes>.activities.first(where: { $0.attributes.kind == kind }) {
            Task { await existing.update(using: state) }
            return existing
        }
        let attrs = AIALiveAttributes(kind: kind)
        do {
            return try Activity.request(
                attributes: attrs,
                contentState: state,
                pushType: nil            // 本地更新，不走 Push
            )
        } catch {
            print("[LiveActivity] start(\(kind)) failed: \(error)")
            return nil
        }
    }

    /// 更新指定 kind 的 Live Activity 动态内容
    func update(kind: String, state: AIALiveAttributes.ContentState) {
        guard let act = Activity<AIALiveAttributes>.activities.first(where: { $0.attributes.kind == kind }) else { return }
        Task { await act.update(using: state) }
    }

    /// 结束指定 kind 的 Live Activity
    func end(kind: String, after: TimeInterval = 0, stale: Bool = false) {
        guard let act = Activity<AIALiveAttributes>.activities.first(where: { $0.attributes.kind == kind }) else { return }
        Task {
            await act.end(dismissalPolicy: after > 0
                ? .after(.now.addingTimeInterval(after))
                : (stale ? .immediate : .default))
        }
    }

    /// 查询当前指定 kind 的活动
    func current(kind: String) -> Activity<AIALiveAttributes>? {
        Activity<AIALiveAttributes>.activities.first(where: { $0.attributes.kind == kind })
    }

    // MARK: - 轮播总览（kind = "carousel"）

    private var carouselTimer: Timer?
    private var carouselItems: [AIALiveAttributes.ContentState.CarouselItem] = []

    /// 启动「四类数据轮播」总览：账单 / 待办 / 健康 / 饮食 在同一张卡片上定时切换。
    /// - Parameters:
    ///   - interval: 每张卡片停留秒数（默认 4s）。注意后台 App 会被系统时停 Timer。
    ///   - items: 自定义卡片；缺省用 `demoCarouselItems()`。
    func startCarousel(interval: TimeInterval = 4,
                       items: [AIALiveAttributes.ContentState.CarouselItem]? = nil) {
        let cards = items ?? Self.demoCarouselItems()
        guard !cards.isEmpty else { return }
        carouselItems = cards
        carouselTimer?.invalidate()

        var index = 0
        // 先插第一张
        start(kind: "carousel",
              state: .init(carouselItems: cards, currentCardIndex: 0))
        // 定时切下一张
        carouselTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            index = (index + 1) % cards.count
            // Timer 回调默认非隔离，update 是 @MainActor 方法，需切回主线程调用。
            Task { @MainActor in
                self.update(kind: "carousel",
                            state: .init(carouselItems: cards, currentCardIndex: index))
            }
        }
    }

    /// 停止轮播并收起卡片。
    func stopCarousel(after: TimeInterval = 1.5) {
        carouselTimer?.invalidate()
        carouselTimer = nil
        carouselItems = []
        end(kind: "carousel", after: after)
    }

    /// Demo 用的四张卡片（真实接入时替换 detail 为线上聚合数据）。
    static func demoCarouselItems() -> [AIALiveAttributes.ContentState.CarouselItem] {
        [
            .init(title: "今日账单", detail: "午餐 ¥42.50 · 共 3 笔", systemImage: "yensign.circle.fill", accent: "bill"),
            .init(title: "待办提醒", detail: "2 项今天到期 · 1 项逾期", systemImage: "checklist", accent: "todo"),
            .init(title: "健康概览", detail: "步数 6,820 · 静息心率 72", systemImage: "heart.fill", accent: "health"),
            .init(title: "饮食记录", detail: "今日已记录 1,240 kcal", systemImage: "fork.knife", accent: "food"),
        ]
    }
}
