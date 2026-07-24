// SelectionComponents.swift
// 列表行：v3 ZStack 方案（仅左半圆圈）。
//   - 底层 NavigationLink 撑满整行（点击 content 区域跳转详情）
//   - 顶层 leadingAccessory（z-order 在上，点击不被 NavigationLink 拦截）
//   - ZStack alignment: .leading → 圆圈靠左对齐，垂直居中
//   - 不在外层加 .frame，避免把内层 Image 36×36 拉伸变形
//
// ⚠️ 重要：因全 App 统一用单 NavigationStack(path: $router.path) + 单 .navigationDestination(for: HomeRoute.self)
// 模式（见 ContentView.swift 注释），**优先用 value-based init**（init(value:leadingAccessory:content:)），
// 让父级 NavigationStack 的 path 处理类型匹配。闭包式 init(destination:) 仅用于 .sheet 弹出的子 NavigationStack
// 内部（如 EditBillView），或用户明确无 path 冲突的场景。
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

/// value-based SelectableCard：配合全局 NavigationStack(path: $router.path) + .navigationDestination(for: HomeRoute.self)。
/// 内部用 `NavigationLink(value:)` 而非 `NavigationLink { destination }`，避免闭包式 destination 与全局 path 类型不一致
/// 引发的 `SwiftUI.AnyNavigationPath.Error.comparisonTypeMismatch` try! 强解崩溃（2026-07-24 第八轮踩坑）。
struct ValueSelectableCard<LeadingAccessory: View, Content: View, Value: Hashable>: View {
    let value: Value
    let leadingAccessory: LeadingAccessory
    let content: Content

    init(value: Value, leadingAccessory: LeadingAccessory, content: Content) {
        self.value = value
        self.leadingAccessory = leadingAccessory
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationLink(value: value) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            leadingAccessory
        }
    }
}

/// value-based + EmptyView accessory 重载
extension ValueSelectableCard where LeadingAccessory == EmptyView {
    init(value: Value, content: Content) {
        self.init(value: value, leadingAccessory: EmptyView(), content: content)
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
