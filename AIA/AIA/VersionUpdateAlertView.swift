// >>> CHANGE-[2026-08-30 14:06:01]-[版本更新弹窗] 开始
// 版本更新建议弹窗：独立自定义视图（不复用通用 centeredAlert，做更精致的营销型样式）。
// 含 App 图标 + 标题 + 副标题 + 上下两个大按钮；半透明遮罩 + 圆角卡片；适配暗色模式。
import SwiftUI

struct VersionUpdateAlertView: View {
    /// 遮罩 + 卡片整体，收到父视图 `.overlay(isPresented:)` 或条件渲染时呈现。
    let latestVersion: String
    let onUpdate: () -> Void
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            // 半透明遮罩，点遮罩 = 暂不（与次按钮同语义，但点遮罩不记 skip，只关闭）
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onSkip() }

            VStack(spacing: 0) {
                // 顶部图标 + 渐变圆环背景
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AIATheme.blue.opacity(0.18), AIATheme.blue.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 112, height: 112)

                    Image(systemName: "sparkles")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AIATheme.blue, AIATheme.blue.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: AIATheme.blue.opacity(0.35), radius: 8, y: 2)
                }
                .padding(.top, 26)
                .padding(.bottom, 16)

                Text("发现新版本")
                    .font(AIATheme.Font.title3.weight(.bold))
                    .foregroundStyle(AIATheme.reading)
                    .multilineTextAlignment(.center)

                Text("增加了一些有趣的新功能～")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.sub)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)

                if !latestVersion.isEmpty {
                    Text("最新版本 \(latestVersion)")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(AIATheme.blue.opacity(0.12))
                        .clipShape(Capsule())
                        .padding(.top, 12)
                }

                // 上下两个大按钮
                VStack(spacing: 10) {
                    Button {
                        onUpdate()
                    } label: {
                        Text("去 App Store 更新")
                            .font(AIATheme.Font.subhead.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                LinearGradient(
                                    colors: [AIATheme.blue, AIATheme.blue.opacity(0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }

                    Button {
                        onSkip()
                    } label: {
                        Text("暂不更新")
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .foregroundStyle(AIATheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.top, 22)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
            .background(AIATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG, style: .continuous))
            .padding(.horizontal, 36)
            .frame(maxWidth: 360)
        }
    }
}

/// 便捷 modifier：在任意视图上挂版本更新弹窗。
extension View {
    func versionUpdateAlert(latestVersion: String,
                            isPresented: Binding<Bool>,
                            onUpdate: @escaping () -> Void,
                            onSkip: @escaping () -> Void) -> some View {
        self.overlay(
            ZStack {
                if isPresented.wrappedValue {
                    VersionUpdateAlertView(
                        latestVersion: latestVersion,
                        onUpdate: {
                            isPresented.wrappedValue = false
                            onUpdate()
                        },
                        onSkip: {
                            isPresented.wrappedValue = false
                            onSkip()
                        }
                    )
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isPresented.wrappedValue)
                }
            }
        )
    }
}
// <<< CHANGE-[2026-08-30 14:06:01]-[版本更新弹窗] 结束
