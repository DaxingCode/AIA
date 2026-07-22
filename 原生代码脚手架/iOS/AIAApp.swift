// AIAApp.swift
// App 入口。创建 SwiftData 容器，加载首页。
import SwiftUI
import SwiftData

@main
struct AIAApp: App {
    let container: ModelContainer

    init() {
        // 显式指定存储路径：换名字即可让旧 store 被「遗弃」，避免 Double→String
        // 这类非轻量迁移卡死启动；同时也方便下面出错时精准删除。
        let schema = Schema([
            Bill.self, Reminder.self, FoodEntry.self, HealthMetric.self
        ])
        let storeURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIA.store")
        let config = ModelConfiguration(schema: schema, url: storeURL)

        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // 开发期 schema 变更（如字段类型 Double→String）SwiftData 无法自动迁移，
            // 旧 store 文件会导致启动时崩溃。直接删旧库重建（开发阶段无用户数据风险）。
            print("⚠️ SwiftData 初始化失败，删除旧库后重建：\(error.localizedDescription)")
            Self.deleteStore(at: storeURL)
            container = try! ModelContainer(for: schema, configurations: [config])
        }
    }

    /// 删除 SwiftData 的 sqlite 主文件及其 -wal / -shm 附属文件
    private static func deleteStore(at url: URL) {
        let fm = FileManager.default
        for ext in ["", "-wal", "-shm"] {
            let file = ext.isEmpty ? url : url.appendingPathExtension(ext)
            try? fm.removeItem(at: file)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
