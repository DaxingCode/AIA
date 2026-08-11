// UIComponents.swift
// 按《UI完整页面流.html》设计系统抽出的复用组件 + 配色主题。
// 四个记录页（饮食/健康/账单/待办）共用，保证视觉一致。
// 设计系统 v2：统一令牌，浅/深自适应，科技蓝强调 + 毛玻璃卡片 + 细描边 + 柔和投影。
import SwiftUI
import SwiftData
import UIKit
import Combine

/// 把进度值（可能为 NaN/Infinity/负数，例如除零 0/0、退款导致负数占比）钳成 [0,1] 的安全 CGFloat。
/// 注意：Swift 的 min/max 对 NaN 会**原样返回 NaN**；负数会直接变成负宽度。
/// 两者进 `.frame(width:)` 都会触发 "Invalid frame dimension (negative or non-finite)" 运行时崩溃。
/// 一切进度环 / 进度条 / 占比条的 width 都走这里，确保任何非有限值或负值都回退为 0。
func safeFraction(_ v: Double) -> CGFloat {
    guard v.isFinite else { return 0 }
    return CGFloat(min(max(v, 0), 1))
}

/// 为 Swift Charts 生成安全的 Y 轴域，避免数据点全相等 / 全为 0 时内部比例除零，
/// 触发 "Invalid frame dimension (negative or non-finite)" 运行时告警。
func safeYDomain(_ values: [Double], fallback: ClosedRange<Double> = 0...100) -> ClosedRange<Double> {
    let finite = values.filter { $0.isFinite }
    guard let maxV = finite.max(), let minV = finite.min() else { return fallback }
    if maxV == minV {
        let pad = max(1, abs(maxV) * 0.05)
        return (minV - pad)...(maxV + pad)
    }
    let pad = (maxV - minV) * 0.12
    return (minV - pad)...(maxV + pad)
}

// MARK: - 设计令牌层（AIATheme / AppearanceMode / Color 扩展）已抽入 AIAKit
// 主 App 通过 `import AIAKit` 获得同名类型，调用点无需改动。

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
                // 页签之间竖向分隔：用 AIATheme.iconInactive（不是 hairline）——
                // hairline light 0xe6e9ec vs 容器 fillSoft 0xeef1f4 色差仅 ~6 级，
                // 浅色模式几乎不可见；iconInactive light 0xc9ced3 色差 ~38 级清晰可见。
                // 深色模式两侧都有足够对比（iconInactive 0x5a5a5e vs fillSoft 0x2c2c2e ≈ 46 级）。
                if i > 0 {
                    // 显式 frame(width: 0.7, height: 18) 控高约 60% 容器高，HStack 默认垂直居中。
                    // 不能用 padding(.vertical, ...) —— Rectangle 在 HStack 里默认被纵向拉满，
                    // padding 只缩内部、外部仍贴顶贴底。
                    Rectangle()
                        .fill(AIATheme.iconInactive)
                        .frame(width: 0.7, height: 18)
                }
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(AIATheme.Font.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .background(selection == opt.value ? Color.white : Color.clear)
                // 选中文字用 AIATheme.ink（白底上近黑可读，符合 iOS 标准分段控件）；
                // 未选中用 AIATheme.sub（深浅自适应中性灰）。
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

// MARK: - Pro 皇冠徽章（会员头像右上角探出）
/// 在头像右上角叠加一枚金黄渐变皇冠，呼应小红书/微博/Twitter 的认证徽章位置。
/// 仅用于「用户本人」头像（首页 / 设置页 / 我的账号页），不用于对话页 agent 头像。
struct ProAvatarBadge: View {
    /// 徽章直径，按头像尺寸等比取（72 头像→24，56→20，36→14）。
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(red: 1.00, green: 0.82, blue: 0.32),
                             Color(red: 0.99, green: 0.66, blue: 0.18)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: diameter, height: diameter)
            Image(systemName: "crown.fill")
                .font(.system(size: diameter * 0.55, weight: .bold))
                .foregroundStyle(.white)
        }
        .overlay(Circle().strokeBorder(Color.white, lineWidth: max(1.5, diameter * 0.06)))
        .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
        .accessibilityLabel("Pro 会员")
    }
}

