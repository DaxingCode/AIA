// TodoDetailView.swift
// ⑭ 待办详情：按《UI完整页面流.html》屏幕 14 + AIATheme 卡片化设计系统重做。
import SwiftUI
import SwiftData

struct TodoDetailView: View {
    let reminder: Reminder
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var toast: String?
    @State private var showEdit = false
    @State private var pendingDeleteID: PersistentIdentifier? = nil
    @State private var pendingDoneID: PersistentIdentifier? = nil

    private var prio: (text: String, color: Color) {
        switch reminder.priority {
        case "high":   return ("高优先级", AIATheme.warn)
        case "low":    return ("低优先级", AIATheme.sub)
        default:       return ("中优先级", AIATheme.amber)
        }
    }
    private var repeatLabel: String {
        switch reminder.repeatRule {
        case "daily":   return "每天"
        case "weekly":  return "每周"
        case "monthly": return "每月"
        default:        return "不重复"
        }
    }
    private var reminderOptionLabel: String {
        if reminder.due == nil { return "未设置截止时间" }
        if reminder.remindTimes.isEmpty, reminder.remindAt == nil { return "不提醒" }
        let times = reminder.remindTimes.isEmpty ? (reminder.remindAt.map { [$0] } ?? []) : reminder.remindTimes
        if times.count == 1 { return AppFormat.dateTime.string(from: times[0]) }
        return "\(times.count) 个提醒时间"
    }
    private var sourceLabel: String { "手动创建" }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    infoCard
                    if reminder.imageName != nil {
                        imageCard
                    }
                    actionCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AIATheme.fillSoft)
            AIBottomBar()
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle("待办详情")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(toast ?? "") }
        .sheet(isPresented: $showEdit) { EditTodoView(reminder: reminder) }
        .onDisappear {
            // 2026-07-20 实测：onDisappear 仍可能在父页面 ReminderListView 刚刚显示、
            // NavigationStack pop 动画尚未完全收尾时调用。此时若同步改模型（syncDeleted/done），
            // 会触发 @Query 重 fetch，与父页面的初始渲染/转场动画竞争，导致返回列表后卡死。
            // 把真正改模型的动作延迟 600ms，等父页面彻底稳定后再执行。
            // 关键：不直接捕获 reminder 对象，只保存 persistentModelID；
            // 因为返回列表后若没有任何 cell 引用该对象，SwiftData 会将其 fault 化，
            // 600ms 后访问 reminder.imageName / syncDeleted 等属性会触发 fault 异常并闪退。
            // 通过 context.model(for:) 重新取活对象可避免此问题。
            if let id = pendingDeleteID {
                pendingDeleteID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    SafeDelete.reminderByID(id, in: context)
                }
            }
            if let id = pendingDoneID {
                pendingDoneID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let r = context.model(for: id) as? Reminder else { return }
                    r.done = true
                    DispatchQueue.main.async {
                        ReminderNotificationManager.cancel(r)
                    }
                }
            }
        }
    }

    // MARK: - 顶部标题卡
    private var headerCard: some View {
        HStack(spacing: 12) {
            Text(reminder.title)
                .font(AIATheme.Font.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            Text(prio.text)
                .font(AIATheme.Font.micro.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(prio.color.opacity(0.12))
                .foregroundStyle(prio.color)
                .clipShape(Capsule())
        }
        .padding(14)
        .card()
    }

    // MARK: - 信息卡
    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow(icon: "folder", label: "分类", value: "—")
            Divider().padding(.leading, 46)
            infoRow(icon: "calendar.badge.clock", label: "截止时间",
                    value: reminder.due.map { AppFormat.dateTime.string(from: $0) } ?? "未设置")
            Divider().padding(.leading, 46)
            Button {
                showEdit = true
            } label: {
                infoRow(icon: "bell.badge", label: "提醒", value: reminderOptionLabel, showChevron: true)
            }
            .buttonStyle(.plain)
            .disabled(reminder.due == nil)
            Divider().padding(.leading, 46)
            infoRow(icon: "arrow.clockwise", label: "重复", value: repeatLabel)
            Divider().padding(.leading, 46)
            infoRow(icon: "doc.text", label: "来源", value: sourceLabel)
            Divider().padding(.leading, 46)
            infoRow(icon: "text.alignleft", label: "备注", value: "—")
        }
        .card()
    }

    private func infoRow(icon: String, label: String, value: String, showChevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.muted)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(AIATheme.Font.subhead)
                .foregroundStyle(AIATheme.sub)
            Spacer()
            Text(value)
                .font(AIATheme.Font.subhead.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
    }

    // MARK: - 识别原图
    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "识别原图")
            AttachmentSection(imageName: reminder.imageName, title: nil)
        }
        .padding(14)
        .card()
    }

    // MARK: - 操作卡
    private var actionCard: some View {
        VStack(spacing: 0) {
            actionRow(title: "标记完成", icon: "checkmark.circle.fill", color: AIATheme.ok) {
                // 同样 pop 后再改 done，避免最后一条完成时 @Query 重 fetch 与 pop 动画叠加。
                // 只保存 ID，不捕获对象，防止对象被 fault 后访问属性闪退。
                pendingDoneID = reminder.persistentModelID
                dismiss()
            }
            Divider().padding(.leading, 46)
            actionRow(title: "编辑", icon: "pencil", color: .primary) {
                showEdit = true
            }
            Divider().padding(.leading, 46)
            actionRow(title: "延后到明天", icon: "calendar.badge.plus", color: .primary) {
                guard let oldDue = reminder.due else { return }
                let newDue = Calendar.current.date(byAdding: .day, value: 1, to: oldDue)!
                let offset = newDue.timeIntervalSince(oldDue)
                reminder.due = newDue
                reminder.remindTimes = reminder.remindTimes.map { $0.addingTimeInterval(offset) }
                if let first = reminder.remindTimes.first {
                    reminder.remindAt = first
                } else if let oldRemindAt = reminder.remindAt {
                    reminder.remindAt = oldRemindAt.addingTimeInterval(offset)
                }
                // 不调 try? context.save()，由 SwiftData autosave 自动持久化
                // 通知调度推到下一帧，避免与 done 变更触发的 @Query 重 fetch 竞争
                DispatchQueue.main.async {
                    ReminderNotificationManager.schedule(reminder)
                }
                dismiss()
            }
            Divider().padding(.leading, 46)
            Button {
                // 先标记删除意图并 pop 回列表，等 onDisappear（pop 动画完全结束）
                // 再真正执行 SafeDelete。避免 syncDeleted=true 触发 @Query 重 fetch
                // 与 NavigationStack pop 动画叠加，导致最后一条删除时卡死。
                // 只保存 ID，不捕获 reminder 对象，防止返回列表后对象被 fault 化，
                // 600ms 后访问属性触发 fault 异常闪退。
                pendingDeleteID = reminder.persistentModelID
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(AIATheme.Font.subhead)
                        .foregroundStyle(AIATheme.warn)
                        .frame(width: 20, alignment: .center)
                    Text("删除")
                        .font(AIATheme.Font.subhead.weight(.medium))
                        .foregroundStyle(AIATheme.warn)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AIATheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AIATheme.warn.opacity(0.6))
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    private func actionRow(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(AIATheme.Font.subhead)
                    .foregroundStyle(color)
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .font(AIATheme.Font.subhead.weight(.medium))
                    .foregroundStyle(color)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
    }
}
