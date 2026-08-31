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
    init?(recognitionType: String) {
        switch recognitionType {
        case "food":      self = .diet
        case "bill":      self = .bill
        case "health":    self = .health
        case "todo":      self = .todo
        default:          return nil
        }
    }
}

// >>> CHANGE-[2026-08-31 17:55:00]-[对话页宫格高亮] 开始
/// 统一登记「首页宫格待高亮」的共享暂存。
///
/// 背景：Siri / 截屏快捷指令 / 对话页内记录（打字·语音·发图·拍照）/ 首页四宫格拍照相册，
/// 只要记录**真正入库**，就登记第一个已知类别对应的宫格，用户进入/返回首页时播一次高亮扫描。
/// 旧实现里这个 key 散落在 TellAIAIntent（硬编码 aia.siriHighlightModule）和多处 if 分支，
/// 本次收敛到本枚举，所有生产方统一走 `HomeHighlight.mark(types:)`。
///
/// 消费方：ContentView.consumeSiriHighlightModule() 读取并删除（防重复触发）。
enum HomeHighlight {
    /// 共享暂存 key（沿用旧名，避免破坏已上线的 Siri 链路）。
    static let key = "aia.siriHighlightModule"

    /// 取 types 里第一个能映射成首页模块的类别登记（与 Siri 旧口径一致：只高亮第一个）。
    /// types 形如 ["bill"] / ["food","health"]，识别类型用 food/bill/health/todo。
    static func mark(types: [String]) {
        guard let first = types.compactMap({ HomeModule(recognitionType: $0) }).first else { return }
        UserDefaults.standard.set(first.rawValue, forKey: key)
    }

    /// 供直接传 HomeModule 的调用方（如待确认卡保存时已知 item.type）。
    static func mark(_ module: HomeModule) {
        UserDefaults.standard.set(module.rawValue, forKey: key)
    }

    /// 读取并消费（消费即删除，防重复触发）。无则返回 nil。
    static func consume() -> HomeModule? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let m = HomeModule(rawValue: raw) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return m
    }
}
// <<< CHANGE-[2026-08-31 17:55:00]-[对话页宫格高亮] 结束

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
