import SwiftUI
import UIKit

// MARK: - UIKit 长按起拖手势（长按 + 后续拖动，单一 recognizer）
/// 为什么必须用 UIKit 而不是 SwiftUI 手势（2026-08-02 反复踩坑记录）：
///
/// 待办列表要同时满足三件事：① ScrollView 上下滚动正常；② 长按 0.5s 起拖改期；
/// ③ 未长按时点击进编辑、左滑露删除照常。SwiftUI 侧试过的三种写法都失败：
///
/// 1. `.simultaneousGesture(DragGesture(minimumDistance: 8))`
///    → DragGesture 在长按前就参与竞争并 claim 事件，**滚动失效**。
///
/// 2. `.gesture(drag, including: longPressArmed ? .gesture : [])`
///    → `including:` **只在视图构建时求值一次**。长按把 @State 改 true，不会让
///      同一次 touch 序列里的 drag "复活"，改期拖动永远接不上，**长按拖拽失效**。
///
/// 3. `.gesture(drag)` 始终挂载 + `onChanged` 首行 `guard longPressArmed`
///    → 错误假设「闭包里 return 就不消费事件」。SwiftUI 手势一旦识别成功就已吞掉
///      touch，闭包 return 与否无关；且 `.gesture` 是高优先级 mask，会压制外层
///      UIScrollView 与内层 LongPressGesture，**滚动和长按双双失效**。
///
/// UIKit 方案天然正确：`UILongPressGestureRecognizer` 在 `minimumPressDuration`
/// 内不会 claim 事件（UIScrollView 照常滚动）；一旦长按成立，它接管该 touch 并在
/// `.changed` 阶段持续回调手指位置——「长按 + 拖拽」本就是同一个 recognizer 的
/// 两个阶段，不存在两个 SwiftUI 手势交接的时序缝隙。
///
/// 关键配置：
/// - `cancelsTouchesInView = false`：不吞事件，SwiftUI 内层的 tap / 左滑仍能识别
/// - `delaysTouchesBegan/Ended = false`：不延迟事件投递，点击手感不变
/// - `shouldRecognizeSimultaneouslyWith = true`：与 UIScrollView 的 pan 并存
/// - `allowableMovement`：长按判定期允许的手指抖动（超出则长按不成立 → 视为滚动）
///
/// 用法：以 `.overlay` 挂在行的最上层，`isEnabled` 控制多选模式等场景下禁用。
/// ```swift
/// .overlay(
///     LongPressDragView(
///         isEnabled: !multiSelectMode,
///         onBegan: { loc in ... },      // 长按成立（手指尚未移动）
///         onChanged: { loc in ... },    // 长按后手指移动，loc 为全局坐标
///         onEnded: { loc in ... }       // 松手 / 手势取消
///     )
///     .allowsHitTesting(true)           // 见下方说明
/// )
/// ```
/// 承载手势的 view **自身不参与 hitTest（返回 nil）**，touch 直接透传给下层
/// SelectableRow（点击 / 左滑 / 滚动照常）；`UILongPressGestureRecognizer` 在
/// `didMoveToSuperview` 时挂到 superview（行容器，是内容的祖先）上。由于 touch 落在
/// 内容时其祖先 superview 也会收到，长按 recognizer 与内容的 tap / 左滑 recognizer
/// 经 `shouldRecognizeSimultaneouslyWith = true` 共存，三态互不抢 touch。
/// **要点：长按 recognizer 必须挂在「内容的祖先」而非 overlay 自身**——overlay 一旦
/// `hitTest → self` 截走 touch，兄弟的内容视图就再也收不到 tap / 左滑（这正是之前
/// 「拖动能用、点击左滑失效」的根因）；而挂在祖先上 + hitTest 透传则两者兼顾。
struct LongPressDragView: UIViewRepresentable {
    /// 是否启用（多选模式等场景传 false，手势完全不参与识别）
    var isEnabled: Bool = true
    /// 长按成立所需时长（秒）
    var minimumPressDuration: TimeInterval = 0.5
    /// 长按判定期允许的手指移动距离（pt）；超出则长按不成立，事件留给 ScrollView 滚动
    var allowableMovement: CGFloat = 12

