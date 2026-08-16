// TrialExpiredPromptView.swift
// 免费 30 天试用期结束后的引导弹窗：保留原有「锁图标 + 文案」居中卡片视觉，
// 在文案下方增加「订阅 Pro 版」按钮，点击后关闭弹窗并跳转到订阅页（PaywallView）。
import SwiftUI

/// 试用期结束引导弹窗。
/// - `isPresented`：是否显示（由 ContentView 监听 EntitlementManager 信号驱动）。
/// - `onSubscribe`：点击「订阅 Pro 版」按钮的回调（关闭弹窗 + 打开订阅页）。
struct TrialExpiredPromptView: View {
    @Binding var isPresented: Bool
    let onSubscribe: () -> Void

    var body: some View {
        ZStack {
            // 半透明遮罩：点遮罩可关闭（与原有 Toast 提示的交互一致，不强制点按钮）。
            Color.black.opacity(0.52)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)

                Text("免费体验已结束")
                    .font(AIATheme.Font.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text("订阅 Pro 版会员后可继续使用 Pro 版功能")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                Button {
                    isPresented = false
                    onSubscribe()
                } label: {
                    Text("订阅 Pro 版")
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AIATheme.blue)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .padding(.top, 8)
            }
            .padding(28)
            .frame(width: 280)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
        }
        .opacity(isPresented ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isPresented)
        .allowsHitTesting(isPresented)
    }
}
