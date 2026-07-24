// UIComponents.swift
// 按《UI完整页面流.html》设计系统抽出的复用组件 + 配色主题。
// 四个记录页（饮食/健康/账单/待办）共用，保证视觉一致。
// 设计系统 v2：统一令牌，浅/深自适应，科技蓝强调 + 毛玻璃卡片 + 细描边 + 柔和投影。
import SwiftUI
import SwiftData
import UIKit
import Combine

// MARK: - 自适应颜色（跟随系统浅/深）
extension UIColor {
    convenience init(hex: UInt64) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8)  & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
    /// 跟随系统：浅色用 light，深色用 dark
    convenience init(light: UInt64, dark: UInt64) {
        self.init { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }
}

extension Color {
    init(hex: UInt64) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
    /// 跟随系统浅/深动态色
    static func adaptive(light: UInt64, dark: UInt64) -> Color {
        Color(UIColor(light: light, dark: dark))
    }
}

// MARK: - 外观模式（浅色 / 深色 / 跟随系统）
/// 持久化键：UserDefaults 的 `aia.appearance`，值为 rawValue（system/light/dark）。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    /// 设置页分段标题
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    /// 系统图标（用于设置项左侧装饰）
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    /// 映射到 SwiftUI ColorScheme；system 返回 nil（即不覆盖，跟随系统）
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// 从持久化字符串解析，非法值兜底为 system
    init(raw: String) {
        self = AppearanceMode(rawValue: raw) ?? .system
    }
}

// MARK: - 设计令牌（统一视觉语言，浅/深自适应）
enum AIATheme {
    // 主强调色（沿用科技蓝）
    static let blue   = Color(hex: 0x378add)
    static let green  = Color(hex: 0x1d9e75)
    static let amber  = Color(hex: 0xe0a23a)
    static let purple = Color(hex: 0x9b59b6)
    static let ink    = Color.adaptive(light: 0x1f2937, dark: 0x2c2c2e)   // 深底（按钮背景，配白字）
    static let warn   = Color.adaptive(light: 0xe0564b, dark: 0xff6f61)
    static let ok     = Color.adaptive(light: 0x3b6d11, dark: 0x7ed957)

    // 语义文字
    static let sub   = Color.adaptive(light: 0x5f5e5a, dark: 0xa1a1a6)
    static let muted = Color.adaptive(light: 0x8a9099, dark: 0x8e8e93)
    static let iconInactive = Color.adaptive(light: 0xc9ced3, dark: 0x5a5a5e)

    // 语义表面（卡片/内层/分隔，自动适配深浅）
    static let surface          = Color.adaptive(light: 0xf7f9fb, dark: 0x1c1c1e)
    static let surfaceSecondary = Color.adaptive(light: 0xf1f3f5, dark: 0x2a2a2c)
    static let hairline         = Color.adaptive(light: 0xe6e9ec, dark: 0x3a3a3c)
    static let fillSoft         = Color.adaptive(light: 0xeef1f4, dark: 0x2c2c2e)
    static let track            = Color.adaptive(light: 0xe3e7ea, dark: 0x363638)

    // 模块底色：与 food/health/bill/todo 语义色同 hue 的淡 tint（深浅自适应），
    // 保证宫格卡片 ↔ 首页时间线圆点 ↔ 各列表标签 三处颜色完全统一，靠色相即可秒认类型。
    static let dietBG   = Color.adaptive(light: 0xfbf0db, dark: 0x2a2416)  // 饮食·琥珀淡底
    static let healthBG = Color.adaptive(light: 0xf3e9f9, dark: 0x241b2c)  // 健康·紫淡底
    static let billBG   = Color.adaptive(light: 0xe3f6ef, dark: 0x15251e)  // 账单·绿淡底
    static let todoBG   = Color.adaptive(light: 0xe7f1fc, dark: 0x16242f)  // 待办·蓝淡底

