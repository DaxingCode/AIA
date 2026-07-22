// ResultConfirmView.swift
// 识别结果确认页：展示模型抽出的字段，用户可改，点「存入」才写库。
// 这一步是可靠性底线——模型会误分类/幻觉，绝不一识别就静默入库。
import SwiftUI
import SwiftData
import Combine

struct ResultConfirmView: View {
    let result: RecognitionResult
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    // 可编辑的本地副本（确认前给用户改）
    @State private var billMerchant: String = ""
    @State private var billAmount: String = ""
    @State private var billCategory: String = ""
    @State private var todoTitle: String = ""
    @State private var todoDueDate: Date = .now
    @State private var foodName: String = ""
    @State private var foodWeight: String = "100"   // 克，用户可改
    @State private var foodCaloriesPer100g: Double = 0
    @State private var foodProteinPer100g: Double = 0
    @State private var foodCarbsPer100g: Double = 0
    @State private var foodFatPer100g: Double = 0
    @State private var healthMetric: String = ""
    @State private var healthValue: String = ""
    @State private var nutritionSource: String = ""   // 营养库校正来源提示

    // 根据重量自动计算总热量
    private var foodCalories: Double {
        let weight = Double(foodWeight) ?? 100
        return foodCaloriesPer100g * weight / 100
    }

    // 根据重量自动计算总蛋白质、碳水、脂肪
    private var foodProtein: Double {
        let weight = Double(foodWeight) ?? 100
        return foodProteinPer100g * weight / 100
    }

    private var foodCarbs: Double {
        let weight = Double(foodWeight) ?? 100
        return foodCarbsPer100g * weight / 100
    }

    private var foodFat: Double {
        let weight = Double(foodWeight) ?? 100
        return foodFatPer100g * weight / 100
    }

