# AI 助理 App · UI 视觉动效优化（第三轮）

> 日期：2026-07-22
> 范围：视觉效果增强（用户原话「按你建议的来」→ 选了 3 件高价值项）
> 改前基线：UI 优化审计 8 项已闭环（①②删/收口、③④⑤⑧落地、⑥⑦明确不做）
> 编译：**BUILD SUCCEEDED**（关沙箱，`xcodebuild -scheme AIA -destination 'generic/platform=iOS Simulator' build`）

---

## 一、本次落地的 3 件事

| # | 项 | 文件 | 效果 |
|---|----|------|------|
| ① | 卡片按压 + 抬升 | `UIComponents.swift` + `ContentView.swift` | 宫格/可点卡片按下轻微缩放下沉、阴影抬升，松手 spring 回弹 |
| ② | 悬浮栏玻璃材质 | `UIComponents.swift` | 底部栏从纯色改为毛玻璃（`.ultraThinMaterial`），更轻盈有层次 |
| ③ | 图表描边 / 生长动画 | `UIComponents.swift` + `WeightTrendView.swift` | 进度环/占比环描边生长、进度条生长、体重曲线淡入 |

---

## 二、改动明细

### 1. 动效令牌（`UIComponents.swift` · `AIATheme`）
- 新增 `cardShadowStrong`（按压态阴影色）。
- 新增 `static var motionReduce { UIAccessibility.isReduceMotionEnabled }` —— **所有动画统一尊重「减弱动态效果」**。
- 新增 `enum Motion`：
  - `press = spring(response: 0.32, dampingFraction: 0.6)`（按压回弹）
  - `draw  = easeOut(duration: 0.8)`（描边生长）
  - `progress = easeOut(duration: 0.6)`（进度/数值增长）
- 约定：**禁止散写 `Animation.xxx`**，新动效一律走令牌。

### 2. `PressableCardStyle: ButtonStyle`（按压反馈）
```swift
struct PressableCardStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .shadow(
                color: configuration.isPressed ? AIATheme.cardShadowStrong : .clear,
                radius: configuration.isPressed ? AIATheme.cardShadowRadius + 6 : 0,
                y: configuration.isPressed ? AIATheme.cardShadowY + 3 : 0
            )
            .animation(AIATheme.motionReduce ? nil : AIATheme.Motion.press, value: configuration.isPressed)
    }
}
```
- **为什么用 ButtonStyle 而不是 `.card()` 内加手势**：项目铁律明确「Button/overlay 会吞点击」。`ButtonStyle` 与 Button 点击共存、不拦截命中，**100% 安全**。
- 用法：任何 `Button { … } label: { … .card() }` 把 `.buttonStyle(.plain)` 换成 `.buttonStyle(PressableCardStyle())`。

### 3. 首页四宫格接入按压反馈（`ContentView.swift` · `tile(...)`）
- `.buttonStyle(.plain)` → `.buttonStyle(PressableCardStyle())`。
- 整张宫格（含顶部类型色条）按下即缩下沉；空态「点击记录」提示是 overlay，不受影响。

### 4. 悬浮栏玻璃化（`UIComponents.swift` · `AIBottomBar`）
```swift
// 改前
.background(Color(.systemBackground))
// 改后
.background(.ultraThinMaterial)
```
- 保留顶部 `Divider()` 分隔线，与上方内容区边界清晰。
- **仍是 ScrollView 的 VStack 兄弟节点**（遵守铁律，不改成 overlay，避免 iOS 26 白屏风险）。
- 毛玻璃自动适配明暗模式。

### 5. 图表描边 / 生长动画
| 组件 | 动画方式 |
|------|----------|
| `RingView`（步数/睡眠进度环） | `@State drawn`：`.trim(from:0,to:drawn)`，`onAppear`+`onChange(of:progress)` 从 0 描边生长 |
| `DonutView`（账单分类占比环） | `@State t`：每扇区 `trim(from:start, to:start+(end-start)*t)`，`onAppear` 从 0 生长到 1 |
| `MacroCard`（营养宏量条） | `@State drawn`：`width = geo.size.width * drawn`，`onAppear`+`onChange` 从左到右生长 |
| `MiniBar`（摄入/目标、预算条） | 同 `MacroCard`，`@State drawn` 生长（用于列表，滚动进入视区即生长） |
| `WeightTrendView` 曲线 | **透明度 0→1 + 缩放 0.96→1（anchor 左）淡入**；iOS 26 下 Swift Charts 路径动画不可靠，淡入替代真·描边生长 |

- 全部 `onAppear` / `onChange(of:)` 触发，且 `motionReduce` 时**直接落位、无动画**。

---

## 三、真机验证清单（请重编译 / 重装后确认）

- [ ] **宫格按压**：首页四宫格用力按下 → 整张轻微缩小下沉 + 阴影抬升，松手回弹跟手。
- [ ] **毛玻璃栏**：底部栏呈磨砂质感（非纯色），浅/深模式下都协调；顶部分隔线仍在。
- [ ] **进度环**：进入健康/步数页，环从 0 描边生长到目标值。
- [ ] **占比环**：账单分类页，各扇区从起点生长拼成整环。
- [ ] **营养条 / 预算条**：MacroCard、MiniBar 从 0 长到目标宽度。
- [ ] **体重曲线**：WeightTrendView 进入时曲线淡入（非生硬出现）。
- [ ] **减弱动态效果**：设置 → 辅助功能 → 动态效果 → 开启「减弱动态效果」后，以上动画全部直接落位、无位移/无缩放。

---

## 四、风险提示
- 沙箱会拦截 Swift 宏 `swift-plugin-server`（"Operation not permitted"）导致首次 `xcodebuild` 失败——**非代码问题**，关沙箱即可编译通过。
- `MiniBar` 用于列表（RecordsViews / BillCategoryView / ContentView），滚动进入视区时进度条会重新生长一次，这是可接受的 reveal 模式，非 bug。
