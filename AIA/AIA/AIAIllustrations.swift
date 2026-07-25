// AIAIllustrations.swift
// 空态插画 + 引导插画：全部用 SwiftUI 矢量绘制（SF Symbols + 渐变 + AIATheme 令牌），
// 跟随系统浅/深自适应，无需打包图片资源。风格：科技蓝渐变 + 可爱小亮点，干净极简。
import SwiftUI

// MARK: - 插画（可复用）
/// 用渐变圆角方块 + 大号 SF Symbol + 柔光晕 + 小亮点，画出"干净极简"的模块插画。
struct IllustrationView: View {
    enum Kind {
        case welcome, screenshot, voice, shortcuts, siri, ask
        case diet, health, bill, todo
    }
    let kind: Kind
    var size: CGFloat = 110

    /// 每个插画的主色 / 辅色 / 图标
    private var palette: (primary: Color, secondary: Color, glyph: String) {
        switch kind {
        case .welcome:   return (AIATheme.blue,   AIATheme.purple, "brain.head.profile")
        case .screenshot:return (AIATheme.blue,   AIATheme.green,  "text.viewfinder")
        case .voice:     return (AIATheme.green,  AIATheme.blue,   "mic.fill")
        case .siri:      return (AIATheme.blue,   AIATheme.purple, "waveform.circle.fill")
        case .ask:       return (AIATheme.blue,   AIATheme.purple, "bubble.left.fill")
        case .shortcuts: return (AIATheme.purple, AIATheme.blue,   "command")
        case .diet:      return (AIATheme.food,   AIATheme.bill,   "fork.knife")
        case .health:    return (AIATheme.health, AIATheme.todo,   "heart.fill")
        case .bill:      return (AIATheme.bill,   AIATheme.health, "yensign")
        case .todo:      return (AIATheme.todo,   AIATheme.food,   "checklist")
        }
    }

    var body: some View {
        ZStack {
            // 柔和光晕
            Circle()
                .fill(palette.primary.opacity(0.12))
                .frame(width: size * 1.35, height: size * 1.35)
            // 主图形：渐变圆角方块
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [palette.primary, palette.secondary],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: palette.primary.opacity(0.28), radius: 14, y: 8)
                .overlay(
                    Image(systemName: palette.glyph)
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                )
            // 可爱小亮点（用背景色挖空，形成悬浮感）
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.18, weight: .bold))
                .foregroundStyle(palette.secondary)
                .background(Circle().fill(Color(.systemBackground)).frame(width: size * 0.28, height: size * 0.28))
                .offset(x: size * 0.4, y: -size * 0.4)
        }
        .frame(width: size * 1.5, height: size * 1.5)
    }
}

// MARK: - 空态（插画 + 文案 + 可选 CTA）
/// 四个模块列表无数据时统一展示；可选 action 引导用户去"用"这个 App。
struct EmptyStateView: View {
    let kind: IllustrationView.Kind
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var footer: String? = nil

    @State private var footerAppeared = false

    var body: some View {
        // 垂直居中：上下 Spacer 让空态（含「点击」提示）落在模块可视区域中央，
        // 而不是堆在顶部。maxHeight 由外层 ScrollView 内容撑满高度后生效。
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                IllustrationView(kind: kind, size: 92)
                if !title.isEmpty {
                    Text(title)
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                if !message.isEmpty {
                    Text(message)
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.sub)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                }
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(AIATheme.blue)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                if let footer, !footer.isEmpty {
                    Text(footer)
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(AIATheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                        .padding(.top, 8)
                        .opacity(footerAppeared ? 1 : 0)
                        .offset(y: footerAppeared ? 0 : 10)
                        .animation(.easeOut(duration: 0.5).delay(0.25), value: footerAppeared)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
        .onAppear { footerAppeared = true }
    }
}

// MARK: - 桌面长按快捷操作插画（新人引导）
/// 模拟手机桌面：App 图标被长按后弹出快捷菜单。
struct HomeScreenQuickActionsIllustration: View {
    var size: CGFloat = 200

    private var menuItems: [MenuItem] {
        [
            MenuItem(icon: "checklist", title: "查待办", color: AIATheme.todo),
            MenuItem(icon: "bubble.left.fill", title: "问阿宝AI", color: AIATheme.blue),
            MenuItem(icon: "camera.fill", title: "拍照记录", color: AIATheme.food),
            MenuItem(icon: "mic.fill", title: "语音记录", color: AIATheme.health)
        ]
    }

    var body: some View {
        ZStack {
            phoneBody
            iconGrid
            quickActionMenu
        }
        .frame(width: size, height: size * 1.25)
    }

    private var phoneBody: some View {
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .fill(AIATheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .stroke(AIATheme.hairline, lineWidth: 1)
            )
            .shadow(color: AIATheme.cardShadow, radius: size * 0.05, y: size * 0.03)
    }

    private func genericIcon(systemName: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
            .fill(color.opacity(0.16))
            .frame(width: size * 0.22, height: size * 0.22)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.11, weight: .semibold))
                    .foregroundStyle(color)
            )
    }

    private var aiaIcon: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(Color.clear)
                .frame(width: size * 0.22, height: size * 0.22)
                .overlay(
                    Image("AppIcon")
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous))
                )
            Circle()
                .fill(Color.red)
                .frame(width: size * 0.08, height: size * 0.08)
                .overlay(
                    Text("1")
                        .font(.system(size: size * 0.04, weight: .bold))
                        .foregroundStyle(.white)
                )
                .offset(x: size * 0.03, y: -size * 0.03)
        }
    }

    private var iconGrid: some View {
        VStack(spacing: size * 0.08) {
            HStack(spacing: size * 0.08) {
                genericIcon(systemName: "music.note", color: .red)
                genericIcon(systemName: "bubble.right.fill", color: .pink)
            }
            HStack(spacing: size * 0.08) {
                genericIcon(systemName: "bag.fill", color: .orange)
                aiaIcon
            }
            HStack(spacing: size * 0.08) {
                genericIcon(systemName: "envelope.fill", color: .blue)
                genericIcon(systemName: "map.fill", color: .green)
            }
        }
        .offset(y: size * 0.08)
    }

    private var quickActionMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<menuItems.count, id: \.self) { i in
                let item = menuItems[i]
                HStack(spacing: size * 0.03) {
                    Image(systemName: item.icon)
                        .font(.system(size: size * 0.06, weight: .semibold))
                        .foregroundStyle(item.color)
                        .frame(width: size * 0.08)
                    Text(item.title)
                        .font(.system(size: size * 0.06, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.vertical, size * 0.03)
                .padding(.horizontal, size * 0.04)
                if i < menuItems.count - 1 {
                    Divider()
                        .padding(.leading, size * 0.14)
                        .background(AIATheme.hairline)
                }
            }
        }
        .frame(width: size * 0.58)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .stroke(AIATheme.hairline, lineWidth: 1)
        )
        .shadow(color: AIATheme.cardShadow, radius: size * 0.05, y: size * 0.02)
        .offset(x: -size * 0.32, y: size * 0.33)
    }

    private struct MenuItem: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let color: Color
    }
}
