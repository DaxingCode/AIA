// HealthManager.swift
// HealthKit 封装：授权、只读查询今日/近7日/近30日健康指标。
// 真机才可用；模拟器 HealthKit 不可用（调用前 isAvailable 会拦截）。
// 注意：免费 Personal Team 无法启用 HealthKit entitlement，因此所有 HealthKit 类型/Store 均按可选处理，
//       避免在启动或初始化阶段因 entitlement 缺失而崩溃或阻塞主线程。
// 只读，绝不回写 HealthKit（用户 2026-08-13 明确禁止 App 向 HealthKit 写数据）。
// 拉到的历史值会落 ManualHealthStore 的「.hk」槽位（见 persistHealthKit），由展示层按来源开关读取。
import HealthKit
import SwiftUI
import Combine
import os.lock
import WidgetKit

@MainActor
final class HealthManager: ObservableObject {
    static let shared = HealthManager()

    // 延迟到第一次 requestAuthorization 时才创建，避免 ContentView 初始化阶段就碰 HealthKit。
    private var store: HKHealthStore?

    @Published var authorized = false
    @Published var stepsToday: Int = 0
    @Published var stepsForDay: [Date: Int] = [:]   // 近 7 天每日步数（key = 当天 0 点），供健康页「近7日步数」柱状图
    @Published var activeEnergyToday: Double = 0   // 今日活动消耗（kcal），用于净热量联动
    @Published var restingEnergyToday: Double = 0   // 今日静息能量消耗（kcal），用于能量圆环（目标=BMR）
    @Published var activeEnergyForDay: [Date: Double] = [:]   // 近 30 天每日活动消耗（key = 当天 0 点），供饮食页按日期查「今日消耗」
    @Published var restingEnergyForDay: [Date: Double] = [:]   // 近 30 天每日静息能量，同上
    @Published var exerciseTimeToday: Double = 0   // 今日运动时长（分钟）
    @Published var restingHeartRate: Double = 0    // 今日静息心率（bpm），用于健康页「静息心率」自动记录
    @Published var exerciseLast7Days: [Date: Double] = [:]   // 近 7 天每日运动时长（分钟），健康页「近7日运动时长」柱状图
    @Published var sleepLast7Days: [Date: Double] = [:]      // 近 7 天每日睡眠时长（小时），健康页「近7日睡眠时长」柱状图
    @Published var authorizationFailed = false     // 标记授权失败（如免费账号无 entitlement），避免反复请求
    @Published var hasHealthKitData = false        // 是否真正读到过非零 HealthKit 数据（用于区分「已授权但无数据」和「未授权/被拒绝」）

    /// 去抖后的变化通知：合并 300ms 内的多次 @Published 改写。
    /// HealthKit 授权后 refreshAll() 会一口气并发发起 10+ 个查询，每个回调在 @MainActor 改写 @Published，
    /// 短时间内密集发出 objectWillChange。首页健康宫格订阅此去抖管道，避免老机型（如 A12/XS Max）
    /// 在首装头一两秒内被反复重算拖卡。
    lazy var debouncedChange: AnyPublisher<Void, Never> = {
        objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }()

    private var authorizationTask: Task<Void, Never>?  // 防止并发请求

    private init() {}

    /// 是否在启动/进入首页时自动请求 HealthKit 授权。
    /// - 必须先在 Apple Developer 后台：① App ID `com.daxing.aia.AIA` 勾选 HealthKit capability；
    ///   ② Xcode「Signing & Capabilities」添加 HealthKit 能力。
    /// - 2026-08-01：付费账号「Wenxing Wei」已激活，后台 App ID HealthKit 已勾选，Xcode 端能力待用户在 Signing & Capabilities 添加（Xcode 会自动注入 HealthKit.entitlements）。
    /// - 关闭后健康卡片显示占位数据；打开后进入首页会弹 HealthKit 授权弹窗。
    static var autoAuthEnabled: Bool = true

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 实时查询 HealthKit 当前授权状态，而非依赖 `authorized` 这个一次性快照。
    /// 用户在系统「设置 → 隐私与健康 → 健康」里撤回/开启权限后，HealthKit 不会回调 App，
    /// 因此 `authorized` 可能已过时。展示授权卡片时必须主动查询真实状态。
    /// `authorizationStatus(for:)` 仅读取权限状态，不会弹出系统授权框，可安全随时调用。
    var isActuallyAuthorized: Bool {
        guard isAvailable else { return false }
        let store = self.store ?? HKHealthStore()
        self.store = store  // 确保 store 存在（只读查询，不会弹系统框）

        // 仅校验「核心必要类型」是否已授权。
        // 不应要求全部类型都 .sharingAuthorized：iOS 重装 App 后，用户在系统弹窗里
        // 未显式勾选的次要类型（如睡眠、静息心率）会回退为 .notDetermined，
        // 若一刀切检查全部类型，会导致「明明已授权却显示未连接」且自动模式整体失效。
        // 只要「步数读取」和「至少一个写入类型」授权，即视为已连接。
        let essentialRead = [stepType].compactMap { $0 }
        let shareTypes: [HKSampleType?] = [stepType, energyType, bodyMassType, heightType, heartRateType]
        let essentialShare = shareTypes.compactMap { $0 }

        for t in essentialRead {
            let s = store.authorizationStatus(for: t)
            // 仅「明确拒绝」才算未授权；.notDetermined（用户未显式处理）不阻断。
            if s == .sharingDenied { return false }
        }
        let anyShareAuthorized = essentialShare.contains { t in
            store.authorizationStatus(for: t) == .sharingAuthorized
        }
        return anyShareAuthorized
    }

