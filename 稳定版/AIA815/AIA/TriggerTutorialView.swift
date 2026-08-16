// TriggerTutorialView.swift
// 触发方式视频教程页：点击「查看视频教程」后进入。
// 右上角固定展示「视频教程」标记；中间播放该触发方式的视频；下方列出步骤并提供「打开系统设置」入口。
// 若未配置视频 URL，则展示用 SwiftUI 绘制的系统设置引导占位图。
import SwiftUI
import AVKit

@available(iOS 16, *)
struct TriggerTutorialView: View {
    let trigger: TriggerType

    @Environment(\.dismiss) private var dismiss
    @State private var showSystemSettingsError = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let url = trigger.videoURL {
                    videoPlayer(url: url)
                } else {
                    tutorialPlaceholder
                }

                stepsCard
                openSettingsButton
            }
            .padding(16)
        }
        .background(AIATheme.fillSoft)
        .navigationTitle(trigger.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: "play.rectangle.fill")
                        .font(AIATheme.Font.caption)
                    Text("视频教程")
                        .font(AIATheme.Font.footnote.weight(.medium))
                }
                .foregroundStyle(AIATheme.blue)
            }
        }
    }

    // MARK: - 视频播放器
    private func videoPlayer(url: URL) -> some View {
        VStack(spacing: 12) {
            AVPlayerControllerView(player: AVPlayer(url: url))
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                .overlay(
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .stroke(AIATheme.hairline, lineWidth: 1)
                )

            Text("教程将自动循环播放，可点击播放器控制条暂停/重播")
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.muted)
        }
    }

    // MARK: - 无视频时的占位教程（模拟系统设置引导页）
    private var tutorialPlaceholder: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: AIATheme.rMD)
                    .fill(AIATheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AIATheme.rMD)
                            .stroke(AIATheme.hairline, lineWidth: 1)
                    )

                VStack(spacing: 0) {
                    // 模拟系统设置导航栏
                    HStack {
                        Image(systemName: "chevron.left")
                            .font(AIATheme.Font.callout.weight(.semibold))
                            .foregroundStyle(AIATheme.blue)
                        Text(settingsPageTitle)
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("视频教程")
                            .font(AIATheme.Font.caption.weight(.medium))
                            .foregroundStyle(AIATheme.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AIATheme.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    // 模拟设置列表项
                    VStack(spacing: 0) {
                        ForEach(0..<placeholderRows.count, id: \.self) { i in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(placeholderRows[i].color)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Image(systemName: placeholderRows[i].icon)
                                            .font(AIATheme.Font.subhead)
                                            .foregroundStyle(.white)
                                    )
                                Text(placeholderRows[i].title)
                                    .font(AIATheme.Font.subhead)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(AIATheme.Font.caption)
                                    .foregroundStyle(AIATheme.muted)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            if i != placeholderRows.count - 1 {
                                Divider()
                                    .padding(.leading, 56)
                                    .background(AIATheme.hairline)
                            }
                        }
                    }
                    .background(AIATheme.surface)

                    Spacer()

                    // 模拟高亮提示
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(AIATheme.Font.title2)
                            .foregroundStyle(AIATheme.blue)
                        Text(placeholderTip)
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(AIATheme.sub)
                            .lineSpacing(2)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(AIATheme.blue.opacity(0.08))
                    .cornerRadius(AIATheme.rMD)
                    .overlay(
                        RoundedRectangle(cornerRadius: AIATheme.rMD)
                            .stroke(AIATheme.blue.opacity(0.2), lineWidth: 1)
                    )
                    .padding(16)
                }
            }
            .aspectRatio(9 / 16, contentMode: .fit)

            Text("视频教程即将上线，当前为步骤引导图")
                .font(AIATheme.Font.caption)
                .foregroundStyle(AIATheme.muted)
        }
    }

    private var settingsPageTitle: String {
        switch trigger {
        case .assistiveTouch: return "触控"
        case .backTap: return "触控"
        case .actionButton: return "操作按钮"
        case .controlCenter: return "控制中心"
        }
    }

    private var placeholderTip: String {
        switch trigger {
        case .assistiveTouch:
            return "点击「辅助触控」进入后，选择一个自定操作绑定「好记AI自动记账、记待办、记饮食」。"
        case .backTap:
            return "点击「轻点背面」进入后，选择「轻点两下」或「轻点三下」绑定指令。"
        case .actionButton:
            return "把操作按钮滑动到「快捷指令」，然后选择「好记AI自动记账、记待办、记饮食」。"
        case .controlCenter:
            return "在控制中心添加「快捷指令」控制，长按后选择本 App 指令即可。"
        }
    }

    private var placeholderRows: [(title: String, icon: String, color: Color)] {
        switch trigger {
        case .assistiveTouch, .backTap:
            return [
                ("飞行模式", "airplane", Color.orange),
                ("无线局域网", "wifi", Color.blue),
                ("蓝牙", "bolt.horizontal", Color.blue),
                ("蜂窝网络", "antenna.radiowaves.left.and.right", Color.green),
                ("辅助功能", "person.fill", Color.blue),
                ("触控", "hand.tap.fill", Color.blue)
            ]
        case .actionButton:
            return [
                ("通用", "gear", AIATheme.iconInactive),
                ("辅助功能", "person.fill", Color.blue),
                ("操作按钮", "button.horizontal.top.press", Color.blue)
            ]
        case .controlCenter:
            return [
                ("飞行模式", "airplane", Color.orange),
                ("无线局域网", "wifi", Color.blue),
                ("控制中心", "switch.2", AIATheme.iconInactive)
            ]
        }
    }

    // MARK: - 步骤卡片
    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配置步骤")
                .font(AIATheme.Font.body.weight(.bold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<trigger.steps.count, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1)")
                            .font(AIATheme.Font.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(AIATheme.blue)
                            .clipShape(Circle())
                        Text(trigger.steps[i])
                            .font(AIATheme.Font.footnote)
                            .foregroundStyle(AIATheme.sub)
                            .lineSpacing(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 打开系统设置
    private var openSettingsButton: some View {
        Button {
            openSystemSettings(trigger)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill")
                Text("打开系统设置")
            }
            .font(AIATheme.Font.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(LinearGradient.techAccent)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if showSystemSettingsError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.white)
                    Text("未能直接打开该设置页，请在「设置」中手动进入")
                        .font(AIATheme.Font.caption.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .clipShape(Capsule())
                .padding(.top, -44)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func openSystemSettings(_ trigger: TriggerType) {
        openTriggerSystemSettings(trigger) { _ in
            withAnimation(.spring()) { showSystemSettingsError = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.spring()) { showSystemSettingsError = false }
            }
        }
    }
}

// MARK: - 远程视频播放器（AVPlayerViewController 包装）
@available(iOS 16, *)
private struct AVPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = self.player
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.playerDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        @objc func playerDidReachEnd(notification: Notification) {
            if let item = notification.object as? AVPlayerItem {
                item.seek(to: .zero, completionHandler: nil)
            }
        }
    }
}
