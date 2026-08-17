// AllRecordsView.swift
// 统一的「全部记录」列表页：把饮食 / 账单 / 健康 / 待办四类记录按时间聚合展示，
// 顶部带分段筛选，左滑可删除。从首页右上角「列表」图标进入。
import SwiftUI
import SwiftData

// 分段筛选
enum RecordFilter: String, CaseIterable, Identifiable {
    case all = "全部", food = "饮食", bill = "账单", health = "健康", todo = "待办"
    var id: String { rawValue }
}

// 统一的行数据（把四种模型拍平成同一种结构，便于混排 / 删除）
private struct RowItem: Identifiable {
    let id: String
    let type: RecordFilter
    let title: String
    let subtitle: String
    let valueText: String
    let date: Date
    let systemImage: String
    let color: Color
    let delete: () -> Void
}

struct AllRecordsView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \FoodEntry.date, order: .reverse) private var foods: [FoodEntry]
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \Bill.time, order: .reverse) private var bills: [Bill]
    @Query(filter: #Predicate { !$0.syncDeleted }, sort: \HealthMetric.date, order: .reverse) private var healths: [HealthMetric]
    @Query(filter: #Predicate<Reminder> { !$0.syncDeleted }) private var reminders: [Reminder]

    @State private var filter: RecordFilter = .all

    // 点击行 → 打开对应类型的编辑弹窗（用各自的模型对象回写）
    @State private var editFood: FoodEntry?
    @State private var editBill: Bill?
    @State private var editTodo: Reminder?
    @State private var editHealth: HealthMetric?

    // 把四类记录拍平成 RowItem 并统一按时间倒序
    private var allItems: [RowItem] {
        var rows: [RowItem] = []

        for f in foods {
            rows.append(RowItem(
                id: "food-\(f.syncId.uuidString)",
                type: .food,
                title: f.name,
                subtitle: "\(f.meal) · 蛋白 \(Int(f.protein)) / 碳水 \(Int(f.carbs)) / 脂肪 \(Int(f.fat))",
                valueText: "\(Int(f.calories)) kcal",
                date: f.date,
                systemImage: "fork.knife",
                color: .orange,
                delete: {
                    // >>> CHANGE-[2026-08-17 11:29:00]-[临时对象失效崩溃] 开始
                    // 原因：f 来自 @Query，删除闭包执行时视图可能已释放引用。回退：改回 SafeDelete.food(f, in: context)
                    SafeDelete.foodByID(f.persistentModelID, in: context)
                    // <<< CHANGE-[2026-08-17 11:29:00]-[临时对象失效崩溃] 结束
                }
            ))
        }

        for b in bills {
            let timeText = AppFormat.dateTime.string(from: b.time)
            let sub = b.category.isEmpty ? timeText : "\(b.category) · \(timeText)"
            rows.append(RowItem(
                id: "bill-\(b.syncId.uuidString)",
                type: .bill,
                title: b.merchant,
                subtitle: sub,
                valueText: String(format: "¥%.2f", b.amount),
                date: b.time,
                systemImage: "yensign.circle",
                color: .green,
                delete: {
                    // >>> CHANGE-[2026-08-17 11:29:30]-[临时对象失效崩溃] 开始
                    // 原因：b 来自 @Query，删除闭包执行时视图可能已释放引用。回退：改回 SafeDelete.bill(b, in: context)
                    SafeDelete.billByID(b.persistentModelID, in: context)
                    // <<< CHANGE-[2026-08-17 11:29:30]-[临时对象失效崩溃] 结束
                }
            ))
        }

        for h in healths {
            let timeText = AppFormat.dateTime.string(from: h.date)
            rows.append(RowItem(
                id: "health-\(h.syncId.uuidString)",
                type: .health,
                title: h.metric,
                subtitle: timeText,
                valueText: "\(h.value)\(h.unit)",
                date: h.date,
                systemImage: "heart.circle",
                color: .blue,
                delete: {
                    // >>> CHANGE-[2026-08-17 11:30:00]-[临时对象失效崩溃] 开始
                    // 原因：h 来自 @Query，删除闭包执行时视图可能已释放引用。回退：改回 SafeDelete.health(h, in: context)
                    SafeDelete.healthByID(h.persistentModelID, in: context)
                    // <<< CHANGE-[2026-08-17 11:30:00]-[临时对象失效崩溃] 结束
                }
            ))
        }

        for r in reminders {
            let dueDate = r.due ?? .distantPast
            let sub = r.due.map { "截止 " + AppFormat.dateTime.string(from: $0) } ?? "无截止时间"
            rows.append(RowItem(
                id: "todo-\(r.syncId.uuidString)",
                type: .todo,
                title: r.title,
                subtitle: sub,
                valueText: r.done ? "已完成" : "待办",
                date: dueDate,
                systemImage: "checklist",
                color: .purple,
                delete: {
                    // >>> CHANGE-[2026-08-17 11:30:30]-[临时对象失效崩溃] 开始
                    // 原因：r 来自 @Query，删除闭包执行时视图可能已释放引用。回退：改回 SafeDelete.reminder(r, in: context)
                    SafeDelete.reminderByID(r.persistentModelID, in: context)
                    // <<< CHANGE-[2026-08-17 11:30:30]-[临时对象失效崩溃] 结束
                }
            ))
        }

        return rows.sorted { $0.date > $1.date }
    }

    private var filtered: [RowItem] {
        filter == .all ? allItems : allItems.filter { $0.type == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("筛选", selection: $filter) {
                ForEach(RecordFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if filtered.isEmpty {
                ContentUnavailableView("暂无记录", systemImage: "tray",
                    description: Text(filter == .all ? "去首页截一张图试试" : "该分类下还没有记录"))
            } else {
                List {
                    ForEach(filtered) { item in
                        Button {
                            openEdit(item)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.systemImage)
                                    .foregroundStyle(item.color)
                                    .frame(width: 26, alignment: .center)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.headline)
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(item.valueText)
                                        .font(.subheadline).fontWeight(.medium)
                                        .foregroundStyle(item.color)
                                    Text(AppFormat.dateTime.string(from: item.date))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for i in offsets { filtered[i].delete() }
                    }
                }
                .listStyle(.plain)
                // >>> CHANGE-[2026-08-17 17:25:00]-[编辑食物统一EditFoodSheet] 开始
                // 原因: 统一走 EditFoodSheet wrapper，避免此入口编辑页无导航栏（看不到取消/保存按钮）。
                // 回退: 改回 EditFoodView(entry: $0)。
                .sheet(item: $editFood) { EditFoodSheet(entry: $0) }
                // <<< CHANGE-[2026-08-17 17:25:00]-[编辑食物统一EditFoodSheet] 结束
                .sheet(item: $editBill) { EditBillView(bill: $0) }
                .sheet(item: $editTodo) { EditTodoSheet(reminder: $0) }
                .sheet(item: $editHealth) { EditHealthView(metric: $0) }
            }
            AIBottomBar()
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle("全部记录")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openEdit(_ item: RowItem) {
        switch item.type {
        case .food:
            editFood = foods.first { "food-\($0.syncId.uuidString)" == item.id }
        case .bill:
            editBill = bills.first { "bill-\($0.syncId.uuidString)" == item.id }
        case .todo:
            editTodo = reminders.first { "todo-\($0.syncId.uuidString)" == item.id }
        case .health:
            editHealth = healths.first { "health-\($0.syncId.uuidString)" == item.id }
        case .all:
            break
        }
    }
}
