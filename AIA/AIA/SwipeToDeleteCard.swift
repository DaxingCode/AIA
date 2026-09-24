// SwipeToDeleteCard.swift
// 通用「左滑删除」卡片：不依赖 List，可在任意 ScrollView / VStack 中使用。
// 向左滑动露出红色删除按钮，点按钮或大幅左滑即删除；未滑满则回弹。
//
// >>> CHANGE-[2026-09-24 09:41:37]-[SwipeToDeleteCard 滚动禁用警示] 开始
// ⚠️ 现状：本项目已无调用方（账单/饮食/待办/健康/商户规则等列表早已迁到 SelectableRow，
//    周期账单页 2026-09-24 迁走）。新页面请直接用 SelectableRow，不要再用本组件。
//    原因：本组件的手势写法 `.gesture(DragGesture())`（默认 10pt 触发、无方向判断、独占）
//    会 claim 掉整行 touch，使外层 ScrollView 完全无法滚动——周期账单页 2026-09-24
//    的「整页滑不动」实测即由此引起。
//    如需复用本组件，必须先把手势改成与 SelectableRow 一致：
//      .simultaneousGesture(DragGesture(minimumDistance: 30, coordinateSpace: .local))
//      且 onChanged / onEnded 首行加 `guard abs(w) > abs(h) else { return }`。
// <<< CHANGE-[2026-09-24 09:41:37]-[SwipeToDeleteCard 滚动禁用警示] 结束

import SwiftUI

struct SwipeToDeleteCard<Content: View>: View {
    let content: Content
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var revealed = false

    private let buttonWidth: CGFloat = 96
    private let revealThreshold: CGFloat = 50
    private let deleteThreshold: CGFloat = 110

    init(onDelete: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 删除底色（随滑动渐显）
            RoundedRectangle(cornerRadius: AIATheme.rMD)
                .fill(AIATheme.warn)
                .opacity(revealed || offset < -8 ? 1 : 0)

            HStack {
                Spacer()
                Button {
                    delete()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(AIATheme.Font.title2.weight(.medium))
                        Text("删除")
                            .font(AIATheme.Font.footnote.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .frame(width: buttonWidth, height: .infinity)
                }
                .buttonStyle(.plain)
            }
            .frame(maxHeight: .infinity)
            .padding(.trailing, 12)

            content
                .offset(x: offset)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let x = value.translation.width
                            // 只允许向左滑（向右不处理）
                            offset = x > 0 ? 0 : max(x, -buttonWidth - 40)
                            revealed = offset < -revealThreshold
                        }
                        .onEnded { value in
                            let x = value.translation.width
                            if x < -deleteThreshold {
                                delete()
                            } else if x < -revealThreshold {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    offset = -buttonWidth
                                    revealed = true
                                }
                            } else {
                                close()
                            }
                        }
                )
                // 已露出时，点卡片区域收起（不触发内部 NavigationLink）
                .overlay(
                    revealed
                        ? Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                        : nil
                )
        }
        .clipped()
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            offset = 0
            revealed = false
        }
    }

    private func delete() {
        withAnimation(.easeInOut(duration: 0.22)) {
            offset = -1000
            revealed = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDelete()
        }
    }
}
