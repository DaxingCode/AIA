// HealthManager.swift
// HealthKit 封装：授权、读今日步数、写体重/身高/心率/摄入热量。
// 真机才可用；模拟器 HealthKit 不可用（调用前 isAvailable 会拦截）。
import HealthKit
import SwiftUI
import Combine

@MainActor
final class HealthManager: ObservableObject {
    static let shared = HealthManager()

    private let store = HKHealthStore()
    @Published var authorized = false
    @Published var stepsToday: Int = 0
    @Published var activeEnergyToday: Double = 0   // 今日活动消耗（kcal），用于净热量联动

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let stepType         = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    private let energyType       = HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed)!
    private let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let bodyMassType     = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
    private let heightType       = HKQuantityType.quantityType(forIdentifier: .height)!
    private let heartRateType    = HKQuantityType.quantityType(forIdentifier: .heartRate)!

    // 请求授权：读步数/体重等，写体重/身高/心率/摄入热量。
    func requestAuthorization() {
        guard isAvailable else { return }
        let toShare: Set<HKSampleType>   = [stepType, energyType, bodyMassType, heightType, heartRateType]
        let toRead:  Set<HKObjectType>   = [stepType, energyType, activeEnergyType, bodyMassType, heightType, heartRateType]
        store.requestAuthorization(toShare: toShare, read: toRead) { [weak self] ok, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authorized = ok
                if let error { print("HealthKit 授权失败：\(error.localizedDescription)") }
                if ok {
                    self.fetchStepsToday()
                    self.fetchActiveEnergyToday()
                }
            }
        }
    }

    // 读今天累计步数
    func fetchStepsToday() {
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
            }
        }
        store.execute(query)
    }

    // 读今天累计「活动消耗」热量（kcal），用于净热量联动
    func fetchActiveEnergyToday() {
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
            }
        }
        store.execute(query)
    }

    // MARK: - 写数据
    func saveSteps(_ steps: Int, date: Date = .now) {
        let sample = HKQuantitySample(type: stepType,
                                      quantity: HKQuantity(unit: .count(), doubleValue: Double(steps)),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }

    func saveCaloriesConsumed(_ kcal: Double, date: Date = .now) {
        let sample = HKQuantitySample(type: energyType,
                                      quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }

    func saveWeight(_ kg: Double, date: Date = .now) {
        let sample = HKQuantitySample(type: bodyMassType,
                                      quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }

    func saveHeight(_ cm: Double, date: Date = .now) {
        let sample = HKQuantitySample(type: heightType,
                                      quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: cm),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }

    func saveHeartRate(_ bpm: Double, date: Date = .now) {
        let sample = HKQuantitySample(type: heartRateType,
                                      quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: bpm),
                                      start: date, end: date)
        store.save(sample) { _, _ in }
    }
}
