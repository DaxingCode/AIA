// RecordsViews.swift
// 四个模块的「记录列表」页：从首页宫格点进来查看/删除明细。
// 全部用 SwiftData @Query 直接读本地库，支持左滑删除；待办支持勾选完成。
import SwiftUI
import SwiftData
import Combine

// MARK: - 饮食记录
struct FoodListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \FoodEntry.date, order: .reverse) private var items: [FoodEntry]

    var body: some View {
        List {
            ForEach(items) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(f.name).font(.headline)
                        Spacer()
                        Text("\(Int(f.calories)) kcal")
                            .foregroundStyle(.orange).font(.subheadline)
                    }
                    HStack(spacing: 10) {
                        Label(f.meal, systemImage: "fork.knife")
                        Text("蛋白 \(Int(f.protein))g")
                        Text("碳水 \(Int(f.carbs))g")
                        Text("脂肪 \(Int(f.fat))g")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(f.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("饮食记录")
        .overlay { if items.isEmpty {
            ContentUnavailableView("还没有饮食记录", systemImage: "fork.knife",
                description: Text("去首页截一张食物图试试"))
        } }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(items[i]) }
        try? context.save()
    }
}

// MARK: - 账单管理
struct BillListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bill.time, order: .reverse) private var items: [Bill]

    var body: some View {
        List {
            ForEach(items) { b in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(b.merchant).font(.headline)
                        Spacer()
                        Text("¥\(b.amount, specifier: "%.2f")")
                            .foregroundStyle(.green).font(.subheadline)
                    }
                    HStack(spacing: 10) {
                        if !b.category.isEmpty { Text(b.category) }
                        Text(b.time, format: .dateTime.month().day().hour().minute())
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("账单管理")
        .overlay { if items.isEmpty {
            ContentUnavailableView("还没有账单", systemImage: "yen.circle",
                description: Text("截一张付款 / 消费截图"))
        } }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(items[i]) }
        try? context.save()
    }
}

// MARK: - 健康管理
struct HealthListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \HealthMetric.date, order: .reverse) private var items: [HealthMetric]

    var body: some View {
        List {
            ForEach(items) { h in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(h.metric).font(.headline)
                        Spacer()
                        Text("\(h.value)\(h.unit)")
                            .foregroundStyle(.blue).font(.subheadline)
                    }
                    Text(h.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("健康管理")
        .overlay { if items.isEmpty {
            ContentUnavailableView("还没有健康记录", systemImage: "heart.circle",
                description: Text("截一张体重 / 体检截图"))
        } }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(items[i]) }
        try? context.save()
    }
}

// MARK: - 待办提醒
struct ReminderListView: View {
    @Environment(\.modelContext) private var context
    @Query private var items: [Reminder]

    var body: some View {
        List {
            ForEach(items) { r in
                HStack {
                    Button {
                        r.done.toggle()
                        try? context.save()
                    } label: {
                        Image(systemName: r.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(r.done ? .green : .secondary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).strikethrough(r.done)
                        if let due = r.due {
                            Text(due, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("待办提醒")
        .overlay { if items.isEmpty {
            ContentUnavailableView("还没有待办", systemImage: "checklist",
                description: Text("截一张待办 / 日程截图"))
        } }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(items[i]) }
        try? context.save()
    }
}
