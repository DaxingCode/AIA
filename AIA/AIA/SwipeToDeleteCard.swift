// SwipeToDeleteCard.swift
// 通用「左滑删除」卡片：不依赖 List，可在任意 ScrollView / VStack 中使用。
// 向左滑动露出红色删除按钮，点按钮或大幅左滑即删除；未滑满则回弹。
// 用于饮食 / 账单 / 待办 / 健康各记录列表，替代在 ScrollView 中无效的 .swipeActions。
import SwiftUI

struct SwipeToDeleteCard<Content: View>: View {
    let content: Content
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var revealed = false

    private let buttonWidth: CGFloat = 76
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
                    VStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(AIATheme.Font.title3.weight(.medium))
                        Text("删除")
                            .font(AIATheme.Font.micro.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .frame(width: buttonWidth)
                }
                .buttonStyle(.plain)
            }
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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: offset)
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
