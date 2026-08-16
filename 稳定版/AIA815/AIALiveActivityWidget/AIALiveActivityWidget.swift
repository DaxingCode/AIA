import ActivityKit
import SwiftUI
import WidgetKit

// 灵动岛 Widget：仅负责 UI 渲染，数据由主 App 的 LiveActivityManager 通过 ContentState 传入。
// 支持两类场景：
//  - kind = "recognition" / "sleep" / "todo"：原有流水线
//  - kind = "carousel"：账单 / 待办 / 健康 / 饮食 多卡片轮播总览

@main
struct AIALiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIALiveActivityWidget()
    }
}

struct AIALiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AIALiveAttributes.self) { context in
            LockScreenBanner(state: context.state, attributes: context.attributes)
        } dynamicIsland: { context in
            if context.attributes.kind == "carousel" {
                return DynamicIsland {
                    DynamicIslandExpandedRegion(.center) {
                        CarouselDI(state: context.state)
                    }
                } compactLeading: {
                    Image(systemName: "star.fill").foregroundStyle(Color.aiaAccent(context.state.currentAccent))
                } compactTrailing: {
                    Text("\(context.state.currentCardIndex + 1)/\(context.state.carouselItems.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } minimal: {
                    Image(systemName: "star.fill").foregroundStyle(Color.aiaAccent(context.state.currentAccent))
                }
            }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DILeadingIcon(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DITrailingMeta(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    DICenter(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DIBottomHint(state: context.state)
                }
            } compactLeading: {
                DILeadingIcon(state: context.state)
            } compactTrailing: {
                DITrailingMeta(state: context.state)
            } minimal: {
                DILeadingIcon(state: context.state)
            }
        }
    }
}

// MARK: - 锁屏横幅（不支持灵动岛机型自动降级显示）
private struct LockScreenBanner: View {
    let state: AIALiveAttributes.ContentState
    let attributes: AIALiveAttributes

    var body: some View {
        switch attributes.kind {
        case "carousel":
            CarouselBanner(state: state)
        case "recognition":
            HStack(spacing: 10) {
                Image(systemName: state.phase == "done" ? "doc.text.fill" : "magnifyingglass")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.recognitionTitle ?? "AI 识别")
                        .font(.headline)
                    Text(state.phase == "done"
                         ? "\(state.recognitionTitle ?? "识别") · \(amountText)"
                         : phaseLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .activityBackgroundTint(.clear)
        case "sleep":
            // TODO: kind=sleep 接入 SleepSession（expanded 给「醒来」按钮）
            Label("睡眠进行中", systemImage: "bed.double.fill")
                .font(.headline)
                .padding(.horizontal, 16)
        case "todo":
            // TODO: kind=todo 接入临近待办倒计时
            Label(state.todoTitle ?? "待办提醒", systemImage: "alarm.fill")
                .font(.headline)
                .padding(.horizontal, 16)
        default:
            Text("好记AI")
        }
    }

    private var phaseLabel: String {
        switch state.phase {
        case "ocr": return "OCR 账单识别中…"
        case "vision": return "视觉模型解析中…"
        case "fail": return "识别失败"
        default: return "处理中…"
        }
    }
    private var amountText: String {
        guard let a = state.recognitionAmount else { return "" }
        return String(format: "¥%.2f", a)
    }
}

// MARK: - 轮播总览卡片（可切换样式）
/// 锁屏横幅的轮播形态：同一张卡片，内容在 账单 / 待办 / 健康 / 饮食 间切换。
private struct CarouselBanner: View {
    let state: AIALiveAttributes.ContentState

    var body: some View {
        let items = state.carouselItems
        let idx = items.isEmpty ? 0 : min(max(state.currentCardIndex, 0), items.count - 1)
        let item = items.isEmpty
            ? AIALiveAttributes.ContentState.CarouselItem(title: "好记AI", detail: "暂无轮播数据", systemImage: "sparkles", accent: "todo")
            : items[idx]
        let accent = Color.aiaAccent(item.accent)

        HStack(spacing: 12) {
            // 带强调色底的圆角图标，强化「卡片」观感
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(accent.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: item.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // 卡片进度指示（如 2/4），让用户感知在轮播
            Text("\(idx + 1)/\(max(items.count, 1))")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.tertiary.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal, 16)
        .activityBackgroundTint(.clear)
    }
}

// MARK: - 灵动岛轮播形态
private struct CarouselDI: View {
    let state: AIALiveAttributes.ContentState
    var body: some View {
        let items = state.carouselItems
        let idx = items.isEmpty ? 0 : min(max(state.currentCardIndex, 0), items.count - 1)
        let item = items.isEmpty
            ? AIALiveAttributes.ContentState.CarouselItem(title: "好记AI", detail: "", systemImage: "sparkles", accent: "todo")
            : items[idx]
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .foregroundStyle(Color.aiaAccent(item.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - 轮播强调色映射
extension Color {
    /// 把 accent 键映射到语义色，与 App 配色保持一致。
    static func aiaAccent(_ name: String) -> Color {
        switch name {
        case "bill":   return .green
        case "todo":   return .blue
        case "health": return .purple
        case "food":   return .orange
        default:       return .blue
        }
    }
}

// MARK: - 灵动岛各区域小视图
private struct DILeadingIcon: View {
    let state: AIALiveAttributes.ContentState
    var body: some View {
        Image(systemName: state.phase == "done" ? "doc.text.fill" : "magnifyingglass")
            .foregroundStyle(state.phase == "done" ? Color.green : Color.blue)
    }
}

private struct DITrailingMeta: View {
    let state: AIALiveAttributes.ContentState
    var body: some View {
        if state.phase == "done", let a = state.recognitionAmount {
            Text(String(format: "¥%.0f", a))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
        } else {
            ProgressView()
                .scaleEffect(0.6)
                .tint(.blue)
        }
    }
}

private struct DICenter: View {
    let state: AIALiveAttributes.ContentState
    var body: some View {
        switch state.phase {
        case "ocr":    Text("OCR 识别中").font(.subheadline)
        case "vision": Text("视觉模型解析中").font(.subheadline)
        case "done":   Text(state.recognitionTitle ?? "识别完成").font(.subheadline.weight(.semibold))
        case "fail":   Text("识别失败").font(.subheadline)
        default:       Text("处理中").font(.subheadline)
        }
    }
}

private struct DIBottomHint: View {
    let state: AIALiveAttributes.ContentState
    var body: some View {
        switch state.phase {
        case "done":
            Text("点按灵动岛跳对话页确认 · 长按展开")
                .font(.caption2).foregroundStyle(.secondary)
        case "fail":
            Text("已存入待确认 · 去对话页查看")
                .font(.caption2).foregroundStyle(.secondary)
        default:
            Text("AI 正在识别，请稍候")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

extension AIALiveAttributes.ContentState {
    /// 当前轮播卡片的强调色键（供灵动岛取色）。
    fileprivate var currentAccent: String {
        let items = carouselItems
        guard !items.isEmpty else { return "todo" }
        let idx = min(max(currentCardIndex, 0), items.count - 1)
        return items[idx].accent
    }
}