    /// 长按成立瞬间回调，参数为手指全局坐标
    var onBegan: (CGPoint) -> Void
    /// 长按成立后手指移动，参数为手指全局坐标
    var onChanged: (CGPoint) -> Void
    /// 松手 / 手势被取消，参数为手指全局坐标
    var onEnded: (CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = PassthroughView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        let gr = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        gr.minimumPressDuration = minimumPressDuration
        gr.allowableMovement = allowableMovement
        // 不吞事件：并与下层 SwiftUI 的 tap / 左滑手势共存（见 Coordinator 的
        // shouldRecognizeSimultaneouslyWith），避免长按起拖时吞掉点击 / 左滑。
        gr.cancelsTouchesInView = false
        gr.delaysTouchesBegan = false
        gr.delaysTouchesEnded = false
        gr.delegate = context.coordinator
        // 关键：recognizer 不在本 overlay 上，而是挂到 superview（行容器），
        // 本 view 的 hitTest 返回 nil 把 touch 透传给下层 SelectableRow。
        // 这样 touch 落在内容上时，作为祖先的 superview 上的长按 recognizer
        // 与内容的 tap / 左滑 recognizer 都能收到，三态并存。
        v.hostedRecognizer = gr

        context.coordinator.recognizer = gr
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
        context.coordinator.recognizer?.minimumPressDuration = minimumPressDuration
        context.coordinator.recognizer?.allowableMovement = allowableMovement
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: LongPressDragView
        weak var recognizer: UILongPressGestureRecognizer?
        /// 长按成立后我们主动禁用的 ScrollView，松手时恢复
        private weak var lockedScrollView: UIScrollView?

        init(_ parent: LongPressDragView) { self.parent = parent }

        @objc func handle(_ gr: UILongPressGestureRecognizer) {
            // 统一取 window 坐标：与 SwiftUI 侧 `geo.frame(in: .global)` 测量的 rowFrames
            // 同源，避免两套坐标系换算错位（沿用「测量与定位必须同源」的既有铁律）。
            let loc = gr.location(in: nil)
            switch gr.state {
            case .began:
                lockEnclosingScrollView(from: gr.view)
                parent.onBegan(loc)
            case .changed:
                parent.onChanged(loc)
            case .ended, .cancelled, .failed:
                parent.onEnded(loc)
                unlockScrollView()
            default:
                break
            }
        }

        /// 长按成立后临时关掉外层 ScrollView 滚动，让同一根手指只驱动改期拖拽，
        /// 不再同时滚列表（置 isScrollEnabled=false 会立即取消进行中的 pan，
        /// 不影响本 recognizer 继续收 .changed）。
        private func lockEnclosingScrollView(from view: UIView?) {
            var v = view?.superview
            while let cur = v {
                if let sv = cur as? UIScrollView {
                    sv.isScrollEnabled = false
                    lockedScrollView = sv
                    return
                }
                v = cur.superview
            }
        }

        private func unlockScrollView() {
            lockedScrollView?.isScrollEnabled = true
            lockedScrollView = nil
        }

        // 与 UIScrollView 的 pan、SwiftUI 内层手势并行识别，互不独占
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }

    /// 本 view 自身不参与 hitTest（返回 nil → touch 透传给下层 SelectableRow，
    /// 点击 / 左滑 / 滚动照常）。真正的 UILongPressGestureRecognizer 在
    /// `didMoveToSuperview` 时挂到 superview（行容器，是内容的祖先）上，
    /// 因此 touch 落在内容时，作为祖先的 superview 上的长按 recognizer 会一并
    /// 收到 began/changed/ended，与内容的 tap / 左滑手势通过
    /// `shouldRecognizeSimultaneouslyWith = true` 共存，三态互不抢 touch。
    private final class PassthroughView: UIView {
        weak var hostedRecognizer: UILongPressGestureRecognizer?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            if let sv = superview, let gr = hostedRecognizer,
               !(sv.gestureRecognizers?.contains(gr) ?? false) {
                sv.addGestureRecognizer(gr)
            } else if superview == nil, let gr = hostedRecognizer {
                gr.view?.removeGestureRecognizer(gr)
            }
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}
