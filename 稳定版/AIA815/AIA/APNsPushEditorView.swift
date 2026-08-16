// APNsPushEditorView.swift
// 开发者中心「仅 APNs 远程推送」：只发锁屏横幅，不写首页公告横条。
// 支持高级选项：目标页跳转、环境筛选（生产/沙盒）、按账号筛选设备。
import SwiftUI

struct APNsPushEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var busy: Bool

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var routeIndex: Int = 0
    @State private var link: String = ""            // 外部链接（可选）；不填则不跳转/走目标页
    @State private var openModeIndex: Int = 0       // 0=App 内打开，1=跳系统浏览器

    // 环境筛选：默认两者都发
    @State private var sendProduction: Bool = true
    @State private var sendSandbox: Bool = true

    // 设备范围
    enum Scope: String, CaseIterable, Identifiable {
        case all = "全部设备"
        case selected = "指定账号"
        var id: String { rawValue }
    }
    @State private var scope: Scope = .all
    @State private var userOptions: [APNsUserOption] = []
    @State private var selectedUsers: Set<String> = []
    @State private var loadingUsers: Bool = false

    private let routeOptions: [(label: String, route: String?)] = [
        ("不跳转（仅进App）", nil),
        ("待办", "todo"),
        ("账单", "bill"),
        ("饮食", "diet"),
        ("健康", "health"),
        ("对话", "chat"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("推送内容") {
                    TextField("标题", text: $title)
                    TextField("正文", text: $bodyText, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("点击横幅跳转") {
                    Picker("目标页", selection: $routeIndex) {
                        ForEach(0..<routeOptions.count, id: \.self) { i in
                            Text(routeOptions[i].label).tag(i)
                        }
                    }
                    TextField("外部链接（可选）", text: $link, axis: .vertical)
                        .lineLimit(1...4)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    Picker("打开方式", selection: $openModeIndex) {
                        Text("App 内打开").tag(0)
                        Text("跳系统浏览器").tag(1)
                    }
                    Text("填了外部链接则优先走链接；未填则按上方目标页跳转。")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.sub)
                }
                Section("发送环境") {
                    Toggle("生产环境（App Store / TestFlight）", isOn: $sendProduction)
                    Toggle("沙盒环境（Xcode 真机调试）", isOn: $sendSandbox)
                    Text("取消全部勾选将不会发送任何设备。真机调试包走沙盒，上架包走生产。")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.sub)
                }
                Section {
                    Picker("设备范围", selection: $scope) {
                        ForEach(Scope.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    if scope == .selected {
                        deviceSelector
                    }
                } header: {
                    Text("接收设备")
                } footer: {
                    Text("「仅 APNs 推送」不写首页公告横条；只向已授权通知的真机设备发送锁屏横幅。")
                        .font(AIATheme.Font.caption)
                }
            }
            .navigationTitle("APNs 推送")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { Task { await send() } }
                        .disabled(!canSend || busy)
                        .overlay { if busy { ProgressView().scaleEffect(0.8) } }
                }
            }
            .onAppear { if scope == .selected { Task { await loadUsers() } } }
            .onChange(of: scope) { _, newValue in
                if newValue == .selected && userOptions.isEmpty { Task { await loadUsers() } }
            }
        }
    }

    private var deviceSelector: some View {
        Group {
            if loadingUsers {
                HStack { ProgressView().scaleEffect(0.8); Text("加载账号列表…") }
                    .font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
            } else if userOptions.isEmpty {
                Text("云端暂无已上报 token 的设备。请先真机登录并授权通知。")
                    .font(AIATheme.Font.caption).foregroundStyle(AIATheme.sub)
            } else {
                ForEach(userOptions) { opt in
                    HStack {
                        Text(opt.userId)
                            .font(AIATheme.Font.subhead)
                        Spacer()
                        Text("\(opt.count) 台 · \(opt.envsText)")
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(AIATheme.muted)
                        Image(systemName: selectedUsers.contains(opt.userId) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedUsers.contains(opt.userId) ? AIATheme.purple : AIATheme.muted)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedUsers.contains(opt.userId) { selectedUsers.remove(opt.userId) }
                        else { selectedUsers.insert(opt.userId) }
                    }
                }
            }
        }
    }

    private var canSend: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !b.isEmpty else { return false }
        guard sendProduction || sendSandbox else { return false }
        if scope == .selected, selectedUsers.isEmpty { return false }
        return true
    }

    private func loadUsers() async {
        loadingUsers = true
        defer { loadingUsers = false }
        do {
            let resp = try await postAdsJSON([
                "action": "listDevices",
                "passcode": DeveloperGate.passcode,
            ])
            guard resp["ok"] as? Bool == true else {
                NSLog("[APNsPush] listDevices 返回失败: \(resp)")
                return
            }
            let users = (resp["users"] as? [[String: Any]]) ?? []
            userOptions = users.compactMap { dict in
                guard let uid = dict["userId"] as? String else { return nil }
                let count = (dict["count"] as? Int) ?? 0
                let envs = (dict["envs"] as? [String]) ?? []
                return APNsUserOption(userId: uid, count: count, envs: envs)
            }
        } catch {
            NSLog("[APNsPush] listDevices 失败: \(error)")
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }

        var envs: [String] = []
        if sendProduction { envs.append("production") }
        if sendSandbox { envs.append("sandbox") }

        let userIds: [String]? = scope == .selected ? Array(selectedUsers) : nil

        // 组装 route：填了外部链接则优先走链接（consumeNotificationRoute 已识别 https:// 与 browser://）。
        let linkTrimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalRoute: String?
        if let url = linkTrimmed.nonEmpty {
            finalRoute = openModeIndex == 1 ? "browser://\(url)" : url
        } else {
            finalRoute = routeOptions[routeIndex].route
        }

        let r = await broadcastPush(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            route: finalRoute,
            userIds: userIds,
            envs: envs
        )
        if r.accepted == 0 {
            // 云端匹配不到设备（aia_devices 为空或筛选无命中）：不 dismiss，留页面改条件。
            ToastCenter.shared.show("云端 0 台设备（aia_devices 为空或筛选无命中，请先真机登录并授权推送）")
        } else {
            let scopeText = userIds == nil ? "全部设备" : "\(userIds!.count) 个账号"
            ToastCenter.shared.show("已提交，后台发送中（约 \(r.accepted) 台 · \(scopeText)）")
            dismiss()
        }
    }
}

struct APNsUserOption: Identifiable {
    let userId: String
    let count: Int
    let envs: [String]
    var id: String { userId }
    var envsText: String {
        let map = envs.map { $0 == "production" ? "生产" : ($0 == "sandbox" ? "沙盒" : $0) }
        return map.isEmpty ? "—" : map.joined(separator: "/")
    }
}
