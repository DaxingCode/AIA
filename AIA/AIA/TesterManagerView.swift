// TesterManagerView.swift
// 开发者中心 → 测试账号管理：增删「测试 / 审核 / 内部」白名单。
// 白名单由云端 aia_testers 集合托管，命中即全功能可用，绕过一切付费限制（含 App Store 审核账号）。
import SwiftUI

struct TesterManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [TesterItem] = []
    @State private var loading = false
    @State private var lastError: String?
    @State private var showEditor = false
    @State private var editing: TesterItem?

    var body: some View {
        VStack(spacing: 0) {
            if let err = lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AIATheme.warn)
                    Text(err).font(AIATheme.Font.footnote).foregroundStyle(.primary).lineLimit(3)
                    Spacer()
                }
                .padding(12).background(AIATheme.warn.opacity(0.08)).padding(.horizontal, 16).padding(.top, 12)
            }
            if loading && items.isEmpty {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.badge.plus").font(.system(size: 44)).foregroundStyle(AIATheme.muted.opacity(0.5))
                    Text("暂无测试账号").font(AIATheme.Font.subhead.weight(.medium))
                    Text("点右上角 + 新增：可填手机号 / 账号 ID / 设备 ID，支持有效期与类型。")
                        .font(AIATheme.Font.footnote).foregroundStyle(AIATheme.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 24)
            } else {
                List {
                    ForEach(items) { it in
                        TesterRow(item: it)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = it; showEditor = true }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await delete(it) } } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await list() }
            }
        }
        .navigationTitle("测试账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .foregroundStyle(AIATheme.blue)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "plus").foregroundStyle(AIATheme.blue).contentShape(Rectangle())
                    .onTapGesture { editing = TesterItem.empty(); showEditor = true }
            }
        }
        .task { await list() }
        .sheet(item: $editing) { it in
            TesterEditorView(item: it) { saved in
                Task { await upsert(saved); await list() }
            }
        }
    }

    private func list() async {
        loading = true; lastError = nil
        do {
            let resp = try await postAdsJSON(["action": "listTesters", "passcode": DeveloperGate.passcode])
            guard resp["ok"] as? Bool == true else {
                let msg = resp["error"] as? String ?? "未知错误"
                lastError = "拉取失败: \(msg)"
                loading = false
                return
            }
            let arr = resp["items"] as? [[String: Any]] ?? []
            items = arr.compactMap { TesterItem(from: $0) }.sorted { $0.updatedAt > $1.updatedAt }
        } catch { lastError = "拉取失败: \(error)" }
        loading = false
    }
    private func upsert(_ it: TesterItem) async {
        do {
            let resp = try await postAdsJSON([
                "action": "upsertTester", "passcode": DeveloperGate.passcode,
                "idType": it.idType, "idValue": it.idValue, "note": it.note,
                "kind": it.kind, "enabled": it.enabled, "expireAt": it.expireAt
            ])
            if resp["ok"] as? Bool != true { lastError = "保存失败: \(resp["error"] ?? "未知")" }
        } catch { lastError = "保存失败: \(error)" }
    }
    private func delete(_ it: TesterItem) async {
        do {
            let resp = try await postAdsJSON(["action": "deleteTester", "passcode": DeveloperGate.passcode, "id": it.id])
            if resp["ok"] as? Bool != true { lastError = "删除失败" }
            else { items.removeAll { $0.id == it.id } }
        } catch { lastError = "删除失败: \(error)" }
    }
}

struct TesterItem: Identifiable {
    var id: String
    var idType: String
    var idValue: String
    var note: String
    var kind: String
    var enabled: Bool
    var expireAt: Int
    var updatedAt: Int
    var createdAt: Int

    static func empty() -> TesterItem {
        TesterItem(id: "", idType: "phone", idValue: "", note: "", kind: "tester", enabled: true, expireAt: 0, updatedAt: 0, createdAt: 0)
    }

    // 自定义 init(from:) 会抑制编译器合成的逐成员 init，这里显式补回。
    init(id: String, idType: String, idValue: String, note: String, kind: String, enabled: Bool, expireAt: Int, updatedAt: Int, createdAt: Int) {
        self.id = id
        self.idType = idType
        self.idValue = idValue
        self.note = note
        self.kind = kind
        self.enabled = enabled
        self.expireAt = expireAt
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }

    init(from d: [String: Any]) {
        self.id = d["_id"] as? String ?? ""
        self.idType = d["idType"] as? String ?? "phone"
        self.idValue = d["idValue"] as? String ?? ""
        self.note = d["note"] as? String ?? ""
        self.kind = d["kind"] as? String ?? "tester"
        self.enabled = (d["enabled"] as? Bool) ?? true
        self.expireAt = (d["expireAt"] as? Int) ?? 0
        self.updatedAt = (d["updatedAt"] as? Int) ?? 0
        self.createdAt = (d["createdAt"] as? Int) ?? 0
    }
}

