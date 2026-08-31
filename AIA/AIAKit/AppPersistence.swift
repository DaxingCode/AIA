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

public enum AppPersistence {
    /// 当前 SwiftData schema 版本（仅用于记录，不再参与文件名）。
    /// 每次改 @Model 字段或新增模型：+1 并在 AIAMigrationPlan 加对应 Stage。
    /// 必须与 `schema` 实际引用的 VersionedSchema（SchemaVersion18）保持一致，
    /// 否则日志/排查时版本号错乱，掩盖真实的迁移失败。
    public static let currentSchemaVersion = 18

    /// App Group 标识符：主 App / Widget / ShareExtension / Siri 都靠它共享同一份 store 文件。
    /// 关键：Widget 是独立进程，它的 applicationSupportDirectory 与
    /// 主 App 沙盒互相隔离。若 store 放沙盒，Widget 打开的是自己沙盒里的空库 →
    /// 锁屏 widget 永远读不到数据（表现为"暂无""暂无记录"）。
    /// 放 App Group 容器目录后，所有进程读写的是同一个 SQLite，Widget 直接读 SwiftData 才生效。
    public static let appGroupID = "group.com.daxing.aia"

    /// 统一 store 文件（不再随版本号变化），位于 App Group 共享容器目录。
    public static var storeURL: URL {
        let groupDir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return groupDir.appendingPathComponent("AIA.store")
    }

