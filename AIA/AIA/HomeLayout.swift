// HomeLayout.swift
// 首页宫格可配置化：模块枚举 + 布局单例（本地 UserDefaults，不跨云同步）。
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// 模块在首页的布局形态。
enum HomeModuleLayout {
    case gridCard   // 四宫格卡片（2 列网格内占 1 格）
    case fullRow    // 整行（如「今日事项预览」气泡区）
}

/// 首页可配置模块。
/// 仅做「显示 / 隐藏」与「排序」，不新增业务卡片。
enum HomeModule: String, CaseIterable, Identifiable, Hashable, Codable {
    case diet, health, bill, todo, aiSummary

    var id: String { rawValue }

    var layout: HomeModuleLayout {
        switch self {
        case .aiSummary: return .fullRow
        default:         return .gridCard
        }
    }

    var title: String {
        switch self {
        case .diet:      return "饮食记录"
        case .health:    return "健康管理"
        case .bill:      return "账单管理"
        case .todo:      return "待办提醒"
        case .aiSummary: return "今日事项预览"
        }
    }

    var icon: String {
        switch self {
        case .diet:      return "fork.knife"
        case .health:    return "heart.fill"
        case .bill:      return "creditcard.fill"
        case .todo:      return "checklist"
        case .aiSummary: return "sparkles"
        }
    }

    /// 语义色（与 UI 约定一致：food/health/bill/todo/blue）
    var accent: Color {
        switch self {
        case .diet:      return AIATheme.food
        case .health:    return AIATheme.health
        case .bill:      return AIATheme.bill
        case .todo:      return AIATheme.todo
        case .aiSummary: return AIATheme.blue
        }
    }

    /// 识别结果类型（food/bill/health/todo）映射到首页模块（diet/bill/health/todo）。
    /// Siri/快捷指令记完后写共享暂存、首页据此高亮对应卡片（识别类型用 food，首页模块用 diet）。
    nonisolated init?(recognitionType: String) {
        switch recognitionType {
        case "food":      self = .diet
        case "bill":      self = .bill
        case "health":    self = .health
        case "todo":      self = .todo
        default:          return nil
        }
    }
}

/// 支持首页编辑态的拖拽重排（.draggable + .dropDestination 需要 Transferable）。
extension HomeModule: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: HomeModule.self, contentType: .data)
    }
}

/// 首页布局单例：order（顺序）+ hidden（隐藏集合）存 UserDefaults，不跨云同步。
///
/// 初始化做「差集补齐」：未来新增的 HomeModule case 若不在已存 order 中，
/// 自动追加到末尾且默认可见——老用户升级零变化、自动见到新模块。
final class HomeLayoutStore: ObservableObject {
    static let shared = HomeLayoutStore()

    static let defaultOrder: [HomeModule] = [.diet, .health, .bill, .todo, .aiSummary]

    private let orderKey  = "home.moduleOrder"
    private let hiddenKey = "home.hiddenModules"

    @Published private(set) var order: [HomeModule]
    @Published private(set) var hidden: Set<HomeModule>

    init() {
        let storedOrder = Self.parseList(UserDefaults.standard.string(forKey: orderKey))
        var merged = storedOrder
        for m in Self.defaultOrder where !merged.contains(m) {
            merged.append(m)
        }
        self.order = merged
        self.hidden = Set(Self.parseList(UserDefaults.standard.string(forKey: hiddenKey)))
    }

    private static func parseList(_ raw: String?) -> [HomeModule] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { HomeModule(rawValue: $0) }
    }

    private func persist() {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: orderKey)
        UserDefaults.standard.set(hidden.map(\.rawValue).joined(separator: ","), forKey: hiddenKey)
    }

    /// 当前可见模块（按 order，剔除 hidden）。
    func visibleModules() -> [HomeModule] {
        order.filter { !hidden.contains($0) }
    }

    func isHidden(_ m: HomeModule) -> Bool { hidden.contains(m) }

    func setHidden(_ m: HomeModule, _ isHidden: Bool) {
        if isHidden { hidden.insert(m) } else { hidden.remove(m) }
        persist()
    }

    /// 列表排序（设置页 .onMove 用）。
    func move(from offsets: IndexSet, to destination: Int) {
        order.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    /// 拖拽重排：把 dragged 插到 target 之前。
    func move(_ dragged: HomeModule, before target: HomeModule) {
        guard dragged != target,
              let from = order.firstIndex(of: dragged),
              order.contains(target) else { return }
        order.remove(at: from)
        if let newTo = order.firstIndex(of: target) {
            order.insert(dragged, at: newTo)
        } else {
            order.append(dragged)
        }
        persist()
    }

    /// 拖拽实时重排（编辑态 live reflow）：每次拖拽物「跨入」某个模块区域即把 dragged 插到该模块原索引，
    /// 其余模块随之让位。dropEntered 仅在进入新模块时触发一次，不会逐帧抖动。
    func relocate(_ dragged: HomeModule, relativeTo target: HomeModule) {
        guard dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(dragged, at: to)
        persist()
    }

    /// 恢复默认布局：顺序复位 + 取消所有隐藏。
    func reset() {
        order = Self.defaultOrder
        hidden = []
        persist()
    }

    /// 放弃内存改动：重读 UserDefaults，将 order/hidden 还原为已持久化的值。
    /// 用于非 Pro 用户「允许看/拖/改但不落库」场景——退出编辑态时回滚本次会话的内存改动。
    func reload() {
        let storedOrder = Self.parseList(UserDefaults.standard.string(forKey: orderKey))
        var merged = storedOrder
        for m in Self.defaultOrder where !merged.contains(m) {
            merged.append(m)
        }
        order = merged
        hidden = Set(Self.parseList(UserDefaults.standard.string(forKey: hiddenKey)))
    }

    /// 编辑态进入瞬间拍下的快照（内存态，不落库）。
    /// 用于非 Pro 用户退出编辑时把内存改动一键回滚到进入前，避免误保存。
    struct Snapshot {
        let order: [HomeModule]
        let hidden: Set<HomeModule>
    }

    func snapshot() -> Snapshot {
        Snapshot(order: order, hidden: hidden)
    }

    /// 用快照回滚内存改动并写回 UserDefaults（丢弃本次编辑会话的隐藏/排序变更）。
    func restore(_ snap: Snapshot) {
        order = snap.order
        hidden = snap.hidden
        persist()
    }
}
