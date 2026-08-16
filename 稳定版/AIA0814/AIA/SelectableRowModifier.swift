import SwiftUI
import UIKit

// MARK: - 通用记录行包装（Bill / Food / Monthly / Reminder / Health 均使用）
/// 取代 `Button` 包裹行（Button 手势会吞掉左滑与长按），并在 `ScrollView` 中
/// 自实现左滑删除（iOS 的 `.swipeActions` 仅在 `List` 生效，对 `ScrollView` 无效）。
///
/// 手势协调：
/// - 非选择模式：
///     · 向左拖拽 → 露出红色「删除」按钮；拖满阈值直接删，未拖满回弹（点卡片收起）
///     · 点击(无位移) → `onTap`（进入详情/编辑）
///     · 长按(0.5s，位移<10) → `onLongPress`（进入多选），松手不再误触点击
/// - 选择模式：
///     · 透明 overlay 拦截点击 → `onToggle`（切换选中），不触发 `onTap`
///     · 左侧显示圆形复选框，选中行轻微高亮；不响应左滑
struct SelectableRow<Content: View>: View {
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void
    /// 长按进多选回调；传 nil 表示本行不需要 SwiftUI 长按手势
    /// （如待办行长按已由外层 UIKit LongPressDragView 接管改期拖拽，
    ///  两个 0.5s 长按同时成立会互抢 touch，且会多震一次）。
    let onLongPress: (() -> Void)?
    let onToggle: () -> Void
    var onDelete: (() -> Void)? = nil
    /// 父层长按进行中（如待办改期拖拽）时传 `true`，本行的左滑手势完全不挂载，
    /// 避免与外层的改期 DragGesture 抢同一次 touch（长按后水平拖会误露删除按钮）。
    var disableSwipe: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var longPressed = false
    @State private var offset: CGFloat = 0
    @State private var revealed = false
    @State private var swiping = false
    @State private var hapticRevealed = false

    init(
        isSelecting: Bool,
        isSelected: Bool,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil,
        onToggle: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        disableSwipe: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.onToggle = onToggle
        self.onDelete = onDelete
        self.disableSwipe = disableSwipe
        self.content = content
    }

    private let buttonWidth: CGFloat = 96
    private let revealThreshold: CGFloat = 65
    private let deleteThreshold: CGFloat = 116

    var body: some View {
        let inner = content()
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isSelecting {
                    Image(systemName: isSelected
                        ? "checkmark.circle.fill"
                        : "circle")
                        .foregroundStyle(isSelected ? AIATheme.blue : AIATheme.muted)
                        .font(.title3)
                        .padding(.leading, 8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .background(isSelecting && isSelected
                ? AIATheme.blue.opacity(0.08)
                : Color.clear)
            .offset(x: isSelecting ? 0 : offset)
            .animation(.easeInOut(duration: 0.18), value: isSelecting)

        ZStack(alignment: .trailing) {
            // 左滑露出的删除底色与按钮（仅非多选且有 onDelete 时）
            if !isSelecting, onDelete != nil {
                RoundedRectangle(cornerRadius: AIATheme.rMD)
                    .fill(AIATheme.warn)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(maxHeight: .infinity)
                    .opacity(revealed || offset < -8 ? 1 : 0)
                HStack {
                    Spacer()
                    Button {
                        performDelete()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(AIATheme.Font.title2.weight(.medium))
                            Text("删除")
                                .font(AIATheme.Font.footnote.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .frame(width: buttonWidth)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxHeight: .infinity)
                .padding(.trailing, 12)
                .opacity(revealed || offset < -8 ? 1 : 0)
            }

            if isSelecting {
                inner
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { onToggle() }
                    }
            } else {
                    inner
                        // disableSwipe（父层长按中）时以空 mask 摘掉左滑手势，只剩外层改期 drag
                        .simultaneousGesture(dragGesture, including: disableSwipe ? [] : .gesture)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                                .onEnded { _ in
                                    longPressed = true
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    onLongPress?()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) {
                                        longPressed = false
                                    }
                                },
                            including: onLongPress == nil ? [] : .gesture
                        )
                        .onTapGesture {
                            // 左滑露出态下：点行内容一律「关闭」而非「进编辑」，
                            // 否则行永远收不回去，体验上像「卡住了」。
                            if revealed {
                                close()
                            } else if !swiping && !longPressed {
                                onTap()
                            }
                        }
                        // revealed 时整个内容层都点得到，仅 trash button 区域由 Button 自己处理 performDelete
                        .contentShape(Rectangle())
            }
        }
        .clipped()
    }

    /// 左滑拖拽手势：向左露出删除按钮，向右不处理；到阈值直接删，否则回弹。
    ///
    /// 与 ScrollView 滚动的关系：
    /// - `minimumDistance: 30` → 手指移动 30pt 前，ScrollView 的滚动优先识别，拖动不抢占
    /// - 方向检测 → 当水平位移 > 垂直位移时才处理（垂直/斜向滑动不触发，滚动不受扰）
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 30, coordinateSpace: .local)
            .onChanged { value in
                // 任何方向的手指移动（>=30pt）都应阻止松手后的 onTapGesture 进编辑
                swiping = true
                let w = value.translation.width
                let h = value.translation.height
                // 垂直或斜向滑动（垂直分量 >= 水平分量）→ 不处理，让 ScrollView 继续滚动
                guard abs(w) > abs(h) else { return }
                let x = w
                offset = x > 0 ? 0 : max(x, -buttonWidth - 40)
                revealed = offset < -revealThreshold
                if revealed && !hapticRevealed {
                    hapticRevealed = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .onEnded { value in
                let w = value.translation.width
                let h = value.translation.height
                // 垂直/斜向松手 → 回弹复位，稍后释放 swiping 标记
                guard abs(w) > abs(h) else {
                    close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { swiping = false }
                    return
                }
                let x = w
                if x < -deleteThreshold {
                    performDelete()
                } else if x < -revealThreshold {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        offset = -buttonWidth
                        revealed = true
                    }
                } else {
                    close()
                }
                // 延迟复位，避免松手瞬间的 onTapGesture 把"滑动"误判为"点击"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    swiping = false
                }
            }
    }

    private func close() {
        hapticRevealed = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            offset = 0
            revealed = false
        }
    }

    private func performDelete() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        withAnimation(.easeInOut(duration: 0.22)) {
            offset = -1000
            revealed = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDelete?()
        }
    }
}