    /// 旧库备份目录：检测到 AIA.store.v1/v2 时先复制一份到这里，作为「导出备份」兜底。
    public static var backupsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups")
    }

    /// 当前 schema：从 AIAMigrationPlan 的 v18 版本化 schema 构造（含 DailyHealthMetric + ChatMessage.actionRouteRaw），
    /// 必须与 `currentSchemaVersion`（18）保持一致，否则新增模型不在 container
    /// schema 里注册 → context.insert 静默丢弃、数据不落盘（删 App 重装后尤为明显）。
    public static var schema: Schema { Schema(versionedSchema: SchemaVersion18.self) }

    /// 崩溃安全：磁盘库任何原因初始化失败，回退到内存存储，保证至少能写入（不白屏）。
    public static func makeContainer() -> ModelContainer {
        // >>> CHANGE-[2026-08-31 18:00:00]-[降级标记粘住修复] 开始
        // 关键修复：每次启动先清除「降级内存存储」标记，使该标记只反映【本次启动】的真实状态。
        // 旧逻辑只在失败时 set(true)、从不清除 → 标记永久粘住，即使后续库正常打开警告也一直弹。
        UserDefaults.standard.removeObject(forKey: "aia.storeDegradedToMemory")
        // <<< CHANGE-[2026-08-31 18:00:00]-[降级标记粘住修复] 结束
        // 🟢 无条件 print：证明函数真的被调用了。如果连这行都看不到 = 跑的是旧二进制
        print("🟢 [AppPersistence.makeContainer] 函数被调用 (build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        // 首次启用新文件名：把旧 AIA.store.v1/v2 备份并迁移到 AIA.store
        migrateLegacyStoreFilesIfNeeded()
        // 把「旧沙盒 AIA.store」一次性迁移到 App Group 容器（storeURL 现已指向 App Group）。
        // 仅当 App Group 里还没有 store、且旧沙盒存在时执行一次，避免覆盖已迁移数据。
        migrateSandboxStoreToAppGroupIfNeeded()

        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)

        // 1. 正式迁移：用 MigrationPlan 自动升级 schema 版本元数据
        do {
            // 临时关闭 os_log 活动流，屏蔽 SwiftData/CoreData 在迁移链构建期间打出的
            // "version checksum while the model is still editable" 噪音日志（仅屏蔽 os_log 活动流，
            // 不影响 stdout 的 print 调试日志，也不影响 SwiftData 行为）。初始化后恢复原值。
            let prevMode = getenv("OS_ACTIVITY_MODE").flatMap { String(cString: $0) }
            setenv("OS_ACTIVITY_MODE", "disable", 1)
            defer {
                if let prev = prevMode { setenv("OS_ACTIVITY_MODE", prev, 1) }
                else { unsetenv("OS_ACTIVITY_MODE") }
            }
            let c = try ModelContainer(for: schema, migrationPlan: AIAMigrationPlan.self, configurations: [config])
            print("✅ [AppPersistence] 磁盘库打开成功 store=\(storeURL.lastPathComponent) schemaVersion=\(currentSchemaVersion)")
            return c
        } catch {
            // >>> CHANGE-[2026-08-31 18:00:00]-[降级日志打全] 开始
            // 旧逻辑只打印 localizedDescription（常是"未能完成操作"，等于没说）。
            // 改为打印完整 error 及底层错误，并附带 store 文件状态，便于定位
            // 「文件损坏 / 版本太新 / schema 校验和冲突」等真实原因。
            print("❌ [AppPersistence] 磁盘库+迁移计划打开失败：\(error)")
            if let nsError = error as NSError? {
                print("   → 错误域: \(nsError.domain) 码: \(nsError.code)")
                if let reason = nsError.localizedFailureReason { print("   → 原因: \(reason)") }
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("   → 底层错误: \(underlying)")
                }
            }
            if FileManager.default.fileExists(atPath: storeURL.path) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: storeURL.path),
                   let size = attrs[.size] as? Int64 {
                    print("   → 磁盘 store 存在，大小 \(size) 字节，路径：\(storeURL.path)")
                }
            } else {
                print("   → 磁盘 store 不存在：\(storeURL.path)")
            }
            // <<< CHANGE-[2026-08-31 18:00:00]-[降级日志打全] 结束
        }
        // 2. 兜底：迁移计划已失败（磁盘 store 的版本不在 v1..v15 迁移阶梯中，
        //    即 "unknown model version"），此时任何「无迁移直接打开」都会把 store 置于
        //    schema 错位状态，随后（后台同步 / 首页 @Query 渲染访问半损坏数据）触发
        //    数组越界崩溃。这是之前真机卡死的根因。
        //    因此：**不再尝试无迁移打开**，直接备份旧 store 并降级为内存存储（安全而非带病运行）。
        //    用户数据在云端，重装 App 登录即恢复；本次降级仅用于避免崩溃 + 给出提示。
        print("❌ [AppPersistence] 迁移计划失败，磁盘 store 版本与当前 schema(v\(currentSchemaVersion)) 不匹配，备份并降级内存存储")
        backupStore(from: storeURL)
        // 标记：本次启动走了「非持久化降级」，供 UI 层提示用户「数据需从云端恢复 / 重装 App」。
        UserDefaults.standard.set(true, forKey: "aia.storeDegradedToMemory")
        // 3. 最终兜底：内存存储，保证不白屏
        // ⚠️ 重要：内存存储意味着每次冷启动数据全丢，必须在控制台醒目提示
        print("🔴 [AppPersistence] 最终回退：内存存储！本次会话写入不会持久化，下次冷启动全丢。")
        let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        if let memContainer = try? ModelContainer(for: schema, configurations: [mem]) {
            return memContainer
        }
        // 4. 极端兜底：连内存 schema 都建不出来（理论不会发生），用空 Schema 保证 App 不崩。
        //    此时任何 SwiftData 读写都会失败，但启动不会 crash，便于排查。
        print("⛔️ [AppPersistence] 内存 schema 也建不出，使用空存储兜底（数据不可读写，仅防崩溃）")
        let empty = Schema([])
        let emptyConfig = ModelConfiguration(schema: empty, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        if let c = try? ModelContainer(for: empty, configurations: [emptyConfig]) {
            return c
        }
        // 最后手段：连空 schema 都无法初始化（代码级 schema bug），给出明确崩溃信息便于定位。
        do {
            return try ModelContainer()
        } catch {
            fatalError("⛔️ [AppPersistence] 无法创建任何 ModelContainer，请检查 SwiftData @Model schema 定义：\(error)")
        }
    }

    /// 只读容器：供 Widget / App Extension 等独立进程访问同一份 store。
    /// 用只读配置打开，避免与正在运行的主 App 争写；打开失败同样回退内存存储。
    public static func makeReadOnlyContainer() -> ModelContainer {
        let config = ModelConfiguration(schema: schema, url: storeURL, allowsSave: false, cloudKitDatabase: .none)
        do {
            let c = try ModelContainer(for: schema, configurations: [config])
            print("✅ [AppPersistence] 只读库打开成功 store=\(storeURL.lastPathComponent)")
            return c
        } catch {
            print("⚠️ [AppPersistence] 只读库打开失败：\(error.localizedDescription)，回退内存存储")
            let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            if let memContainer = try? ModelContainer(for: schema, configurations: [mem]) {
                return memContainer
            }
            // 极端兜底：连内存 schema 都建不出，用空 Schema 保证 Widget 进程不崩。
            let empty = Schema([])
            let emptyConfig = ModelConfiguration(schema: empty, isStoredInMemoryOnly: true)
            if let c = try? ModelContainer(for: empty, configurations: [emptyConfig]) {
                return c
            }
            // 最后手段：连空 schema 都无法初始化（代码级 schema bug），给出明确崩溃信息便于定位。
            do {
                return try ModelContainer()
            } catch {
                fatalError("⛔️ [AppPersistence] 无法创建任何只读 ModelContainer，请检查 SwiftData @Model schema 定义：\(error)")
            }
        }
    }

    /// Siri/快捷指令后台写入用的【独立可写】container，指向与主 App 同一份 AIA.store。
    /// 关键：与主 App 的 sharedContainer 是**不同实例**——SwiftData 的
    /// NSManagedObjectContextDidSaveNotification 合并按 container 的 parentContext 链传播，
    /// 不同 container 之间**不会**自动合并，因此前台 @Query 完全不被这次写入惊动 → 不卡首页。
    /// 无论 App 前台/后台/冷启都走它，彻底断开与 mainContext 的实时合并。
    /// 打开失败回退内存存储（保证不崩，仅本次不持久化）。
    public static func makeSiriWriteContainer() -> ModelContainer? {
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        // 同 makeContainer：临时屏蔽 CoreData 迁移链噪音，不影响 print 与 SwiftData 行为。
        let prevMode = getenv("OS_ACTIVITY_MODE").flatMap { String(cString: $0) }
        setenv("OS_ACTIVITY_MODE", "disable", 1)
        defer {
            if let prev = prevMode { setenv("OS_ACTIVITY_MODE", prev, 1) }
            else { unsetenv("OS_ACTIVITY_MODE") }
        }
        if let c = try? ModelContainer(for: schema, migrationPlan: AIAMigrationPlan.self, configurations: [config]) {
            print("✅ [AppPersistence] Siri 独立写库打开成功 store=\(storeURL.lastPathComponent)")
            return c
        }
        print("⚠️ [AppPersistence] Siri 独立写库打开失败，回退内存存储")
        let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try? ModelContainer(for: schema, configurations: [mem])
    }

    // MARK: - 旧版本 store 文件迁移 + 备份兜底
    /// 旧版本 store 文件名示例：AIA.store.v1、AIA.store.v2（早期开发期用版本后缀做防白屏兜底）。
    /// 把旧沙盒（applicationSupportDirectory）里的 AIA.store 一次性迁移到 App Group 容器。
    /// storeURL 现已指向 App Group，旧数据留在主 App 沙盒里会导致用户数据"丢失"。
    /// 仅当 App Group 容器里还没有 AIA.store、且旧沙盒存在时复制一次，幂等安全。
    private static func migrateSandboxStoreToAppGroupIfNeeded() {
        let fm = FileManager.default
        let sandboxStore = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIA.store")
        // App Group 里已存在 → 已迁移过，跳过
        guard !fm.fileExists(atPath: storeURL.path) else { return }
        // 旧沙盒里也没有 → 全新安装，无需迁移
        guard fm.fileExists(atPath: sandboxStore.path) else { return }

        // 旧沙盒可能带 v1/v2 后缀或配套 wal/sha 文件，整体按 AIA.store 前缀迁移
        let sandboxDir = sandboxStore.deletingLastPathComponent()
        let candidates = ["AIA.store", "AIA.store-wal", "AIA.store-shm"]
        var migratedAny = false
        for name in candidates {
            let from = sandboxDir.appendingPathComponent(name)
            let to = storeURL.deletingLastPathComponent().appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) {
                try? fm.copyItem(at: from, to: to)
                migratedAny = true
            }
        }
        if migratedAny {
            print("✅ [AppPersistence] 已把旧沙盒 AIA.store 迁移到 App Group 容器 store=\(storeURL.path)")
        }
    }

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
