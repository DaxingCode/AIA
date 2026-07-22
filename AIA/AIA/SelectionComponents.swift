// SelectionComponents.swift
// 列表行：v3 ZStack 方案（仅左半圆圈）。
//   - 底层 NavigationLink 撑满整行（点击 content 区域跳转详情）
//   - 顶层 leadingAccessory（z-order 在上，点击不被 NavigationLink 拦截）
//   - ZStack alignment: .leading → 圆圈靠左对齐，垂直居中
//   - 不在外层加 .frame，避免把内层 Image 36×36 拉伸变形
import SwiftUI

/// 列表行：圆圈（ZStack 顶层 left）+ 导航（底层 NavigationLink）
struct SelectableCard<LeadingAccessory: View, Content: View, Destination: View>: View {
    let leadingAccessory: LeadingAccessory
    let content: Content
    let destination: Destination

    init(
        leadingAccessory: LeadingAccessory,
        content: Content,
        destination: Destination
    ) {
        self.leadingAccessory = leadingAccessory
        self.content = content
        self.destination = destination
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // 底层：NavigationLink 撑满整行
            NavigationLink {
                destination
            } label: {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // 顶层：圆圈靠左对齐（z-order 高于 NavigationLink）
            // leadingAccessory 自身已是 Image.frame(36,36).contentShape(Rectangle()).onTapGesture
            // ZStack alignment: .leading → 圆圈靠左、垂直居中于 ZStack
            leadingAccessory
        }
    }
}

extension SelectableCard where LeadingAccessory == EmptyView {
    init(
        content: Content,
        destination: Destination
    ) {
        self.init(
            leadingAccessory: EmptyView(),
            content: content,
            destination: destination
        )
    }
}

/// 多选模式底部操作栏（不再使用，保留避免编译错误；后续可删除）
struct BatchDeleteBar: View {
    let selectedCount: Int
    let totalCount: Int
    let onSelectAll: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    private var allSelected: Bool { selectedCount == totalCount && totalCount > 0 }

    var body: some View {
        EmptyView()
    }
}
