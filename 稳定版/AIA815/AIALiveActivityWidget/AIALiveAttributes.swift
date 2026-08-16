import ActivityKit
import SwiftUI

/// 灵动岛（Live Activity）统一活动属性。
/// - 静态字段（attributes）：启动后不变，用于路由场景。
/// - 动态字段（ContentState）：随业务阶段变化，由主 App 的 `LiveActivityManager` 更新。
///
/// 本文件同时被「主 App」与「AIALiveActivityWidget 扩展」两个 target 编译
/// （主 App 通过显式 Build File 引用；扩展通过同步根目录组自动包含），
/// 因此两个进程各自拥有一份相同定义，互不冲突。
public struct AIALiveAttributes: ActivityAttributes, Codable, Hashable {
    public typealias LiveData = ContentState

    public struct ContentState: Codable, Hashable, Sendable {
        // —— 识别流水线（kind = "recognition"）——
        public var phase: String?            // "ocr" / "vision" / "done" / "fail"
        public var recognitionTitle: String? // "午餐" / "账单"
        public var recognitionAmount: Double?

        // —— 睡眠（kind = "sleep"）——
        public var sleepStartedAt: Date?

        // —— 待办临近（kind = "todo"）——
        public var todoTitle: String?
        public var todoDueInMinutes: Int?

        // —— 轮播总览（kind = "carousel"）——
        /// 单张轮播卡片的数据（标题 / 副标题 / 图标 / 强调色键）。
        public struct CarouselItem: Codable, Hashable, Sendable {
            public var title: String
            public var detail: String
            public var systemImage: String
            public var accent: String   // "bill" | "todo" | "health" | "food"
            public init(title: String, detail: String, systemImage: String, accent: String) {
                self.title = title
                self.detail = detail
                self.systemImage = systemImage
                self.accent = accent
            }
        }
        /// 全部轮播卡片（顺序即轮播顺序）。
        public var carouselItems: [CarouselItem]
        /// 当前展示到第几张（由主 App 轮播调度切换）。
        public var currentCardIndex: Int

        public init(
            phase: String? = nil,
            recognitionTitle: String? = nil,
            recognitionAmount: Double? = nil,
            sleepStartedAt: Date? = nil,
            todoTitle: String? = nil,
            todoDueInMinutes: Int? = nil,
            carouselItems: [CarouselItem] = [],
            currentCardIndex: Int = 0
        ) {
            self.phase = phase
            self.recognitionTitle = recognitionTitle
            self.recognitionAmount = recognitionAmount
            self.sleepStartedAt = sleepStartedAt
            self.todoTitle = todoTitle
            self.todoDueInMinutes = todoDueInMinutes
            self.carouselItems = carouselItems
            self.currentCardIndex = currentCardIndex
        }

        // nonisolated：start(kind:) 的默认参数在非隔离调用点求值，
        // 标 nonisolated 避免 Swift 6 下「main actor-isolated 属性从非隔离上下文引用」报错。
        nonisolated public static let empty = ContentState()
    }

    // 静态、启动后即不变
    public var kind: String            // "recognition" / "sleep" / "todo" / "carousel"
    public var startedAt: Date

    public init(kind: String, startedAt: Date = .now) {
        self.kind = kind
        self.startedAt = startedAt
    }
}