    // MARK: 类型语义色（圆点 / 标签 / 图表分段，深浅自适应）
    // 蓝色只保留作品牌主操作色；四类记录各配稳定 hue，全局统一使用，靠颜色即可秒认类型。
    static let food   = Color.adaptive(light: 0xd98e1f, dark: 0xf2b04a)  // 饮食·暖琥珀
    static let health = Color.adaptive(light: 0x9b59b6, dark: 0xc187e0)  // 健康·紫
    static let bill   = Color.adaptive(light: 0x1d9e75, dark: 0x4cc79a)  // 账单·森绿
    static let todo   = Color.adaptive(light: 0x378add, dark: 0x6fb0f0)  // 待办·科技蓝

    // 收支语义（个人记账：收入绿 / 支出红；注意股票视图若以后加需反过来用「红涨绿跌」）
    static let income  = Color.adaptive(light: 0x1d9e75, dark: 0x4cc79a)  // 收入·绿
    static let expense = Color.adaptive(light: 0xe0564b, dark: 0xff6f61)  // 支出·红
    // 预算健康度：预警琥珀 → 超支深红
    static let warning = Color.adaptive(light: 0xba7517, dark: 0xe0a23a)  // 预算预警
    static let over    = Color.adaptive(light: 0x791f1f, dark: 0xc4453f)  // 超支

    // 圆角尺度
    static let rLG: CGFloat = 18
    static let rMD: CGFloat = 14
    static let rSM: CGFloat = 10
    static let rXS: CGFloat = 8

    // MARK: - 字体令牌（统一字号阶梯，消除散写 .system(size:)）
    // 命名按角色；尺寸与既有设计像素对齐，并吸附到统一阶梯（9/10pt 提到 11pt，满足最小可读规范）。
    // 权重用 .weight() 叠加，例如 AIATheme.Font.subhead.weight(.medium)。
    enum Font {
        // 注意：enum 名为 Font，内部必须用 SwiftUI.Font 限定，否则 Font 会被解析成此 enum 自身而编译报错。
        static let micro     = SwiftUI.Font.system(size: 11)   // 最小可读：原 9/10pt 统一提到 11pt
        static let caption   = SwiftUI.Font.system(size: 12)
        static let footnote  = SwiftUI.Font.system(size: 13)
        static let subhead   = SwiftUI.Font.system(size: 14)
        static let callout   = SwiftUI.Font.system(size: 15)
        static let body      = SwiftUI.Font.system(size: 16)
        static let headline  = SwiftUI.Font.system(size: 17)
        static let title3    = SwiftUI.Font.system(size: 18)
        static let title2    = SwiftUI.Font.system(size: 20)
        static let title1    = SwiftUI.Font.system(size: 22)
        static let largeTitle = SwiftUI.Font.system(size: 24)
        static let display   = SwiftUI.Font.system(size: 28)
        static let hero      = SwiftUI.Font.system(size: 34)
        static let ultra     = SwiftUI.Font.system(size: 40)
    }

    // 柔和阴影（深色下由 hairline 提供分隔）
    static let cardShadow = Color.black.opacity(0.06)
    static let cardShadowRadius: CGFloat = 10
    static let cardShadowY: CGFloat = 3
    // 按压抬升时的更强阴影
    static let cardShadowStrong = Color.black.opacity(0.12)

    // MARK: - 动效令牌（统一缓动与时长；所有动效须尊重减弱动态效果）
    /// 用户是否开启「减弱动态效果」——动效据此降级为无动画。
    static var motionReduce: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
    enum Motion {
        /// 按压回弹（卡片/按钮）
        static let press    = Animation.spring(response: 0.32, dampingFraction: 0.6)
        /// 描边生长（环形 / 账单 donut）
        static let draw     = Animation.easeOut(duration: 0.8)
        /// 进度条 / 数值增长
        static let progress = Animation.easeOut(duration: 0.6)
    }
}

