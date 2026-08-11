// MyAccountView.swift
// 「我的账号」详情页：聚合昵称编辑、账号信息（登录方式 + 手机号）与退出登录。
// 由 SettingsView 的「我的账号」入口 NavigationLink push 进入，
// 因此本页不能再自带 NavigationStack（避免栈中栈）。
import SwiftUI
import SwiftData

struct MyAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: AuthManager
    @ObservedObject private var ent = EntitlementManager.shared
    @ObservedObject private var sync = CloudSyncManager.shared

    @AppStorage("userNickname") private var userNickname = "小记的朋友"
    @State private var showLinkSheet = false

    // iCloud 备份相关状态（本机备份/重装恢复，与腾讯云跨端同步并存互补）
    @AppStorage(ICloudBackupManager.enabledKey) private var icloudEnabled = true
    @State private var icloudAvailable: Bool = false
    @State private var icloudBusy: Bool = false
    @State private var uploadProgress: (uploaded: Int, total: Int)? = nil
    @State private var lastBackup: Date? = nil
    @State private var backupCount: Int = 0
    @State private var showRestoreConfirm: Bool = false
    @State private var showDeleteSheet: Bool = false
    @State private var deleteConfirmText: String = ""
    @State private var deleting: Bool = false
    @State private var showCopied = false
    @State private var toastText = "已复制同步账号"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                profileHeader
                nicknameEditCard
                autoSyncSettingsCard
                icloudBackupCard
                accountInfoCard
                accountLinkCard
                logoutCard
                deleteCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showLinkSheet) {
            AccountLinkView()
                .environmentObject(auth)
        }
        .scrollDismissesKeyboard(.immediately)
        .onTapGesture { hideKeyboard() }
        .background(AIATheme.fillSoft)
        .overlay(alignment: .top) {
            if showCopied {
                copiedToast
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(), value: showCopied)
            }
        }
        .navigationTitle("我的账号")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: userNickname) { _, _ in
            // 记录修改时间并触发增量同步。昵称同时经 backupIdentityProfile 冗余备份到「登录账号分区」
            // （与小程序绑定码合并为同一 profile 记录），重装后重登同一账号即自动回写，避免分区错位丢失。
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "userNicknameUpdatedAt")
            CloudSyncManager.shared.syncAfterLocalChange(context: modelContext)
            CloudSyncManager.backupIdentityProfile()
        }
        .sheet(isPresented: $showDeleteSheet) {
            NavigationStack {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                        .padding(.top, 24)
                    Text("删除账户")
                        .font(AIATheme.Font.title2.weight(.semibold))
                    Text("此操作不可恢复，将永久删除你的所有云端与本地数据。\n若你已订阅会员，请先到系统「设置 → Apple ID → 订阅」取消订阅，否则 Apple 会继续扣费。")
                        .font(AIATheme.Font.callout)
                        .foregroundStyle(AIATheme.muted)
                        .multilineTextAlignment(.center)
                    TextField("请输入「删除」以确认", text: $deleteConfirmText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(AIATheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    Button {
                        showDeleteSheet = false
                        performDeleteAccount()
                    } label: {
                        if deleting { ProgressView().tint(.white) }
                        else { Text("确认删除") }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(deleteConfirmText == "删除" && !deleting ? Color.red : Color.red.opacity(0.4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    .disabled(deleteConfirmText != "删除" || deleting)
                    Button("取消", role: .cancel) {
                        deleteConfirmText = ""
                        showDeleteSheet = false
                    }
                    .font(AIATheme.Font.callout)
                    .padding(.bottom, 8)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - 顶部头像 + 昵称
    private var profileHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient.techAccent.opacity(0.15))
                    .frame(width: 72, height: 72)
                // 默认展示好好记头像（AIAvatar = app icon）。昵称首字不再作为头像，避免与首页好好记形象割裂。
                Image("AIAvatar")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
            }
            .proAvatarBadge(isPro: ent.isPro, badgeDiameter: 24)
            Text(userNickname.isEmpty ? "小记的朋友" : userNickname)
                .font(AIATheme.Font.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - 昵称编辑
    private var nicknameEditCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("昵称")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            TextField("输入昵称", text: $userNickname)
                .font(AIATheme.Font.body.weight(.medium))
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(AIATheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            Text("昵称会显示在首页招呼与识别记录等位置，修改后会同步到云端，换设备登录沿用。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
        }
        .padding(14)
        .card()
    }

    // MARK: - 账号信息
    private var accountInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("账号信息")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AIATheme.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: authProviderIcon)
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.providerTitle)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                    if !auth.displayPhone.isEmpty {
                        Text(auth.displayPhone)
                            .font(AIATheme.Font.caption)
                            .foregroundStyle(AIATheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }

            Divider().background(AIATheme.hairline)

            HStack {
                Text("登录方式")
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(AIATheme.sub)
                Spacer()
                Text(auth.providerTitle)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
            }
            if !auth.displayPhone.isEmpty {
                HStack {
                    Text("绑定手机号")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(AIATheme.sub)
                    Spacer()
                    Text(auth.displayPhone)
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - 账号关联
    private var accountLinkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.blue)
                Text("账号关联")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("把手机号、Apple 账号等其他登录方式关联到当前账号，合并各自云端数据；之后用任意一种已关联方式登录，都能看到全部记录。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
            Button {
                showLinkSheet = true
            } label: {
                Text("管理账号关联")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(AIATheme.blue)
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .card()
    }

    // MARK: - 自动同步设置
    private var autoSyncSettingsCard: some View {
        Button {
            NavigationRouter.shared.navigate(.autoSyncSettings)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AIATheme.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动同步设置")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(sync.status)
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // ⚠️ 放在 .frame 之后、.card()/裁剪之前，覆盖整个卡片矩形
            .contentShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
        }
        .buttonStyle(PressableCardStyle())
        .card()
    }

    // MARK: - iCloud 备份（本机备份 / 重装恢复，与腾讯云跨端同步并存互补）
    private var icloudBackupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("iCloud 自动备份", systemImage: "icloud.and.arrow.up")
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if icloudAvailable {
                    Toggle("", isOn: $icloudEnabled)
                        .labelsHidden()
                }
            }
            if !icloudAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AIATheme.warn)
                    Text("未检测到 iCloud：请在系统「设置 → Apple ID → iCloud」开启 iCloud Drive，并允许本 App 使用。")
                        .font(AIATheme.Font.micro)
                        .foregroundStyle(AIATheme.muted)
                        .lineSpacing(2)
                }
            } else {
                if let last = lastBackup {
                    HStack {
                        Label("上次备份", systemImage: "clock")
                            .font(AIATheme.Font.subhead)
                            .foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(AppFormat.dateTime.string(from: last))
                                .font(AIATheme.Font.subhead.weight(.medium))
                                .foregroundStyle(AIATheme.muted)
                            if backupCount > 0 {
                                Text("·")
                                    .font(AIATheme.Font.subhead)
                                    .foregroundStyle(AIATheme.muted)
                                Text("已备份 \(backupCount) 个文件")
                                    .font(AIATheme.Font.caption)
                                    .foregroundStyle(AIATheme.muted)
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        backupNow()
                    } label: {
                        HStack(spacing: 6) {
                            if icloudBusy {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Image(systemName: "icloud.and.arrow.up")
                            }
                            Text(icloudBusy
                                ? (uploadProgress.map { "备份中… \($0.uploaded)/\($0.total)" } ?? "备份中…")
                                : "立即备份")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(AIATheme.blue)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    .buttonStyle(.plain)
                    .disabled(icloudBusy)

                    Button {
                        showRestoreConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            if icloudBusy {
                                ProgressView().tint(AIATheme.sub).scaleEffect(0.8)
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                            }
                            Text(icloudBusy ? "恢复中…" : "恢复")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(AIATheme.fillSoft)
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                    }
                    .buttonStyle(.plain)
                    .disabled(icloudBusy)
                }
                Text("开启「iCloud 备份」后，每次退出 App 会自动把本地数据库与图片备份到你本人的 iCloud（仅你本人可见），换手机或重装 App 后，会自动从 iCloud 恢复资料。")
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .card()
        .task {
            // 模拟器不真实上传 iCloud（容器为本地占位）：直接视为不可用，跳过一切探测，
            // 避免残留备份文件触发主线程上传监控导致导航卡死。
            #if targetEnvironment(simulator)
            icloudAvailable = false
            icloudBusy = false
            return
            #endif
            // 容器不可达（未开启 iCloud Drive）：iCloud 状态一律置为不可用，
            // 不再探测 lastBackup/resumeUploadMonitor，避免主线程同步查 ubiquity 文件卡死导航转场。
            guard ICloudBackupManager.isAvailable() else {
                icloudAvailable = false
                icloudBusy = false
                return
            }
            icloudAvailable = true
            lastBackup = ICloudBackupManager.lastBackupDate()
            // 后台读取已备份文件数（目录 I/O 较重，避免阻塞主线程）
            Task.detached(priority: .utility) {
                let count = ICloudBackupManager.backupFileCount()
                await MainActor.run { backupCount = count }
            }
            // 重进页面：若退出页面期间系统仍在后台上传（监控被停但文件尚未全部上传），
            // 还原「备份中」UI 并接回进度轮询；已全部传完则显示正常按钮 + 最新备份时间。
            if ICloudBackupManager.isMonitoringUpload
                || ICloudBackupManager.liveProgress != nil
                || ICloudBackupManager.resumeUploadMonitorIfNeeded(completion: { uploaded, total in
                    Task { @MainActor in
                        icloudBusy = false
                        uploadProgress = nil
                        backupCount = ICloudBackupManager.backupFileCount()
                        showToast("已备份到 iCloud（\(uploaded)/\(total) 个文件已上传）")
                    }
                }) {
                icloudBusy = true
            }
        }
        .task(id: icloudBusy) {
            // 备份/恢复进行中：周期性把后台写入的 liveProgress 同步到本地 @State 刷新 UI。
            // 仅在 busy 为 true 时轮询，busy 变回 false 时 task 自动取消。
            guard icloudBusy, ICloudBackupManager.isAvailable() else { return }
            var ticks = 0
            while icloudBusy && ICloudBackupManager.isAvailable() {
                uploadProgress = ICloudBackupManager.liveProgress
                try? await Task.sleep(nanoseconds: 300_000_000)
                ticks += 1
                // 兜底：约 90 秒内一直没收到完成回调 → 强制解锁，避免无限轮询
                if ticks >= 300 { break }
            }
            icloudBusy = false
            uploadProgress = nil
        }
        .confirmationDialog("从 iCloud 恢复", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button("恢复并重启 App", role: .none) { restoreNow() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这将用 iCloud 中的备份覆盖本机当前数据。恢复完成后需重启 App 才能生效。")
        }
    }

    private func backupNow() {
        // 方案 B：点击立即备份后，复制文件到 iCloud 容器立即返回（不阻塞），
        // 按钮保持 busy，由 ICloudBackupManager.startUploadMonitor（本地清单 + resourceValues
        // 同源轮询）异步监听系统上传进度，上传完成才弹最终提示。退出页面不中断上传，
        // 重进页面用 resumeUploadMonitorIfNeeded 接续进度。
        icloudBusy = true
        uploadProgress = nil
        Task {
            let ok = await Task.detached(priority: .background) {
                ICloudBackupManager.backup()
            }.value
            if !ok {
                icloudBusy = false
                uploadProgress = nil
                showToast("备份失败，请确认 iCloud 可用")
                return
            }
            // 复制成功：刷新「上次备份」时间，按钮保持 busy 直到上传完成
            lastBackup = ICloudBackupManager.lastBackupDate()
            // 启动异步上传监听；全部上传完成时解锁并提示
            ICloudBackupManager.startUploadMonitor { uploaded, total in
                Task { @MainActor in
                    icloudBusy = false
                    uploadProgress = nil
                    backupCount = ICloudBackupManager.backupFileCount()
                    showToast("已备份到 iCloud（\(uploaded)/\(total) 个文件已上传）")
                }
            }
            // 若容器为空（无附件、数据库极小）或监听异常未能触发完成回调，
            // 给一个兜底：2 秒后若仍在 busy 且进度无变化，强制解锁避免卡死。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if icloudBusy && ICloudBackupManager.liveProgress == nil {
                    icloudBusy = false
                    showToast("已备份到 iCloud（文件正在后台上传）")
                }
            }
        }
    }

    private func restoreNow() {
        icloudBusy = true
        Task {
            let r = await Task.detached(priority: .background) {
                ICloudBackupManager.restore()
            }.value
            icloudBusy = false
            showToast(r.summary)
        }
    }

    private func showToast(_ text: String) {
        toastText = text
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCopied = false }
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

    // MARK: - 退出登录
    private var logoutCard: some View {
        VStack(spacing: 0) {
            Button {
                auth.logout()
            } label: {
                Text("退出登录")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.warn)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(AIATheme.warn.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
            }
            .buttonStyle(.plain)
            Text("退出后下次打开 App 将回到登录页，本地记录不受影响。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
                .padding(.top, 10)
        }
        .padding(14)
        .card()
    }

    private var authProviderIcon: String {
        switch LoginProvider(rawValue: auth.loginProvider) {
        case .apple:  return "apple.logo"
        case .wechat: return "bubble.left.fill"
        case .phone, .onepass, .none: return "phone.fill"
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - 删除账户（苹果 Guideline 5.1.1(v) 强制：支持账户创建的 App 必须提供应用内账户删除）
    private var deleteCard: some View {
        VStack(spacing: 0) {
            Button {
                guard !deleting else { return }
                deleteConfirmText = ""
                showDeleteSheet = true
            } label: {
                HStack(spacing: 6) {
                    if deleting { ProgressView().tint(.red).scaleEffect(0.8) }
                    Text(deleting ? "注销中…" : "删除账户")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                }
            }
            .buttonStyle(.plain)
            .disabled(deleting)
            Text("永久注销账号并删除全部云端与本地数据，操作不可恢复。")
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
                .lineSpacing(2)
                .padding(.top, 10)
        }
        .padding(14)
        .card()
    }

    private func performDeleteAccount() {
        deleting = true
        Task { @MainActor in
            // deleteAccount 内部：云端删除 → 本地全量清空 → 清 Keychain → 切回登录页。
            await CloudSyncManager.shared.deleteAccount(context: modelContext)
            deleting = false
            deleteConfirmText = ""
        }
    }
}
