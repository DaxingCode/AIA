// ContentView.swift
// 首页（简化版「E宫」四模块宫格）+ 测试识别入口 + 后台结果检查 + HealthKit 步数。
import SwiftUI
import SwiftData
import Combine

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var bills: [Bill]
    @Query private var reminders: [Reminder]
    @Query private var foods: [FoodEntry]

    @StateObject private var health = HealthManager.shared

    @State private var showPicker = false
    @State private var pickedImage: UIImage?
    @State private var result: RecognitionResult?
    @State private var showResultSheet = false
    @State private var isRecognizing = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var didAutoSync = false

    var body: some View {
        NavigationStack {
            ScrollView {
                DashboardView(health: health)
                    .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    tile(.food,   "饮食记录", "\(Int(todayCalories))", "kcal", "今日摄入", .orange)
                    tile(.health, "健康管理", "\(health.stepsToday)", "步", "今日步数", .blue)
                    tile(.bill,   "账单管理", "¥\(Int(billsSum))", "本月", "\(bills.count) 笔", .green)
                    tile(.todo,   "待办提醒", "\(reminders.filter { !$0.done }.count)", "项", "待完成", .purple)
                }
                .padding()
            }
            .navigationTitle("AI 助理")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("测试识别") { showPicker = true }
                }
            }
            .sheet(isPresented: $showPicker) { ImagePicker(image: $pickedImage) }
            .onChange(of: pickedImage) { _, new in
                if let img = new { runRecognize(img) }
            }
            // 无感路径：App 启动时检查后台识别结果
            .onAppear { checkPending() }
            // HealthKit：进首页即请求授权并拉今日步数（真机生效，模拟器跳过）
            .task { health.requestAuthorization() }
            // 云同步：开启自动同步则启动后同步一次
            .task {
                guard !didAutoSync else { return }
                didAutoSync = true
                let mgr = await CloudSyncManager.shared
                if await CloudSyncManager.autoSync {
                    await mgr.sync(context: context)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(\.modelContext, context)
            }
            .sheet(isPresented: $showResultSheet) {
                if let res = result {
                    ResultConfirmView(result: res)
                        .environment(\.modelContext, context)
                }
            }
            .overlay {
                if isRecognizing {
                    ProgressView("识别中…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("提示", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    // 宫格卡片：点击跳转到对应模块的列表页
    @ViewBuilder
    private func tile(_ kind: ModuleKind, _ title: String, _ big: String,
                      _ unit: String, _ sub: String, _ color: Color) -> some View {
        NavigationLink { destination(for: kind) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(big).font(.system(size: 30, weight: .bold))
                Text("\(unit) · \(sub)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func destination(for kind: ModuleKind) -> some View {
        switch kind {
        case .food:   FoodListView()
        case .health: HealthListView()
        case .bill:   BillListView()
        case .todo:   ReminderListView()
        }
    }

    private enum ModuleKind { case food, health, bill, todo }

    private var todayCalories: Double {
        foods.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.calories }
    }
    private var billsSum: Double {
        bills.reduce(0) { $0 + $1.amount }
    }

    private func runRecognize(_ img: UIImage) {
        isRecognizing = true
        Task {
            do {
                result = try await RecognizeService.recognize(image: img)
                showResultSheet = true
            } catch let decoding as DecodingError {
                errorMessage = "云端返回格式不对：\(decoding.localizedDescription)"
            } catch {
                errorMessage = "识别失败：\(error.localizedDescription)"
            }
            isRecognizing = false
        }
    }

    private func checkPending() {
        if let pending = ScreenshotStore.loadPending() {
            result = pending
            ScreenshotStore.clearPending()
            showResultSheet = true
        }
    }
}
