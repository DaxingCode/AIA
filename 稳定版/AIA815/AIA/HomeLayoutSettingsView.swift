// HomeLayoutSettingsView.swift
// 设置页「首页布局」编辑：List + .onMove 排序 + Toggle 隐藏/显示 + 恢复默认。
import SwiftUI
import Combine

struct HomeLayoutSettingsView: View {
    @ObservedObject private var layout = HomeLayoutStore.shared
    @ObservedObject private var ent = EntitlementManager.shared
    @Environment(\.dismiss) private var dismiss
    /// 非 Pro 用户允许看/改，但返回时回滚本次内存改动 + 弹订阅页。
    @State private var showPaywall = false
    /// 进入本页瞬间拍下的布局快照；setHidden/move 在操作瞬间已写 UserDefaults，
    /// 必须用进入前的快照才能在退出时回滚，仅 reload() 读不回旧值。
    @State private var preEditLayout: HomeLayoutStore.Snapshot? = nil

    var body: some View {
        List {
            if !ent.isFullAccess {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "crown.fill")
                                .font(AIATheme.Font.callout.weight(.semibold))
                                .foregroundStyle(AIATheme.amber)
                            Text("Pro 专属功能")
                                .font(AIATheme.Font.callout.weight(.semibold))
                                .foregroundStyle(AIATheme.amber)
                        }
                        Text("首页布局自定义是 Pro 专属功能，你可以在此试用拖动排序与隐藏模块，但返回本页时改动不会保存。订阅 Pro 后可永久自定义布局。")
                            .font(AIATheme.Font.footnote)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                        Button {
                            showPaywall = true
                        } label: {
                            Text("升级 Pro")
                                .font(AIATheme.Font.callout.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(AIATheme.amber)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }

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
                HStack(spacing: 6) {
                    Text("首页模块顺序与显示")
                    if !ent.isFullAccess {
                        Image(systemName: "crown.fill")
                            .font(AIATheme.Font.footnote.weight(.semibold))
                            .foregroundStyle(AIATheme.amber)
                            .accessibilityLabel("Pro 专属")
                    }
                }
            } footer: {
                if ent.isFullAccess {
                    Text("拖动排序，关闭开关即隐藏该模块。修改即时生效，仅保存在本机。")
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(AIATheme.Font.footnote)
                            .foregroundStyle(AIATheme.amber)
                        Text("当前为免费版，离开本页时改动不会保存，订阅 Pro 后可永久自定义布局。")
                    }
                    .foregroundStyle(AIATheme.amber)
                }
            }

            Section {
                Button {
                    layout.reset()
                    // 非 Pro 用户：恢复默认应真正生效，刷新进入前快照，
                    // 使 onDisappear 回滚时回滚到"已恢复默认"状态而非旧布局。
                    if !ent.isFullAccess {
                        preEditLayout = layout.snapshot()
                    }
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
        .onAppear {
            // 拍下进入本页前的布局快照，非 Pro 用户退出时回滚到此。
            preEditLayout = layout.snapshot()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        // 非 Pro 用户返回时回滚本次内存改动（布局永不被非 Pro 落库），并提示订阅。
        .onDisappear {
            if !ent.isFullAccess {
                if let snap = preEditLayout { layout.restore(snap) }
                showPaywall = true
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }
}
