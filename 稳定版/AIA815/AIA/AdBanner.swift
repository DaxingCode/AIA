// AdBanner.swift
// 首页广告位：云端 aia_ads 集合远程控制，平时无广告则不展示（返回 EmptyView）。
// list 公开、listAll/upsert/delete 需开发者口令（见 DeveloperTools.swift）。
import SwiftUI
import Foundation
import Combine

// MARK: - 数据模型

struct AdItem: Codable, Identifiable {
    var id: String
    var name: String?          // 广告名称：仅在广告管理页展示，用于区分广告（旧文档无此字段，故可选）
    var title: String          // 广告标题：展示在 App 首页广告位
    var subtitle: String?
    var link: String
    var openMode: String?      // 链接打开方式："inApp"=App 内打开，"browser"=跳系统浏览器；nil 默认 "inApp"
    var imageURL: String?
    var imageBase64: String?   // 开发者端直接传 base64，免远程图床
    var start: String          // ISO8601
    var end: String            // ISO8601
    var enabled: Bool
    var order: Int
}

extension AdItem {
    static func empty() -> AdItem {
        let now = Date()
        return AdItem(
            id: "",
            name: nil,
            title: "",
            subtitle: nil,
            link: "",
            openMode: "inApp",
            imageURL: nil,
            imageBase64: nil,
            start: ISO8601DateFormatter().string(from: now),
            end: ISO8601DateFormatter().string(from: now.addingTimeInterval(7 * 86400)),
            enabled: true,
            order: 0
        )
    }
}

/// 容错解码中间体：云端旧文档可能用主键 _id 而非 id、可能缺 name 等字段。
/// 全部字段可选，解码绝不抛错；再 map 成 AdItem（缺字段用默认值/回退）。
private struct AdItemRaw: Decodable {
    let id: String?
    let _id: String?
    let name: String?
    let title: String?
    let subtitle: String?
    let link: String?
    let openMode: String?
    let imageURL: String?
    let imageBase64: String?
    let start: String?
    let end: String?
    let enabled: Bool?
    let order: Int?

    var toAdItem: AdItem {
        AdItem(
            id: (id?.isEmpty == false ? id! : (_id ?? "")),
            name: name,
            title: title ?? "",
            subtitle: subtitle,
            link: link ?? "",
            openMode: openMode,
            imageURL: imageURL,
            imageBase64: imageBase64,
            start: start ?? "",
            end: end ?? "",
            enabled: enabled ?? true,
            order: order ?? 0
        )
    }
}

// MARK: - 网络

enum AIAAdEndpoint {
    static let url = URL(string: "https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/sync")!
}

/// 向 /sync 端点 POST JSON（广告逻辑已并入 /sync，action 用 list/listAll/upsert/delete）。失败抛出。
func postAdsJSON(_ payload: [String: Any]) async throws -> [String: Any] {
    let action = payload["action"] as? String ?? "?"
    NSLog("🧪 [DEBUG] postAdsJSON 发出 → action=\(action)")
    var req = URLRequest(url: AIAAdEndpoint.url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (data, resp) = try await URLSession.shared.data(for: req)
    let raw = String(data: data, encoding: .utf8) ?? ""
    if let http = resp as? HTTPURLResponse {
        NSLog("🧪 [DEBUG] postAdsJSON 收到 ← HTTP \(http.statusCode) body=\(raw.prefix(300))")
    } else {
        NSLog("🧪 [DEBUG] postAdsJSON 收到 ← body=\(raw.prefix(300))")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "ads", code: -2, userInfo: [NSLocalizedDescriptionKey: "返回非 JSON"])
    }
    return json
}

extension Encodable {
    func asDictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Store

@MainActor
final class AdStore: ObservableObject {
    static let shared = AdStore()

    @Published private(set) var items: [AdItem] = []
    private let cacheKey = "aia.adsCache"
    private let ud = UserDefaults.standard
    private var lastFetch = Date.distantPast

    /// 防抖拉取：60 秒内且已有数据则不重复请求。
    func fetchIfNeeded() async {
        if Date().timeIntervalSince(lastFetch) < 60, !items.isEmpty { return }
        await fetch()
    }

