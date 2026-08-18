// AIATheme.swift
// 从 UIComponents.swift 抽出的完整设计令牌层，供主 App / Widget / Extension 共享。
// 主 App 通过 `import AIAKit` 获得同名类型，调用点零改动。
import SwiftUI
import UIKit

// MARK: - 自适应颜色（跟随系统浅/深）
extension UIColor {
    public convenience init(hex: UInt64) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8)  & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
    /// 跟随系统：浅色用 light，深色用 dark
    public convenience init(light: UInt64, dark: UInt64) {
        self.init { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }
}

extension Color {
    public init(hex: UInt64) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
    /// 跟随系统浅/深动态色
    public static func adaptive(light: UInt64, dark: UInt64) -> Color {
        Color(UIColor(light: light, dark: dark))
    }
}

// MARK: - 外观模式（浅色 / 深色 / 跟随系统）
/// 持久化键：UserDefaults 的 `aia.appearance`，值为 rawValue（system/light/dark）。
public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }

    /// 设置页分段标题
    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    /// 系统图标（用于设置项左侧装饰）
    public var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    /// 映射到 SwiftUI ColorScheme；system 返回 nil（即不覆盖，跟随系统）
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// 从持久化字符串解析，非法值兜底为 system
    public init(raw: String) {
        self = AppearanceMode(rawValue: raw) ?? .system
    }
}

// MARK: - 设计令牌（统一视觉语言，浅/深自适应）
public enum AIATheme {
    // 主强调色（沿用科技蓝）
    public static let blue   = Color(hex: 0x378add)
    public static let green  = Color(hex: 0x1d9e75)
    public static let amber  = Color(hex: 0xe0a23a)
    public static let purple = Color(hex: 0x9b59b6)
    public static let ink    = Color.adaptive(light: 0x1f2937, dark: 0x2c2c2e)   // 深底（按钮背景，配白字）
    public static let warn   = Color.adaptive(light: 0xe0564b, dark: 0xff6f61)
    public static let ok     = Color.adaptive(light: 0x3b6d11, dark: 0x7ed957)

    // 语义文字
    public static let sub   = Color.adaptive(light: 0x5f5e5a, dark: 0xa1a1a6)
    public static let muted = Color.adaptive(light: 0x8a9099, dark: 0x8e8e93)
    // 「需清晰可读的卡片次要文字」专用：深色值提到 0xd1d1d6（系统 label 级亮灰），
    // 在深色近黑底（surface 0x1c1c1e）上对比度 ~15:1。
    public static let reading = Color.adaptive(light: 0x3c3c43, dark: 0xd1d1d6)
    public static let iconInactive = Color.adaptive(light: 0xc9ced3, dark: 0x5a5a5e)

    // 语义表面（卡片/内层/分隔，自动适配深浅）
    public static let surface          = Color.adaptive(light: 0xf7f9fb, dark: 0x1c1c1e)
    public static let surfaceSecondary = Color.adaptive(light: 0xf1f3f5, dark: 0x2a2a2c)
    public static let hairline         = Color.adaptive(light: 0xe6e9ec, dark: 0x636366)
    public static let fillSoft         = Color.adaptive(light: 0xeef1f4, dark: 0x2c2c2e)
    public static let track            = Color.adaptive(light: 0xe3e7ea, dark: 0x363638)

    // 模块底色：与 food/health/bill/todo 语义色同 hue 的淡 tint（深浅自适应）
    public static let dietBG   = Color.adaptive(light: 0xfbf0db, dark: 0x2a2416)  // 饮食·琥珀淡底
    public static let healthBG = Color.adaptive(light: 0xf3e9f9, dark: 0x241b2c)  // 健康·紫淡底
    public static let billBG   = Color.adaptive(light: 0xe3f6ef, dark: 0x15251e)  // 账单·绿淡底
    public static let todoBG   = Color.adaptive(light: 0xe7f1fc, dark: 0x16242f)  // 待办·蓝淡底
    public static let amberBG = Color.adaptive(light: 0xfbeed5, dark: 0x3a2f1a)   // 待确认·琥珀淡底