// MARK: - 统一卡片样式（表面色 + 细描边 + 柔和投影）
struct CardModifier: ViewModifier {
    var radius: CGFloat = AIATheme.rLG
    var bg: Color = AIATheme.surface
    var shadow: Bool = true
    func body(content: Content) -> some View {
        content
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            // ⚠️ 描边 overlay 必须 allowsHitTesting(false)，否则它会盖在内容上方拦截点击
            // （四宫格卡片用 Button 套 .card() 时，描边 overlay 会"吃掉" Button 的点击，导致点了没反应）
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(AIATheme.hairline, lineWidth: 1).allowsHitTesting(false))
            .shadow(color: shadow ? AIATheme.cardShadow : .clear,
                    radius: AIATheme.cardShadowRadius, y: AIATheme.cardShadowY)
    }
}
extension View {
    /// 统一卡片：表面色 + 1px 细描边 + 柔和投影（shadow:false 仅描边，用于列表行）
    func card(radius: CGFloat = AIATheme.rLG, bg: Color = AIATheme.surface, shadow: Bool = true) -> some View {
        modifier(CardModifier(radius: radius, bg: bg, shadow: shadow))
    }
}

// MARK: - 按压反馈样式（卡片/按钮按下时轻微缩放下沉 + 阴影抬升）
/// 用于可点卡片与按钮：按下 scaleEffect(0.97) + 阴影抬升，松手 spring 回弹。
/// 用 ButtonStyle 实现（而非在 .card() 内加手势），可与 Button 点击共存、不吞点击，
/// 且自动遵守「减弱动态效果」。任何 `Button { } label: { ... .card() }` 把
/// `.buttonStyle(.plain)` 换成 `.buttonStyle(PressableCardStyle())` 即可获得按压反馈。
struct PressableCardStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .shadow(
                color: configuration.isPressed ? AIATheme.cardShadowStrong : .clear,
                radius: configuration.isPressed ? AIATheme.cardShadowRadius + 6 : 0,
                y: configuration.isPressed ? AIATheme.cardShadowY + 3 : 0
            )
            .animation(AIATheme.motionReduce ? nil : AIATheme.Motion.press, value: configuration.isPressed)
    }
}

// MARK: - 科技感渐变（强调色 → 青）
extension LinearGradient {
    static let techAccent = LinearGradient(
        colors: [AIATheme.blue, Color(hex: 0x22d3ee)],
        startPoint: .leading, endPoint: .trailing)
}

// MARK: - 分段控件（胶囊，选中白底）
struct SegmentedPicker<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<options.count, id: \.self) { i in
                let opt = options[i]
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(AIATheme.Font.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .background(selection == opt.value ? Color.white : Color.clear)
                .foregroundStyle(selection == opt.value ? AIATheme.ink : AIATheme.sub)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rXS))
                // 禁用背景色变化的隐式动画，避免切换时两个 segment 同时出现白色中间态。
                .animation(nil, value: selection)
            }
        }
        .padding(3)
        .background(AIATheme.fillSoft)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }
}

// MARK: - Pill 标签（普通 / 警告 / 完成）
struct Pill: View {
    let text: String
    var style: Style = .normal
    enum Style { case normal, warn, ok }
    var body: some View {
        Text(text)
            .font(AIATheme.Font.micro)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(Capsule())
    }
    private var bg: Color {
        switch style {
        case .warn: return AIATheme.warn.opacity(0.12)
        case .ok:   return AIATheme.ok.opacity(0.14)
        case .normal: return AIATheme.fillSoft
        }
    }
    private var fg: Color {
        switch style {
        case .warn: return AIATheme.warn
        case .ok:   return AIATheme.ok
        case .normal: return AIATheme.sub
        }
    }
}