    /// 强制刷新：忽略 60 秒防抖，用于广告保存后立即同步到首页。
    func invalidateAndFetch() async {
        lastFetch = .distantPast
        await fetch()
    }

    func fetch() async {
        lastFetch = Date()
        do {
            let resp = try await postAdsJSON(["action": "list"])
            guard resp["ok"] as? Bool == true,
                  let arr = resp["items"] as? [[String: Any]] else {
                loadCache()
                return
            }
            let data = try JSONSerialization.data(withJSONObject: arr)
            // 用容错中间体解码，避免旧文档缺字段导致整批解码失败
            let decoded = try JSONDecoder().decode([AdItemRaw].self, from: data).map { $0.toAdItem }
            items = decoded
            saveCache(decoded)
            print("[AdStore] fetch 成功，条数: \(decoded.count)，启用且在时间窗内: \(activeItems().count)")
        } catch {
            // 解码失败通常是云端文档缺字段（如旧广告无 name）：打印错误便于排查，回退缓存。
            print("[AdStore] fetch 解码失败: \(error)")
            loadCache()
        }
    }

    /// 当前生效的广告（启用 + 在时间窗内），按 order 升序。
    func activeItems() -> [AdItem] {
        let now = Date()
        return items.filter { item in
            guard item.enabled else { return false }
            guard let s = ISO8601DateFormatter().date(from: item.start),
                  let e = ISO8601DateFormatter().date(from: item.end) else { return false }
            return now >= s && now <= e
        }
        .sorted { $0.order < $1.order }
    }

    private func saveCache(_ items: [AdItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        ud.set(data, forKey: cacheKey)
    }
    private func loadCache() {
        guard let data = ud.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([AdItem].self, from: data) else { return }
        items = decoded
    }
}

// MARK: - 视图

/// 轮播页：用唯一 id 包裹，支持尾部克隆页实现单向无缝循环。
private struct AdPage: Identifiable {
    let id: String
    let item: AdItem
}

struct AdBannerView: View {
    @StateObject private var store = AdStore.shared
    @State private var scrollID: String? = nil
    @State private var currentIndex: Int = 0
    @State private var loopKey: String = ""   // 广告列表变化（增删/排序）时用于重置到首条
    // 本环境 .task 闭包不派发，改用 Timer + .onReceive（.onReceive 已验证可靠）。
    @State private var timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    // 方案 D（本地边界调度）：本地 1 秒心跳只做时间比较，不联网；
    // 仅当「下一条广告边界（到点出现/消失）」已到达时才真正拉取云端一次（invalidateAndFetch，无防抖）。
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var boundaryFiring = false   // 防止边界时刻 1s 心跳重复触发拉取的守护
    @State private var browserTarget: BrowserTarget?  // App 内打开广告链接（inApp 模式）

    var body: some View {
        // Group 永远存在，确保 onAppear/onReceive 在 content 解析为 EmptyView 时也能触发
        Group { content }
            .onAppear { Task { await AdStore.shared.fetchIfNeeded() } }  // 冷启动/回到首页拉一次全量（含待启用）
            .onReceive(tick) { _ in boundaryCheck() }
            .inAppBrowser(target: $browserTarget)
    }

    /// 本地边界调度：算出下一条会改变「生效广告集合」的时刻，到点才拉云端。
    private func boundaryCheck() {
        guard let nb = nextBoundary, Date() >= nb, !boundaryFiring else { return }
        boundaryFiring = true
        Task {
            await AdStore.shared.invalidateAndFetch()   // 无防抖，边界时刻必拉最新
            boundaryFiring = false
        }
    }

    /// 下一条边界时间：每条启用且未过期广告的「开始(start，待启用→出现)」或「结束(end，进行中→消失)」中最早的一个。
    private var nextBoundary: Date? {
        let now = Date()
        var best: Date?
        let fmt = ISO8601DateFormatter()
        for it in store.items {
            guard it.enabled,
                  let s = fmt.date(from: it.start),
                  let e = fmt.date(from: it.end) else { continue }
            if now < s {
                if best == nil || s < best! { best = s }      // 待启用：到点出现
            } else if now <= e {
                if best == nil || e < best! { best = e }      // 进行中：到点消失
            }
            // 已过期(end<now)：不会再改变生效集合，跳过
        }
        return best
    }

