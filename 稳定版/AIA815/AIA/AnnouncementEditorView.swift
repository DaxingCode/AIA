// AnnouncementEditorView.swift
// 开发者中心「群发通知」编辑器：填写标题/正文/跳转/生效时间，
// 可选「同时 APNs 推送」（方案 A）。发布走 GlobalConfigStore.saveAnnouncement（方案 B 云端公告）；
// 勾选推送时再调云函数 broadcast（方案 A 远程推送）。
import SwiftUI

struct AnnouncementEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var global = GlobalConfigStore.shared
    @Binding var busy: Bool

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var routeIndex: Int = 0          // 目标页选择；0=不跳转（仅进App）
    @State private var link: String = ""            // 外部链接（可选）；不填则不跳转/走目标页
    @State private var openModeIndex: Int = 0       // 0=App 内打开，1=跳系统浏览器
    @State private var enableTimeRange: Bool = false
    @State private var startAt: Date = Date()
    @State private var endAt: Date = Date().addingTimeInterval(7 * 86400)
    @State private var alsoPushAPNs: Bool = false   // 方案 A 开关

    // 目标页选项（route 字符串对应 consumeNotificationRoute 支持的值）。
    private let routeOptions: [(label: String, route: String?)] = [
        ("不跳转（仅进App）", nil),
        ("待办", "todo"),
        ("账单", "bill"),
        ("饮食", "diet"),
        ("健康", "health"),
        ("对话", "chat"),
    ]

    // 编辑已有公告时预填
    init(busy: Binding<Bool>) {
        self._busy = busy
        if let ann = GlobalConfigStore.shared.announcement {
            _title = State(initialValue: ann.title)
            _bodyText = State(initialValue: ann.body)
            if let r = ann.route?.nonEmpty, let idx = routeOptions.firstIndex(where: { $0.route == r }) {
                _routeIndex = State(initialValue: idx)
            }
            _link = State(initialValue: ann.link?.nonEmpty ?? "")
            if (ann.openMode ?? "inApp") == "browser" {
                _openModeIndex = State(initialValue: 1)
            }
            if ann.startAt > 0 || ann.endAt > 0 {
                _enableTimeRange = State(initialValue: true)
                _startAt = State(initialValue: Date(timeIntervalSince1970: ann.startAt > 0 ? ann.startAt : Date().timeIntervalSince1970))
                _endAt = State(initialValue: Date(timeIntervalSince1970: ann.endAt > 0 ? ann.endAt : Date().addingTimeInterval(7*86400).timeIntervalSince1970))
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $title)
                    TextField("正文", text: $bodyText, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section("点击跳转") {
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
                Section {
                    Toggle("指定生效时间段", isOn: $enableTimeRange)
                    if enableTimeRange {
                        DatePicker("开始", selection: $startAt)
                        DatePicker("结束", selection: $endAt, in: startAt...)
                    }
                } header: {
                    Text("生效时间")
                } footer: {
                    Text("不指定则立即长期生效；指定后仅在时间窗内展示（App 本地时间判定）。")
                }
                Section {
                    Toggle("同时发 APNs 远程推送", isOn: $alsoPushAPNs)
                } header: {
                    Text("远程推送（方案 A）")
                } footer: {
                    Text("开启后，已授权通知的用户即使未打开 App 也会在锁屏收到横幅。需设备已上报 token（真机）。")
                }
            }
            .navigationTitle("发布通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(alsoPushAPNs ? "发布并推送" : "发布") {
                        Task { await publish() }
                    }
                    .disabled(title.isEmpty || bodyText.isEmpty || busy)
                    .overlay { if busy { ProgressView().scaleEffect(0.8) } }
                }
            }
        }
    }

    private func publish() async {
        busy = true
        defer { busy = false }

        let now = Date().timeIntervalSince1970
        let routeValue = routeOptions[routeIndex].route
        let linkTrimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkValue = linkTrimmed.isEmpty ? nil : linkTrimmed
        let openModeValue = linkValue == nil ? nil : (openModeIndex == 1 ? "browser" : "inApp")
        let payload = AnnouncementPayload(
            id: "ann-\(Int(now))",
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            route: routeValue,
            link: linkValue,
            openMode: openModeValue,
            startAt: enableTimeRange ? startAt.timeIntervalSince1970 : 0,
            endAt: enableTimeRange ? endAt.timeIntervalSince1970 : 0,
            createdAt: now
        )

        // 方案 B：写云端公告（所有用户打开 App 时拉取）
        let ok = await global.saveAnnouncement(payload)
        if !ok {
            ToastCenter.shared.show("发布失败（云端写入错误）")
            return
        }

        // 方案 A：同时 APNs 远程推送（route 带外部链接与打开方式，点击横幅复用 consumeNotificationRoute）
        if alsoPushAPNs {
            let finalRoute: String? = {
                if let url = linkValue {
                    return openModeValue == "browser" ? "browser://\(url)" : url
                }
                return routeValue
            }()
            let r = await broadcastPush(title: payload.title, body: payload.body, route: finalRoute)
            if r.accepted == 0 {
                // 集合为空：没有设备上报过 token（最常见是未登录/推送能力未配）。
                ToastCenter.shared.show("已发布；但云端 0 台设备（aia_devices 为空，请先真机登录并授权推送）")
            } else {
                ToastCenter.shared.show("已发布并后台推送中（约 \(r.accepted) 台设备）")
            }
        } else {
            ToastCenter.shared.show("已发布")
        }
        dismiss()
    }
}

/// 调用云函数 aia-sync broadcast（方案 B：接单即返回 + 后台 job）。
/// - userIds: 仅发给指定 userId 集合；nil/空表示全部设备。
/// - envs: 仅发指定环境子集（"production"/"sandbox"）；nil/空表示两者都发。
/// 返回 accepted（云端计划发送数，>0 即表示已提交后台发送）；兼容旧字段 sent/failed/total。
func broadcastPush(title: String, body: String, route: String?, userIds: [String]? = nil, envs: [String]? = nil) async -> (accepted: Int, sent: Int, failed: Int, total: Int) {
    do {
        var payload: [String: Any] = [
            "action": "broadcast",
            "passcode": DeveloperGate.passcode,
            "title": title,
            "body": body,
            "route": route ?? NSNull(),
            "submitterDeviceId": UserDefaults.standard.string(forKey: "aia.deviceTokenHex") ?? "",
            "submitterEnv": UserDefaults.standard.string(forKey: "aia.apnsEnv") ?? "sandbox",
        ]
        if let userIds, !userIds.isEmpty { payload["userIds"] = userIds }
        if let envs, !envs.isEmpty { payload["envs"] = envs }
        let resp = try await postAdsJSON(payload)
        guard resp["ok"] as? Bool == true else {
            NSLog("[Announcement] broadcast 云端返回失败: \(resp)")
            return (0, 0, 0, 0)
        }
        let accepted = (resp["accepted"] as? Int) ?? 0
        let total = (resp["total"] as? Int) ?? 0
        NSLog("[Announcement] broadcast accepted=\(accepted) total=\(total)")
        return (accepted, 0, 0, total)
    } catch {
        NSLog("[Announcement] broadcast 失败: \(error)")
        return (0, 0, 0, 0)
    }
}