extension View {
    /// 条件叠加 Pro 皇冠徽章。皇冠斜戴在圆环右上角，底部贴着圆环外缘，不拦截点击。
    @ViewBuilder
    func proAvatarBadge(isPro: Bool, badgeDiameter: CGFloat) -> some View {
        if isPro {
            self.overlay(alignment: .topTrailing) {
                GeometryReader { gp in
                    let size = gp.size
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = min(size.width, size.height) / 2
                    // 1 点钟方向：从 12 点（-90°）顺时针 30° = -60°
                    let angle = -60.0 * .pi / 180
                    // 徽章中心沿外缘放置，使其底部（旋转后）贴着圆环外环
                    let dist = radius + badgeDiameter * 0.3
                    let x = center.x + dist * cos(angle)
                    let y = center.y + dist * sin(angle)
                    ProAvatarBadge(diameter: badgeDiameter)
                        .rotationEffect(.degrees(45), anchor: .bottom)
                        .position(x: x, y: y)
                }
                .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}

// MARK: - 单进度环（步数/睡眠）
struct RingView: View {
    let value: String
    let caption: String
    var secondary: String? = nil      // 可选副数值（如「目标 1730」）
    var progress: Double = 0          // 0..1
    var color: Color = AIATheme.blue
    var size: CGFloat = 84
    var lineWidth: CGFloat = 8
    @State private var drawn: Double = 0   // 描边生长动画的当前进度（0→progress）

    var body: some View {
        ZStack {
            Circle().stroke(AIATheme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: safeFraction(drawn))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                // 2026-07-30：圆环内文字在窄直径（74px）下，"目标 10000" 这类长串会被推到第二行。
                // 统一单行 + 自动缩字号兜底：保证圆环内数字/副行一行显示，绝不换行。
                Text(value)
                    .font(AIATheme.Font.body.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let secondary {
                    Text(secondary)
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.sub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(caption)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
    /// 建议摄入量文本（如 "25g" / "2000mg"），传 nil 则不显示后缀。
    /// 渲染为 "0g / 25g"——主数值保持 subhead 大字，建议量跟随后用 muted 微缩以弱化次要信息。
    var targetText: String? = nil
    var progress: Double = 0
    var color: Color = AIATheme.blue
    @State private var drawn: Double = 0   // 进度条生长动画的当前进度（0→progress）

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(AIATheme.Font.subhead.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .center)
            // 标题 + 建议量同行（还原紧凑布局）。3 列窄格下 4 字标题"膳食纤维"+"建议 27g"容易溢出，
            // 故字号从 micro(11pt) 调小到 10pt、字间距收窄到 3，并加 minimumScaleFactor 兜底，
            // 让"膳食纤维"能完整显示而非截断成"膳食…"。
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let target = targetText {
                    Text("建议\(target)")
                        .font(.system(size: 10))
                        .foregroundStyle(AIATheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            GeometryReader { geo in
                Capsule().fill(AIATheme.track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: geo.size.width * safeFraction(drawn), height: 4)
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
    /// 2026-07-30 动画触发令牌（方案 C）：统一覆盖「返回首页 + 热启动（后台回前台）」两种场景。
    /// 外部每次进入首页 / App 回前台递增此值，MiniBar 监听后走 replayMini()：
    /// 先让填充淡出（宽度保持 value 不变 → 只觉颜色褪去、不觉得变短），
    /// 由动画 completion 回调在淡出结束后归零并淡入生长——无 Task.sleep 竞态，
    /// 快速连续触发只让最新一代（replayGen）落位。
    /// 其他场景（饮食记录/账单分类等普通页面）不传，保持默认 0，行为不变。
    var resetToken: Int = 0
    @State private var drawn: Double = 0   // 进度条生长动画的当前进度（0→value）
    @State private var fillOpacity: Double = 1   // 重播路径：先让颜色褪去（宽度不变）
    @State private var replayGen: Int = 0        // 重播世代：快速连续触发只让最新一代落位

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: height / 2).fill(AIATheme.fillSoft)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: height / 2).fill(color)
                        .frame(width: geo.size.width * safeFraction(drawn), height: height)
                        .opacity(fillOpacity)
                }
        }
        .frame(height: height)
        .onAppear {
            // 2026-07-30 修复：首页宫格卡片有入场动画（animateTiles 延迟 16ms 才淡入），
            // .onAppear 在卡片仍隐藏(opacity=0)时即触发，生长动画在幕后跑完，用户只见终点。
            // 延迟 ~50ms 等卡片可见后再生长，确保「从左到右变长」动画可见。
            Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                animateMini()
            }
        }
        .onChange(of: value) { _, _ in animateMini() }
        .onChange(of: resetToken) { _, _ in replayMini() }   // 单令牌覆盖：返回首页 + 热启动
    }

    /// 2026-07-30（方案 C）：统一重播路径，覆盖「返回首页」与「热启动」两种场景。
    /// 先让填充淡出（宽度保持 value 不变，只觉颜色褪去、不觉得变短），由动画 completion
    /// 回调在淡出结束后归零并淡入生长——精确零竞态，无需 Task.sleep 去猜动画时长。
    /// 「减弱动态效果」下退化为即时落位。
    private func replayMini() {
        let gen = replayGen + 1
        replayGen = gen
        guard !AIATheme.motionReduce else {
            drawn = 0
            withAnimation(AIATheme.Motion.progressFade) { fillOpacity = 1 }
            animateMini()
            return
        }
        withAnimation(AIATheme.Motion.progressFade) { fillOpacity = 0 } completion: {
            guard replayGen == gen else { return }   // 已被更新的重播取代，跳过
            drawn = 0
            withAnimation(AIATheme.Motion.progressFade) { fillOpacity = 1 }
            animateMini()
        }
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
            // 2026-07-30：身高 / 体重这类数字在 4 列窄卡片里"165.0cm"会被推到第二行只留个"m"。
            // 单行 + 自动缩字号兜底：保证数字一行内显示，宁可变小也不换行。
            Text(value)
                .font(AIATheme.Font.body.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
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
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let img = systemImage {
                Image(systemName: img).foregroundStyle(AIATheme.health)
            }
            Text(text).font(AIATheme.Font.caption.weight(.medium)).foregroundStyle(AIATheme.muted)
            Spacer()
            if let t = trailing { Text(t).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted) }
        }
        .padding(.top, 6)
    }
}

// MARK: - 相机/相册 → 云端识别 → 对话气泡 的复用流程
// AIBottomBar 与首页快捷操作「拍照记录」共用，避免重复实现识别链路。
//
// **v2 改造（2026-08-02）**：删掉了"识别中"全屏 cover（CameraCoverItem.recognizing + RecognizingOverlay）。
// 原因：用户已经能看到自己发的图，识别中全屏浮层是多余的——而且会"盖住"对话页，反而看不清好好记。
// 现在识别中直接展示对话页面，发图消息会先出现、识别卡片随后跟上，全屏遮罩一律不再用。

extension View {
    /// 挂载「相机/相册拍照 → 云端识别 → 结果确认页」完整流程。
    /// - Parameters:
    ///   - showCamera: 调用方控制拉起相机（如点按钮、快捷操作）。
    ///   - showPicker: 调用方控制拉起相册（如相机不可用时「改用相册」）。
    ///   - navigateToChat: 识别结束后是否跳到对话页看好好记回复（非对话页入口应传 true）。
    func cameraRecognitionFlow(showCamera: Binding<Bool>, showPicker: Binding<Bool>,
                               navigateToChat: Bool = false) -> some View {
        modifier(CameraRecognitionFlowModifier(showCamera: showCamera, showPicker: showPicker,
                                               navigateToChat: navigateToChat))
    }
}

struct CameraRecognitionFlowModifier: ViewModifier {
    @Binding var showCamera: Bool
    @Binding var showPicker: Bool
    /// true = 识别完自动跳对话页（首页底部栏等非对话页入口）；false = 留在原页（对话页自身）
    var navigateToChat: Bool = false
    @Environment(\.modelContext) private var context

    @State private var pickedImage: UIImage?
    @State private var errorMessage: String?
    @State private var cameraUnavailable = false

    func body(content: Content) -> some View {
        content
            // 相机不可用时（模拟器等）不直接开系统相机，转「相机不可用」提示并可改用相册；
            // 可用时直接调 CameraPresenter 弹独立黑窗（不经 fullScreenCover，无白屏过渡），
            // 并立即把 showCamera 复位，保证下次点按仍能触发 onChange。
            .onChange(of: showCamera) { _, new in
                guard new else { return }
                showCamera = false
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    cameraUnavailable = true
                    return
                }
                CameraPresenter.shared.present { img in
                    if let img { runRecognize(img) }
                }
            }
            .sheet(isPresented: $showPicker) { ImagePicker(image: $pickedImage) }
            .onChange(of: pickedImage) { _, new in
                if let img = new {
                    runRecognize(img)
                    pickedImage = nil
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
        // 拍照/选图完成这一瞬间立即跳对话页（先看到「你发的图」+「好好记正在识别…」加载条），
        // 不再等云端识别完成。已在对话页时（navigateToChat=false）不重复跳。
        // runImageRecognition.finish 里仍保留兜底跳转（path.last != r 幂等守卫，不会双跳）。
        if navigateToChat {
            // 招呼气泡定位锚点：必须打在「插入本次第一条新消息」之前
            // （runImageRecognition 内会同步 appendUserImageMessage 插图），
            // 否则 ChatView 会把这张新图算成历史，招呼气泡排到图片后面。
            NavigationRouter.shared.beginChatSession()
            NavigationRouter.shared.navigateToChat()
        }
        runImageRecognition(image: img, context: context,
                            errorMessage: $errorMessage, navigateToChat: navigateToChat)
    }
}

/// 跨视图共享：图片识别进行中信号。
/// runImageRecognition 开始/结束置位；ChatView 输入栏上方的加载提示据此显示「好好记正在识别...」。
/// 用单例而非 @State 绑定，避免用户中途退出对话页导致绑定失效/崩溃。
/// 普通 ObservableObject（非 @MainActor）：其置位/复位调用点均为主线程（UI 事件 / MainActor.run 内），
/// 不引入跨 actor 隔离约束，避免 runImageRecognition（非隔离自由函数）编译报错。
final class RecognitionActivity: ObservableObject {
    static let shared = RecognitionActivity()
    @Published var isRecognizing = false
}

/// 公共识别入口：任意视图拿到 UIImage 后调用，统一走「像微信一样发给好好记」的流程——
/// 先把用户这张图作为一条用户消息插进对话流，识别完成后好好记在同一条对话里回结果卡片。
/// 结果按「识别自动处理」设置分流（自动保存 / 待确认 / 丢弃），全程不再弹全屏确认页。
/// - Parameter navigateToChat: 识别结束后是否跳到对话页看好好记回复。
///   非对话页入口（首页底部栏、四宫格快捷操作等）必须传 true，否则用户留在原页看不到回复；
///   ChatView 自身的拍照/相册/文件入口传 false，避免在对话页上再压一层对话页。
func runImageRecognition(image: UIImage,
                         context: ModelContext,
                         errorMessage: Binding<String?>,
                         navigateToChat: Bool = false) {
    // 先发图：像微信一样，对话流里先出现「你发的这张图」，好好记随后回识别卡片。
    // 返回的文件名同时给识别结果复用，同一张原图不必落盘两次。
    // 所有调用点都来自 UI 事件（主线程），assumeIsolated 成立。
    // 2026-08-02：删掉了原「识别中」全屏 cover（`coverItem` 参数已移除），识别中直接展示对话页。
    let presavedName = MainActor.assumeIsolated {
        appendUserImageMessage(image: image, context: context)
    }
    // 图片已 insert 进对话流，但 ChatView 的消息列表是手动 fetch 的 @State（非 @Query，非响应式），
    // 不会因 insert 自动刷新。这里主动广播滚动信号，让「你发的图」立刻显示并贴底，
    // 而不是憋到识别完成时 processRecognition 的 save/广播才和识别结果卡一起冒出来。
    NotificationCenter.default.post(name: Notification.Name("AIA.chatScrollToBottom"), object: nil)

    /// 识别进行中：点亮对话页输入栏上方的「好好记正在识别...」加载提示。
    RecognitionActivity.shared.isRecognizing = true

    /// 好好记的收尾回复 + 可选跳转。用户已经「发了图」，任何分支都必须有回应，否则像石沉大海。
    @MainActor func finish(reply: String?) {
        if let reply { context.insert(ChatMessage(role: .ai, text: reply)) }
        if navigateToChat { NavigationRouter.shared.navigateToChat() }
        RecognitionActivity.shared.isRecognizing = false
        // 识别收尾插入的消息（付费墙/失败等任何分支）需要让对话页手动 fetch 的消息列表刷新；
        // ChatView 的 messages 是非响应式 @State，不主动广播就要退出重进对话页才看得到。
        NotificationCenter.default.post(name: Notification.Name("AIA.chatScrollToBottom"), object: nil)
    }

    Task {
        do {
            let output = try await RecognizeService.recognizeWithLocalPriority(image: image, in: context)
            let res = output.result
            let rawText = output.rawText
            let outcome = await Task { @MainActor in
                await RecognitionSaver.processRecognition(result: res, rawText: rawText, image: image,
                                                          context: context, source: output.source,
                                                          entryOrigin: "image",
                                                          presavedImageName: presavedName)
            }.value
            await MainActor.run {
                switch outcome {
                case .inserted:
                    try? context.save()
                    finish(reply: nil)
                case .nothing:
                    // 按设置丢弃或未识别到内容
                    finish(reply: "这张图我没识别到可记录的内容～可以在「设置 → 识别结果保存方式设置」里调整保存策略。")
                }
            }
        } catch let decoding as DecodingError {
            await MainActor.run {
                errorMessage.wrappedValue = "云端返回格式不对：\(decoding.localizedDescription)"
                finish(reply: "这张图识别失败了：云端返回格式不对，稍后再试试～")
            }
        } catch {
            await MainActor.run {
                if error is AIAEntitlementError {
                    // 付费墙拦截（免费版无云端视觉）：只给一条带升级 Pro 入口的引导气泡，
                    // 不弹系统 Alert（否则会露出 entitlement_denied:xxx 生硬错误码，体验差）。
                    finish(reply: UPGRADE_PRO_PREFIX + "这张图用本地AI识别失败了，如果你想体验更好，可升级 Pro版会员后，使用云端大模型AI进行识别。")
                } else {
                    errorMessage.wrappedValue = "识别失败：\(error.localizedDescription)"
                    finish(reply: "这张图识别失败了：\(error.localizedDescription)")
                }
            }
        }
        await MainActor.run {
            RecognitionActivity.shared.isRecognizing = false
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
    let entrySource: String   // "food" / "health" / "bill" / "todo" / "home"
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

    init(prompts: [AIPrompt]? = nil, entrySource: String = "home") {
        self.prompts = prompts ?? [
            AIPrompt(text: "问问小记", pointsTo: nil),
            AIPrompt(text: "点拍照能自动识别哦", pointsTo: .camera),
            AIPrompt(text: "叫小记帮记", pointsTo: nil),
            AIPrompt(text: "点麦克风可语音输入哦", pointsTo: .mic),
            AIPrompt(text: "叫小记帮总结", pointsTo: nil),
            AIPrompt(text: "点相册可上传、识别哦", pointsTo: .album)
        ]
        self.entrySource = entrySource
    }

    var body: some View {
        // 悬浮胶囊：一个整体 Capsule 承载所有控件，替代原来 4 个独立按钮分散布局。
        // 玻璃材质 + 柔阴影 + 左右 12pt 边距 → 真正"浮动"，不再贴满屏幕宽。
        HStack(spacing: 4) {
            // 语音按钮（不再有独立圆背景，图标直接浮在胶囊玻璃底色上）
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                router.chatEntrySource = "voice"; router.navigate(.chatVoice)
            } label: {
                Image(systemName: "mic.fill")
                    .font(AIATheme.Font.title3.weight(.medium))
                    .foregroundStyle(AIATheme.sub)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)

            // 中间滚动文案区（浅灰填充的小胶囊，与外部大胶囊形成双层视觉层次）
            Button { router.chatEntrySource = entrySource; router.navigateToChatAutofocus() } label: {
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
        // 底部栏出现在首页/各模块页（不含对话页），识别完要把用户带到对话页看好好记回复
        .cameraRecognitionFlow(showCamera: $showCamera, showPicker: $showPicker, navigateToChat: true)
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
