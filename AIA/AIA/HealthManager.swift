// HealthManager.swift
// HealthKit 封装：授权、读今日步数、写体重/身高/心率/摄入热量。
// 真机才可用；模拟器 HealthKit 不可用（调用前 isAvailable 会拦截）。
// 注意：免费 Personal Team 无法启用 HealthKit entitlement，因此所有 HealthKit 类型/Store 均按可选处理，
//       避免在启动或初始化阶段因 entitlement 缺失而崩溃或阻塞主线程。
import HealthKit
import SwiftUI
import Combine

@MainActor
final class HealthManager: ObservableObject {
    static let shared = HealthManager()

    // 延迟到第一次 requestAuthorization 时才创建，避免 ContentView 初始化阶段就碰 HealthKit。
    private var store: HKHealthStore?

    @Published var authorized = false
    @Published var stepsToday: Int = 0
    @Published var activeEnergyToday: Double = 0   // 今日活动消耗（kcal），用于净热量联动
    @Published var restingEnergyToday: Double = 0   // 今日静息能量消耗（kcal），用于能量圆环（目标=BMR）
    @Published var exerciseTimeToday: Double = 0   // 今日运动时长（分钟）
    @Published var authorizationFailed = false     // 标记授权失败（如免费账号无 entitlement），避免反复请求
    @Published var hasHealthKitData = false        // 是否真正读到过非零 HealthKit 数据（用于区分「已授权但无数据」和「未授权/被拒绝」）

    private var authorizationTask: Task<Void, Never>?  // 防止并发请求

    private init() {}

    /// ⚠️ 是否在启动/进入首页时自动请求 HealthKit 授权。
    /// 免费 Personal Team 账号无法启用 HealthKit entitlement，
    /// 在真机调用 requestAuthorization 会因「缺失 entitlement」直接崩溃（表现为白屏 / SIGKILL）。
    /// → 免费账号请保持 false（默认），健康卡片显示占位数据，App 稳定不崩。
    /// → 升级到付费 $99/年会员、并在 Xcode「Signing & Capabilities」勾选 HealthKit 后，再改为 true。
    static var autoAuthEnabled: Bool = false

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // 所有类型都按可选处理：在缺少 entitlement 的免费账号真机上，这些类型可能无法创建。
    private var stepType:         HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .stepCount) }
    private var energyType:       HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed) }
    private var activeEnergyType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) }
    private var restingEnergyType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) }
    private var exerciseTimeType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) }
    private var bodyMassType:     HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .bodyMass) }
    private var heightType:       HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .height) }
    private var heartRateType:    HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .heartRate) }

    // 请求授权：读步数/体重等，写体重/身高/心率/摄入热量。
    // 注意：HealthKit 需要 Apple Developer 付费会员（$99/年）才能在真机启用 entitlement。
    // 免费账号调用会失败，因此这里做延迟+异步+失败标记，避免阻塞启动或反复崩溃。
    func requestAuthorization() {
        guard Self.autoAuthEnabled else {
            print("[HealthKit] 自动授权已关闭（免费账号默认关闭，避免真机因缺失 entitlement 崩溃）。升级付费账号并启用 HealthKit 后可开启。")
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
              let bodyMassType, let heightType, let heartRateType else {
            print("HealthKit 类型无法创建，可能缺少 entitlement，跳过授权。")
            authorizationFailed = true
            return
        }
        let store = self.store ?? HKHealthStore()
        self.store = store

        let toShare: Set<HKSampleType> = Set([stepType, energyType, bodyMassType, heightType, heartRateType]
            .compactMap { $0 }.map { $0 as HKSampleType })
        let toRead: Set<HKObjectType> = Set([stepType, energyType, activeEnergyType, restingEnergyType, exerciseTimeType, bodyMassType, heightType, heartRateType]
            .compactMap { $0 }.map { $0 as HKObjectType })

        store.requestAuthorization(toShare: toShare, read: toRead) { [weak self] ok, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    print("HealthKit 授权失败：\(error.localizedDescription)")
                    self.authorizationFailed = true
                }
                self.authorized = ok
                if ok {
                    self.fetchStepsToday()
                    self.fetchActiveEnergyToday()
                    self.fetchRestingEnergyToday()
                    self.fetchExerciseTimeToday()
                }
            }
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
                if sum > 0 { self.hasHealthKitData = true }
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
                if sum > 0 { self.hasHealthKitData = true }
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
                if sum > 0 { self.hasHealthKitData = true }
            }
        }
        store.execute(query)
    }

    // MARK: - 写数据
    func saveSteps(_ steps: Int, date: Date = .now) {
        guard let store, let stepType else { return }
        let sample = HKQuantitySample(type: stepType,
                                      quantity: HKQuantity(unit: .count(), doubleValue: Double(steps)),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }

    func saveCaloriesConsumed(_ kcal: Double, date: Date = .now) {
        guard let store, let energyType else { return }
        let sample = HKQuantitySample(type: energyType,
                                      quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }

    func saveWeight(_ kg: Double, date: Date = .now) {
        guard let store, let bodyMassType else { return }
        let sample = HKQuantitySample(type: bodyMassType,
                                      quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }

    func saveHeight(_ cm: Double, date: Date = .now) {
        guard let store, let heightType else { return }
        let sample = HKQuantitySample(type: heightType,
                                      quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: cm),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }

    func saveHeartRate(_ bpm: Double, date: Date = .now) {
        guard let store, let heartRateType else { return }
        let sample = HKQuantitySample(type: heartRateType,
                                      quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: bpm),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }
}
