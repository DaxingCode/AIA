// DeveloperTools.swift
// 开发者模式：长按版本号输入口令解锁；广告管理页（仅解锁后可见）。
// 口令硬编码常量（避免把 userId 白名单写进前端泄露）；写操作服务端再次校验口令。
import SwiftUI
import PhotosUI
import Foundation
import Combine

enum DeveloperGate {
    /// 解锁口令（与服务端 DEV_PASSCODE 一致）。改口令需同步云函数环境变量。
    static let passcode = "Daxing@0329"
    private static let key = "aia.devModeUnlocked"

    static var isUnlocked: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 设置页解锁后展示的「开发者中心」入口卡片。
struct DeveloperCenterCard: View {
    var body: some View {
        NavigationLink {
            AdManagerView()
        } label: {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .font(AIATheme.Font.callout.weight(.medium))
                    .foregroundStyle(AIATheme.purple)
                Text("开发者中心")
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
        .card()
    }
}

// MARK: - 广告管理 Store

@MainActor
final class AdManagerStore: ObservableObject {
    static let shared = AdManagerStore()

    @Published var items: [AdItem] = []
    @Published var loading = false

    func listAll() async {
        loading = true
        defer { loading = false }
        do {
            let resp = try await postAdsJSON(["action": "listAll", "passcode": DeveloperGate.passcode])
            guard resp["ok"] as? Bool == true, let arr = resp["items"] as? [[String: Any]] else { return }
            let data = try JSONSerialization.data(withJSONObject: arr)
            items = try JSONDecoder().decode([AdItem].self, from: data)
        } catch {
            items = []
        }
    }

    func upsert(_ item: AdItem, imageBase64: String?) async -> Bool {
        var dict = (try? item.asDictionary()) ?? [:]
        if let b64 = imageBase64 { dict["imageBase64"] = b64 }
        else { dict["imageBase64"] = NSNull() }
        do {
            let resp = try await postAdsJSON([
                "action": "upsert",
                "passcode": DeveloperGate.passcode,
                "item": dict
            ])
            return resp["ok"] as? Bool == true
        } catch {
            return false
        }
    }

    func delete(_ id: String) async -> Bool {
        do {
            let resp = try await postAdsJSON([
                "action": "delete",
                "passcode": DeveloperGate.passcode,
                "id": id
            ])
            return resp["ok"] as? Bool == true
        } catch {
            return false
        }
    }
}

// MARK: - 广告管理页

struct AdManagerView: View {
    @StateObject private var mgr = AdManagerStore.shared
    @State private var editing: AdItem?
    @State private var showEditor = false

    var body: some View {
        Group {
            if mgr.loading && mgr.items.isEmpty {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(mgr.items) { item in
                        AdRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editing = item
                                showEditor = true
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task {
                                        if await mgr.delete(item.id) { await mgr.listAll() }
                                    }
                                } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("广告管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "plus")
                    .font(AIATheme.Font.body.weight(.semibold))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editing = AdItem.empty()
                        showEditor = true
                    }
            }
        }
        .task { await mgr.listAll() }
        .sheet(isPresented: $showEditor) {
            if let item = editing {
                AdEditorView(item: item) { saved, b64 in
                    Task {
                        _ = await mgr.upsert(saved, imageBase64: b64)
                        await mgr.listAll()
                    }
                }
            }
        }
    }
}

struct AdRow: View {
    let item: AdItem
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? "(未命名)" : item.title)
                    .font(AIATheme.Font.callout.weight(.medium))
                Text(item.link)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.enabled ? "已启用" : "已停用")
                        .foregroundStyle(item.enabled ? AIATheme.ok : AIATheme.muted)
                    Text("排序 \(item.order)")
                        .foregroundStyle(AIATheme.muted)
                }
                .font(AIATheme.Font.micro)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(AIATheme.muted)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 广告编辑 Sheet

struct AdEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: AdItem
    var onSave: (AdItem, String?) -> Void

    @State private var picked: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var imagePreview: UIImage?

    init(item: AdItem, onSave: @escaping (AdItem, String?) -> Void) {
        _draft = State(initialValue: item)
        _imagePreview = State(initialValue:
            item.imageBase64
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { UIImage(data: $0) })
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // 自定义顶部栏：避开内嵌 NavigationStack 在 sheet 里渲染空白的问题
            HStack(spacing: 16) {
                Text("取消")
                    .font(AIATheme.Font.body)
                    .foregroundStyle(AIATheme.blue)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                Spacer()
                Text(draft.id.isEmpty ? "新建广告" : "编辑广告")
                    .font(AIATheme.Font.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("保存")
                    .font(AIATheme.Font.body.weight(.semibold))
                    .foregroundStyle(AIATheme.blue)
                    .contentShape(Rectangle())
                    .onTapGesture { save() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AIATheme.surface)

            Form {
                Section("基础") {
                    TextField("标题", text: $draft.title)
                    TextField("副标题（可选）", text: Binding(
                        get: { draft.subtitle ?? "" },
                        set: { draft.subtitle = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("跳转链接", text: $draft.link)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
                Section("展示时间") {
                    DatePicker("开始", selection: startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("结束", selection: endDate, displayedComponents: [.date, .hourAndMinute])
                }
                Section("开关与排序") {
                    Toggle("启用", isOn: $draft.enabled)
                    Stepper("排序：\(draft.order)", value: $draft.order, in: 0...99)
                }
                Section("封面图（可选）") {
                    PhotosPicker(selection: $picked, matching: .images) {
                        if let img = imagePreview {
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(height: 120).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: AIATheme.rMD))
                        } else {
                            Label("从相册选择", systemImage: "photo")
                        }
                    }
                    if imagePreview != nil {
                        Text("移除图片")
                            .foregroundStyle(.red)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                picked = nil
                                imagePreview = nil
                                imageData = nil
                            }
                    }
                }
            }
        }
        .onChange(of: picked) { _ in loadPicked() }
    }

    private var startDate: Binding<Date> {
        Binding(
            get: { ISO8601DateFormatter().date(from: draft.start) ?? Date() },
            set: { draft.start = ISO8601DateFormatter().string(from: $0) }
        )
    }
    private var endDate: Binding<Date> {
        Binding(
            get: { ISO8601DateFormatter().date(from: draft.end) ?? Date().addingTimeInterval(86400) },
            set: { draft.end = ISO8601DateFormatter().string(from: $0) }
        )
    }

    private func loadPicked() {
        guard let item = picked else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                imageData = data
                imagePreview = UIImage(data: data)
            }
        }
    }

    private func save() {
        var toSave = draft
        if toSave.id.isEmpty { toSave.id = UUID().uuidString }
        // 图片转 base64（限制尺寸，避免载荷过大）
        var b64: String?
        if let data = imageData,
           let ui = UIImage(data: data)?.downscaledToFit(CGSize(width: 800, height: 800)),
           let jpg = ui.jpegData(compressionQuality: 0.7) {
            b64 = jpg.base64EncodedString()
        }
        onSave(toSave, b64)
        dismiss()
    }
}
