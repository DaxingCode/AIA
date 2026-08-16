// ICloudBackupManager.swift
// iCloud 备份/恢复（重装备份模式，与腾讯云跨端同步并存互补）。
// 把本地 SwiftData 数据库（AIA.store 三件套）+ 附件图片（Documents/attachments）
// 备份到 iCloud Drive 容器的专用目录；重装/换手机后首次启动可自动恢复到本地。
//
// 与 CloudSyncManager（腾讯云 /sync 跨端同步）的关系：
//   - 腾讯云：业务数据按账号跨端多设备共享（含小程序）。
//   - iCloud：本机数据 + 图片的"设备级备份/恢复"，用于换机或重装后本地资料回流。
//   - 两者各管各的，不冲突：恢复本地库后，腾讯云 syncAfterLogin 仍会按 userId 增量合并。
import Foundation
import os.lock

enum ICloudBackupManager {
    /// 容器内备份子目录名
    private nonisolated static let backupFolderName = "AIA.iCloudBackup"
    /// SwiftData store 基础文件名（不含扩展名）；三件套：.store / -wal / -shm
    private nonisolated static let storeBaseName = "AIA.store"
    /// 用户开关 key（SettingsView 用 @AppStorage 同 key 读写）
    static let enabledKey = "aia.icloudSyncEnabled"

    /// 启动期自动恢复总开关（默认 false）。
    /// 2026-08-06 关闭：SwiftData schema 升级后，iCloud 里旧 AIA.store 的模型版本
    /// 不在当前 AIAMigrationPlan 迁移链中（NSCocoaErrorDomain 134504），启动期自动覆盖
    /// 到本地会导致主库初始化失败、回退内存库再崩（134060），表现即真机卡在「正在恢复数据…」。
    /// 跨端/换机数据回流改由腾讯云 CloudSyncManager（按账号增量合并）负责，与 iCloud 备份解耦。
    /// 设为 true 可重新开启启动期自动恢复（restore() 本身仍保留，未来设置页可暴露手动恢复入口）。
    static let startupAutoRestoreEnabled = false

    /// 备份上传进度（仅展示用）。由 backup 的 uploadStatus 回调写入；
    /// View 在备份进行中周期性读取刷新本地 @State。放这里避免跨 actor 捕获值类型 View 的 self。
    /// 用 unfair lock 包住，保证非隔离上下文（backup 内部 / View 轮询）跨线程读写安全，
    /// 且不把 backup/restore 拖成 @MainActor（否则 Swift 6 下从 Task.detached 调用会变成 error）。
    private static let progressLock = OSAllocatedUnfairLock<(uploaded: Int, total: Int)?>(initialState: nil)
    static var liveProgress: (uploaded: Int, total: Int)? {
        get { progressLock.withLock { $0 } }
        set { progressLock.withLock { $0 = newValue } }
    }

    /// 上传监听查询的当前状态（方案 B：异步监听，不阻塞 backup 返回）。
    /// 用 unfair lock 包住，供主线程轮询读取，避免跨隔离域捕获。
    private static let uploadMonitorLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// 当前是否处于「文件已复制到 iCloud 容器、等待系统后台上传」的监听态。
    static var isMonitoringUpload: Bool {
        get { uploadMonitorLock.withLock { $0 } }
        set { uploadMonitorLock.withLock { $0 = newValue } }
    }

    // MARK: - 路径
    /// iCloud ubiquity 容器根目录。用户已开启 iCloud Drive 且 App 已授权才有值，否则 nil。
    nonisolated static var containerURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    /// 备份目录：<ubiquity>/AIA.iCloudBackup/
    /// 只读不回写：探测状态的调用方（如页面级 resume）不应顺手创建目录，
    /// 避免容器不可达时在不可达路径上抛错或拖慢。
    nonisolated static var backupDir: URL? {
        guard let c = containerURL else { return nil }
        return c.appendingPathComponent(backupFolderName, isDirectory: true)
    }

