// OnboardingView.swift
// 首次启动引导：多页轮播，介绍好记AI能做什么，并重点指向「快捷指令」配置
// （截图无感识别 + 跟好记AI说一句话记账/提醒）。最后一步"开始使用"由调用方标记完成。
import SwiftUI
import UIKit

struct OnboardingView: View {
    /// 完成回调：调用方负责写 UserDefaults（aia.onboardingDone = true）并 dismiss。
    var onFinish: () -> Void

    @State private var page = 0
    private let total = 12

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

                // 只渲染当前页，避免 TabView.page 一次性构建全部 12 页导致的首帧渲染死锁（老机型黑屏卡死）。
                // 外层包 DragGesture 实现手指左右滑动翻页；第 10 页（shortcutsPage 内含纵向 ScrollView）
                // 不挂整页横向手势，避免与纵向滚动抢事件，该页仍用按钮翻页。
                GeometryReader { geo in
                    Group {
                        switch page {
                        case 0: welcomePage
                        case 1: screenshotPage
                        case 2: payScreenshotPage
                        case 3: notifyScreenshotPage
                        case 4: payFoodPage
                        case 5: voiceScenarioPage
                        case 6: siriPage
                        case 7: quickActionsPage
                        case 8: healthPage
                        case 9: askPage
                        case 10: shortcutsPage
                        default: donePage
                        }
                    }
                    .id(page)
                    .transition(.opacity)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .animation(.easeInOut(duration: 0.25), value: page)
                    .gesture(
                        // 第 10 页不挂整页横向手势（与内部纵向 ScrollView 共存），其余页支持左右滑。
                        page == 10 ? nil :
                        DragGesture(minimumDistance: 25)
                            .onEnded { value in
                                let w = geo.size.width
                                // 左滑（位移为负）= 前进
                                if value.translation.width < -w * 0.18, page < total - 1 {
                                    goNext()
                                }
                                // 右滑（位移为正）= 后退，且不在第 0 页
                                else if value.translation.width > w * 0.18, page > 0 {
                                    page -= 1
                                }
                            }
                    )
                }

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
                    HStack(spacing: 12) {
                        if page > 0 {
                            Button {
                                page -= 1
                            } label: {
                                Text("上一步")
                                    .font(AIATheme.Font.body.weight(.semibold))
                                    .foregroundStyle(AIATheme.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                                    .background(AIATheme.blue.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            goNext()
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
                    }
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

    /// 前进一页；若已在最后一页则完成引导。
    private func goNext() {
        if page < total - 1 { page += 1 } else { onFinish() }
    }

    private func showToast(_ text: String) {
        toastText = text
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showToast = false }
    }

    // MARK: - 普通页（欢迎 / 截图 / 语音 / 完成）
    private var welcomePage: some View {
        pageContent(kind: .welcome,
                    title: "你好，我是小记 👋",
                    message: "你的专属AI助理，自动记账、记待办、记饮食、管健康，一个App全搞定")
    }
    private var screenshotPage: some View {
        pageContent(kind: .screenshot,
                    title: "自动记账、记待办、记饮食",
                    message: "截屏、语音、Siri、拍照、图片、文字，都能自动记账、记待办、记饮食、记健康，超方便的！")
    }
    private var payScreenshotPage: some View {
        pageContent(kind: .screenshot,
                    title: "付款后截屏自动记账",
                    message: "付款完成，截一张屏，小记自动识别金额与商户并记账，不用手动填")
    }
    private var payFoodPage: some View {
        pageContent(kind: .diet,
                    title: "吃饭拍照自动记营养",
                    message: "吃饭时拍张照，小记自动识别热量、卡路里与营养元素，饮食管理零负担")
    }
    private var notifyScreenshotPage: some View {
        pageContent(kind: .todo,
                    title: "收到通知截屏记待办",
                    message: "收到通知时截一张屏，小记自动建好待办，并在指定时间提醒你")
    }
    private var voiceScenarioPage: some View {
        pageContent(kind: .voice,
                    title: "记账、待办、饮食，一句话搞定",
                    message: "跟小记说「中午吃烤肉花了50元」，自动记一笔账单和烤肉热量\n跟小记说「周五提醒我交报表」，自动记好周五的待办，会自动提醒哦")
    }
    private var siriPage: some View {
        pageContent(kind: .siri,
                    title: "通过Siri记账、记待办、记饮食",
                    message: "跟Siri说「用好记AI」，就可以自动记账、记饮食、记待办，到点自动提醒")
    }
    private var askPage: some View {
        pageContent(kind: .ask,
                    title: "都可以问小记",
                    message: "账单、饮食、待办、运动、睡眠、健康管理，都可以问「小记」")
    }
    private var healthPage: some View {
        pageContent(kind: .health,
                    title: "已打通苹果健康数据",
                    message: "睡眠、心率、运动、健康，App 全掌握")
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
                Text("在手机桌面长按「好记AI」图标，无需打开 App 就能一键：")
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
                quickActionGridItem(icon: "bubble.left.fill", text: "问小记", color: AIATheme.blue)
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
                    message: "现在就去截张图，或跟小记说句话试试吧。随时在「设置 → 重新查看新人引导」回看。")
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

            Text("添加「好记AI自动记账、记待办、记饮食」快捷指令；已安装同名指令时，请选择「替换」操作。")
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.sub)
                .lineSpacing(3)

            VStack(spacing: 12) {
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

                // 次按钮：查看视频教程
                Button {
                    if let url = URL(string: "https://mp.weixin.qq.com/s/l0Gw35TCMUGgkYf18F73XA") {
                        presentInAppBrowser(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                        Text("查看视频教程")
                    }
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(AIATheme.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 第二步：设置自动记录方式
    private var stepTwoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "2.circle.fill")
                    .font(AIATheme.Font.title3)
                    .foregroundStyle(AIATheme.blue)
                Text("第二步：设置自动记录方式")
                    .font(AIATheme.Font.body.weight(.bold))
                    .foregroundStyle(.primary)
            }

            Text("付款完成时截屏记账单，收到通知时截屏记待办。")
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
                            Text("打开系统设置")
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

                    if trigger != .controlCenter {
                        Button {
                            if let url = trigger.articleURL {
                                presentInAppBrowser(url)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.circle.fill")
                                Text("查看视频教程")
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
                    }

                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }
}