// MARK: - 单进度环（步数/睡眠）
struct RingView: View {
    let value: String
    let caption: String
    var progress: Double = 0          // 0..1
    var color: Color = AIATheme.blue
    var size: CGFloat = 84
    var lineWidth: CGFloat = 8
    @State private var drawn: Double = 0   // 描边生长动画的当前进度（0→progress）

    var body: some View {
        ZStack {
            Circle().stroke(AIATheme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(drawn, 0), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(value).font(AIATheme.Font.body.weight(.medium))
                Text(caption).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
            }
        }
        .frame(width: size, height: size)
        .onAppear { animateRing() }
        .onChange(of: progress) { _, _ in animateRing() }
    }

    /// 进入 / 数据刷新时，让进度环从 0 描边生长到目标值；「减弱动态效果」下直接落位。
    private func animateRing() {
        guard !AIATheme.motionReduce else { drawn = progress; return }
        withAnimation(AIATheme.Motion.draw) { drawn = progress }
    }
}

// MARK: - 占比环（账单分类）
struct DonutView: View {
    let segments: [(color: Color, fraction: Double)]
    var size: CGFloat = 96
    var lineWidth: CGFloat = 12
    @State private var t: Double = 0   // 各扇区从起点描边生长的插值系数（0→1）

    private var arcs: [(color: Color, start: Double, end: Double)] {
        let total = segments.reduce(0) { $0 + max($1.fraction, 0) }
        guard total > 0 else { return [] }
        var acc = 0.0
        return segments.map { seg in
            let f = max(seg.fraction, 0) / total
            let s = acc
            acc += f
            return (seg.color, s, acc)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(AIATheme.track, lineWidth: lineWidth)
            ForEach(0..<arcs.count, id: \.self) { i in
                let arc = arcs[i]
                Circle()
                    .trim(from: arc.start, to: arc.start + (arc.end - arc.start) * t)
                    .stroke(arc.color, lineWidth: lineWidth)
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .onAppear { animateDonut() }
    }

    /// 进入时各扇区按占比从起点描边生长；「减弱动态效果」下直接落位。
    private func animateDonut() {
        guard !AIATheme.motionReduce else { t = 1; return }
        t = 0
        withAnimation(AIATheme.Motion.draw) { t = 1 }
    }
}

// MARK: - 营养宏量卡（蛋白/碳水/脂肪/纤维）
struct MacroCard: View {
    let title: String
    let value: String
    var progress: Double = 0
    var color: Color = AIATheme.blue
    @State private var drawn: Double = 0   // 进度条生长动画的当前进度（0→progress）

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(AIATheme.Font.subhead.weight(.medium))
            Text(title).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
            GeometryReader { geo in
                Capsule().fill(AIATheme.track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: geo.size.width * CGFloat(min(max(drawn, 0), 1)), height: 4)
                    }
            }
            .frame(height: 4)
        }
        .padding(10)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .onAppear { animateMacro() }
        .onChange(of: progress) { _, _ in animateMacro() }
    }

    /// 进入 / 数据刷新时，进度条从左到右生长；「减弱动态效果」下直接落位。
    private func animateMacro() {
        guard !AIATheme.motionReduce else { drawn = progress; return }
        withAnimation(AIATheme.Motion.progress) { drawn = progress }
    }
}

// MARK: - 迷你进度条（摄入/目标、预算）
struct MiniBar: View {
    var value: Double = 0           // 0..1
    var color: Color = AIATheme.green
    var height: CGFloat = 8
    @State private var drawn: Double = 0   // 进度条生长动画的当前进度（0→value）

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: height / 2).fill(AIATheme.fillSoft)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: height / 2).fill(color)
                        .frame(width: geo.size.width * CGFloat(min(max(drawn, 0), 1)), height: height)
                }
        }
        .frame(height: height)
        .onAppear { animateMini() }
        .onChange(of: value) { _, _ in animateMini() }
    }

    /// 进入 / 数据刷新时，进度条从左到右生长；「减弱动态效果」下直接落位。
    private func animateMini() {
        guard !AIATheme.motionReduce else { drawn = value; return }
        withAnimation(AIATheme.Motion.progress) { drawn = value }
    }
}