    // 所有类型都按可选处理：在缺少 entitlement 的免费账号真机上，这些类型可能无法创建。
    private var stepType:         HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .stepCount) }
    private var energyType:       HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed) }
    private var activeEnergyType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) }
    private var restingEnergyType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) }
    private var exerciseTimeType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) }
    private var bodyMassType:     HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .bodyMass) }
    private var heightType:       HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .height) }
    private var heartRateType:    HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .heartRate) }
    private var restingHeartRateType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .restingHeartRate) }
    private var sleepAnalysisType: HKCategoryType? { HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) }

    // 请求授权：只读步数/能量/运动/睡眠/心率等。绝不申请写入权限（App 不回写 HealthKit，用户 2026-08-13 明确禁止）。
    // 注意：HealthKit 需要 Apple Developer 付费会员（$99/年）才能在真机启用 entitlement。
    // 免费账号调用会失败，因此这里做延迟+异步+失败标记，避免阻塞启动或反复崩溃。
    /// 自动授权入口（首页 onAppear 调）：受 autoAuthEnabled / authorizationFailed 守卫，避免在失败/未开通时反复弹窗。
    func requestAuthorization() {
        guard Self.autoAuthEnabled else {
            print("[HealthKit] 自动授权已关闭。")
            return
        }
        guard isAvailable else {
            print("HealthKit 不可用（模拟器或设备不支持），跳过授权。")
            return
        }
        guard !authorizationFailed else {
            print("HealthKit 已标记授权失败，跳过本次请求。")
            return
        }
        startAuthorizationRequest()
    }

    /// 设置页主动授权用：忽略 autoAuthEnabled / authorizationFailed 守卫，必定尝试弹系统授权框（仍可重试）。
    /// 若检测到权限已被用户在系统设置中撤销（.sharingDenied），iOS 不会再弹授权框，直接引导去系统设置手动开启。
    func requestAuthorizationForSettings() {
        guard isAvailable else {
            print("HealthKit 不可用（模拟器或设备不支持），跳过授权。")
            return
        }

        // 检测是否已被用户在系统设置中撤销/拒绝。
        // iOS 规则：一旦 .sharingDenied，后续 requestAuthorization 不会再弹窗（静默返回 ok=false），只能引导手动开。
        let store = self.store ?? HKHealthStore()
        self.store = store
        let probeTypes: [HKObjectType?] = [stepType, energyType, bodyMassType, heightType, heartRateType,
                                           activeEnergyType, restingEnergyType, exerciseTimeType,
                                           restingHeartRateType, sleepAnalysisType]
        let denied = probeTypes.compactMap { $0 }.contains { store.authorizationStatus(for: $0) == .sharingDenied }
        if denied {
            print("HealthKit 权限已被撤销，引导前往系统设置。")
            authorizationFailed = true
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            return
        }

        authorizationFailed = false
        startAuthorizationRequest()
    }

    /// 实际发起授权请求（延迟 0.5s 确保首页 UI 先渲染）。
    private func startAuthorizationRequest() {
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in
            // 延迟 0.5 秒，确保首页 UI 已先渲染出来再请求授权
            try? await Task.sleep(for: .seconds(0.5))
            guard let self, !Task.isCancelled else { return }
            self.performAuthorizationRequest()
        }
    }

    @MainActor
    private func performAuthorizationRequest() {
        guard let stepType, let energyType, let activeEnergyType, let exerciseTimeType,
              let bodyMassType, let heightType, let heartRateType,
              let sleepAnalysisType, let restingHeartRateType else {
            print("HealthKit 类型无法创建，可能缺少 entitlement，跳过授权。")
            authorizationFailed = true
            return
        }
        let store = self.store ?? HKHealthStore()
        self.store = store

        let toShare: Set<HKSampleType> = Set([stepType, energyType, bodyMassType, heightType, heartRateType]
            .compactMap { $0 }.map { $0 as HKSampleType })
        let toRead: Set<HKObjectType> = Set([stepType, energyType, activeEnergyType, restingEnergyType, exerciseTimeType, bodyMassType, heightType, heartRateType, restingHeartRateType, sleepAnalysisType]
            .compactMap { $0 }.map { $0 as HKObjectType })

        store.requestAuthorization(toShare: toShare, read: toRead) { [weak self] ok, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    print("HealthKit 授权失败：\(error.localizedDescription)")
                }
                // iOS 真机硬规则：一旦用户曾在系统弹窗里「允许/拒绝」过，
                // 后续再调 requestAuthorization 都不会再弹窗，会直接以之前的决定静默返回。
                // 因此 ok==false（含 error 为 nil 的静默失败，典型即用户之前拒绝过）必须标记失败，
                // 否则卡片仍显示「连接 Apple 健康」且点了毫无反应，用户无从得知。
                if !ok {
                    self.authorizationFailed = true
                    // 授权失败（含 iOS 静默返回 ok=false 的撤销情况）时自动引导用户去系统设置手动开启，
                    // 否则用户点了「连接 Apple 健康」毫无反馈。
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                self.authorized = ok
                if ok {
                    // 授权成功后用实时状态回填，防止系统弹窗返回 ok 与真实状态不一致
                    self.authorized = self.isActuallyAuthorized
                    self.refreshAll()
                }
            }
        }
    }

    /// 一次性拉取全部今日健康指标（步数/活动消耗/静息能量/运动时长/静息心率 + 近7天步数）。
    /// 供授权成功、进入健康页、回前台、定时器周期刷新统一调用。内部各 fetch 已对 store==nil 做 guard，未授权/无 entitlement 时为安全空操作。
    func refreshAll() {
        fetchStepsToday()
        fetchStepsLast7Days()
        fetchExerciseLast7Days()
        fetchSleepLast7Days()
        fetchActiveEnergyToday()
        fetchRestingEnergyToday()
        fetchActiveEnergyLast30Days()
        fetchRestingEnergyLast30Days()
        fetchExerciseTimeToday()
        fetchRestingHeartRateToday()

        // 健康数据全部是异步从 HealthKit 拉的，回前台那一刻可能还没回来（stepsToday 仍是 0）。
        // 延迟 1.5s 等各 fetch 回调都写完后再补偿刷新一次桌面 widget，避免 widget 永久停在空态。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            WidgetSnapshot.refreshAfterWrite()
        }
    }

    // MARK: - 读数据
    func fetchStepsToday() {
        guard let store, let stepType else { return }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: stepType,
                                      quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { [weak self] _, result, _ in
            let sum = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stepsToday = Int(sum)
                if sum > 0 {
                    self.hasHealthKitData = true
                    self.persistHealthKit(metric: "steps", value: sum, date: now)
                }
            }
        }
        store.execute(query)
    }

    /// 近 7 天每日步数（健康页「近7日步数」柱状图用）。
    /// HKStatisticsCollectionQuery 按天聚合，结果缓存到 stepsForDay（key = 当天 0 点）。
    func fetchStepsLast7Days() {
        guard let store, let stepType else { return }
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        let end = now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let interval = DateComponents(day: 1)
        let query = HKStatisticsCollectionQuery(quantityType: stepType,
                                                quantitySamplePredicate: predicate,
                                                options: .cumulativeSum,
                                                anchorDate: cal.startOfDay(for: now),
                                                intervalComponents: interval)
        query.initialResultsHandler = { [weak self] _, collection, _ in
            guard let self, let collection else { return }
            // Swift 6：enumerateStatistics 的嵌套闭包并发捕获 var dict 会报错，
            // 用 unfair lock 包裹累积，最后取出不可变副本传给 @MainActor Task。
            let box = OSAllocatedUnfairLock<[Date: Int]>(initialState: [:])
            collection.enumerateStatistics(from: start, to: end) { stat, _ in
                let day = cal.startOfDay(for: stat.startDate)
                let sum = stat.sumQuantity()?.doubleValue(for: .count()) ?? 0
                box.withLock { $0[day] = Int(sum) }
            }
            let dict = box.withLock { $0 }
            Task { @MainActor in
                self.stepsForDay = dict
                if dict.values.contains(where: { $0 > 0 }) {
                    self.hasHealthKitData = true
                    for (day, v) in dict { self.persistHealthKit(metric: "steps", value: Double(v), date: day) }
                }
            }
        }
        store.execute(query)
    }

    /// 近 7 天每日运动时长（分钟），健康页「近7日运动时长」柱状图用。
    /// 复用 fetchStepsLast7Days 的 HKStatisticsCollectionQuery 写法，聚合 appleExerciseTime。
    func fetchExerciseLast7Days() {
        guard let store, let exerciseTimeType else { return }
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        let end = now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let interval = DateComponents(day: 1)
        let query = HKStatisticsCollectionQuery(quantityType: exerciseTimeType,
                                                quantitySamplePredicate: predicate,
                                                options: .cumulativeSum,
                                                anchorDate: cal.startOfDay(for: now),
                                                intervalComponents: interval)
        query.initialResultsHandler = { [weak self] _, collection, _ in
            guard let self, let collection else { return }
            let box = OSAllocatedUnfairLock<[Date: Double]>(initialState: [:])
            collection.enumerateStatistics(from: start, to: end) { stats, _ in
                let dayStart = cal.startOfDay(for: stats.startDate)
                let sum = stats.sumQuantity()?.doubleValue(for: .minute()) ?? 0
                box.withLock { $0[dayStart] = sum }
            }
            let dict = box.withLock { $0 }
            Task { @MainActor in
                self.exerciseLast7Days = dict
                if dict.values.contains(where: { $0 > 0 }) {
                    self.hasHealthKitData = true
                    for (day, v) in dict { self.persistHealthKit(metric: "exercise", value: v, date: day) }
                }
            }
        }
        store.execute(query)
    }

    /// 近 7 天每日睡眠时长（小时），健康页「近7日睡眠时长」柱状图用。
    /// 睡眠是 category 类型，需过滤 asleep 系列状态、按时长求和，再按天聚合（key=当天0点）。
    func fetchSleepLast7Days() {
        guard let store, let sleepType = sleepAnalysisType else { return }
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        let end = now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, _ in
            guard let self, let samples = samples as? [HKCategorySample] else { return }
            let box = OSAllocatedUnfairLock<[Date: Double]>(initialState: [:])
            for s in samples {
                // 仅统计睡眠（asleep）状态：含核心/深睡/REM 子状态，排除 inBed/awake
                let v = s.value
                let isAsleep = v == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                    || v == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                guard isAsleep else { continue }
                let dayStart = cal.startOfDay(for: s.endDate)
                box.withLock { $0[dayStart, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 3600 }
            }
            let dict = box.withLock { $0 }
            Task { @MainActor in
                self.sleepLast7Days = dict
                if dict.values.contains(where: { $0 > 0 }) {
                    self.hasHealthKitData = true
                    for (day, v) in dict { self.persistHealthKit(metric: "sleep", value: v, date: day) }
                }
            }
        }
        store.execute(query)
    }

    func fetchActiveEnergyToday() {
        guard let store, let activeEnergyType else { return }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: activeEnergyType,
                                      quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { [weak self] _, result, _ in
            let sum = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeEnergyToday = sum
                if sum > 0 {
                    self.hasHealthKitData = true
                    self.persistHealthKit(metric: "activeCalories", value: sum, date: now)
                }
            }
        }
        store.execute(query)
    }

    func fetchRestingEnergyToday() {
        guard let store, let restingEnergyType else { return }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: restingEnergyType,
                                      quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { [weak self] _, result, _ in
            let sum = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.restingEnergyToday = sum
                if sum > 0 { self.hasHealthKitData = true }
            }
        }
        store.execute(query)
    }

    func fetchExerciseTimeToday() {
        guard let store, let exerciseTimeType else { return }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: exerciseTimeType,
                                      quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { [weak self] _, result, _ in
            let sum = result?.sumQuantity()?.doubleValue(for: .minute()) ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.exerciseTimeToday = sum
                if sum > 0 {
                    self.hasHealthKitData = true
                    self.persistHealthKit(metric: "exercise", value: sum, date: now)
                }
            }
        }
        store.execute(query)
    }

    /// 近 30 天每日活动消耗（kcal），饮食页「今日消耗」列按 selectedDate 查。
    /// 复用 HKStatisticsCollectionQuery 按天聚合，结果缓存到 activeEnergyForDay（key = 当天 0 点）。
    func fetchActiveEnergyLast30Days() {
        guard let store, let activeEnergyType else { return }
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!
        let end = now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let interval = DateComponents(day: 1)
        let query = HKStatisticsCollectionQuery(quantityType: activeEnergyType,
                                                quantitySamplePredicate: predicate,
                                                options: .cumulativeSum,
                                                anchorDate: cal.startOfDay(for: now),
                                                intervalComponents: interval)
        query.initialResultsHandler = { [weak self] _, collection, _ in
            guard let self, let collection else { return }
            let box = OSAllocatedUnfairLock<[Date: Double]>(initialState: [:])
            collection.enumerateStatistics(from: start, to: end) { stat, _ in
                let day = cal.startOfDay(for: stat.startDate)
                let sum = stat.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                box.withLock { $0[day] = sum }
            }
            let dict = box.withLock { $0 }
            Task { @MainActor in
                self.activeEnergyForDay = dict
                if dict.values.contains(where: { $0 > 0 }) {
                    self.hasHealthKitData = true
                    for (day, v) in dict { self.persistHealthKit(metric: "activeCalories", value: v, date: day) }
                }
            }
        }
        store.execute(query)
    }

    /// 近 30 天每日静息能量（kcal），同上，供饮食页按日期查「今日消耗」的另一半。
    func fetchRestingEnergyLast30Days() {
        guard let store, let restingEnergyType else { return }
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!
        let end = now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let interval = DateComponents(day: 1)
        let query = HKStatisticsCollectionQuery(quantityType: restingEnergyType,
                                                quantitySamplePredicate: predicate,
                                                options: .cumulativeSum,
                                                anchorDate: cal.startOfDay(for: now),
                                                intervalComponents: interval)
        query.initialResultsHandler = { [weak self] _, collection, _ in
            guard let self, let collection else { return }
            let box = OSAllocatedUnfairLock<[Date: Double]>(initialState: [:])
            collection.enumerateStatistics(from: start, to: end) { stat, _ in
                let day = cal.startOfDay(for: stat.startDate)
                let sum = stat.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                box.withLock { $0[day] = sum }
            }
            let dict = box.withLock { $0 }
            Task { @MainActor in
                self.restingEnergyForDay = dict
                if dict.values.contains(where: { $0 > 0 }) {
                    self.hasHealthKitData = true
                    for (day, v) in dict { self.persistHealthKit(metric: "restingCalories", value: v, date: day) }
                }
            }
        }
        store.execute(query)
    }

    /// 按任意日期取「活动+静息」能量实际达成（kcal）。
    /// 优先读近 30 天缓存字典（HealthKit 路径，实时）；
    /// 命中不到（如更早的历史日）回落到 ManualHealthStore 的「.hk」落库值（刷新后持久化），
    /// 仍取不到再返回 0，由调用方回落到手动补录或目标值。
    func tdeeActual(for date: Date) -> Double {
        let day = Calendar.current.startOfDay(for: date)
        let active = activeEnergyForDay[day] ?? ManualHealthStore.shared.healthKitValue("activeCalories", for: day)
        let resting = restingEnergyForDay[day] ?? ManualHealthStore.shared.healthKitValue("restingCalories", for: day)
        return active + resting
    }

    /// 今日静息心率（离散样本，用 .discreteAverage 取均值，单位 bpm）。
    /// 静息心率不是累计量，误用 .cumulativeSum 会出错，必须用 .discreteAverage。
    func fetchRestingHeartRateToday() {
        guard let store, let restingHeartRateType else { return }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: restingHeartRateType,
                                      quantitySamplePredicate: predicate,
                                      options: .discreteAverage) { [weak self] _, result, _ in
            let avg = result?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.restingHeartRate = avg
                if avg > 0 {
                    self.hasHealthKitData = true
                    self.persistHealthKit(metric: "heartRate", value: avg, date: now)
                }
            }
        }
        store.execute(query)
    }

    // MARK: - HealthKit 值落库（只读，不回写 HealthKit）

    /// 把 HealthKit 拉到的历史值落 ManualHealthStore 的「.hk」槽位（按来源开关二选一展示）。
    /// 仅当 HealthKit 可用（真机已授权）时调用，模拟器/未授权时各 fetch 已提前 return，不会进入此处。
    private func persistHealthKit(metric: String, value: Double, date: Date) {
        ManualHealthStore.shared.setHealthKitValue(value, metric: metric, for: date)
    }
}
