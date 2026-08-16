// SubscriptionManager.swift
// StoreKit 2 订阅层：¥88/年 + ¥8.8/月（自动续期，同一订阅组内互斥升降级）。
//
// 与付费墙的关系：
//   本类只负责「本机是否持有有效订阅」这一客户端事实（isPaid），
//   真正的权益判定链仍在服务端 aia-sync/entitlement.js：白名单 → 订阅 → 试用 → 免费额度 → 全局熔断。
//   交易状态变化后写入 UserDefaults("aia.isPaid")，供 EntitlementManager 注入每次云请求。
//
// App Store Connect 配置（必须与下方 productId 完全一致）：
//   订阅组：AIA Pro
//     - com.daxing.aia.pro.monthly  ¥8.8  / 月（价格档 Tier CNY 8.80）
//     - com.daxing.aia.pro.yearly   ¥88   / 年（价格档 Tier CNY 88.00）
//   两者放在同一订阅组内，用户可自由升降级，Apple 自动按比例退补差价。
import Foundation
import StoreKit
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 订阅商品定义
enum SubscriptionProduct: String, CaseIterable, Identifiable, Sendable {
    case monthly = "com.daxing.aia.pro.monthly"
    case yearly  = "com.daxing.aia.pro.yearly"

    var id: String { rawValue }

    /// 展示名
    var title: String {
        switch self {
        case .monthly: return "包月"
        case .yearly:  return "包年"
        }
    }

    /// 兜底价格文案（商品未加载成功时展示；真实价格以 StoreKit 返回的本地化价格为准）
    var fallbackPrice: String {
        switch self {
        case .monthly: return "¥8.8"
        case .yearly:  return "¥88"
        }
    }

    var periodText: String {
        switch self {
        case .monthly: return "每月"
        case .yearly:  return "每年"
        }
    }

    /// 折算月均（仅年付展示）
    var perMonthText: String? {
        switch self {
        case .monthly: return nil
        case .yearly:  return "约 ¥7.3 / 月"
        }
    }

    /// 相对月付的省钱幅度（88 / (8.8*12=105.6) ≈ 省 17%）
    var savingBadge: String? {
        switch self {
        case .monthly: return nil
        case .yearly:  return "省 17%"
        }
    }

    /// 年付为推荐档
    var isRecommended: Bool { self == .yearly }
}

@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    /// 已加载的商品（按 monthly、yearly 顺序）
    @Published private(set) var products: [Product] = []
    /// 当前生效的订阅（nil = 未订阅）
    @Published private(set) var activeProduct: SubscriptionProduct?
    /// 订阅到期时间（自动续期订阅为「本周期到期日」）
    @Published private(set) var expiresAt: Date?
    /// 正在加载商品 / 正在购买 / 正在恢复
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var purchasingId: String?
    @Published private(set) var isRestoring = false
    /// 最近一次错误（供 UI 弹窗）
    @Published var lastError: String?

    private let ud = UserDefaults.standard
    private let kIsPaid = "aia.isPaid"
    private let kExpiresAt = "aia.sub.expiresAt"
    private let kActiveProduct = "aia.sub.activeProduct"

    private var updatesTask: Task<Void, Never>?

    private init() {
        // 冷启动先用本地缓存兜底，避免首帧闪「未订阅」
        if let raw = ud.string(forKey: kActiveProduct), let p = SubscriptionProduct(rawValue: raw) {
            activeProduct = p
        }
        let exp = ud.double(forKey: kExpiresAt)
        if exp > 0 { expiresAt = Date(timeIntervalSince1970: exp) }
    }

    /// 是否持有有效订阅（客户端断言；服务端仍以此为参考并配合白名单/额度判定）
    var isSubscribed: Bool { activeProduct != nil }

    /// 取指定档位已加载的 StoreKit 商品
    func product(for item: SubscriptionProduct) -> Product? {
        products.first { $0.id == item.rawValue }
    }

    /// 本地化价格文案（加载失败时回落到硬编码兜底）
    func priceText(for item: SubscriptionProduct) -> String {
        product(for: item)?.displayPrice ?? item.fallbackPrice
    }

    // MARK: - 启动入口
    /// App 启动调用：加载商品 + 校验当前权益 + 开始监听交易更新。
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let t) = result {
                    await t.finish()
                }
                await self.refreshEntitlements()
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    // MARK: - 商品加载
    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let ids = SubscriptionProduct.allCases.map(\.rawValue)
            let fetched = try await Product.products(for: ids)
            // 固定顺序：包年在前（推荐档），包月在后
            let order: [String] = [SubscriptionProduct.yearly.rawValue, SubscriptionProduct.monthly.rawValue]
            products = fetched.sorted { a, b in
                (order.firstIndex(of: a.id) ?? 99) < (order.firstIndex(of: b.id) ?? 99)
            }
        } catch {
            lastError = "商品加载失败：\(error.localizedDescription)"
            print("[Subscription] loadProducts 失败: \(error)")
        }
    }

    // MARK: - 购买
    @discardableResult
    func purchase(_ item: SubscriptionProduct) async -> Bool {
        guard let product = product(for: item) else {
            lastError = "商品尚未加载完成，请稍后重试"
            return false
        }
        purchasingId = item.rawValue
        defer { purchasingId = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                    return true
                case .unverified(_, let error):
                    lastError = "交易校验失败：\(error.localizedDescription)"
                    return false
                }
            case .userCancelled:
                return false
            case .pending:
                lastError = "购买待确认（可能需要家长同意），完成后会自动生效"
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "购买失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 恢复购买
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
        } catch {
            lastError = "恢复失败：\(error.localizedDescription)"
        }
        await refreshEntitlements()
        if activeProduct == nil && lastError == nil {
            lastError = "未找到可恢复的订阅"
        }
    }

    // MARK: - 权益校验（唯一写 isPaid 的地方）
    func refreshEntitlements() async {
        var found: SubscriptionProduct?
        var exp: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            guard t.productType == .autoRenewable else { continue }
            if let revoked = t.revocationDate, revoked <= Date() { continue }
            if let e = t.expirationDate, e <= Date() { continue }
            guard let p = SubscriptionProduct(rawValue: t.productID) else { continue }
            // 同组内若同时存在（升降级切换窗口），取到期更晚的一笔
            if let currentExp = exp, let newExp = t.expirationDate, newExp <= currentExp { continue }
            found = p
            exp = t.expirationDate
        }
        activeProduct = found
        expiresAt = exp
        persist(found, exp)
        // 订阅状态变化后，重新拉一次服务端权益快照
        await EntitlementManager.shared.refresh()
    }

    private func persist(_ p: SubscriptionProduct?, _ exp: Date?) {
        ud.set(p != nil, forKey: kIsPaid)
        if let p { ud.set(p.rawValue, forKey: kActiveProduct) } else { ud.removeObject(forKey: kActiveProduct) }
        if let exp { ud.set(exp.timeIntervalSince1970, forKey: kExpiresAt) } else { ud.removeObject(forKey: kExpiresAt) }
    }

    /// 打开系统「管理订阅」页
    func openManageSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        Task { @MainActor in
            #if canImport(UIKit)
            _ = await UIApplication.shared.open(url)
            #endif
        }
    }
}