// MARK: - 统计卡（体重/身高/心率/BMI）
struct StatCard: View {
    let value: String
    let caption: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(AIATheme.Font.body.weight(.medium))
            Text(caption).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(AIATheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }
}

// MARK: - 卡片行（睡眠分期等）
struct CardRow: View {
    let icon: String
    let iconBG: Color
    let title: String
    let subtitle: String
    let value: String
    var body: some View {
        HStack(spacing: 12) {
            Text(icon).font(AIATheme.Font.callout)
                .frame(width: 34, height: 34)
                .background(iconBG)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AIATheme.Font.footnote.weight(.medium))
                Text(subtitle).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
            }
            Spacer()
            Text(value).font(AIATheme.Font.footnote.weight(.medium))
        }
        .padding(11)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
    }
}

// MARK: - 小节标题
struct SectionTitle: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text).font(AIATheme.Font.caption.weight(.medium)).foregroundStyle(AIATheme.muted)
            Spacer()
            if let t = trailing { Text(t).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted) }
        }
        .padding(.top, 6)
    }
}

// MARK: - 相机/相册 → 云端识别 → 结果确认页 的复用流程
// AIBottomBar 与首页快捷操作「拍照记录」共用，避免重复实现识别链路。
enum CameraCoverItem: Identifiable {
    case recognizing(UIImage)
    case present(RecognitionPresent)
    var id: String {
        switch self {
        case .recognizing(let img):
            // 用图片 hash 唯一化 id，避免连续两次 fullScreenCover 冲突
            return "recognizing-\(img.hashValue)"
        case .present(let p): return "present-\(p.id)"
        }
    }
}

extension View {
    /// 挂载「相机/相册拍照 → 云端识别 → 结果确认页」完整流程。
    /// - Parameters:
    ///   - showCamera: 调用方控制拉起相机（如点按钮、快捷操作）。
    ///   - showPicker: 调用方控制拉起相册（如相机不可用时「改用相册」）。
    func cameraRecognitionFlow(showCamera: Binding<Bool>, showPicker: Binding<Bool>) -> some View {
        modifier(CameraRecognitionFlowModifier(showCamera: showCamera, showPicker: showPicker))
    }
}

struct CameraRecognitionFlowModifier: ViewModifier {
    @Binding var showCamera: Bool
    @Binding var showPicker: Bool
    @Environment(\.modelContext) private var context

    @State private var pickedImage: UIImage?
    @State private var coverItem: CameraCoverItem?
    @State private var errorMessage: String?
    @State private var cameraUnavailable = false

    func body(content: Content) -> some View {
        content
            // 相机不可用时（模拟器等）不直接开 CameraView，转「相机不可用」提示并可改用相册
            .onChange(of: showCamera) { _, new in
                if new && !UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = false
                    cameraUnavailable = true
                }
            }
            .fullScreenCover(isPresented: $showCamera) { CameraView(image: $pickedImage) }
            .sheet(isPresented: $showPicker) { ImagePicker(image: $pickedImage) }
            .onChange(of: pickedImage) { _, new in
                if let img = new {
                    runRecognize(img)
                    pickedImage = nil
                }
            }
            .fullScreenCover(item: $coverItem) { item in
                switch item {
                case .recognizing(let img):
                    RecognizingOverlay(image: img, onBack: { coverItem = nil })
                case .present(let p):
                    makeResultConfirmView(p)
                        .environment(\.modelContext, context)
                }
            }
            .alert("提示", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .alert("相机不可用", isPresented: $cameraUnavailable) {
                Button("改用相册") { showPicker = true }
                Button("好", role: .cancel) {}
            } message: {
                Text("当前设备没有摄像头（模拟器无法拍照），可改用相册选图；真机运行即可直接拍照。")
            }
    }

