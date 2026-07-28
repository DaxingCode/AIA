// DuplicateStore.swift
// 重复识别指纹的侧车存储：不进 SwiftData（避免升 schemaVersion、不动业务库），
// 仅用 Documents/imageHashes.json 记录「已存记录的图片指纹 + 时间 + 摘要」。
// 识别入库前比对指纹，命中仅用于「似乎已记录过」警告提示，不再阻断入库；
// 用户可在确认页编辑/保留/删除，是否真重复由用户决定。
import Foundation
import UIKit

/// 一条历史指纹记录（持久化用）。
/// hashD 为主指纹（dHash）；ratio 为图片宽/高，用于 match 比例校验降低误报。
struct DuplicateEntry: Codable, Identifiable {
    var id: String { hashD }
    let hashD: String
    let ratio: CGFloat
    let recognizedAt: Date
    let types: String      // 逗号分隔类型，如 "bill,todo"
    let summary: String    // 人类可读摘要，如 "账单 ¥19.96 · 中国电信"

    private enum CodingKeys: String, CodingKey {
        case hashD, ratio, recognizedAt, types, summary, hash
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = try? c.decode(String.self, forKey: .hashD)
        let a = try? c.decode(String.self, forKey: .hash)   // 兼容旧版 aHash 字段
        self.hashD = d ?? a ?? ""
        self.ratio = (try? c.decode(CGFloat.self, forKey: .ratio)) ?? 0
        self.recognizedAt = try c.decode(Date.self, forKey: .recognizedAt)
        self.types = try c.decode(String.self, forKey: .types)
        self.summary = try c.decode(String.self, forKey: .summary)
    }

    init(hashD: String, ratio: CGFloat, recognizedAt: Date, types: String, summary: String) {
        self.hashD = hashD; self.ratio = ratio
        self.recognizedAt = recognizedAt; self.types = types; self.summary = summary
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hashD, forKey: .hashD)
        try c.encode(ratio, forKey: .ratio)
        try c.encode(recognizedAt, forKey: .recognizedAt)
        try c.encode(types, forKey: .types)
        try c.encode(summary, forKey: .summary)
        // 不编码 hash（旧字段），避免 CodingKeys 引用无对应存储属性而编解码失败
    }
}

/// 命中重复时携带的上下文：原始识别输入 + 匹配到的原记录信息。
/// （历史流程：用户点「仍要记录」才真正入库。现改为命中即自动入库，仅作警告参考。）
struct DuplicatePayload {
    let result: RecognitionResult
    let rawText: String
    let sourceImage: UIImage?
    let hash: String
    let ratio: CGFloat      // 图片宽/高，供确认页回写指纹时保留比例，避免被 0 覆盖
    let recognizedAt: Date   // 原记录时间
    let summary: String      // 原记录摘要
    let existingTypes: String
    /// 识别来源（本地 / 云端），确认页据此展示标签。
    let source: RecognizeService.RecognitionSource = .cloud
}

/// 疑似重复提示（已自动入库，仅用于确认页顶部警告横幅）。
/// 与 DuplicatePayload 不同：这里不阻断入库，只携带原记录元数据供用户参考。
struct DuplicateHint: Codable {
    let recognizedAt: Date
    let summary: String
    let existingTypes: String
}

/// 入库决策：当前统一「正常入库」；命中重复指纹时仍入库，仅在 session.duplicateHint 挂警告。
/// （历史上存在 .duplicate 分支用于「命中即不入库」，现已移除，保留枚举字段无副作用。）
enum SaveDecision {
    case saved(SavedSession)
    case duplicate(DuplicatePayload)
}

/// 确认页呈现载荷（统一三个入口的驱动状态）。
enum RecognitionPresent: Identifiable {
    case saved(SavedSession)      // 已自动入库（旧流程，保留兼容）
    case duplicate(DuplicatePayload)  // 命中重复（尚未入库）
    case pending(RecognitionResult, rawText: String, image: UIImage?, source: RecognizeService.RecognitionSource)  // 新鲜识别，未入库
    var id: String {
        switch self {
        case .saved(let s): return "saved-\(s.id.uuidString)"
        case .duplicate(let d): return "dup-\(d.hash)"
        case .pending(let result, let rawText, _, _):
            // 基于内容生成确定性 id，避免每次访问 UUID() 产生新值导致 SwiftUI 误认为不同 item 而反复关闭/重现 cover
            let summary = RecognitionSaver.summary(of: result)
            return "pending-\(rawText.hashValue)-\(summary.hash)"
        }
    }
}

extension SaveDecision {
    var present: RecognitionPresent {
        switch self {
        case .saved(let s): return .saved(s)
        case .duplicate(let d): return .duplicate(d)
        }
    }
}

enum DuplicateStore {
    /// 汉明距离阈值（0~64），越大越宽松。dHash 更稳，从 aHash 的 10 收紧到 8 降低误报。
    private static let threshold = 8
    /// LRU 容量上限，超出丢弃最旧，避免 imageHashes.json 无限膨胀带来跨类别误命中。
    private static let capacity = 500

    private static let file: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imageHashes.json")
    }()

    static func load() -> [DuplicateEntry] {
        guard let data = try? Data(contentsOf: file),
              let arr = try? JSONDecoder().decode([DuplicateEntry].self, from: data) else { return [] }
        return arr
    }

    static func save(_ entries: [DuplicateEntry]) {
        try? JSONEncoder().encode(entries).write(to: file)
    }

    /// 返回与给定 hash 汉明距离 ≤ threshold 且比例相近的最近一条历史；无则 nil。
    /// ratio 校验（宽/高差 < 0.05）可过滤不同尺寸/裁切的图，大幅降低误报。
    static func match(_ hash: String, ratio: CGFloat) -> DuplicateEntry? {
        var best: DuplicateEntry?
        var bestDist = Int.max
        for e in load() {
            guard !e.hashD.isEmpty else { continue }
            guard abs(e.ratio - ratio) < 0.05 else { continue }
            let d = ImageHasher.hammingDistance(hash, e.hashD)
            if d <= threshold, d < bestDist {
                bestDist = d
                best = e
            }
        }
        return best
    }

    /// 登记一条新指纹（同 hashD 去重覆盖；超出容量丢弃最旧，实现 LRU）。
    static func add(_ entry: DuplicateEntry) {
        var entries = load()
        entries.removeAll { $0.hashD == entry.hashD }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        save(entries)
    }
}
