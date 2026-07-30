// BillToolsView.swift
// 聚合入口：周期记账、账单导入、自动记账等工具入口。
// 入口：账单列表页（BillListView）顶部「周期记账/账单导入/自动记账」按钮跳转至此。
import SwiftUI
import SwiftData

struct BillToolsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "周期记账")

                Button {
                    NavigationRouter.shared.navigate(.recurringRuleList)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "repeat.circle.fill")
                            .font(AIATheme.Font.title3)
                            .foregroundStyle(AIATheme.bill)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("周期 / 订阅账单")
                                .font(AIATheme.Font.subhead.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("房租、会员费、房贷等每月自动入账")
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

                SectionTitle(text: "数据导入")

                Button {
                    NavigationRouter.shared.navigate(.billImport)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(AIATheme.Font.title3)
                            .foregroundStyle(AIATheme.bill)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("账单导入")
                                .font(AIATheme.Font.subhead.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("从 CSV 文件或剪贴板批量导入历史账单")
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

                SectionTitle(text: "智能归类")

                Button {
                    NavigationRouter.shared.navigate(.merchantRuleList)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "building.columns.fill")
                            .font(AIATheme.Font.title3)
                            .foregroundStyle(AIATheme.bill)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("商户分类规则")
                                .font(AIATheme.Font.subhead.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("记住常去商户的账单分类，自动归类")
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

                SectionTitle(text: "自动记账")

                Button {
                    NavigationRouter.shared.navigate(HomeRoute.autoSetup)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .font(AIATheme.Font.title3)
                            .foregroundStyle(AIATheme.bill)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动记账教程")
                                .font(AIATheme.Font.subhead.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("设置快捷指令，截屏自动记账单 / 待办 / 饮食")
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
        .navigationTitle("记账工具")
        .navigationBarTitleDisplayMode(.inline)
    }
}