    /// 本地 SwiftData 文件集合（AIA.store / -wal / -shm，存在才列）。
    nonisolated static var localStoreFiles: [URL] {
        let dir = AppPersistence.storeURL.deletingLastPathComponent()
        return [storeBaseName, storeBaseName + "-wal", storeBaseName + "-shm"]
            .map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 本地附件目录（Documents/attachments）。
    nonisolated static var localAttachmentsDir: URL { LocalImageStore.dir }

    // MARK: - 状态
    /// iCloud 是否可用（用户已开启 iCloud Drive 且 App 有 iCloud 权限）。
    nonisolated static func isAvailable() -> Bool { containerURL != nil }

    /// 是否存在可用备份（store 或 wal 任一存在即认为有）。
    nonisolated static func hasBackup() -> Bool {
        guard let d = backupDir else { return false }
        return FileManager.default.fileExists(atPath: d.appendingPathComponent(storeBaseName).path)
            || FileManager.default.fileExists(atPath: d.appendingPathComponent(storeBaseName + "-wal").path)
    }

    /// 上次备份时间（读 backup.meta）。
    static func lastBackupDate() -> Date? {
        guard let d = backupDir,
              let data = try? Data(contentsOf: d.appendingPathComponent("backup.meta")),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = dict["date"] as? Double else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// 备份总大小（字节）。遍历本地 ubiquity 备份目录（含 attachments 递归），不含 .meta。
    /// 模拟器/容器不可达返回 0。I/O 较重，调用方应在后台线程查。
    static func backupTotalBytes() -> Int64 {
        #if targetEnvironment(simulator)
        return 0
        #endif
        guard let d = backupDir else { return 0 }
        return directorySize(d)
    }

    /// 备份文件数（不含 .meta 与隐藏文件，含 attachments 递归）。
    /// 模拟器/容器不可达返回 0。I/O 较重，调用方应在后台线程查。
    nonisolated static func backupFileCount() -> Int {
        #if targetEnvironment(simulator)
        return 0
        #endif
        guard let d = backupDir else { return 0 }
        return collectUploadFiles(directory: d).count
    }

    /// 递归目录大小（字节）。
    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for child in children {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                total += directorySize(child)
            } else {
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// 是否应在启动期自动恢复：本地为全新空库 + iCloud 容器可达 + 存在 iCloud 备份（重装场景）。
    /// 不依赖本地开关（重装后 UserDefaults 已清），由「是否有备份」间接体现「之前开过 iCloud 同步」。
    /// 修复（2026-08-05）：增加 iCloud 容器可达性守卫——模拟器 / 未开启 iCloud Drive 时
    /// `containerURL` 为 nil，`backupDir` 也 nil，此时绝不进入恢复路径，否则会死等 20 秒且可能把
    /// 不兼容的旧 store 覆盖到本地导致卡死。真机 iCloud 正常时 `backupDir` 非 nil，行为完全不变。
    static func shouldAutoRestore() -> Bool {
        // 启动期自动恢复总开关关闭时直接放弃（见 startupAutoRestoreEnabled 注释）。
        guard startupAutoRestoreEnabled else { return false }
        // 本地库已存在：无需恢复（也避免覆盖正在用的库）。
        guard !FileManager.default.fileExists(atPath: AppPersistence.storeURL.path) else { return false }
        // iCloud 容器不可达（模拟器 / 未开启 iCloud Drive）：直接放弃恢复，走新建空容器，避免死局。
        guard backupDir != nil else { return false }
        return hasBackup()
    }

    // MARK: - 备份
    /// 执行备份（复制本地 store 三件套 + attachments 到 iCloud 容器）。
    /// ⚠️ 关键修复（2026-08-04 · 方案 B）：`copyItem` 只把文件放进本地 ubiquity 目录，
    /// 系统会**异步**把这些文件上传到 iCloud 服务器。但本方法**不再同步阻塞等待上传完成**，
    /// 而是「复制完即返回 true」，上传进度交由 `startUploadMonitor` 遍历本地备份清单 +
    /// 查 `ubiquitousItemDownloadingStatusKey` 资源值异步监听，UI 上按钮立即解锁、独立进度条
    /// 显示上传状态。
    /// 这样既保证用户点一次按钮不卡死，又能在后台真正等到文件上传完成（应对「删 App 丢图片」）。
    /// 返回值表示文件是否成功复制到 iCloud 容器（true = 已复制，上传在后台进行）。
    @discardableResult
    nonisolated static func backup() -> Bool {
        guard isAvailable(), let dest = backupDir else {
            print("[iCloud] backup skipped: iCloud 不可用")
            return false
        }
        let fm = FileManager.default
        do {
            // 数据库三件套
            for f in localStoreFiles {
                let to = dest.appendingPathComponent(f.lastPathComponent)
                try? fm.removeItem(at: to)
                try fm.copyItem(at: f, to: to)
            }
            // 附件目录（整目录复制，含所有识别原图/健康卡图等）
            let toAtt = dest.appendingPathComponent("attachments", isDirectory: true)
            try? fm.removeItem(at: toAtt)
            if fm.fileExists(atPath: localAttachmentsDir.path) {
                try fm.copyItem(at: localAttachmentsDir, to: toAtt)
            }
            // 写 meta（备份时间）
            let meta = ["date": Date().timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: meta)
                .write(to: dest.appendingPathComponent("backup.meta"))

            print("[iCloud] backup copied → \(dest.path)，等待系统后台上传")
            return true
        } catch {
            print("[iCloud] backup failed: \(error)")
            return false
        }
    }

    /// 进行中监听的完成回调（主线程）。由 `startUploadMonitor` 设置，`stopUploadMonitor`
    /// 或自然完成时清 nil，保证退出页面后重进仍能接续同一份完成回调。
    private static var uploadCompletion: ((_ uploaded: Int, _ total: Int) -> Void)?

    /// 启动上传监听（方案 B 核心，2026-08-05 v2 修正）：
    /// 遍历本地备份清单 + 查资源值判断「已上传到云端」，Timer 轮询。
    /// 关键修正：进度 `done` **只增不减**——iCloud 上传完成后会回收本地内容(evict)，
    /// 此刻 `ubiquitousItemIsUploadedKey` 在本地可能瞬时回落，导致已到 9/9 又跌回 0/9。
    /// 因此用 `max(历史 done, 本轮 done)` 锁死；一旦 `everDone >= total` 立即判定完成并停轮询，
    /// 不再回退。判据改用 `ubiquitousItemDownloadingStatusKey == .current`（云端有完整副本、
    /// 本地可用），它在 evict 之后比 `isUploaded` 更稳定；`isUploaded` 仅作兜底。
    /// 该方法非阻塞，立即返回；Timer 在 RunLoop.main 驱动，全部上传完成或手动停止时清场。
    /// - Parameter completion: 全部上传完成时回调（主线程），传最终已上传/总数。
    static func startUploadMonitor(completion: ((_ uploaded: Int, _ total: Int) -> Void)? = nil) {
        let files = collectUploadFiles(directory: backupDir ?? URL(fileURLWithPath: "/dev/null"))
        let total = files.count
        uploadCompletion = completion
        guard total > 0 else {
            liveProgress = (0, 0)
            isMonitoringUpload = false
            completion?(0, 0)
            return
        }
        // 记录「曾经达到过的最大 done」，保证只增不减（即使 evict 让本地查询瞬时回落也不回退）
        var everDone = liveProgress?.uploaded ?? 0
        isMonitoringUpload = true
        liveProgress = (everDone, total)

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            // 耗时查询（ubiquity 文件 resourceValues）放到后台线程，避免阻塞主线程
            // （模拟器/弱网下同步查会卡死导航转场）。结果回主线程写状态。
            DispatchQueue.global(qos: .utility).async {
                var done = 0
                for url in files {
                    // 判据1：下载状态为 .current（云端有完整副本、本地可用）—— evict 后仍稳定
                    let status = (try? url.resourceValues(
                        forKeys: [.ubiquitousItemDownloadingStatusKey]
                    ))?.ubiquitousItemDownloadingStatus
                    // 判据2：明确标记已上传（兜底）
                    let isUp = (try? url.resourceValues(
                        forKeys: [.ubiquitousItemIsUploadedKey]
                    ))?.ubiquitousItemIsUploaded == true
                    if status == .current || isUp { done += 1 }
                }
                DispatchQueue.main.async {
                    // 只增不减：不回退，锁死已达峰值
                    everDone = max(everDone, done)
                    liveProgress = (everDone, total)
                    if everDone >= total {
                        t.invalidate()
                        isMonitoringUpload = false
                        uploadCompletion?(total, total)
                        uploadCompletion = nil
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 取消进行中的上传监听（如用户离开页面或切换账号）。
    /// 注意：仅清内存态，**不停止系统后台上传**——iCloud 守护进程会继续把容器文件推到云端。
    /// 退出页面不调此方法是安全的（上传仍会完成），重进页面用 `resumeUploadMonitorIfNeeded` 接续。
    static func stopUploadMonitor() {
        isMonitoringUpload = false
        liveProgress = nil
        uploadCompletion = nil
    }

    /// 若系统仍在后台上传（监控被停但文件尚未全部 uploaded），重新挂上 Timer 轮询并接回完成回调。
    /// 用于「用户退出页面再重进」时接续显示备份进度，而不是从头再来或进度丢失。
    /// - Returns: 是否确实仍在上传中（true=已重新挂监听；false=已全部传完或无处可查）。
    @discardableResult
    static func resumeUploadMonitorIfNeeded(
        completion: ((_ uploaded: Int, _ total: Int) -> Void)? = nil
    ) -> Bool {
        // 模拟器不真实上传：容器为本地占位，残留备份文件会误导「仍在传」并挂主线程 Timer 卡死
        // 导航转场。直接返回 false，不挂上传监听（模拟器本就无云端可传）。
        #if targetEnvironment(simulator)
        return false
        #endif
        guard let dest = backupDir else { return false }
        let files = collectUploadFiles(directory: dest)
        let total = files.count
        guard total > 0 else { return false }

        var done = 0
        for url in files {
            // 与 startUploadMonitor 一致：优先 .current，isUploaded 兜底
            let status = (try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            ))?.ubiquitousItemDownloadingStatus
            let isUp = (try? url.resourceValues(
                forKeys: [.ubiquitousItemIsUploadedKey]
            ))?.ubiquitousItemIsUploaded == true
            if status == .current || isUp { done += 1 }
        }
        // 已传完：清态并返回 false，由调用方显示正常"立即备份"按钮
        guard done < total else {
            liveProgress = (total, total)
            isMonitoringUpload = false
            return false
        }
        // 仍在传：重新挂持久轮询，接回进度
        startUploadMonitor(completion: completion ?? uploadCompletion)
        return true
    }

    /// 收集目录内所有需上传的文件（含 attachments 子目录递归），排除 meta/隐藏文件。
    private nonisolated static func collectUploadFiles(directory: URL) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        if let top = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in top {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if let sub = try? fm.subpathsOfDirectory(atPath: url.path) {
                        for rel in sub {
                            files.append(url.appendingPathComponent(rel))
                        }
                    }
                } else {
                    files.append(url)
                }
            }
        }
        return files.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "meta" }
    }

    /// 自动备份：仅当用户在设置开启「iCloud 同步」时调用（App 进入后台时触发）。
    /// 注意：backup() 仅把文件复制到 iCloud 容器并立即返回，不再阻塞等待上传；
    /// 之后调用 startUploadMonitor 在后台异步监听系统上传进度（不卡住主线程）。
    /// 返回值：是否「已启动」自动备份（不代表上传完成）。
    @discardableResult
    static func autoBackupIfEnabled() -> Bool {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return false }
        DispatchQueue.global(qos: .background).async {
            if backup() {
                startUploadMonitor()
            }
        }
        return true
    }

    // MARK: - 恢复
    /// 恢复结果（方案 B：让调用方给出精准提示，而非静默成败）。
    struct RestoreResult {
        /// 数据库是否恢复成功（聊天记录/业务数据）
        let databaseOK: Bool
        /// 期望恢复的图片数（备份里 attachments 内的文件数）；备份无 attachments 时为 0
        let imagesExpected: Int
        /// 实际恢复到本地的图片数
        let imagesRestored: Int
        /// 是否整体成功（数据库恢复即算成功；图片缺失单独提示）
        var success: Bool { databaseOK }
        /// 图片是否完整恢复
        var imagesComplete: Bool { imagesExpected == 0 || imagesRestored == imagesExpected }

        nonisolated var summary: String {
            if !databaseOK { return "恢复失败，请确认 iCloud 中有备份" }
            if imagesExpected == 0 { return "恢复成功，请重启 App 生效" }
            if imagesRestored == imagesExpected {
                return "恢复成功（含 \(imagesRestored) 张图片），请重启 App 生效"
            }
            // 图片缺失：最常见的根因是「备份时图片还没上传到云端就删了 App」
            return "数据库已恢复，但仅 \(imagesRestored)/\(imagesExpected) 张图片回到本地（其余图片可能未在备份前上传到 iCloud）"
        }
    }

    /// 从 iCloud 恢复到本地。⚠️ 必须在 SwiftData 容器初始化之前调用（否则 store 被占用无法覆盖）。
    /// 含 ubiquity 文件下载等待（最多 waitSeconds 秒，应对重装后云端文件尚未落到本地的情形）。
    /// 方案 B：返回结构化结果，含图片恢复数量校验，避免「恢复成功但图片缺失」的静默误导。
    nonisolated static func restore(waitSeconds: TimeInterval = 20) -> RestoreResult {
        guard let src = backupDir else {
            print("[iCloud] restore skipped: iCloud 不可用")
            return RestoreResult(databaseOK: false, imagesExpected: 0, imagesRestored: 0)
        }
        ensureDownloaded(directory: src, waitSeconds: waitSeconds)
        let fm = FileManager.default

        // 备份里期望的图片数（用于恢复后校验）
        let fromAtt = src.appendingPathComponent("attachments", isDirectory: true)
        let imagesExpected = (try? fm.subpathsOfDirectory(atPath: fromAtt.path))?.count ?? 0

        var dbOK = false
        do {
            // 恢复数据库三件套
            for name in [storeBaseName, storeBaseName + "-wal", storeBaseName + "-shm"] {
                let from = src.appendingPathComponent(name)
                let to = AppPersistence.storeURL.deletingLastPathComponent().appendingPathComponent(name)
                if fm.fileExists(atPath: from.path) {
                    try? fm.removeItem(at: to)
                    try fm.copyItem(at: from, to: to)
                    dbOK = true
                }
            }
        } catch {
            print("[iCloud] restore db failed: \(error)")
        }

        // 恢复附件
        var imagesRestored = 0
        if fm.fileExists(atPath: fromAtt.path) {
            let toAtt = localAttachmentsDir
            try? fm.removeItem(at: toAtt)
            do {
                try fm.copyItem(at: fromAtt, to: toAtt)
                imagesRestored = (try? fm.subpathsOfDirectory(atPath: toAtt.path))?.count ?? 0
            } catch {
                print("[iCloud] restore attachments failed: \(error)")
            }
        }

        let result = RestoreResult(databaseOK: dbOK,
                                   imagesExpected: imagesExpected,
                                   imagesRestored: imagesRestored)
        print("[iCloud] restore done → \(result.summary)")
        return result
    }

    /// 触发 ubiquity 项目下载并等待 present（最多 waitSeconds）。
    /// 注意：同步等待会阻塞调用线程（仅应在启动期容器初始化前调用，此时尚无 UI）。
    private nonisolated static func ensureDownloaded(directory: URL, waitSeconds: TimeInterval) {
        let fm = FileManager.default
        // 容器本身不可达（directory 实际取不到）：立即放弃，避免下方 contentsOfDirectory 抛错或空转。
        // 典型场景：模拟器 / 未开启 iCloud Drive 时 `backupDir` 虽非 nil（路径残留）但目录无法枚举。
        // 真机 iCloud 正常时这一层为 no-op，等待窗口与轮询逻辑不受影响。
        guard (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) != nil
        else { return }
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
            options: []
        ) else { return }

        for url in contents {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            let allPresent = contents.allSatisfy { url in
                (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus == .current
            }
            if allPresent { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