struct TesterRow: View {
    let item: TesterItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.idValue.isEmpty ? "(未填)" : item.idValue)
                    .font(AIATheme.Font.callout.weight(.medium))
                Spacer()
                Text(kindText).font(AIATheme.Font.micro).foregroundStyle(kindColor)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(kindColor.opacity(0.1)).clipShape(Capsule())
            }
            HStack(spacing: 6) {
                Text(typeText).font(AIATheme.Font.micro).foregroundStyle(AIATheme.blue)
                Text(item.enabled ? "启用中" : "已停用")
                    .font(AIATheme.Font.micro).foregroundStyle(item.enabled ? AIATheme.ok : AIATheme.muted)
                if item.expireAt > 0 { Text(relExpire).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted) }
                else { Text("永久").font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted) }
            }
            if !item.note.isEmpty {
                Text(item.note).font(AIATheme.Font.micro).foregroundStyle(AIATheme.muted).lineLimit(1)
            }
        }.padding(.vertical, 6)
    }
    private var kindText: String { item.kind == "review" ? "审核" : (item.kind == "internal" ? "内部" : "测试") }
    private var kindColor: Color { item.kind == "review" ? AIATheme.purple : (item.kind == "internal" ? AIATheme.blue : AIATheme.ok) }
    private var typeText: String { item.idType == "phone" ? "手机号" : (item.idType == "userId" ? "账号ID" : "设备ID") }
    private var relExpire: String {
        let left = item.expireAt - Int(Date().timeIntervalSince1970)
        if left <= 0 { return "已过期" }
        let d = left / 86400
        return d >= 1 ? "\(d) 天后到期" : "\(left / 3600) 小时后到期"
    }
}

struct TesterEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: TesterItem
    var onSave: (TesterItem) -> Void

    @State private var pickedType: Int = 0
    @State private var hasExpire = false
    @State private var expireDate = Date().addingTimeInterval(86400 * 30)

    init(item: TesterItem, onSave: @escaping (TesterItem) -> Void) {
        _draft = State(initialValue: item)
        _pickedType = State(initialValue: item.idType == "userId" ? 1 : (item.idType == "deviceId" ? 2 : 0))
        _hasExpire = State(initialValue: item.expireAt > 0)
        if item.expireAt > 0 { _expireDate = State(initialValue: Date(timeIntervalSince1970: TimeInterval(item.expireAt))) }
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("取消").foregroundStyle(AIATheme.blue).contentShape(Rectangle()).onTapGesture { dismiss() }
                Spacer()
                Text(draft.id.isEmpty ? "新增测试账号" : "编辑测试账号").font(AIATheme.Font.headline.weight(.semibold))
                Spacer()
                Text("保存").foregroundStyle(AIATheme.blue).font(AIATheme.Font.body.weight(.semibold)).contentShape(Rectangle()).onTapGesture { save() }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(AIATheme.surface)

            Form {
                Section("标识类型") {
                    Picker("类型", selection: $pickedType) {
                        Text("手机号").tag(0); Text("账号 ID").tag(1); Text("设备 ID").tag(2)
                    }.pickerStyle(.segmented)
                    TextField(typePlaceholder, text: $draft.idValue).autocapitalization(.none)
                }
                Section("类型 / 状态") {
                    Picker("用途", selection: $draft.kind) {
                        Text("测试").tag("tester"); Text("审核").tag("review"); Text("内部").tag("internal")
                    }
                    Toggle("启用", isOn: $draft.enabled)
                }
                Section {
                    Toggle("设置有效期", isOn: $hasExpire)
                    if hasExpire { DatePicker("到期时间", selection: $expireDate) }
                } footer: {
                    Text("不设置有效期 = 永久有效。审核账号建议长期，测试账号可设短期。")
                        .font(AIATheme.Font.footnote).foregroundStyle(AIATheme.muted)
                }
                Section("备注（仅管理页可见）") {
                    TextField("如：小张的测试机", text: $draft.note)
                }
            }
        }
    }
    private var typePlaceholder: String {
        pickedType == 0 ? "如：138xxxx" : (pickedType == 1 ? "账号 ID（设置页可复制）" : "设备 ID（设置页可复制）")
    }
    private func save() {
        var d = draft
        d.idType = pickedType == 0 ? "phone" : (pickedType == 1 ? "userId" : "deviceId")
        d.id = "tester_" + d.idType + "_" + d.idValue
        d.expireAt = hasExpire ? Int(expireDate.timeIntervalSince1970) : 0
        onSave(d)
        dismiss()
    }
}
