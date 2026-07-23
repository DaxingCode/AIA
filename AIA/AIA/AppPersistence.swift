// AppPersistence.swift
// SwiftData 容器单一来源：主 App 与 App Intents（Siri 后台运行）都用它，
// 确保访问的是「同一个」store 文件（AIA.store），不会各写各的沙盒。
//
// 迁移策略（防数据丢失）：
//   - store 文件名固定为 AIA.store，不再带版本后缀。
//   - 新增模型/字段时，在 AIAMigrationPlan.swift 追加 SchemaVersion + MigrationStage，
//     SwiftData 会自动完成轻量迁移，老用户数据不会丢。
//   - 若旧文件存在（AIA.store.v1 / AIA.store.v2），首次切换到新文件前会自动备份到
//     Backups/ 目录，再复制到 AIA.store 交给迁移计划处理。
//   - 迁移/初始化仍失败时，回退到内存存储（保证不白屏），并保留旧文件备份。
import SwiftData
import Foundation

enum AppPersistence {
    /// 当前 SwiftData schema 版本（仅用于记录，不再参与文件名）。
    /// 每次改 @Model 字段或新增模型：+1 并在 AIAMigrationPlan 加对应 Stage。
    static let currentSchemaVersion = 9

    /// 统一 store 文件（不再随版本号变化）。
    static var storeURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIA.store")
    }

    /// 旧库备份目录：检测到 AIA.store.v1/v2 时先复制一份到这里，作为「导出备份」兜底。
    static var backupsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups")
    }

    /// 当前 schema：从 AIAMigrationPlan 的 v9 版本化 schema 构造，确保迁移计划能识别。
    static var schema: Schema { Schema(versionedSchema: SchemaVersion9.self) }

    /// 崩溃安全：磁盘库任何原因初始化失败，回退到内存存储，保证至少能写入（不白屏）。
    static func makeContainer() -> ModelContainer {
        // 首次启用新文件名：把旧 AIA.store.v1/v2 备份并迁移到 AIA.store
        migrateLegacyStoreFilesIfNeeded()

        let config = ModelConfiguration(schema: schema, url: storeURL)

        // 1. 正式迁移：用 MigrationPlan 自动升级 schema 版本元数据
        do {
            let c = try ModelContainer(for: schema, migrationPlan: AIAMigrationPlan.self, configurations: [config])
            print("✅ [AppPersistence] 磁盘库打开成功 store=\(storeURL.lastPathComponent) schemaVersion=9")
            return c
        } catch {
            print("❌ [AppPersistence] 磁盘库+迁移计划打开失败：\(error.localizedDescription)\n  → 失败原因通常是 schema checksum 不匹配或 v8→v9 迁移无法识别同 model（v8 内嵌 RecurringRule vs v9 外层 RecurringRule 不同 class identity）")
        }
        // 2. 兜底：迁移计划失败时，尝试无迁移计划直接打开（旧 v2 文件元数据异常时的逃生通道）
        do {
            let c = try ModelContainer(for: schema, configurations: [config])
            print("⚠️ [AppPersistence] 跳过迁移计划直接打开成功——这通常意味着 schema 已被识别为 v9，不需要迁移")
            return c
        } catch {
            print("❌ [AppPersistence] 跳过迁移也失败：\(error.localizedDescription)\n  → 极可能是 SwiftData 模型类 identity 与 store 不匹配，将回退到内存存储（**冷启动数据会丢**）")
        }
        // 3. 最终兜底：内存存储，保证不白屏
        // ⚠️ 重要：内存存储意味着每次冷启动数据全丢，必须在控制台醒目提示
        print("🔴 [AppPersistence] 最终回退：内存存储！本次会话写入不会持久化，下次冷启动全丢。")
        let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return (try? ModelContainer(for: schema, configurations: [mem]))!
    }

    // MARK: - 旧版本 store 文件迁移 + 备份兜底
    /// 旧版本 store 文件名示例：AIA.store.v1、AIA.store.v2（早期开发期用版本后缀做防白屏兜底）。
    /// 本函数只做一次：在 AIA.store 不存在时，按 v2 → v1 优先级查找旧文件，
    /// 先备份到 Backups/，再复制到 AIA.store，然后由 AIAMigrationPlan 自动迁移。
    private static func migrateLegacyStoreFilesIfNeeded() {
        let fm = FileManager.default
        let baseDir = storeURL.deletingLastPathComponent()
        let v2URL = baseDir.appendingPathComponent("AIA.store.v2")
        let v1URL = baseDir.appendingPathComponent("AIA.store.v1")

        guard !fm.fileExists(atPath: storeURL.path) else { return }

        if fm.fileExists(atPath: v2URL.path) {
            backupStore(from: v2URL)
            try? fm.copyItem(at: v2URL, to: storeURL)
            print("[AppPersistence] 已复制旧库 \(v2URL.lastPathComponent) → AIA.store")
        } else if fm.fileExists(atPath: v1URL.path) {
            backupStore(from: v1URL)
            try? fm.copyItem(at: v1URL, to: storeURL)
            print("[AppPersistence] 已复制旧库 \(v1URL.lastPathComponent) → AIA.store，将由 AIAMigrationPlan 迁移到 v2")
        }
    }

    /// 把旧库文件复制到 Backups/ 目录，带时间戳，作为「导出备份」兜底。
    private static func backupStore(from url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true, attributes: nil)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let backupName = "\(url.lastPathComponent).backup_\(fmt.string(from: Date()))"
        let backupURL = backupsDirectory.appendingPathComponent(backupName)

        try? fm.copyItem(at: url, to: backupURL)
        print("[AppPersistence] 旧库已备份到 \(backupURL)")
    }
}