    private func runRecognize(_ img: UIImage) {
        runImageRecognition(image: img, context: context, coverItem: $coverItem, errorMessage: $errorMessage)
    }
}

/// 识别中浮层：背景展示用户提交的照片（模糊化），中央显示双行提示 + spinner，底部「返回」按钮。
struct RecognizingOverlay: View {
    let image: UIImage
    let onBack: () -> Void

    var body: some View {
        ZStack {
            // 背景：用户照片撑满 + 模糊
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: 25)
                .ignoresSafeArea()

            // 半透明白色遮罩，让文字可读
            Color.white.opacity(0.45)
                .ignoresSafeArea()

            // 中央：spinner + 双行文字
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AIATheme.food)
                VStack(spacing: 4) {
                    Text("阿宝AI正在识别中")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    Text("账单、食物、通知都能识别哦")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            // 底部：返回按钮
            VStack {
                Spacer()
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(AIATheme.Font.footnote.weight(.semibold))
                        Text("返回")
                            .font(AIATheme.Font.subhead.weight(.medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .padding(.bottom, 24)
            }
        }
    }
}

/// 公共识别入口：任意视图拿到 UIImage 后调用，统一走「识别中 → 结果确认页」流程。
func runImageRecognition(image: UIImage,
                         context: ModelContext,
                         coverItem: Binding<CameraCoverItem?>,
                         errorMessage: Binding<String?>) {
    coverItem.wrappedValue = .recognizing(image)
    Task {
        do {
            let output = try await RecognizeService.recognizeWithLocalPriority(image: image, in: context)
            // 用户已点返回关闭 cover：丢弃结果，避免覆盖已关闭状态
            guard coverItem.wrappedValue != nil else { return }
            let res = output.result
            let rawText = output.rawText
            await MainActor.run {
                let present = RecognitionSaver.preparePresent(result: res, rawText: rawText, image: image, context: context, source: output.source)
                coverItem.wrappedValue = .present(present)
            }
        } catch let decoding as DecodingError {
            await MainActor.run {
                errorMessage.wrappedValue = "云端返回格式不对：\(decoding.localizedDescription)"
                coverItem.wrappedValue = nil
            }
        } catch {
            await MainActor.run {
                errorMessage.wrappedValue = "识别失败：\(error.localizedDescription)"
                coverItem.wrappedValue = nil
            }
        }
    }
}

// MARK: - 全局底部 AI 栏
// 相机/相册调用云端识别，文字/麦克风进入对话页；识别态与结果页自封在组件内。
// 注意：底部栏的「问问 AI / 麦克风」按钮走 NavigationRouter.shared.path 编程式跳转，
// 不能再用 NavigationLink(destination:) 闭包式——它位于首页 NavigationStack(path:) 根层，
// 老式 NavigationLink 与 .navigationDestination(for:) 混用会导致 path 推送的目的地不触发（白跳）。
// MARK: - 底部栏图标与提示文案的「单一布局真源」
// 改图标左右顺序时，只改 `iconOrder` 这一处，箭头方向会自动跟随，无需手动改文案。
enum AIBarTarget: Equatable { case mic, camera, album }

/// 一条底部栏提示：正文 + 指向哪个按钮（用于自动推导箭头方向）。
struct AIPrompt: Equatable {
    let text: String            // 不含箭头的正文
    let pointsTo: AIBarTarget?  // 指向哪个按钮；nil 表示不指向任何按钮（无箭头）
}

struct AIBottomBar: View {
    let prompts: [AIPrompt]
    @State private var promptIndex = 0
    @State private var rolling = false
    @State private var showCamera = false
    @State private var showPicker = false
    /// 共享导航栈：统一走 path 编程式导航（与首页四宫格一致），任何层级的底部栏都推到同一主栈。
    private let router = NavigationRouter.shared
    private let rowH: CGFloat = 21

