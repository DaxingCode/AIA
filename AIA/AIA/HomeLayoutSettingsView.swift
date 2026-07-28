// HomeLayoutSettingsView.swift
// 设置页「首页布局」编辑：List + .onMove 排序 + Toggle 隐藏/显示 + 恢复默认。
import SwiftUI
import Combine

struct HomeLayoutSettingsView: View {
    @ObservedObject private var layout = HomeLayoutStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(layout.order) { m in
                    HStack(spacing: 12) {
                        Image(systemName: m.icon)
                            .font(AIATheme.Font.callout.weight(.medium))
                            .foregroundStyle(m.accent)
                            .frame(width: 26, height: 26)
                            .background(m.accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text(m.title)
                            .font(AIATheme.Font.body)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Toggle("显示 \(m.title)", isOn: Binding(
                            get: { !layout.isHidden(m) },
                            set: { layout.setHidden(m, !$0) }
                        ))
                        .labelsHidden()
                    }
                }
                .onMove { from, to in layout.move(from: from, to: to) }
            } header: {
                Text("首页模块顺序与显示")
            } footer: {
                Text("拖动排序，关闭开关即隐藏该模块。修改即时生效，仅保存在本机。")
            }

            Section {
                Button {
                    layout.reset()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("恢复默认布局")
                    }
                    .foregroundStyle(AIATheme.blue)
                }
            } footer: {
                Text("将所有模块顺序复位为饮食、健康、账单、待办、今日事项预览，并全部显示。")
            }
        }
        .navigationTitle("首页布局")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }
}
