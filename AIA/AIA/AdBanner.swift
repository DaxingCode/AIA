// AdBanner.swift
// 首页广告位：云端 aia_ads 集合远程控制，平时无广告则不展示（返回 EmptyView）。
// list 公开、listAll/upsert/delete 需开发者口令（见 DeveloperTools.swift）。
import SwiftUI
import Foundation
import Combine

// MARK: - 数据模型

struct AdItem: Codable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var link: String
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
            title: "",
            subtitle: nil,
            link: "",
            imageURL: nil,
            imageBase64: nil,
            start: ISO8601DateFormatter().string(from: now),
            end: ISO8601DateFormatter().string(from: now.addingTimeInterval(7 * 86400)),
            enabled: true,
            order: 0
        )
    }
}

// MARK: - 网络

enum AIAAdEndpoint {
    static let url = URL(string: "https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/ads")!
}

/// 向 /ads 端点 POST JSON，返回原始字典。失败抛出。
func postAdsJSON(_ payload: [String: Any]) async throws -> [String: Any] {
    var req = URLRequest(url: AIAAdEndpoint.url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (data, _) = try await URLSession.shared.data(for: req)
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
            let decoded = try JSONDecoder().decode([AdItem].self, from: data)
            items = decoded
            saveCache(decoded)
        } catch {
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

struct AdBannerView: View {
    @StateObject private var store = AdStore.shared
    @State private var current = 0
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        content
            .task { await store.fetchIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        let active = store.activeItems()
        if active.isEmpty {
            EmptyView()
        } else {
            TabView(selection: $current) {
                ForEach(Array(active.enumerated()), id: \.offset) { idx, item in
                    adCell(item).tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: active.count > 1 ? .automatic : .never))
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: AIATheme.rLG))
            .onReceive(timer) { _ in
                guard active.count > 1 else { return }
                withAnimation { current = (current + 1) % active.count }
            }
        }
    }

    private func adCell(_ item: AdItem) -> some View {
        Button {
            if let url = URL(string: item.link), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
        } label: {
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
        }
        .buttonStyle(.plain)
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
