// SettingsView.swift
// 云同步设置：同步账号、自动同步开关、立即同步、上次同步时间。
import SwiftUI
import SwiftData
import Combine
import PhotosUI
import MessageUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    @StateObject private var sync = CloudSyncManager.shared

    // 外观模式：浅色 / 深色 / 跟随系统（写 UserDefaults，ContentView 读取并应用到全窗口）
    @AppStorage("aia.appearance") private var appearanceRaw = "system"
    @State private var showCopied = false
    @State private var toastText = "已复制同步账号"
    @State private var showShortcutGuide = false
    @State private var showOnboarding = false
    // 开发者模式口令
    @State private var showPasscode = false
    @State private var passcodeText = ""
    @State private var showPasscodeError = false
    @State private var devUnlocked: Bool = DeveloperGate.isUnlocked
    @State private var devNavigate = false
    @State private var browserTarget: BrowserTarget?
    @State private var settingsDidLoad = false

    // MARK: - 每天使用提醒（每晚定时汇总四模块，带操作按钮）
    private var dailyCheckinCard: some View {
        let enabled = Binding<Bool>(
            get: { UserDefaults.standard.bool(forKey: ReminderNotificationManager.dailyEnabledKey) },
            set: { on in
                UserDefaults.standard.set(on, forKey: ReminderNotificationManager.dailyEnabledKey)
                if on {
                    ReminderNotificationManager.rescheduleFromStoredDefaults()
                } else {
                    ReminderNotificationManager.cancelDailyCheckin()
                }
            }
        )
        let storedHour = UserDefaults.standard.integer(forKey: ReminderNotificationManager.dailyHourKey)
        let storedMin = UserDefaults.standard.integer(forKey: ReminderNotificationManager.dailyMinuteKey)
        let timeBinding = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: storedHour, minute: storedMin, second: 0, of: Date()) ?? Date() },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let h = c.hour ?? 22
                let m = c.minute ?? 0
                UserDefaults.standard.set(h, forKey: ReminderNotificationManager.dailyHourKey)
                UserDefaults.standard.set(m, forKey: ReminderNotificationManager.dailyMinuteKey)
                ReminderNotificationManager.rescheduleFromStoredDefaults()
            }
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("每天使用提醒")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Toggle("提醒我记账 / 记饮食 / 记健康 / 看待办", isOn: enabled)
                .font(AIATheme.Font.subhead)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if enabled.wrappedValue {
                DatePicker("提醒时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .font(AIATheme.Font.subhead)
            }
            Text("到点会发一条汇总提醒，长按通知可分别跳到各模块。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
            // 健康目标傍晚提醒：独立子开关（默认跟随每日提醒开启），傍晚提示补步数/饮水。
            let healthEnabled = Binding<Bool>(
                get: { UserDefaults.standard.bool(forKey: ReminderNotificationManager.healthGoalEnabledKey) },
                set: { on in
                    UserDefaults.standard.set(on, forKey: ReminderNotificationManager.healthGoalEnabledKey)
                    ReminderNotificationManager.rescheduleFromStoredDefaults()
                }
            )
            Divider().padding(.vertical, 4)
            Toggle("提醒我完成今日步数 / 饮水目标", isOn: healthEnabled)
                .font(AIATheme.Font.subhead)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            let healthHour = UserDefaults.standard.integer(forKey: ReminderNotificationManager.healthGoalHourKey)
            let healthMin = UserDefaults.standard.integer(forKey: ReminderNotificationManager.healthGoalMinuteKey)
            let healthTimeBinding = Binding<Date>(
                get: { Calendar.current.date(bySettingHour: healthHour, minute: healthMin, second: 0, of: Date()) ?? Date() },
                set: { newDate in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                    UserDefaults.standard.set(c.hour ?? 19, forKey: ReminderNotificationManager.healthGoalHourKey)
                    UserDefaults.standard.set(c.minute ?? 0, forKey: ReminderNotificationManager.healthGoalMinuteKey)
                    ReminderNotificationManager.rescheduleFromStoredDefaults()
                }
            )
            if healthEnabled.wrappedValue {
                DatePicker("提醒时间", selection: healthTimeBinding, displayedComponents: .hourAndMinute)
                    .font(AIATheme.Font.subhead)
            }
        }
        .padding(14)
        .card()
    }

    // >>> CHANGE-[2026-08-18 18:28:46]-[睡眠提醒设置卡] 开始
    // 原因: 新增独立"睡觉提醒"卡，默认开+默认23:00，点通知进首页并开始记录睡眠。
    // 回退: 删除本 card 定义 + 删除 body 中 sleepReminderCard 调用即可。
    private var sleepReminderCard: some View {
        let enabled = Binding<Bool>(
            get: { UserDefaults.standard.bool(forKey: ReminderNotificationManager.sleepEnabledKey) },
            set: { on in
                UserDefaults.standard.set(on, forKey: ReminderNotificationManager.sleepEnabledKey)
                ReminderNotificationManager.rescheduleFromStoredDefaults()
            }
        )
        let storedHour = UserDefaults.standard.integer(forKey: ReminderNotificationManager.sleepHourKey)
        let storedMin = UserDefaults.standard.integer(forKey: ReminderNotificationManager.sleepMinuteKey)
        let timeBinding = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: storedHour, minute: storedMin, second: 0, of: Date()) ?? Date() },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                UserDefaults.standard.set(c.hour ?? 23, forKey: ReminderNotificationManager.sleepHourKey)
                UserDefaults.standard.set(c.minute ?? 0, forKey: ReminderNotificationManager.sleepMinuteKey)
                ReminderNotificationManager.rescheduleFromStoredDefaults()
            }
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "moon.stars")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.health)
                Text("睡觉提醒")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Toggle("到点提醒我该睡觉了", isOn: enabled)
                .font(AIATheme.Font.subhead)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if enabled.wrappedValue {
                DatePicker("提醒时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .font(AIATheme.Font.subhead)
            }
            Text("到点发一条睡觉提醒，点通知会进首页并开始记录你的睡眠时间 🌙")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }
    // <<< CHANGE-[2026-08-18 18:28:46]-[睡眠提醒设置卡] 结束

    @StateObject private var ent = EntitlementManager.shared
    @StateObject private var sub = SubscriptionManager.shared
    @StateObject private var cfg = GlobalConfigStore.shared
    @State private var showPaywall = false
    @State private var showFeedbackMail = false
    @State private var feedbackMailUnavailable = false

    var body: some View {
        // 注意：本页由首页 navigationDestination(for:) push 进来，
        // 绝不能再自带 NavigationStack（栈中栈 → 首次点无反应、二次点崩溃）。
        // 内部的 NavigationLink 会自动依附首页那一个 NavigationStack。
        ScrollView {
            VStack(spacing: 16) {
                myAccountEntry
                // 本月福利卡片显示条件：
                // ① 付费用户且「未」开启免费版体验模式 → 显示（口径：不限次）；
                // ② 开发者已开启免费额度（cfg.freeQuotaEnabled）→ 显示（口径：剩余次数）。
                // 付费用户开启体验模式后与免费用户对齐：免额关→不显示；免额开→显示(剩次数)。
                if (ent.isFullAccess && !ent.simulateFree) || cfg.freeQuotaEnabled {
                    monthlyBenefitCard
                }
                appearanceCard
                backgroundNavRow
                homeLayoutEntry
                screenshotAutoCard
                imageAutoRecogCard
                membershipCard
                dailyCheckinCard
                sleepReminderCard
                guideCard
                aboutCard
                if devUnlocked {
                    DeveloperCenterCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(AIATheme.fillSoft)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 去重：设置页反复 appear（如从「我的账号」返回）时不再重复拉取，避免无谓云请求与日志噪音。
            guard !settingsDidLoad else { return }
            settingsDidLoad = true
            Task {
                await GlobalConfigStore.shared.fetchConfig()
                await ent.refresh()
            }
        }
        .navigationDestination(isPresented: $devNavigate) { DeveloperCenterView() }
        .overlay(alignment: .top) {
            if showCopied {
                copiedToast
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(), value: showCopied)
            }
        }
        .sheet(isPresented: $showShortcutGuide) {
            if #available(iOS 16, *) {
                AutoRecognitionSetupView()
            } else {
                ScreenshotAutomationGuideView()
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .inAppBrowser(target: $browserTarget)
        .alert("解锁开发者模式", isPresented: $showPasscode) {
            SecureField("输入口令", text: $passcodeText)
            Button("取消", role: .cancel) { passcodeText = "" }
            Button("确认") {
                // >>> CHANGE-[2026-08-19 15:32:37]-口令云端化 开始
                // 原因: 明文口令不再本地比对, 改为云端 devLogin 校验+签发 token
                // 回退: 恢复 if passcodeText == DeveloperGate.passcode 本地比对
                let input = passcodeText
                passcodeText = ""
                Task { @MainActor in
                    if await DeveloperGate.verify(input) {
                        DeveloperGate.isUnlocked = true
                        devUnlocked = true
                        // 等 alert -dismiss 动画结束后再 push，避免与 NavigationStack 转场冲突
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            devNavigate = true
                        }
                    } else {
                        // 等 passcode alert 完全 dismiss 后再弹错误提示，避免两个 .alert 冲突导致提示不出现
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showPasscodeError = true
                        }
                    }
                }
                // <<< CHANGE-[2026-08-19 15:32:37]-口令云端化 结束
            }
        } message: {
            Text("长按版本号可解锁广告管理与开发者工具。")
        }
        .centeredAlert(isPresented: $showPasscodeError,
                       title: "口令错误",
                       message: "请重新长按版本号输入正确口令。",
                       dismissTitle: "知道了")
        .sheet(isPresented: $showFeedbackMail) {
            MailComposer(
                recipient: "754727942@qq.com",
                subject: "好记AI 意见反馈",
                body: "请描述您遇到的问题或建议：\n\n"
            )
        }
        .centeredAlert(isPresented: $feedbackMailUnavailable,
                       title: NSLocalizedString("feedback.mailUnavailableTitle", comment: ""),
                       message: String(format: NSLocalizedString("feedback.mailUnavailableMessage", comment: ""), "754727942@qq.com"),
                       dismissTitle: "知道了",
                       secondaryTitle: NSLocalizedString("feedback.copyEmail", comment: ""),
                       onSecondary: {
                           UIPasteboard.general.string = "754727942@qq.com"
                       })
    }

    // MARK: - 我的账号入口（聚合昵称 + 账号信息 + 退出登录）
    private var myAccountEntry: some View {
        Button {
            NavigationRouter.shared.navigate(.myAccount)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.techAccent.opacity(0.15))
                        .frame(width: 56, height: 56)
                    // 默认展示好记AI头像，与首页/我的账号页一致
                    Image("AIAvatar")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }
                .proAvatarBadge(isPro: ent.isPro, badgeDiameter: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的账号")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("昵称、账号信息、退出登录")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(14)
            .background(AIATheme.surface)
        }
        .buttonStyle(.plain)
        .card()
    }

    // MARK: - 外观模式
    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("外观模式")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Picker("外观模式", selection: $appearanceRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(4)
            .background(AIATheme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            Text("可选择浅色、深色，或跟随系统自动切换。修改后立即生效。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - App背景图（进入子页设置，与主页其他入口一致）
    private var backgroundNavRow: some View {
        Button {
            NavigationRouter.shared.navigate(.backgroundSettings)
        } label: {
            HStack {
                Label("App 背景图", systemImage: "photo.fill")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: "crown.fill")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(AIATheme.amber)
                    .accessibilityLabel("Pro 专属")
                Spacer()
                if AppBackgroundStore.shared.isEnabled {
                    Text("已设置")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.muted)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
                    .padding(.leading, 4)
            }
            .padding(14)
            .background(AIATheme.surface)
        }
        .buttonStyle(.plain)
        .card()
    }

    // MARK: - 首页布局（模块排序 / 显示隐藏）
    private var homeLayoutEntry: some View {
        Button {
            NavigationRouter.shared.navigate(.homeLayoutSettings)
        } label: {
            HStack {
                Label("首页布局", systemImage: "square.grid.2x2")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: "crown.fill")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(AIATheme.amber)
                    .accessibilityLabel("Pro 专属")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
                    .padding(.leading, 4)
            }
            .padding(14)
            .background(AIATheme.surface)
        }
        .buttonStyle(.plain)
        .card()
    }

    // MARK: - 识别档位（免费/付费分层）
    private var membershipCard: some View {
        MembershipCompareView(showPaywall: $showPaywall)
    }

    // MARK: - 本月福利（开发者在开发者中心改 N，随 aia_config 动态跟随）
    @ViewBuilder
    private var monthlyBenefitCard: some View {
        let r = ent.freeQuotaRemaining
        let n = cfg.freeQuotaPerMonth
        // 仅"真付费挡"（付费且未开体验模式）展示"已解锁全功能/不限次"；
        // 付费+体验 或 免费用户 都走剩余次数口径，与免费用户对齐。
        if ent.isFullAccess && !ent.simulateFree {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.health)
                    Text("本月福利")
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                Text("已解锁全功能 · 云端识别、云端对话、云同步不限次，畅享所有 Pro 能力。")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineSpacing(2)
            }
            .padding(14)
            .card()
        } else {
            // 免费用户（且开发者已开启免费额度）：右上胶囊=剩余 r 次；副文案=共 N 次，已用 M 次。
            let gRemain = cfg.freeQuotaGlobalRemaining
            let gUsed = cfg.freeQuotaGlobalUsed
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.warn)
                    Text("本月福利")
                        .font(AIATheme.Font.subhead.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if r >= 0 {
                        Text("剩余 \(r) 次")
                            .font(AIATheme.Font.micro.weight(.semibold))
                            .foregroundStyle(AIATheme.warn)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AIATheme.warn.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                if r < 0 {
                    Text("免费云端体验 · 本月不限次（视觉识别、云端对话、云同步等）。")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                        .lineSpacing(2)
                } else {
                    Text("免费云端体验 · 共 \(n) 次，已用 \(max(0, n - r)) 次（用完自动降级到免费版AI识别，本地功能不受影响）。")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                        .lineSpacing(2)
                }
                // 全平台每月上限（成本熔断）：仅当开发者设置了全局额度才展示实时全平台用量。
                if gRemain >= 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.over)
                        Text("全平台本月已用 \(gUsed) 次，剩余 \(gRemain) 次（触顶将暂停所有免费云端功能）。")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.over)
                            .lineSpacing(2)
                    }
                }
            }
            .padding(14)
            .card()
        }
    }

    // MARK: - 截屏自动记账、记待办
    private var screenshotAutoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("设置自动记账、记待办、记饮食")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Button {
                showShortcutGuide = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text("一键设置自动记账、记待办、记饮食")
                }
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(AIATheme.blue)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(AIATheme.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
            Text("开启后，任意界面截屏即会在后台自动识别并归类（账单/待办/饮食/健康），无需打开 App。点击上方按钮跟随引导设置。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 图片自动识别（按类别 自动保存 / 自动弹出）
    private var imageAutoRecogCard: some View {
        VStack(spacing: 0) {
            Button {
                NavigationRouter.shared.navigate(.imageAutoRecogSettings)
            } label: {
                HStack {
                    Label("识别结果设置", systemImage: "photo.badge.checkmark")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("自动保存 · 弹出确认页")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.muted)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                        .padding(.leading, 4)
                }
                .padding(14)
                .background(AIATheme.surface)
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    // MARK: - 新人引导（重新查看）
    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "book.fill")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("新人引导")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Button {
                showOnboarding = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.right.fill")
                    Text("重新查看新人引导")
                }
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(AIATheme.blue)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(AIATheme.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
            Text("第一次打开 App 时的引导，含快捷指令配置说明（截屏自动识别 + 跟小记说一句话记账）。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 关于

    private var aboutCard: some View {
        VStack(spacing: 0) {
            Button {
                NavigationRouter.shared.navigate(.recognitionRecords)
            } label: {
                HStack {
                    Label("识别记录", systemImage: "doc.text.magnifyingglass")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                }
                .padding(14)
                .background(AIATheme.surface)
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 14).background(AIATheme.hairline)

            Button {
                browserTarget = BrowserTarget(url: AppURLs.privacyPolicy)
            } label: {
                HStack {
                    Label("隐私政策", systemImage: "hand.raised.fill")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                }
                .padding(14)
                .background(AIATheme.surface)
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 14).background(AIATheme.hairline)

            Button {
                browserTarget = BrowserTarget(url: AppURLs.userAgreement)
            } label: {
                HStack {
                    Label("用户协议", systemImage: "doc.plaintext.fill")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                }
                .padding(14)
                .background(AIATheme.surface)
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 14).background(AIATheme.hairline)

            Button {
                if MFMailComposeViewController.canSendMail() {
                    showFeedbackMail = true
                } else {
                    feedbackMailUnavailable = true
                }
            } label: {
                HStack {
                    Label("帮助与反馈", systemImage: "envelope.fill")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.muted)
                }
                .padding(14)
                .background(AIATheme.surface)
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 14).background(AIATheme.hairline)

            HStack {
                Label("版本", systemImage: "info.circle")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text("MVP · M5 云同步")
                    .font(AIATheme.Font.footnote)
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(14)
            .background(AIATheme.surface)
            .onLongPressGesture(minimumDuration: 1.2) {
                showPasscode = true
            }
        }
        .card()
    }

    // MARK: - 复制账号标识（白名单录入用）
    private func copyAccountId(_ value: String) {
        UIPasteboard.general.string = value
        toastText = "已复制：\(value.prefix(12))"
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }

    // MARK: - 复制成功提示
    private var copiedToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
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

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

}

    // MARK: - 截屏自动识别引导页
    // iOS 不允许 App 直接安装「带触发器的自动化」，这一步必须用户在快捷指令里手动创建。
    // 但「好记AI自动记账、记待办、记饮食」动作已随 App 自动注册（AppShortcutsProvider），所以搭建时它就在动作区顶部，
    // 用户只需选「截屏」触发器 + 关掉「运行前询问」即可，约 20 秒。
    struct ScreenshotAutomationGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(icon: String, title: String, detail: String)] = [
        ("plus.circle.fill", "新建个人自动化",
         "打开快捷指令 App → 底部「自动化」→ 右上「+」→ 选「创建个人自动化」。"),
        ("camera.viewfinder", "选择「截屏」触发",
         "在触发列表里找到并选择「截屏」，点「下一步」。"),
        ("text.viewfinder", "添加「好记AI自动记账、记待办、记饮食」动作",
         "点「添加操作」，搜索「好记AI自动记账、记待办、记饮食」（本 App 已自动注册，通常直接就在顶部），点它加入。"),
        ("bolt.slash.fill", "关掉「运行前询问」",
         "点「下一步」，关闭「运行前询问」开关并确认。这样截屏后才会静默运行、真正无感。")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 顶部说明
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.viewfinder")
                                .font(AIATheme.Font.title2.weight(.semibold))
                                .foregroundStyle(AIATheme.blue)
                            Text("设置截屏自动识别")
                                .font(AIATheme.Font.title3.weight(.bold))
                        }
                        Text("「好记AI自动记账、记待办、记饮食」动作已随 App 自动装好。只差最后一步——由你在快捷指令里绑定「截屏」触发器（iOS 规定自动化只能本人手动创建）。跟着下面 4 步，约 20 秒完成。")
                            .font(AIATheme.Font.footnote)
                            .foregroundStyle(AIATheme.sub)
                            .lineSpacing(3)
                    }
                    .padding(14)
                    .card()

                    // 步骤列表
                    VStack(spacing: 0) {
                        ForEach(0..<steps.count, id: \.self) { i in
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(AIATheme.blue.opacity(0.12))
                                        .frame(width: 34, height: 34)
                                    Text("\(i + 1)")
                                        .font(AIATheme.Font.callout.weight(.bold))
                                        .foregroundStyle(AIATheme.blue)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: steps[i].icon)
                                            .font(AIATheme.Font.footnote)
                                            .foregroundStyle(AIATheme.blue)
                                        Text(steps[i].title)
                                            .font(AIATheme.Font.callout.weight(.semibold))
                                            .foregroundStyle(.primary)
                                    }
                                    Text(steps[i].detail)
                                        .font(AIATheme.Font.footnote)
                                        .foregroundStyle(AIATheme.sub)
                                        .lineSpacing(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            if i < steps.count - 1 {
                                Divider().padding(.leading, 46).background(AIATheme.hairline)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .card()

                    // 打开快捷指令 App 按钮
                    Button {
                        openShortcutsApp()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(AIATheme.Font.title3.weight(.medium))
                            Text("打开快捷指令 App")
                                .font(AIATheme.Font.body.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(AIATheme.Font.footnote.weight(.semibold))
                                .opacity(0.7)
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(LinearGradient.techAccent)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
                    }
                    .buttonStyle(.plain)

                    // 提示
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(AIATheme.warn)
                        Text("设置一次即可长期生效。之后正常截屏 → 后台静默识别 → 收到「识别完成」通知 → 打开本 App 自动弹确认页，改字段点「存入」即可。")
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(AIATheme.muted)
                            .lineSpacing(2)
                    }
                    .padding(12)
                    .background(AIATheme.warn.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                .padding(16)
            }
            .background(AIATheme.fillSoft)
            .navigationTitle("截屏自动识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func openShortcutsApp() {
        // shortcuts:// 打开快捷指令 App；iOS 无「直接新建自动化」的公开 URL，
        // 打开后按引导切到「自动化」标签即可。
        if let url = URL(string: "shortcuts://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
