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
        Button {
            NavigationRouter.shared.navigate(.developerCenter)
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
    @Published var lastError: String?

    func listAll() async {
        loading = true
        defer { loading = false }
        do {
            let resp = try await postAdsJSON(["action": "listAll", "passcode": DeveloperGate.passcode])
            print("[AdManager] listAll resp: \(resp)")
            guard resp["ok"] as? Bool == true else {
                lastError = (resp["error"] as? String) ?? "listAll 失败"
                items = []
                return
            }
            lastError = nil
            guard let arr = resp["items"] as? [[String: Any]] else {
                items = []
                return
            }
            let data = try JSONSerialization.data(withJSONObject: arr)
            items = try JSONDecoder().decode([AdItem].self, from: data)
        } catch {
            print("[AdManager] listAll error: \(error)")
            lastError = error.localizedDescription
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
            print("[AdManager] upsert resp: \(resp)")
            guard resp["ok"] as? Bool == true else {
                lastError = (resp["error"] as? String) ?? "upsert 失败"
                return false
            }
            lastError = nil
            return true
        } catch {
            print("[AdManager] upsert error: \(error)")
            lastError = error.localizedDescription
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
            guard resp["ok"] as? Bool == true else {
                lastError = (resp["error"] as? String) ?? "delete 失败"
                return false
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 手动排序：对当前 tab 展示的广告本地 move 后重设 order，再批量同步到云端。
    /// 成功后立即刷新首页广告位，避免 60 秒缓存导致顺序未变。
    func reorder(displayed: [AdItem], fromOffsets: IndexSet, toOffset: Int) async {
        var reordered = displayed
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        // 更新当前 tab 内展示广告的 order（按新顺序）
        var updated = items
        for (idx, item) in reordered.enumerated() {
            if let i = updated.firstIndex(where: { $0.id == item.id }) {
                updated[i].order = idx
            }
        }
        items = updated

        let orders: [[String: Any]] = reordered.enumerated().map { ["id": $0.element.id, "order": $0.offset] }
        do {
            let resp = try await postAdsJSON([
                "action": "reorder",
                "passcode": DeveloperGate.passcode,
                "orders": orders
            ])
            guard resp["ok"] as? Bool == true else {
                lastError = (resp["error"] as? String) ?? "reorder 失败"
                await listAll() // 失败则回拉云端顺序
                return
            }
            lastError = nil
            await AdStore.shared.invalidateAndFetch()
        } catch {
            lastError = error.localizedDescription
            await listAll()
        }
    }
}

// MARK: - 广告管理页

/// 广告状态页签：已启用（在窗展示中）/ 待启用（未到开始或停用待启用）/ 已结束（已过结束时间）。
private enum AdTab: String, CaseIterable, Identifiable {
    case enabled = "已启用"
    case pending = "待启用"
    case ended = "已结束"
    var id: String { rawValue }
}

struct AdManagerView: View {
    @StateObject private var mgr = AdManagerStore.shared
    // 用 item 绑定 sheet：避免 .sheet(isPresented:) 首次弹窗时闭包拿到旧值/空值导致空白
    @State private var editing: AdItem?
    @State private var isSorting = false
    @State private var tab: AdTab = .enabled

    var body: some View {
        Group {
            VStack(spacing: 0) {
                // 状态页签：分段控件，切换只看对应状态的广告
                Picker("状态", selection: $tab) {
                    ForEach(AdTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if let err = mgr.lastError {
                    errorBanner(err)
                }

                if mgr.loading && mgr.items.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    emptyState(tab)
                } else {
                    List {
                        ForEach(filtered) { item in
                            AdRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard !isSorting else { return }
                                    editing = item
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task {
                                            if await mgr.delete(item.id) {
                                                await mgr.listAll()
                                                // 删除后立即同步首页广告位，避免 60 秒缓存导致旧广告仍显示
                                                await AdStore.shared.invalidateAndFetch()
                                            }
                                        }
                                    } label: { Label("删除", systemImage: "trash") }
                                }
                        }
                        .onMove { from, to in
                            Task { await mgr.reorder(displayed: filtered, fromOffsets: from, toOffset: to) }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.editMode, .constant(isSorting ? .active : .inactive))
                    .refreshable { await mgr.listAll() }
                }
            }
        }
        .navigationTitle("广告管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
                    Text(isSorting ? "完成" : "排序")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture { isSorting.toggle() }

                    Divider()
                        .frame(width: 1, height: 16)
                        .overlay(AIATheme.iconInactive)

                    Image(systemName: "plus")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(AIATheme.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = AdItem.empty() }
                }
                .background(AIATheme.surfaceSecondary)
                .clipShape(Capsule())
            }
        }
        .task { await mgr.listAll() }
        .sheet(item: $editing) { item in
            AdEditorView(item: item) { saved, b64 in
                Task {
                    let ok = await mgr.upsert(saved, imageBase64: b64)
                    print("[AdManager] upsert result: \(ok)")
                    await mgr.listAll()
                    // 保存后立即同步首页广告位，避免 60 秒缓存导致看不到
                    await AdStore.shared.invalidateAndFetch()
                }
            }
        }
    }

    /// 当前页签下的广告（按 order 升序）。
    private var filtered: [AdItem] {
        mgr.items.filter { adTab(of: $0) == tab }
            .sorted { $0.order < $1.order }
    }

    /// 状态分类：已结束（优先）> 已启用（启用且在窗）> 待启用（未到开始 / 已停用）。
    private func adTab(of item: AdItem) -> AdTab {
        let now = Date()
        if let end = ISO8601DateFormatter().date(from: item.end), now > end { return .ended }
        if item.enabled {
            if let start = ISO8601DateFormatter().date(from: item.start), now < start { return .pending }
            return .enabled
        }
        return .pending
    }

    private func emptyState(_ t: AdTab) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                .font(.system(size: 48))
                .foregroundStyle(AIATheme.muted.opacity(0.5))
            Text("「\(t.rawValue)」分类下暂无广告")
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(.primary)
            Text("点击右上角 + 新建一条广告")
                .font(AIATheme.Font.footnote)
                .foregroundStyle(AIATheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AIATheme.warn)
            Text(text)
                .font(AIATheme.Font.footnote)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(AIATheme.warn.opacity(0.08))
        .cornerRadius(AIATheme.rMD)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

struct AdRow: View {
    let item: AdItem
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(AIATheme.Font.callout.weight(.medium))
                Text(item.link.isEmpty ? "无跳转链接" : item.link)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                Text(timeRange)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(statusText)
                        .foregroundStyle(statusColor)
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

    /// 广告管理页显示「广告名称」；未填时回退到标题，标题也空则显示(未命名)。
    private var displayName: String {
        if let n = item.name, !n.isEmpty { return n }
        if !item.title.isEmpty { return item.title }
        return "(未命名)"
    }

    /// 是否已过结束时间。
    private var isEnded: Bool {
        guard let end = ISO8601DateFormatter().date(from: item.end) else { return false }
        return Date() > end
    }

    /// 是否还未到开始时间（已启用但待展示）。
    private var isPending: Bool {
        guard let start = ISO8601DateFormatter().date(from: item.start) else { return false }
        return Date() < start
    }

    /// 状态文案：已结束 > 待启用 > 已启用 / 已停用（与页签分类一致）。
    private var statusText: String {
        if isEnded { return "已结束" }
        if isPending { return "待启用" }
        return item.enabled ? "已启用" : "已停用"
    }

    private var statusColor: Color {
        if isEnded { return AIATheme.warn }
        if isPending { return AIATheme.blue }
        return item.enabled ? AIATheme.ok : AIATheme.muted
    }

    /// 展示时间范围，格式：yyyy.MM.dd HH:mm ~ yyyy.MM.dd HH:mm。
    private var timeRange: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy.MM.dd HH:mm"
        guard let start = ISO8601DateFormatter().date(from: item.start),
              let end = ISO8601DateFormatter().date(from: item.end) else {
            return "展示时间未设置"
        }
        return "\(fmt.string(from: start)) ~ \(fmt.string(from: end))"
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
                Section {
                    TextField("广告名称（仅管理页可见）", text: Binding(
                        get: { draft.name ?? "" },
                        set: { draft.name = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("标题（首页广告位展示）", text: $draft.title)
                    TextField("副标题（可选）", text: Binding(
                        get: { draft.subtitle ?? "" },
                        set: { draft.subtitle = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("跳转链接", text: $draft.link)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    Picker("打开方式", selection: Binding(
                        get: { draft.openMode ?? "inApp" },
                        set: { draft.openMode = $0 }
                    )) {
                        Text("App 内打开").tag("inApp")
                        Text("跳系统浏览器").tag("browser")
                    }
                    TextField("图片外链（可选）", text: Binding(
                        get: { draft.imageURL ?? "" },
                        set: { draft.imageURL = $0.isEmpty ? nil : $0 }
                    ))
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                } header: {
                    Text("基础")
                } footer: {
                    Text("「图片外链」填一张网络图片地址（https://…），无体积限制，适合大图/高清图；与下方「封面图」二选一，封面图优先显示。")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.muted)
                }
                Section("展示时间") {
                    DatePicker("开始", selection: startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("结束", selection: endDate, displayedComponents: [.date, .hourAndMinute])
                }
                Section("开关与排序") {
                    Toggle("启用", isOn: $draft.enabled)
                    Stepper("排序：\(draft.order)", value: $draft.order, in: 0...99)
                }
                Section {
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
                } header: {
                    Text("封面图（可选）")
                } footer: {
                    Text("从相册选择，App 自动压缩到约 250KB 以内（宽幅图最佳，约 4:1）。若原图过大压不下会自动丢弃图片、仅保留文字。想用大图/高清图请改填上方「图片外链」。")
                        .font(AIATheme.Font.footnote)
                        .foregroundStyle(AIATheme.muted)
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
        // 封面图：CloudBase 默认域名 HTTP 网关请求体上限很小，必须强力压缩；
        // 压不到安全阈值就丢弃（保证文字广告一定能存），改用 imageURL 外链配图。
        var b64: String?
        if let data = imageData {
            if let compressed = Self.compressedAdImage(data) {
                b64 = compressed
            } else {
                print("[AdEditor] 封面图过大，已跳过上传（避免 CloudBase EXCEED_MAX_PAYLOAD_SIZE）；可改用「跳转链接」配图或换更小原图")
            }
        }
        onSave(toSave, b64)
        dismiss()
    }

    /// 渐进式压缩到安全体积：尺寸从大到小、质量从高到低，首个 ≤ 阈值即返回 base64。
    /// 阈值按「实际 JPEG 字节」算，base64 膨胀约 1.33x，留足余量给其它字段与默认域名小限额。
    private static func compressedAdImage(_ data: Data) -> String? {
        guard let img = UIImage(data: data) else { return nil }
        let maxActualBytes = 250 * 1024   // 实际 JPEG 字节上限（base64 后约 333KB）
        let sizes: [CGFloat] = [512, 400, 320, 256]
        let qualities: [CGFloat] = [0.6, 0.5, 0.45, 0.4]
        for size in sizes {
            let ui = img.downscaledToFit(CGSize(width: size, height: size))
            for q in qualities {
                if let jpg = ui.jpegData(compressionQuality: q), jpg.count <= maxActualBytes {
                    return jpg.base64EncodedString()
                }
            }
        }
        return nil
    }
}