    /// 底部栏图标从左到右的顺序，必须与 HStack 内 Button 顺序一致。
    /// nil 代表中间的输入框胶囊。改图标位置只改这里，箭头自动跟着变。
    private static let iconOrder: [AIBarTarget?] = [.mic, nil, .camera, .album]

    /// 根据图标位置推导箭头：目标在输入框左侧 → ←，在右侧 → →。无指向返回空串。
    private func arrowPrefix(_ target: AIBarTarget?) -> String? {
        guard let target = target,
              let textIdx = Self.iconOrder.firstIndex(where: { $0 == nil }),
              let targetIdx = Self.iconOrder.firstIndex(of: target) else { return nil }
        return targetIdx < textIdx ? "←" : "→"
    }

    /// 组合出带箭头的显示文案：指向左侧时箭头在前，指向右侧时箭头在后。
    private func displayText(_ prompt: AIPrompt) -> String {
        guard let arrow = arrowPrefix(prompt.pointsTo) else { return prompt.text }
        return arrow == "←" ? arrow + prompt.text : prompt.text + arrow
    }

    init(prompts: [AIPrompt]? = nil) {
        self.prompts = prompts ?? [
            AIPrompt(text: "问问阿宝AI", pointsTo: nil),
            AIPrompt(text: "点拍照能自动识别哦", pointsTo: .camera),
            AIPrompt(text: "叫阿宝AI帮记", pointsTo: nil),
            AIPrompt(text: "点麦克风可语音输入哦", pointsTo: .mic),
            AIPrompt(text: "叫阿宝AI帮总结", pointsTo: nil),
            AIPrompt(text: "点相册可上传、识别哦", pointsTo: .album)
        ]
    }

