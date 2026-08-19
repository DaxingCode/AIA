// DeveloperCenterView.swift
// 开发者中心：解锁后展示的高级功能入口页。广告管理、Agent、AI 模型等高级功能从这里进入，便于后续扩展。
import SwiftUI
import UserNotifications

struct DeveloperCenterView: View {
    @Environment(\.dismiss) private var dismiss

    // 全局配置改为云端权威：开发者切换后写入云端，所有用户自动跟随。
    // 不再用 @AppStorage 直写本地，统一走 GlobalConfigStore（写云端 + 本地缓存）。
    @ObservedObject private var global = GlobalConfigStore.shared

    @State private var showTesters = false
    @State private var showFreeQuota = false
    @State private var showBillTest = false

    // 免费体验调试
    @ObservedObject private var ent = EntitlementManager.shared
    @State private var customTrialDate: Date = Date()
    // >>> CHANGE-[2026-08-19 20:55:27]-试用天数云端化 开始
    // 原因: 开发者中心新增"试用天数配置"(云端全局下发), 编辑值初始取当前全局天数
    // 回退: 删除本行 + trialDaysConfigCard + body 插入行
    @State private var trialDaysEdit: Int = GlobalConfigStore.shared.trialDays
    // <<< CHANGE-[2026-08-19 20:55:27]-试用天数云端化 结束

    // 群发公告（方案 B 云端公告 + 方案 A APNs 远程推送）
    @State private var showAnnouncement = false
    @State private var broadcastBusy = false

    // 仅 APNs 远程推送（独立通道，不写首页公告）
    @State private var showAPNsPush = false
    @State private var showBroadcastHistory = false

    // 协议链接配置（方式 B：云端写入，普通用户无入口）
    @State private var privacyUrlText: String = ""
    @State private var agreementUrlText: String = ""
    @State private var featureIntroUrlText: String = ""
    @State private var agreementBusy = false