    // MARK: 类型语义色（圆点 / 标签 / 图表分段，深浅自适应）
    public static let food   = Color.adaptive(light: 0xd98e1f, dark: 0xf2b04a)  // 饮食·暖琥珀
    public static let health = Color.adaptive(light: 0x9b59b6, dark: 0xc187e0)  // 健康·紫
    public static let bill   = Color.adaptive(light: 0x1d9e75, dark: 0x4cc79a)  // 账单·森绿
    public static let todo   = Color.adaptive(light: 0x378add, dark: 0x6fb0f0)  // 待办·科技蓝

    // 收支语义
    public static let income  = Color.adaptive(light: 0x1d9e75, dark: 0x4cc79a)  // 收入·绿
    public static let expense = Color.adaptive(light: 0xe0564b, dark: 0xff6f61)  // 支出·红
    public static let warning = Color.adaptive(light: 0xba7517, dark: 0xe0a23a)  // 预算预警
    public static let over    = Color.adaptive(light: 0x791f1f, dark: 0xc4453f)  // 超支

    // 圆角尺度
    public static let rLG: CGFloat = 18
    public static let rMD: CGFloat = 14
    public static let rSM: CGFloat = 10
    public static let rXS: CGFloat = 8

    // MARK: - 字体令牌
    public enum Font {
        public static let micro     = SwiftUI.Font.system(size: 11)
        public static let caption   = SwiftUI.Font.system(size: 12)
        public static let footnote  = SwiftUI.Font.system(size: 13)
        public static let chatBody  = SwiftUI.Font.system(size: 13.3)
        public static let subhead   = SwiftUI.Font.system(size: 14)
        public static let callout   = SwiftUI.Font.system(size: 15)
        public static let body      = SwiftUI.Font.system(size: 16)
        public static let headline  = SwiftUI.Font.system(size: 17)
        public static let title3    = SwiftUI.Font.system(size: 18)
        public static let title2    = SwiftUI.Font.system(size: 20)
        public static let title1    = SwiftUI.Font.system(size: 22)
        public static let largeTitle = SwiftUI.Font.system(size: 24)
        public static let display   = SwiftUI.Font.system(size: 28)
        public static let hero      = SwiftUI.Font.system(size: 34)
        public static let ultra     = SwiftUI.Font.system(size: 40)
    }

    // 柔和阴影
    public static let cardShadow = Color.black.opacity(0.06)
    public static let cardShadowRadius: CGFloat = 10
    public static let cardShadowY: CGFloat = 3
    public static let cardShadowStrong = Color.black.opacity(0.12)

    // MARK: - 动效令牌
    public static var motionReduce: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
    public enum Motion {
        public static let press    = Animation.spring(response: 0.32, dampingFraction: 0.6)
        // 2026-08-13：ease-out「先快后慢」前 30% 时间跑完 60% 进度 → 视觉急促。
        // 改 spring「前后缓冲」：开始稍缓、中段匀速、末段柔和减速，观感更优雅。
        // spring 无固定时长，响应+阻尼控制节奏；iOS17 用 interpolatingSpring 更稳。
        public static let draw     = Animation.interpolatingSpring(stiffness: 60, damping: 15)
        // 进度条生长动画现由 MiniBar 自行驱动：三处触发(onAppear/onChange(resetToken)/onChange(value))
        // 统一先 displayed=0 落位，再 DispatchQueue.main.asyncAfter(.now()+延迟) 排 withAnimation，
        // 并用 @State pendingGrow(DispatchWorkItem) 防抖（见 MiniBar 14:38:40/14:54:59 标记）。
        // 本弹簧常量保留供 RingView 等其它进度环复用，未改动语义。
        public static let progress = Animation.interpolatingSpring(stiffness: 80, damping: 17)
        public static let progressFade = Animation.easeOut(duration: 0.16)
        // 圆环专属：固定 1.5 秒缓出，比弹簧从容，长弧不被冲量放大。
        public static let ring      = Animation.easeOut(duration: 1.5)
        // 圆环快速补位：手动点击 / 数据刷新导致进度增长时即时反馈，仅 0.25 秒。
        public static let ringFast  = Animation.easeOut(duration: 0.25)
    }
}
