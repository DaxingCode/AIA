// TodoToolsView.swift
// 待办工具聚合页：默认提醒时间、截屏自动记待办等入口。
import SwiftUI
import SwiftData

struct TodoToolsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "提醒设置")

                NavigationLink {
                    DefaultReminderSettingsView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.badge.fill")
                            .font(AIATheme.Font.title3)
                            .foregroundStyle(AIATheme.todo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("设置默认提醒时间")
                                .font(AIATheme.Font.subhead.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("新建待办时自动按这些时间发送通知")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(AIATheme.muted)
                    }
                    .padding(12)
                    .card()
                }
                .buttonStyle(.plain)

                SectionTitle(text: "自动记待办")

                Button {
                    NavigationRouter.shared.path.append(HomeRoute.autoSetup)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles.rectangle.portrait.fill")
                            .font(AIATheme.Font.title3)
                            .foregroundStyle(AIATheme.todo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("截屏自动生成待办")
                                .font(AIATheme.Font.subhead.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("设置快捷指令，截屏/付款后自动识别待办")
                                .font(AIATheme.Font.micro)
                                .foregroundStyle(AIATheme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(AIATheme.Font.footnote.weight(.medium))
                            .foregroundStyle(AIATheme.muted)
                    }
                    .padding(12)
                    .card()
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .background(AIATheme.fillSoft.ignoresSafeArea())
        .navigationTitle("提醒设置 / 自动记待办")
        .navigationBarTitleDisplayMode(.inline)
    }
}
