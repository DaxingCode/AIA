// AutoRecognitionSetupView.swift
// 「截屏自动识别」一键设置页。
// 交互：① 添加快捷指令（跳转系统安装页） → ② 选择触发方式并按引导配置。
// 注意：iOS 不允许 App 直接静默安装快捷指令，最后一步「添加」需用户在系统页亲手点。
//
// 重要：本 View 不再内嵌 NavigationStack——外层 NavigationStack 已 push 进来，再嵌一个会冲突卡死。
// 「完成」按钮直接 router.path.removeLast() pop 出栈。
import SwiftUI

@available(iOS 16, *)
struct AutoRecognitionSetupView: View {
    @State private var expandedTrigger: TriggerType? = .assistiveTouch
    @State private var toastText = ""
    @State private var showToast = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                stepOneCard
                stepTwoCard
            }
            .padding(16)
        }
        .background(AIATheme.fillSoft)
        .navigationTitle("自动截屏识别")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { finish() }
            }
        }
        .overlay(alignment: .top) {
            if showToast {
                toastView
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(), value: showToast)
            }
        }
    }

    // MARK: - 第一步：添加快捷指令
    private var stepOneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "1.circle.fill")
                    .font(AIATheme.Font.title3)
                    .foregroundStyle(AIATheme.blue)
                Text("第一步：添加快捷指令")
                    .font(AIATheme.Font.body.weight(.bold))
                    .foregroundStyle(.primary)
            }

            Text("添加「阿宝AI自动记账、记待办、记饮食」快捷指令；已安装同名指令时，请选择「替换」操作。")
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.sub)
                .lineSpacing(3)

            HStack(spacing: 12) {
                Button {
                    openShortcutImport { _, msg in
                        if let msg { showToast(msg) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("去添加")
                    }
                    .font(AIATheme.Font.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(LinearGradient.techAccent)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 第二步：设置触发方式
    private var stepTwoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "2.circle.fill")
                    .font(AIATheme.Font.title3)
                    .foregroundStyle(AIATheme.blue)
                Text("第二步：设置触发方式")
                    .font(AIATheme.Font.body.weight(.bold))
                    .foregroundStyle(.primary)
            }

            Text("根据您的喜好，设置自动截屏识别的触发方式。")
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.sub)
                .lineSpacing(3)

            VStack(spacing: 0) {
                ForEach(TriggerType.allCases) { trigger in
                    triggerRow(trigger)
                    if trigger.rawValue != TriggerType.allCases.last?.rawValue {
                        Divider().padding(.leading, 46).background(AIATheme.hairline)
                    }
                }
            }
            .card(bg: AIATheme.surface, shadow: false)
        }
        .padding(14)
        .card()
    }

    private func triggerRow(_ trigger: TriggerType) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3)) {
                    expandedTrigger = (expandedTrigger == trigger) ? nil : trigger
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: trigger.icon)
                        .font(AIATheme.Font.headline)
                        .foregroundStyle(AIATheme.blue)
                        .frame(width: 24)
                        .rotationEffect(.degrees(trigger.rotation))
                    Text(trigger.rawValue)
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: expandedTrigger == trigger ? "chevron.down" : "chevron.right")
                        .font(AIATheme.Font.footnote.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedTrigger == trigger {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<trigger.steps.count, id: \.self) { i in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1).")
                                .font(AIATheme.Font.footnote.weight(.bold))
                                .foregroundStyle(AIATheme.blue)
                            Text(trigger.steps[i])
                                .font(AIATheme.Font.footnote)
                                .foregroundStyle(AIATheme.sub)
                                .lineSpacing(2)
                            Spacer(minLength: 0)
                        }
                    }
                    Button {
                        openTriggerSystemSettings(trigger) { msg in showToast(msg) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.fill")
                            Text("打开对应系统设置")
                        }
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(AIATheme.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    NavigationLink {
                        TriggerTutorialView(trigger: trigger)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                            Text("查看视频教程")
                        }
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient.techAccent)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    // MARK: - 打开快捷指令安装页
    private var toastView: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.white)
            Text(toastText)
                .font(AIATheme.Font.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
        .clipShape(Capsule())
        .padding(.top, 8)
    }

    private func showToast(_ text: String) {
        toastText = text
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showToast = false }
    }

    /// 统一退出：从 path 驱动进入则 pop path；从 NavigationLink 等场景进入则 dismiss。
    private func finish() {
        let router = NavigationRouter.shared
        if router.path.last == .autoSetup {
            router.path.removeLast()
        } else {
            dismiss()
        }
    }
}
