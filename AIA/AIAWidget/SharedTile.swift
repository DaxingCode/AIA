//
//  SharedTile.swift
//  AIAWidget
//
//  首页四宫格的通用展示骨架，复刻 ContentView.tile 的视觉结构。
//  四个独立小 widget（账单/待办/饮食/健康）共用，确保与首页宫格口径一致。
//  透明背景（.ultraThinMaterial）+ 内容撑满。

import SwiftUI
import WidgetKit
import AIAKit

/// 宫格标题行（图标 + 标题 + 可选角标 + 右上角挂件）
struct TileHeader: View {
    let accent: Color
    let icon: String
    let title: String
    let badge: String
    var titleTrailing: (any View)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(AIATheme.Font.micro.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(accent.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(title)
                .font(AIATheme.Font.caption.weight(.medium))
                .foregroundStyle(AIATheme.sub)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
            if !badge.isEmpty {
                Text(badge)
                    .font(AIATheme.Font.micro)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Color.black.opacity(0.06))
                    .foregroundStyle(AIATheme.sub)
                    .clipShape(Capsule())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
            if let titleTrailing {
                AnyView(titleTrailing)
            }
        }
    }
}

/// 主数字区（大数字模式）
struct TileBigNumber: View {
    let number: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(number)
                .font(AIATheme.Font.title2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if !unit.isEmpty {
                Text(unit)
                    .font(AIATheme.Font.micro)
                    .foregroundStyle(AIATheme.muted)
            }
        }
    }
}

/// 标签在前、金额在后的横向一行（仅小 widget 在「今日*」场景使用）
struct TileLabeledNumber: View {
    let label: String
    let value: String
    let valueColor: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(label)
                .font(AIATheme.Font.micro)
                .foregroundStyle(AIATheme.muted)
            Text(value)
                .font(AIATheme.Font.title2.weight(.medium))
                .foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

/// 通用宫格容器：透明背景 + 撑满 + 空态遮罩
struct WidgetTile<Content: View>: View {
    let accent: Color
    let icon: String
    let title: String
    let badge: String
    let number: String
    let unit: String
    let isEmpty: Bool
    var showBigNumber: Bool = true
    var titleTrailing: (any View)? = nil
    @ViewBuilder var details: () -> Content

    var body: some View {
        ZStack {
            // 铺满整块的语义色淡底（与大 widget 同语言），无白边
            Rectangle()
                .fill(accent.opacity(0.14))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                TileHeader(accent: accent, icon: icon, title: title,
                           badge: badge, titleTrailing: titleTrailing)
                if showBigNumber {
                    TileBigNumber(number: number, unit: unit)
                }
                details()
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap")
                        .font(AIATheme.Font.micro.weight(.semibold))
                    Text("点击记录")
                        .font(AIATheme.Font.micro.weight(.medium))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(accent.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .containerBackground(Color.clear, for: .widget)
    }
}

/// 详情区一行（标签 + 右对齐值），与宫格 calSummaryRow / healthSummaryRow 同款
struct TileRow: View {
    let label: String
    let value: String
    let valueColor: Color

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(AIATheme.sub)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor)
        }
        .font(AIATheme.Font.micro)
        .lineLimit(1)
    }
}

/// 进度条（widget 专用精简版，对应 ContentView.MiniBar）。
struct MiniBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}