    var body: some View {
        NavigationStack {
            Form {
                let types = result.types ?? []
                if types.contains("bill") {
                    Section("账单") {
                        TextField("商户", text: $billMerchant)
                        TextField("金额", text: $billAmount).keyboardType(.decimalPad)
                        TextField("分类", text: $billCategory)
                    }
                }
                if types.contains("todo") {
                    Section("待办") {
                        TextField("事项", text: $todoTitle)
                        DatePicker("日期", selection: $todoDueDate, displayedComponents: .date)
                        DatePicker("时间", selection: $todoDueDate, displayedComponents: .hourAndMinute)
                    }
                }
                if types.contains("food") {
                    Section("食物") {
                        TextField("名称", text: $foodName)
                        HStack {
                            Text("重量")
                            Spacer()
                            TextField("克", text: $foodWeight)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("g")
                        }
                        HStack {
                            Text("热量")
                            Spacer()
                            Text("\(foodCalories, specifier: "%.1f") kcal")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("蛋白质")
                            Spacer()
                            Text("\(foodProtein, specifier: "%.1f") g (\(foodProteinPer100g, specifier: "%.1f") g / 100g)")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("碳水")
                            Spacer()
                            Text("\(foodCarbs, specifier: "%.1f") g (\(foodCarbsPer100g, specifier: "%.1f") g / 100g)")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("脂肪")
                            Spacer()
                            Text("\(foodFat, specifier: "%.1f") g (\(foodFatPer100g, specifier: "%.1f") g / 100g)")
                                .foregroundStyle(.secondary)
                        }
                        if !nutritionSource.isEmpty {
                            Text(nutritionSource)
                                .font(.caption2)
                                .foregroundStyle(nutritionSource.hasPrefix("已按") ? .green : .secondary)
                        }
                    }
                }
                if types.contains("health") {
                    Section("健康") {
                        TextField("指标", text: $healthMetric)
                        TextField("数值", text: $healthValue).keyboardType(.default)
                    }
                }
                if types.contains("none") || types.isEmpty {
                    Section {
                        Text("未识别到可记录的内容").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("确认识别结果")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("跳过") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存入") { save(); dismiss() }
                }
            }
            .onAppear(perform: fillFromResult)
        }
    }

    // 待办日期/时间默认值：图片有日期用日期，否则今天；图片有时间用时间，否则 8:00
    // 模型在「没有时间」时常返回 ...T00:00:00，按产品规则视为「无时间 → 8:00」。
    private func defaultTodoDueDate() -> Date {
        let calendar = Calendar.current
        let todayAtEight = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now

        guard let dueString = result.todo?.due, !dueString.isEmpty else {
            return todayAtEight
        }

        // 1) 解析「年-月-日」（优先 ISO8601，回退 yyyy-MM-dd）
        var baseDate: Date?
        if let d = ISO8601DateFormatter().date(from: dueString) {
            baseDate = d
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            baseDate = f.date(from: dueString)
        }
        guard let date = baseDate else { return todayAtEight }

        // 2) 抽时间：字符串里是否含 HH:MM(:SS)
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        let timePattern = #"(\d{1,2}):(\d{2})(?::(\d{2}))?"#
        if let range = dueString.range(of: timePattern, options: .regularExpression) {
            let parts = dueString[range].components(separatedBy: ":").compactMap { Int($0) }
            let h = parts.first ?? 8
            let m = parts.count > 1 ? parts[1] : 0
            let s = parts.count > 2 ? parts[2] : 0
            if h == 0 && m == 0 && s == 0 {
                // 模型没给时间却填了 00:00 → 按规则视为「无时间 → 8:00」
                comps.hour = 8; comps.minute = 0; comps.second = 0
            } else {
                comps.hour = h; comps.minute = m; comps.second = s
            }
        } else {
            comps.hour = 8; comps.minute = 0; comps.second = 0
        }
        return calendar.date(from: comps) ?? todayAtEight
    }

    // 用模型结果预填表单
    private func fillFromResult() {
        billMerchant = result.bill?.merchant ?? ""
        billAmount = result.bill?.amount.map { "\($0)" } ?? ""
        billCategory = result.bill?.category ?? ""
        todoTitle = result.todo?.title ?? ""
        todoDueDate = defaultTodoDueDate()

        foodName = result.food?.name ?? ""
        foodCaloriesPer100g = result.food?.calories ?? 0
        foodProteinPer100g = result.food?.protein ?? 0
        foodCarbsPer100g = result.food?.carbs ?? 0
        foodFatPer100g = result.food?.fat ?? 0

        // 营养库校正：匹配到就用可信参考值覆盖模型估算（更准），匹配不到保留模型值
        if let ref = NutritionLibrary.shared.match(foodName) {
            foodCaloriesPer100g = ref.kcal
            foodProteinPer100g = ref.protein
            foodCarbsPer100g = ref.carbs
            foodFatPer100g = ref.fat
            nutritionSource = "已按营养库「\(ref.name)」校正：每100g \(Int(ref.kcal)) kcal"
        } else {
            nutritionSource = result.food?.name?.isEmpty == false
                ? "未匹配营养库，使用模型估算值（可手动改重量）"
                : ""
        }

        // 从 portion（如 "100克"）中解析重量，默认 100
        let portion = result.food?.portion ?? "100克"
        if let match = portion.range(of: #"\d+"#, options: .regularExpression) {
            foodWeight = String(portion[match])
        } else {
            foodWeight = "100"
        }

        healthMetric = result.health?.metric ?? ""
        healthValue = result.health?.value ?? ""
    }

    // 按命中类型存入对应 SwiftData 模型
    private func save() {
        if (result.types ?? []).contains("bill"),
           let amt = Double(billAmount), !billMerchant.isEmpty {
            let time = result.bill.flatMap { RecognitionResult.date(from: $0.time) } ?? .now
            context.insert(Bill(merchant: billMerchant, amount: amt,
                                category: billCategory, time: time))
        }
        if (result.types ?? []).contains("todo"), !todoTitle.isEmpty {
            context.insert(Reminder(title: todoTitle, due: todoDueDate))
        }
        if (result.types ?? []).contains("food"),
           let weight = Double(foodWeight), weight > 0, !foodName.isEmpty {
            let ratio = weight / 100
            let cal = foodCaloriesPer100g * ratio
            let protein = foodProteinPer100g * ratio
            let carbs = foodCarbsPer100g * ratio
            let fat = foodFatPer100g * ratio
            let meal = Calendar.current.isDateInToday(.now) ? "午餐" : "其他"
            context.insert(FoodEntry(name: foodName, calories: cal,
                                     protein: protein, carbs: carbs, fat: fat,
                                     portion: "\(Int(weight))克", meal: meal))
            // 同步写入 HealthKit「膳食能量」
            HealthManager.shared.saveCaloriesConsumed(cal, date: .now)
        }
        if (result.types ?? []).contains("health"), !healthMetric.isEmpty {
            context.insert(HealthMetric(metric: healthMetric, value: healthValue,
                                        unit: result.health?.unit ?? ""))
            // 按指标名写回 HealthKit（中文/英文都认）
            let v = Double(healthValue) ?? 0
            if healthMetric.contains("体重") || healthMetric.lowercased().contains("weight") {
                HealthManager.shared.saveWeight(v)
            } else if healthMetric.contains("身高") || healthMetric.lowercased().contains("height") {
                HealthManager.shared.saveHeight(v)
            } else if healthMetric.contains("心率") || healthMetric.lowercased().contains("heart") {
                HealthManager.shared.saveHeartRate(v)
            }
        }
        try? context.save()
    }
}
