// OnboardingView.swift
// 首次启动引导：多页轮播，介绍阿宝能做什么，并重点指向「快捷指令」配置
// （截图无感识别 + 跟阿宝说一句话记账/提醒）。最后一步"开始使用"由调用方标记完成。
import SwiftUI
import UIKit

struct OnboardingView: View {
    /// 完成回调：调用方负责写 UserDefaults（aia.onboardingDone = true）并 dismiss。
    var onFinish: () -> Void

    @State private var page = 0
    private let total = 7

    // 快捷指令配置页状态
    @State private var expandedTrigger: TriggerType? = .assistiveTouch
    @State private var selectedTriggerForTutorial: TriggerType? = nil
    @State private var showToast = false
    @State private var toastText = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [AIATheme.blue.opacity(0.12), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                // 顶部跳过
                HStack {
                    Spacer()
                    if page < total - 1 {
                        Button { onFinish() } label: {
                            Text("跳过").font(AIATheme.Font.subhead.weight(.medium)).foregroundStyle(AIATheme.sub)
                        }
                        .padding(.trailing, 18).padding(.top, 14)
                    }
                }

                TabView(selection: $page) {
                    welcomePage.tag(0)
                    screenshotPage.tag(1)
                    voicePage.tag(2)
                    siriPage.tag(3)
                    quickActionsPage.tag(4)
                    shortcutsPage.tag(5)
                    donePage.tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                // 底部页码 + 主按钮
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        ForEach(0..<total, id: \.self) { i in
                            Capsule()
                                .fill(i == page ? AIATheme.blue : AIATheme.iconInactive.opacity(0.5))
                                .frame(width: i == page ? 22 : 8, height: 8)
                                .animation(.spring(), value: page)
                        }
                    }
                    Button {
                        if page < total - 1 { page += 1 } else { onFinish() }
                    } label: {
                        Text(page == total - 1 ? "开始使用" : "下一步")
                            .font(AIATheme.Font.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(LinearGradient.techAccent)
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 30)
            }
        }
        .sheet(item: $selectedTriggerForTutorial) { trigger in
            NavigationStack {
                TriggerTutorialView(trigger: trigger)
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

    // MARK: - 普通页（欢迎 / 截图 / 语音 / 完成）
    private var welcomePage: some View {
        pageContent(kind: .welcome,
                    title: "你好，我是阿宝 👋",
                    message: "你的 AI 生活助理。记账、饮食、健康、待办，自动帮你搞定。")
    }
    private var screenshotPage: some View {
        pageContent(kind: .screenshot,
                    title: "自动记账、记待办、记饮食",
                    message: "设置快捷指令后截屏，阿宝会自动识别内容，归类到账单 / 待办 / 饮食 / 健康，不用手动输入。")
    }
    private var voicePage: some View {
        pageContent(kind: .voice,
                    title: "跟阿宝说一句话",
                    message: "「跟阿宝说 午饭35」记一笔账单 + 热量；「跟阿宝说 周五提醒我交报表」建好待办。动动嘴就行。")
    }
    private var siriPage: some View {
        pageContent(kind: .siri,
                    title: "通过Siri记账、记待办、记饮食",
                    message: "跟Siri说「用阿宝AI管家记」，就可以自动记账、记饮食、记待办，到点自动提醒")
    }
    private var quickActionsPage: some View {
        VStack(spacing: 0) {
            Spacer()
            HomeScreenQuickActionsIllustration(size: 210)
                .padding(.bottom, 8)
            VStack(spacing: 10) {
                Text("桌面长按，更快一步")
                    .font(AIATheme.Font.title1.weight(.bold))
                    .foregroundStyle(.primary)
                Text("在手机桌面长按「阿宝AI管家」图标，无需打开 App 就能一键：")
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(AIATheme.sub)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
            .padding(.top, 16)
            .padding(.bottom, 20)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                quickActionGridItem(icon: "checklist", text: "查待办", color: AIATheme.todo)
                quickActionGridItem(icon: "bubble.left.fill", text: "问阿宝AI", color: AIATheme.blue)
                quickActionGridItem(icon: "camera.fill", text: "拍照记录", color: AIATheme.food)
                quickActionGridItem(icon: "mic.fill", text: "语音记录", color: AIATheme.health)
            }
            .padding(.horizontal, 12)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func quickActionGridItem(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(AIATheme.Font.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(text)
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AIATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AIATheme.rMD, style: .continuous).stroke(AIATheme.hairline, lineWidth: 1))
    }

    private var donePage: some View {
        pageContent(kind: .welcome,
                    title: "一切就绪 🎉",
                    message: "现在就去截张图，或跟阿宝说句话试试吧。随时在「设置 → 重新查看新人引导」回看。")
    }

    private func pageContent(kind: IllustrationView.Kind, title: String, message: String) -> some View {
        VStack(spacing: 22) {
            Spacer()
            IllustrationView(kind: kind, size: 120)
            VStack(spacing: 12) {
                Text(title).font(AIATheme.Font.title1.weight(.bold)).foregroundStyle(.primary)
                Text(message)
                    .font(AIATheme.Font.callout)
                    .foregroundStyle(AIATheme.sub)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // MARK: - 快捷指令配置页（核心）
    private var shortcutsPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                shortcutsPageTitle
                stepOneCard
                stepTwoCard

                Text("提示：设置一次长期生效。之后任意界面截屏 → 后台静默识别 → 收到「识别完成」通知 → 打开 App 自动弹确认页。")
                    .font(AIATheme.Font.caption).foregroundStyle(AIATheme.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
    }

    private var shortcutsPageTitle: some View {
        VStack(spacing: 8) {
            Text("设置自动记账、记待办、记饮食")
                .font(AIATheme.Font.title2.weight(.bold))
                .foregroundStyle(AIATheme.blue)
                .multilineTextAlignment(.center)
            Text("让截屏和语音自动变成账单、待办、饮食记录")
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.sub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
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

                    Button {
                        selectedTriggerForTutorial = trigger
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
}