    var body: some View {
        // 悬浮胶囊：一个整体 Capsule 承载所有控件，替代原来 4 个独立按钮分散布局。
        // 玻璃材质 + 柔阴影 + 左右 12pt 边距 → 真正"浮动"，不再贴满屏幕宽。
        HStack(spacing: 4) {
            // 语音按钮（不再有独立圆背景，图标直接浮在胶囊玻璃底色上）
            Button { router.path.append(.chatVoice) } label: {
                Image(systemName: "mic.fill")
                    .font(AIATheme.Font.title3.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)

            // 中间滚动文案区（浅灰填充的小胶囊，与外部大胶囊形成双层视觉层次）
            Button { router.path.append(.chat) } label: {
                HStack {
                    Spacer()
                    ZStack(alignment: .center) {
                        Text(displayText(prompts[promptIndex]))
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(AIATheme.muted)
                            .lineLimit(1)
                            .offset(y: rolling ? -rowH : 0)
                        Text(displayText(prompts[(promptIndex + 1) % max(prompts.count, 1)]))
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(AIATheme.muted)
                            .lineLimit(1)
                            .offset(y: rolling ? 0 : rowH)
                    }
                    .frame(height: rowH)
                    .clipped()
                    Spacer()
                }
                .frame(height: 42)
                .background(AIATheme.fillSoft)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // 拍照按钮
            Button { showCamera = true } label: {
                Image(systemName: "camera")
                    .font(AIATheme.Font.title3.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)

            // 相册按钮
            Button { showPicker = true } label: {
                Image(systemName: "photo")
                    .font(AIATheme.Font.title3.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        // 玻璃胶囊 + 柔阴影 → 真正"悬浮"（不再贴边、不再有顶部分割线）
        .background(
            Capsule()
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .overlay(
            Capsule()
                .stroke(Color(.separator), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        // 左右 20pt 边距 → 与首页「今日事项预览」气泡同宽，整页对齐
        .padding(.horizontal, 20).padding(.bottom, 10)
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker)
        .task {
            guard prompts.count > 1 else { return }
            var idx = promptIndex
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                idx = (idx + 1) % prompts.count
                // 当前文案向上滚出，下一条从下方滚入
                withAnimation(.easeInOut(duration: 0.5)) {
                    rolling = true
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                // 动画结束后静默切换 index 并复位，准备下一轮
                withAnimation(nil) {
                    promptIndex = idx
                    rolling = false
                }
            }
        }
    }
}

// MARK: - AI 摘要文案（首页与对话页共用，保证一致）
// 顺序固定为：饮食 / 健康 / 账单 / 待办，每条一格，缺数据时给兜底文案。
enum AISummary {
    /// 各模块候选内容（用于首页四条气泡内部各自轮播）。每条返回 ≥1 条字符串。
    static func dietMessages(foods: [FoodEntry]) -> [String] {
        let todayFoods = foods.filter { Calendar.current.isDateInToday($0.date) }
        if todayFoods.isEmpty {
            return ["饮食记录 · 今天还没记录，点底部相机拍张餐食吧"]
        }
        let sorted = todayFoods.sorted(by: { $0.date > $1.date })
        return sorted.map { "饮食记录 · \($0.meal)：\($0.name) · \(Int($0.calories)) kcal" }
    }

    static func healthMessages(health: HealthManager, healths: [HealthMetric]) -> [String] {
        let stat = { (key: String) -> String in
            healths.first(where: { $0.metric.contains(key) }).map { "\($0.value)\($0.unit)" } ?? "—"
        }
        return [
            "健康管理 · 今日步数 \(health.stepsToday)，距目标还差 \(max(0, 10000 - health.stepsToday))",
            "健康管理 · 运动时长 \(Int(health.exerciseTimeToday)) min",
            "健康管理 · 能量消耗 \(stat("静息能量"))",
            "健康管理 · 静息心率 \(stat("静息心率"))"
        ]
    }

    static func billMessages(bills: [Bill]) -> [String] {
        let todayBills = bills.filter { Calendar.current.isDateInToday($0.time) }
        let todayTotal = todayBills.reduce(0) { $0 + $1.amount }
        var list = ["账单管理 · 今日支出 ¥\(Int(todayTotal))，共 \(todayBills.count) 笔"]
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let monthExpense = bills.filter { $0.time >= monthStart && !$0.isIncome }.reduce(0) { $0 + $1.amount }
        list.append("账单管理 · 本月支出 ¥\(Int(monthExpense))")
        return list
    }

    static func todoMessages(reminders: [Reminder]) -> [String] {
        let now = Date()
        let upcoming = reminders
            .filter { $0.due != nil && !$0.done && $0.due! >= now }
            .sorted { ($0.due ?? now) < ($1.due ?? now) }
            .prefix(5)
        if upcoming.isEmpty {
            return ["待办事项 · 今天待办已全搞定，真不错 👍"]
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let cal = Calendar.current
        return upcoming.map { r in
            let timeText: String
            if let due = r.due {
                if cal.isDateInToday(due) {
                    timeText = "今天 \(f.string(from: due))"
                } else if cal.isDateInTomorrow(due) {
                    timeText = "明天 \(f.string(from: due))"
                } else {
                    let md = DateFormatter(); md.dateFormat = "M/d"
                    timeText = "\(md.string(from: due)) \(f.string(from: due))"
                }
            } else {
                timeText = ""
            }
            return "待办事项 · 「\(r.title)」\(timeText) 到期"
        }
    }

    /// 兼容旧调用：返回每个模块的第一条（与首页单条气泡时代一致）。
    static func messages(foods: [FoodEntry], bills: [Bill], reminders: [Reminder], healths: [HealthMetric], health: HealthManager) -> [String] {
        return [
            dietMessages(foods: foods).first ?? "",
            healthMessages(health: health, healths: healths).first ?? "",
            billMessages(bills: bills).first ?? "",
            todoMessages(reminders: reminders).first ?? ""
        ]
    }
}