// MARK: - 多选模式底部固定操作条
/// 多选模式时显示在页面底部：三个并排的胶囊按钮（左 取消 / 中 全选 / 右 红色 删除(N)）。
/// 通过 `.overlay(alignment: .bottom)` 挂载在主内容容器上，覆盖 AIBottomBar 之上。
/// 替换原顶部 toolbar 的多选 ToolbarItem，让长按多选交互更符合 iOS 原生习惯
/// （Mail / Photos 多选模式都是底部操作条）。
///
/// 视觉：
/// - 容器：`.ultraThinMaterial` 毛玻璃 + 顶部分隔线
/// - 取消：浅灰胶囊，深色文字，明确可点但不抢镜
/// - 全选 / 取消全选：蓝色胶囊，蓝色 SF Symbol + 文字，勾选图标 + "全选"（全满时切换为"取消全选"）
/// - 删除(N)：红色胶囊 + 白字 + trash 图标；count==0 时退化为 systemGray3 禁用态
/// - 三者等高 44pt、等宽，视觉上对齐
struct MultiSelectBottomBar: View {
    let count: Int
    let totalCount: Int
    let onCancel: () -> Void
    let onSelectAll: () -> Void
    let onDelete: () -> Void

    private let buttonHeight: CGFloat = 44
    private var allSelected: Bool { count > 0 && count == totalCount }

    var body: some View {
        HStack(spacing: 8) {
            // 取消：浅灰胶囊，文字色为主色
            Button(action: onCancel) {
                Text(NSLocalizedString("common.cancel", comment: ""))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: buttonHeight)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // 全选 / 取消全选：蓝色胶囊，选中态切换文字
            Button(action: onSelectAll) {
                HStack(spacing: 5) {
                    Image(systemName: allSelected
                          ? "checkmark.circle.fill"
                          : "checkmark.circle")
                        .font(.footnote.weight(.semibold))
                    Text(allSelected
                         ? NSLocalizedString("common.deselectAll", comment: "取消全选")
                         : NSLocalizedString("common.selectAll", comment: "全选"))
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(AIATheme.blue)
                .frame(maxWidth: .infinity, minHeight: buttonHeight)
                .background(AIATheme.blue.opacity(0.10))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // 删除(N)：实色红胶囊 + 白字 + 图标
            let isDisabled = count == 0
            Button(action: onDelete) {
                HStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("\(NSLocalizedString("common.delete", comment: ""))(\(count))")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: buttonHeight)
                .background(isDisabled ? Color(.systemGray3) : Color.red)
                .clipShape(Capsule())
                .opacity(isDisabled ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
    }
}
