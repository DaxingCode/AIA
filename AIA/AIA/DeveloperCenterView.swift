// DeveloperCenterView.swift
// 开发者中心：解锁后展示的高级功能入口页。广告管理等子功能从这里进入，便于后续扩展。
import SwiftUI

struct DeveloperCenterView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                adManagerEntry
                // 后续新增开发者功能在这里加卡片即可
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(AIATheme.fillSoft)
        .navigationTitle("开发者中心")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 广告管理入口
    private var adManagerEntry: some View {
        NavigationLink {
            AdManagerView()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AIATheme.rMD)
                        .fill(AIATheme.purple.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                        .font(AIATheme.Font.callout.weight(.medium))
                        .foregroundStyle(AIATheme.purple)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("广告管理")
                        .font(AIATheme.Font.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("配置首页轮播广告位")
                        .font(AIATheme.Font.caption)
                        .foregroundStyle(AIATheme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AIATheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(AIATheme.muted)
            }
            .padding(14)
            .background(AIATheme.surface)
        }
        .buttonStyle(.plain)
        .card()
    }
}
