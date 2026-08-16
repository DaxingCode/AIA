// SleepMaskOverlay.swift
// 首页「睡眠模式」全屏遮罩：在首页健康宫格右上角点 ☀️ 进入入睡后盖住整个首页，
// 提示「已经进入梦乡」并实时显示已睡时长；点「我醒了」结束睡眠会话并收起遮罩。
//
// 设计约定：
// - 遮罩只负责「展示 + 回调」，不碰 ModelContext。睡眠落库统一走 SleepSession.swift 的
//   toggleSleepSession，保证首页图标 / 健康页 SleepToggleButton / 遮罩三处写库口径一致。
// - 次级按钮「先用一下 App」只收遮罩、不结束睡眠，避免用户被锁死在遮罩里出不来。
// - 深夜配色固定，不跟随浅/深色模式——遮罩本身就是「夜」的语境。
import SwiftUI

struct SleepMaskOverlay: View {
    /// 当前进行中的睡眠会话。刚点下「入睡」那一帧 @Query 还没刷新，允许为 nil（按「刚刚入睡」展示）。
    let session: SleepSession?
    /// 遮罩可见性：直接由父层 showSleepMask 驱动，绝不经 @State 中间层（反复重建会丢状态 → opacity=0 看不见）。
    let show: Bool
    /// 点「我醒了」：结束睡眠 + 收起遮罩，由父视图执行。
    var onWake: () -> Void
    /// 点「先用一下 App」：仅收遮罩，睡眠继续计时。
    var onDismiss: () -> Void

    @State private var breathe = false
    /// 锁定入睡时刻：醒来后 session 会变 nil，若直接读 session 会让淡出动画期间文案闪成「刚刚入睡」。
    @State private var lockedStart: Date?

    private var sleepStart: Date { lockedStart ?? session?.sleepStart ?? Date() }

    // 深夜配色（固定值，不跟随浅/深色模式——遮罩本身就是「夜」的语境）
    private let night1 = Color(red: 0.07, green: 0.06, blue: 0.20)
    private let night2 = Color(red: 0.17, green: 0.11, blue: 0.32)
    private let amber  = Color(red: 0.88, green: 0.64, blue: 0.23)

    var body: some View {
        ZStack {
            // 背景：毛玻璃 + 深夜渐变，整屏铺满并吞掉底层点击
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(colors: [night1.opacity(0.94), night2.opacity(0.96)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea()

            starField

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                moonBadge
                Text("已经进入梦乡")
                    .font(AIATheme.Font.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                Text("晚安，好梦～ 手机先放下吧")
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 8)
                durationCard
                    .padding(.top, 28)
                Spacer(minLength: 0)
                actionButtons
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .opacity(show ? 1 : 0)
            .offset(y: show ? 0 : 14)
            .animation(.easeOut(duration: 0.45), value: show)
        }
        // 整屏拦截点击，防止误触被遮住的宫格
        .contentShape(Rectangle())
        .onTapGesture { }
        .onAppear {
            if lockedStart == nil { lockedStart = session?.sleepStart }
            // 呼吸动画不依赖 @State 点亮开关，仅在首次挂载时启动一次 repeatForever（丢了无所谓，遮罩可见性由 show 保证）。
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        }
        .onChange(of: session?.sleepStart) { _, new in
            // 入睡那一帧 session 还是 nil，等 @Query 刷新后补锁真实入睡时刻
            if let new, lockedStart == nil { lockedStart = new }
        }
    }

    // MARK: 月亮徽标（呼吸光晕）
    private var moonBadge: some View {
        ZStack {
            Circle()
                .fill(amber.opacity(0.16))
                .frame(width: 148, height: 148)
                .scaleEffect(breathe ? 1.10 : 0.92)
            Circle()
                .fill(amber.opacity(0.22))
                .frame(width: 104, height: 104)
                .scaleEffect(breathe ? 1.05 : 0.95)
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(amber)
                .symbolRenderingMode(.hierarchical)
        }
    }

    // MARK: 入睡时刻 + 实时时长
    private var durationCard: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            VStack(spacing: 6) {
                Text(durationText(now: ctx.date))
                    .font(AIATheme.Font.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("入睡于 \(Self.hm.string(from: sleepStart))")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: AIATheme.rLG, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AIATheme.rLG, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
            )
        }
    }

    // MARK: 按钮组
    private var actionButtons: some View {
        VStack(spacing: 14) {
            Button {
                onWake()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max.fill")
                    Text("我醒了")
                }
                .font(AIATheme.Font.body.weight(.semibold))
                .foregroundStyle(night1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Capsule().fill(amber))
            }
            .buttonStyle(.plain)

            // 次级出口：不结束睡眠，只是把遮罩收起来继续用 App
            Button {
                onDismiss()
            } label: {
                Text("先用一下 App")
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 星点装饰（固定坐标，随呼吸明暗）
    private var starField: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Self.stars.indices, id: \.self) { i in
                    let s = Self.stars[i]
                    Circle()
                        .fill(.white.opacity(s.o))
                        .frame(width: s.r, height: s.r)
                        .position(x: geo.size.width * s.x, y: geo.size.height * s.y)
                        .opacity(breathe ? 1 : 0.35)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, o: Double)] = [
        (0.12, 0.14, 3, 0.55), (0.28, 0.09, 2, 0.40), (0.46, 0.17, 2.5, 0.30),
        (0.72, 0.11, 3, 0.50), (0.88, 0.21, 2, 0.35), (0.18, 0.31, 2, 0.28),
        (0.83, 0.36, 2.5, 0.32), (0.09, 0.62, 2, 0.25), (0.92, 0.68, 3, 0.30),
        (0.34, 0.78, 2, 0.22), (0.66, 0.85, 2.5, 0.26)
    ]

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private func durationText(now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(sleepStart)) / 60)
        if minutes < 1 { return "刚刚入睡" }
        return "已睡 \(minutes / 60)h\(minutes % 60)m"
    }
}