    // 智能问答开关（写云端）
    private var agentBinding: Binding<Bool> {
        Binding(get: { global.agentEnabled },
                set: { nv in
                    global.agentEnabled = nv
                    Task { await global.saveConfig(agentEnabled: nv, modelProvider: global.modelProvider, visionModelProvider: global.visionModelProvider) }
                })
    }
    // 问答 / Agent 文本模型（写云端）
    private var modelBinding: Binding<String> {
        Binding(get: { global.modelProvider },
                set: { nv in
                    global.modelProvider = nv
                    Task { await global.saveConfig(agentEnabled: global.agentEnabled, modelProvider: nv, visionModelProvider: global.visionModelProvider) }
                })
    }
    // 截图识别视觉模型（写云端）
    private var visionBinding: Binding<String> {
        Binding(get: { global.visionModelProvider },
                set: { nv in
                    global.visionModelProvider = nv
                    Task { await global.saveConfig(agentEnabled: global.agentEnabled, modelProvider: global.modelProvider, visionModelProvider: nv) }
                })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                adManagerEntry
                syncSettingsEntry
                dataStatsEntry
                agentCard
                modelProviderCard
                agreementUrlCard
                testNotifyCard
                announcementCard
                apnsPushCard
                testerManagerEntry
                freeQuotaEntry
                liveActivityDemoCard
                screenshotPaywallDemoCard
                trialDaysConfigCard
                trialTestCard
                freeSimulateCard
                resetNewUserCard
                billTestEntry
                // 后续新增开发者功能在这里加卡片即可
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(AIATheme.fillSoft)
        .navigationTitle("开发者中心")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTesters) { NavigationStack { TesterManagerView() } }
        .sheet(isPresented: $showFreeQuota) { FreeQuotaConfigView() }
        .sheet(isPresented: $showBillTest) { BillRecognitionTestView() }
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
            .contentShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .onTapGesture {
                ReminderNotificationManager.sendTest(after: 5) { ok in
                    if ok {
                        ToastCenter.shared.show("测试通知已安排，5 秒后弹出")
                    } else {
                        ToastCenter.shared.show("未开启通知权限，请到系统设置开启")
                    }
                }
            }
            Text("点击后 5 秒弹出一条本地通知。可切到后台或锁屏查看效果；若无反应，请到 iPhone「设置 → 通知 → 好记」确认已允许通知。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 群发公告（方案 B 云端公告 + 方案 A APNs 远程推送）
    private var announcementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("群发通知")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                // 当前已发布公告状态
                if let ann = global.announcement {
                    Text(ann.isEffective ? "生效中" : "未到/已过期")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(ann.isEffective ? AIATheme.green : AIATheme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((ann.isEffective ? AIATheme.green : AIATheme.muted).opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            if let ann = global.announcement {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ann.title).font(AIATheme.Font.subhead.weight(.semibold)).foregroundStyle(.primary)
                    Text(ann.body).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted).lineSpacing(2)
                    if let r = ann.route?.nonEmpty {
                        Text("跳转：\(r)").font(AIATheme.Font.micro).foregroundStyle(AIATheme.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AIATheme.fillSoft)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            HStack(spacing: 10) {
                Button {
                    showAnnouncement = true
                } label: {
                    Text(global.announcement == nil ? "发布通知" : "编辑 / 重发")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(AIATheme.purple)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
                if global.announcement != nil {
                    Button {
                        Task {
                            let ok = await global.saveAnnouncement(nil)
                            ToastCenter.shared.show(ok ? "已撤销当前公告" : "撤销失败")
                        }
                    } label: {
                        Text("撤销")
                            .font(AIATheme.Font.subhead.weight(.medium))
                            .foregroundStyle(AIATheme.over)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(AIATheme.over.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                }
            }
            Text("发布后所有用户下次打开 App 会在首页看到公告横条；勾选「同时 APNs 推送」的用户锁屏也能收到横幅（需真机授权通知）。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
        .sheet(isPresented: $showAnnouncement) { AnnouncementEditorView(busy: $broadcastBusy) }
        .sheet(isPresented: $showAPNsPush) { APNsPushEditorView(busy: $broadcastBusy) }
    }

    // MARK: - 仅 APNs 远程推送（独立通道，不写首页公告横条）
    private var apnsPushCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("APNs 远程推送")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text("只发锁屏推送（不显示首页横条）")
            }
            .font(AIATheme.Font.subhead.weight(.medium))
            .foregroundStyle(AIATheme.purple)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(AIATheme.purple.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .contentShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .onTapGesture { showAPNsPush = true }
            Text("独立通道：仅向已授权通知的真机设备发送锁屏横幅，不影响首页公告横条。支持按目标页、发送环境、指定账号筛选，适合临时提醒、紧急通知等无需常驻首页的场景。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
            Divider().padding(.vertical, 4)
            Button {
                showBroadcastHistory = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("推送记录")
                }
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(AIATheme.blue)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(AIATheme.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
        }
        .padding(14)
        .card()
        .sheet(isPresented: $showBroadcastHistory) { BroadcastHistoryView() }
    }

    // MARK: - 广告管理入口
    private var adManagerEntry: some View {
        Button {
            NavigationRouter.shared.navigate(.adManager)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .fill(AIATheme.purple.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.purple)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("广告管理")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("配置首页轮播广告位")
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

    // MARK: - 同步设置入口
    private var syncSettingsEntry: some View {
        Button {
            NavigationRouter.shared.navigate(.autoSyncSettings)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .fill(AIATheme.blue.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("自动同步设置")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("自动同步开关、立即同步、强制恢复、查看同步状态")
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

    // MARK: - 数据统计与导出入口
    private var dataStatsEntry: some View {
        Button {
            NavigationRouter.shared.navigate(.dataStatsExport)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .fill(AIATheme.blue.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("数据统计与导出")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("全部用户的活跃度与功能热度，可导出 CSV")
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
                Toggle("智能问答 Agent", isOn: agentBinding)
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
                Picker("问答模型", selection: modelBinding) {
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
                Picker("识别模型", selection: visionBinding) {
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

    // MARK: - 协议链接配置（方式 B：云端写入，普通用户无入口）
    private var agreementUrlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("协议链接")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("隐私政策 / 用户协议在 App 内的跳转地址。留空=沿用 App 内置默认域名。改后所有用户下次启动自动生效，无需发版。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
            VStack(alignment: .leading, spacing: 4) {
                Text("隐私政策 URL")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                TextField("留空=默认域名", text: $privacyUrlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("用户协议 URL")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                TextField("留空=默认域名", text: $agreementUrlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("App 功能介绍 URL（首页灯泡按钮）")
                    .font(AIATheme.Font.micro.weight(.medium))
                    .foregroundStyle(AIATheme.muted)
                TextField("留空=默认微信文章", text: $featureIntroUrlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                Task {
                    agreementBusy = true
                    let ok1 = await global.saveAgreementUrls(privacyPolicyUrl: privacyUrlText,
                                                             userAgreementUrl: agreementUrlText)
                    let ok2 = await global.saveFeatureIntroUrl(featureIntroUrlText)
                    agreementBusy = false
                    ToastCenter.shared.show(ok1 && ok2 ? "已保存链接" : "保存失败")
                }
            } label: {
                if agreementBusy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("保存到云端")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(AIATheme.blue)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
            }
            .disabled(agreementBusy)
        }
        .padding(14)
        .card()
        .onAppear {
            privacyUrlText = global.privacyPolicyUrl?.absoluteString ?? ""
            agreementUrlText = global.userAgreementUrl?.absoluteString ?? ""
            featureIntroUrlText = global.featureIntroUrl?.absoluteString ?? ""
        }
    }

    // MARK: - 测试账号管理
    private var testerManagerEntry: some View {
        Button {
            showTesters = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .fill(AIATheme.purple.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.badge.key.fill")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.purple)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("测试账号管理")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("增删白名单：测试 / 审核 / 内部账号可全功能")
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

    // MARK: - 免费额度配置
    private var freeQuotaEntry: some View {
        Button {
            showFreeQuota = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .fill(AIATheme.blue.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "gift.fill")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("免费额度配置")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("每月 N 次 / 权重 / 全局月度熔断")
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

    // MARK: - 灵动岛 Demo
    private var liveActivityDemoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("灵动岛 Demo")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            demoRow(icon: "island", title: "启动 Demo 灵动岛") { startDemoIsland() }
            demoRow(icon: "arrow.2.circlepath", title: "启动轮播总览 Demo") { startCarouselDemo() }
            Text("真机点按后：灵动岛展开「识别中」，5 秒后收缩为「🧾 ¥42」，12 秒后自动收起；轮播 Demo 则在锁屏横幅 / 灵动岛轮播 账单·待办·健康·饮食 四类数据（每 4 秒一切）。模拟器不显示灵动岛，仅预览锁屏横幅。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    /// 单条可点按的 Demo 按钮行
    private func demoRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
        }
        .font(AIATheme.Font.subhead.weight(.medium))
        .foregroundStyle(AIATheme.blue)
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(AIATheme.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .contentShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
        .onTapGesture(perform: action)
    }

    private func startDemoIsland() {
        LiveActivityManager.shared.start(kind: "recognition",
                                         state: .init(phase: "ocr", recognitionTitle: "午餐"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Task { @MainActor in
                LiveActivityManager.shared.update(kind: "recognition",
                                                  state: .init(phase: "done", recognitionTitle: "午餐", recognitionAmount: 42.5))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            Task { @MainActor in
                LiveActivityManager.shared.end(kind: "recognition")
            }
        }
        ToastCenter.shared.show("灵动岛已启动，看一眼真机顶部")
    }

    private func startCarouselDemo() {
        LiveActivityManager.shared.startCarousel(interval: 4)
        ToastCenter.shared.show("轮播总览已启动：账单→待办→健康→饮食")
    }

    // MARK: - 批量识别测试（本机调试）
    private var billTestEntry: some View {
        Button {
            showBillTest = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .fill(AIATheme.green.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.green)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("批量识别测试")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("喂「支付截图/」目录批量跑识别，验证金额/时间（本机调试）")
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

    // MARK: - 模拟截屏付费墙拦截 Demo
    /// 复现「后台截屏被免费版付费墙拦截」的完整链路，方便真机验证：
    /// 存付费墙标记 → 发「识别遇到限制」通知 → 前台 post .screenshotRecognitionReady
    /// 让 ContentView.checkScreenshotPending 识别到 isPaywallBlocked，回插「升级 Pro」气泡并跳对话页。
    private var screenshotPaywallDemoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模拟截屏付费墙拦截")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("写入付费墙标记并跳对话页")
            }
            .font(AIATheme.Font.subhead.weight(.medium))
            .foregroundStyle(AIATheme.warn)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(AIATheme.warn.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .contentShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            .onTapGesture(perform: simulateScreenshotPaywall)
            Text("等价于后台识别被免费版拦截后主 App 打开时的表现：对话页出现「升级 Pro」引导气泡并自动跳转。可配合「免费版体验模式」复现真实免费用户场景。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    private func simulateScreenshotPaywall() {
        // 1. 存一条带付费墙标记的 pending（等价 ScreenshotIntent.perform 的兜底分支）
        ScreenshotStore.savePaywallBlocked(imageData: nil)
        // 2. 发一条友好「识别遇到限制」通知（等价 notifyPaywallBlocked），点它也能走 route 进对话页
        let content = UNMutableNotificationContent()
        content.title = "识别遇到限制"
        content.body = "这张图片需要 Pro 会员才能识别，点开详情可查看并升级解锁。"
        content.userInfo["route"] = "screenshotRecognition"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
        // 3. 前台立即刷新：触发 ContentView.checkScreenshotPending(navigateToChat: true)，
        //    识别到 isPaywallBlocked → 回插「升级 Pro」气泡 + 跳对话页。
        NotificationCenter.default.post(name: .screenshotRecognitionReady, object: nil)
        NavigationRouter.shared.navigate(.chat)
        ToastCenter.shared.show("已写入付费墙标记，进入对话页查看升级引导")
    }

    // >>> CHANGE-[2026-08-19 20:55:27]-试用天数云端化 开始
    // 原因: 全局试用天数云端配置卡——写入后所有用户下次拉取跟随(方案X)
    // 回退: 删除本卡片 + body 里的 trialDaysConfigCard 行
    // MARK: - 试用天数配置（云端全局下发，所有用户跟随）
    private var trialDaysConfigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("试用天数配置")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text("全局 \(global.trialDays) 天")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.blue)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(AIATheme.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
            Text("写入云端后，所有用户下次启动/回前台拉取生效。已开始体验的用户按 max(开始锁定天数, 当前全局天数) 计算：只延长不缩短。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
            HStack {
                Stepper(value: $trialDaysEdit, in: 1...365) {
                    Text("\(trialDaysEdit) 天")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding(10)
            .background(AIATheme.fillSoft)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            demoRow(icon: "icloud.and.arrow.up", title: "写入云端（所有用户生效）") {
                Task {
                    if await global.saveTrialDays(trialDaysEdit) {
                        ToastCenter.shared.show("已写入云端：免费体验 \(trialDaysEdit) 天")
                    } else {
                        ToastCenter.shared.show("写入失败：请检查口令/网络")
                    }
                }
            }
            demoRow(icon: "arrow.counterclockwise", title: "重置为默认 7 天") {
                trialDaysEdit = 7
                Task {
                    if await global.saveTrialDays(7) {
                        ToastCenter.shared.show("已重置：免费体验 7 天")
                    }
                }
            }
        }
        .padding(14)
        .card()
    }
    // <<< CHANGE-[2026-08-19 20:55:27]-试用天数云端化 结束

    // MARK: - 免费体验调试
    /// 集中操控试用起点（Keychain trial_start_at），方便在「试用中 / 临界 / 已过期」间随时切换，无需真实等 N 天或重装。
    private var trialTestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("免费体验 \(ent.trialDaysLimit) 天调试")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                // 当前状态胶囊
                Text(ent.trialActive ? "试用中" : (ent.trialStartAt == nil ? "未设置" : "已过期"))
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(ent.trialActive ? AIATheme.green : AIATheme.over)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((ent.trialActive ? AIATheme.green : AIATheme.over).opacity(0.12))
                    .clipShape(Capsule())
            }
            // 当前起点 + 剩余天数
            if let start = ent.trialStartAt {
                HStack(spacing: 6) {
                    Text("当前起点：\(Self.trialDateFmt.string(from: Date(timeIntervalSince1970: start)))")
                    Spacer()
                    Text("剩余 \(ent.trialRemainingDays) 天")
                        .foregroundStyle(ent.trialActive ? AIATheme.green : AIATheme.over)
                }
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            } else {
                Text("当前起点：未设置（首次登录并同步后会自动记入 \(EntitlementManager.trialDays) 天）")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
            // 一键预设
            demoRow(icon: "clock.arrow.circlepath", title: "重置为现在（进入试用）") {
                ent.setTrialStart()
                ToastCenter.shared.show("试用起点已设为现在，进入 \(ent.trialDaysLimit) 天试用")
            }
            demoRow(icon: "clock.badge.xmark", title: "设为 \(ent.trialDaysLimit + 1) 天前（模拟过期）") {
                ent.setTrialStart(Date().addingTimeInterval(-Double(ent.trialDaysLimit + 1) * 86400))
                ToastCenter.shared.show("已模拟过期：试用窗口已结束")
            }
            demoRow(icon: "clock.badge.checkmark", title: "设为 \(max(1, ent.trialDaysLimit - 1)) 天前（临界验证）") {
                ent.setTrialStart(Date().addingTimeInterval(-Double(max(1, ent.trialDaysLimit - 1)) * 86400))
                ToastCenter.shared.show("已设为临界：仍在 \(ent.trialDaysLimit) 天窗口内")
            }
            // 自定义起点
            HStack(spacing: 8) {
                DatePicker("自定义起点", selection: $customTrialDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .font(AIATheme.Font.micro)
                    .tint(AIATheme.blue)
                Spacer()
                Text("应用")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(AIATheme.blue)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    .contentShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    .onTapGesture {
                        ent.setTrialStart(customTrialDate)
                        ToastCenter.shared.show("已写入自定义试用起点")
                    }
            }
            .padding(10)
            .background(AIATheme.fillSoft)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            // 清除（模拟卸载重装）
            demoRow(icon: "trash", title: "清除试用起点（卸载式重计）") {
                ent.clearTrialStart()
                ToastCenter.shared.show("已清除；下次冷启会重新记入 \(EntitlementManager.trialDays) 天")
            }
            Text("操作后权益快照会自动刷新，可配合「会员对比页」查看档位（trial / 过期），或触发云识别观察付费墙本地降级；过期后即使有免费额度，云同步 push 也会被挡。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 免费版体验模式（独立总开关，模拟纯免费档，真实权益不受影响）
    /// 从「设置页」迁移至此：开发者中心天然只对解锁者可见，与「免费体验 30 天调试」同属会员模拟工具。
    private var freeSimulateCard: some View {
        let on = Binding<Bool>(
            get: { EntitlementManager.shared.simulateFree },
            set: { EntitlementManager.shared.simulateFree = $0 }
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("免费版体验模式")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Toggle("", isOn: on)
                    .labelsHidden()
            }
            Text("开启后，本机将模拟「纯免费版」：云端识别、对话、同步与备份均不可用；首页布局自定义、背景图等 Pro 专属功能也会暂时锁定，仅本地基础功能（OCR / 端侧模型 / 离线记账）可演示。这不影响你的真实订阅或试用权益，关闭即恢复。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
            if on.wrappedValue {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.blue)
                    Text("体验模式已开启：当前所有云端功能在本机被禁用。")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.blue)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AIATheme.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 恢复新用户状态（模拟首次安装）
    /// 复现「新用户首次打开 App」：复位新人引导 + 首启类开关（轻量）或连同登录态一并清空（彻底）。
    /// 注意：不涉及 SwiftData 业务数据清空（账单/待办等仍需靠模拟器 `xcrun simctl erase`），避免运行中 @Query 页面崩溃。
    private var resetNewUserCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("恢复新用户状态")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            demoRow(icon: "sparkles", title: "轻量复位（重新弹新人引导）") { resetOnboardingOnly() }
            demoRow(icon: "arrow.counterclockwise.circle", title: "彻底重置（模拟卸载重装）") { resetAsFreshInstall() }
            Text("轻量复位：仅把新人引导等首次类开关改回「未看过」，杀掉 App 冷启即可重新看到 12 页引导，登录态与数据都保留。彻底重置：额外清掉 Keychain 登录态 + 登录标记，冷启将走「未登录 → 登录页 → 新人引导」全流程。两种都不清空业务数据（账单/待办/饮食等），彻底清空请到模拟器用 `xcrun simctl erase` 整机重置。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    /// 轻量：只复位首启类本地开关（不清登录、不清数据），下次冷启重新弹新人引导。
    private func resetOnboardingOnly() {
        let ud = UserDefaults.standard
        ud.set(false, forKey: "aia.onboardingDone")
        ud.synchronize()
        ToastCenter.shared.show("已复位新人引导，杀掉 App 重新冷启即可看到")
    }

    /// 彻底：模拟卸载重装——清登录态(Keychain) + 首启开关，下次冷启走登录页→引导。
    private func resetAsFreshInstall() {
        let ud = UserDefaults.standard
        ud.set(false, forKey: "aia.onboardingDone")
        ud.set(false, forKey: "aia.isLoggedIn")
        ud.synchronize()
        // 清 Keychain 身份并切回登录界面（logout 内部已调 switchToLoginInterface）。
        AuthManager.shared.logout()
        ToastCenter.shared.show("已模拟重装：杀掉 App 冷启将走登录页→新人引导")
    }

    private static let trialDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
