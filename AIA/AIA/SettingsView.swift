// SettingsView.swift
// 云同步设置：同步账号、自动同步开关、立即同步、上次同步时间。
import SwiftUI
import SwiftData
import Combine
import PhotosUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    @StateObject private var sync = CloudSyncManager.shared

    @AppStorage("userNickname") private var userNickname = "阿宝的朋友"
    // 外观模式：浅色 / 深色 / 跟随系统（写 UserDefaults，ContentView 读取并应用到全窗口）
    @AppStorage("aia.appearance") private var appearanceRaw = "system"
    // 智能问答 Agent 总开关（与「云同步」同组）。默认关，零污染。
    @AppStorage("aia.agentEnabled") private var agentEnabled = false
    // 模型供应商选择（云端 PROVIDERS 已配齐五家文字+视觉，前端只传 provider 标识）。默认智谱 GLM。
    @AppStorage("aia.modelProvider") private var modelProvider = "glm"
    // 视觉识别模型单独选择（截图理解），默认智谱 GLM，与文本模型解耦。
    @AppStorage("aia.visionModelProvider") private var visionModelProvider = "glm"
    @State private var showCopied = false
    @State private var toastText = "已复制同步账号"
    @State private var showShortcutGuide = false
    @State private var showOnboarding = false
    // 背景图选择
    @State private var bgPicker: PhotosPickerItem?
    @State private var bgPreview: UIImage?
    @State private var bgEnabled: Bool = AppBackgroundStore.shared.isEnabled
    // 开发者模式口令
    @State private var showPasscode = false
    @State private var passcodeText = ""
    @State private var devUnlocked: Bool = DeveloperGate.isUnlocked
    @State private var devNavigate = false

    var body: some View {
        // 注意：本页由首页 navigationDestination(for:) push 进来，
        // 绝不能再自带 NavigationStack（栈中栈 → 首次点无反应、二次点崩溃）。
        // 内部的 NavigationLink 会自动依附首页那一个 NavigationStack。
        ScrollView {
            VStack(spacing: 16) {
                myAccountEntry
                appearanceCard
                backgroundCard
                homeLayoutEntry
                tierCard
                autoSyncSettingsCard
                agentCard
                modelProviderCard
                screenshotAutoCard
                imageAutoRecogCard
                reminderCard
                testNotifyCard
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
        .onTapGesture {
            hideKeyboard()
        }
        .background(AIATheme.fillSoft)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $devNavigate) { AdManagerView() }
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
        .alert("解锁开发者模式", isPresented: $showPasscode) {
            SecureField("输入口令", text: $passcodeText)
            Button("取消", role: .cancel) { passcodeText = "" }
            Button("确认") {
                if passcodeText == DeveloperGate.passcode {
                    DeveloperGate.isUnlocked = true
                    devUnlocked = true
                    devNavigate = true
                }
                passcodeText = ""
            }
        } message: {
            Text("长按版本号可解锁广告管理与开发者工具。")
        }
    }

    // MARK: - 我的账号入口（聚合昵称 + 账号信息 + 退出登录）
    private var myAccountEntry: some View {
        NavigationLink {
            MyAccountView()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.techAccent.opacity(0.15))
                        .frame(width: 56, height: 56)
                    // 默认展示阿宝头像，与首页/我的账号页一致
                    Image("AIAvatar")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(userNickname.isEmpty ? "阿宝的朋友" : userNickname)
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

    // MARK: - App 背景图（用户本人从相册换图，仅本机）

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "photo.fill")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.purple)
                Text("App 背景图")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if bgEnabled {
                    Button {
                        AppBackgroundStore.shared.reset()
                        bgEnabled = false
                        bgPreview = nil
                    } label: {
                        Text("恢复默认").font(AIATheme.Font.footnote).foregroundStyle(AIATheme.blue)
                    }
                }
            }

            if let img = bgPreview ?? AppBackgroundStore.shared.loadImage() {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(height: 120).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }

            PhotosPicker(selection: $bgPicker, matching: .images) {
                Label(bgEnabled ? "更换背景图" : "从相册选择背景图",
                      systemImage: "photo.on.rectangle.angled")
                    .font(AIATheme.Font.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }

            if bgEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("遮罩浓度（保证文字可读）：\(Int(AppBackgroundStore.shared.maskOpacity * 100))%")
                        .font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted)
                    Slider(value: Binding(
                        get: { AppBackgroundStore.shared.maskOpacity },
                        set: { AppBackgroundStore.shared.maskOpacity = $0 }
                    ), in: 0...0.85)
                }
            }

            Text("仅首页与聊天页生效；图片仅保存在本机，不会上传。")
                .font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted).lineSpacing(2)
        }
        .padding(14)
        .card()
        .onChange(of: bgPicker) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    AppBackgroundStore.shared.save(img)
                    bgEnabled = true
                    bgPreview = img
                }
                bgPicker = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiaBackgroundChanged)) { _ in
            bgEnabled = AppBackgroundStore.shared.isEnabled
            bgPreview = AppBackgroundStore.shared.loadImage()
        }
    }

    // MARK: - 首页布局（模块排序 / 显示隐藏）
    private var homeLayoutEntry: some View {
        NavigationLink {
            HomeLayoutSettingsView()
        } label: {
            HStack {
                Label("首页布局", systemImage: "square.grid.2x2")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
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
    private var tierCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag.circle.fill")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("识别档位")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Picker("识别档位", selection: tierBinding) {
                ForEach(UserTier.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(4)
            .background(AIATheme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))

            if let remaining = AppUserTier.freeUsageRemaining {
                HStack(spacing: 6) {
                    Image(systemName: "cloud.fill")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                    Text("本月云端识别剩余 \(remaining) 次 · 免费版仅本地+文本模型，不发的图")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                }
                .lineSpacing(2)
            } else {
                Text("付费版：复杂图片（食物照片、模糊小票）走云端视觉识别，准确率最高；本地不发的图也能尽量准。")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .card()
    }

    private var tierBinding: Binding<UserTier> {
        Binding(
            get: { AppUserTier.current },
            set: { AppUserTier.current = $0 }
        )
    }

    // MARK: - 自动同步设置
    private var autoSyncSettingsCard: some View {
        NavigationLink {
            AutoSyncSettingsView()
        } label: {
            HStack {
                Label("自动同步设置", systemImage: "arrow.triangle.2.circlepath")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(sync.status)
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
        .card()
    }

    // MARK: - 智能问答 Agent（可单独开关）
    private var agentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("智能问答 Agent")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("智能问答 Agent", isOn: $agentEnabled)
                    .labelsHidden()
            }
            Text("开启后，对话页的问答由 AI 基于你的记录智能回答（只读，不会改动任何数据）。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 模型供应商选择（文本 / 视觉独立切换，零污染云端）
    private var modelProviderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("AI 模型")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("问答与截图识别可分别选择模型（默认均为智谱 GLM）。需在云端对应环境变量已配置该供应商 Key。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
            // 文本模型（问答 / Agent）
            VStack(alignment: .leading, spacing: 4) {
                Text("问答 / Agent 模型")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                Picker("问答模型", selection: $modelProvider) {
                    ForEach(AIAModelProvider.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(AIATheme.blue)
            }
            // 视觉模型（截图识别）。仅展示支持视觉的 provider，过滤掉 DeepSeek（仅文字）。
            VStack(alignment: .leading, spacing: 4) {
                Text("截图识别模型")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                Picker("识别模型", selection: $visionModelProvider) {
                    ForEach(AIAModelProvider.visionCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(AIATheme.blue)
            }
            Text("DeepSeek 仅支持文字，对话体验更好但不能用于截图识别（视觉 Picker 已自动隐藏）。Agent 模式推荐用 DeepSeek，function-calling 准确度高于其他。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
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
            NavigationLink {
                ImageAutoRecogSettingsView()
            } label: {
                HStack {
                    Label("图片自动识别", systemImage: "photo.badge.checkmark")
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

    // MARK: - 待办提醒
    private var reminderCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                DefaultReminderSettingsView()
            } label: {
                HStack {
                    Label("默认提醒时间", systemImage: "bell.badge")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(DefaultReminderSettings.shared.summary)
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

    // MARK: - 测试通知
    private var testNotifyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("通知测试")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Button {
                ReminderNotificationManager.sendTest(after: 5) { ok in
                    if ok {
                        showToast("测试通知已安排，5 秒后弹出")
                    } else {
                        showToast("未开启通知权限，请到系统设置开启")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                    Text("发送测试通知")
                }
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(AIATheme.blue)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(AIATheme.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
            Text("点击后 5 秒弹出一条本地通知。可切到后台或锁屏查看效果；若无反应，请到 iPhone「设置 → 通知 → 阿宝AI管家」确认已允许通知。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
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
            Text("第一次打开 App 时的引导，含快捷指令配置说明（截屏自动识别 + 跟阿宝说一句话记账）。")
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
            NavigationLink {
                RecognitionRecordsView()
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

            Divider().padding(.leading, 14).background(AIATheme.hairline)

            Link(destination: URL(string: "https://www.cloudbase.net/")!) {
                HStack {
                    Label("CloudBase 文档", systemImage: "doc.text")
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
        }
        .card()
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

    private func showToast(_ text: String) {
        toastText = text
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCopied = false }
    }
}

    // MARK: - 截屏自动识别引导页
    // iOS 不允许 App 直接安装「带触发器的自动化」，这一步必须用户在快捷指令里手动创建。
    // 但「阿宝AI自动记账、记待办、记饮食」动作已随 App 自动注册（AppShortcutsProvider），所以搭建时它就在动作区顶部，
    // 用户只需选「截屏」触发器 + 关掉「运行前询问」即可，约 20 秒。
    struct ScreenshotAutomationGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(icon: String, title: String, detail: String)] = [
        ("plus.circle.fill", "新建个人自动化",
         "打开快捷指令 App → 底部「自动化」→ 右上「+」→ 选「创建个人自动化」。"),
        ("camera.viewfinder", "选择「截屏」触发",
         "在触发列表里找到并选择「截屏」，点「下一步」。"),
        ("text.viewfinder", "添加「阿宝AI自动记账、记待办、记饮食」动作",
         "点「添加操作」，搜索「阿宝AI自动记账、记待办、记饮食」（本 App 已自动注册，通常直接就在顶部），点它加入。"),
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
                        Text("「阿宝AI自动记账、记待办、记饮食」动作已随 App 自动装好。只差最后一步——由你在快捷指令里绑定「截屏」触发器（iOS 规定自动化只能本人手动创建）。跟着下面 4 步，约 20 秒完成。")
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