    @ViewBuilder
    private var content: some View {
        let active = store.activeItems()
        if active.isEmpty {
            EmptyView()
        } else {
            let loop = active.count > 1
            let built = buildPages(active, loop: loop)
            // 以广告 id 顺序作为重置键：增删或排序变化都会重建并重新定位到首条
            let key = active.map(\.id).joined(separator: ",")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(built) { p in
                        adCell(p.item)
                            .id(p.id)
                            .containerRelativeFrame(.horizontal)
                            .frame(maxHeight: .infinity)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollID)
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
            .onAppear {
                // 进入时定位到首条（.onAppear 已验证触发）
                currentIndex = 0
                scrollID = built[0].id
            }
            .overlay(alignment: .bottomTrailing) {
                if loop {
                    pageDots(count: active.count, current: dotIndex(builtCount: built.count))
                        .padding(8)
                }
            }
            // 多条广告时每 4 秒从右往左推进一页；到末尾克隆页后无动画瞬移回真实首条，方向始终一致。
            // 用 .onReceive(timer) 代替 .task(id:)，避免本环境 .task 不派发的问题。
            .onReceive(timer) { _ in
                // 广告列表变化（新增/删除/排序）时重置到首条
                if loopKey != key {
                    loopKey = key
                    currentIndex = 0
                    scrollID = built[0].id
                    return
                }
                guard loop, currentIndex < built.count else {
                    currentIndex = 0
                    scrollID = built[0].id
                    return
                }
                currentIndex += 1
                withAnimation(.easeInOut(duration: 0.35)) { scrollID = built[currentIndex].id }
                // 到达尾部克隆页（内容与首条相同）：动画结束后无动画瞬移回真实首条，视觉无缝
                if currentIndex == built.count - 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        currentIndex = 0
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { scrollID = built[0].id }
                    }
                }
            }
        }
    }

    /// 多条时：在真实列表后追加一条「首条克隆页」，用于单向循环到尾时无缝接回首条。
    private func buildPages(_ items: [AdItem], loop: Bool) -> [AdPage] {
        guard loop, let first = items.first else {
            return items.map { AdPage(id: $0.id, item: $0) }
        }
        var result = items.map { AdPage(id: $0.id, item: $0) }
        result.append(AdPage(id: "tail-\(first.id)", item: first))
        return result
    }

    /// 当前小圆点下标：尾部克隆页等同首条（dot 0）。
    private func dotIndex(builtCount: Int) -> Int {
        if currentIndex <= 0 { return 0 }
        if currentIndex >= builtCount - 1 { return 0 }
        return currentIndex
    }

    private func pageDots(count: Int, current: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.white : Color.white.opacity(0.5))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func adCell(_ item: AdItem) -> some View {
        ZStack {
            adImage(item)
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .bottom, endPoint: .top)
                .ignoresSafeArea()
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(AIATheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let sub = item.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(AIATheme.Font.micro)
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .padding(14)
        }
        .clipped()
        // 本环境自定义 Button(action:) 闭包不派发，改用 .onTapGesture 触发跳转
        .contentShape(Rectangle())
        .onTapGesture {
            guard let url = URL(string: item.link), UIApplication.shared.canOpenURL(url) else { return }
            if (item.openMode ?? "inApp") == "browser" {
                UIApplication.shared.open(url)          // 跳系统浏览器
            } else {
                browserTarget = BrowserTarget(url: url) // App 内打开（默认）
            }
        }
    }

    @ViewBuilder
    private func adImage(_ item: AdItem) -> some View {
        if let b64 = item.imageBase64, let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let u = item.imageURL, let url = URL(string: u) {
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFill() }
                else { gradient }
            }
        } else {
            gradient
        }
    }

    private var gradient: some View {
        LinearGradient.techAccent
    }
}
