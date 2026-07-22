# AI 助理 App · UI 优化审计报告

> 审计范围：`AIA/AIA/` 下全部 SwiftUI 视图（80 个 .swift，重点 UIComponents / ContentView / RecordsViews / ResultConfirmView / DashboardView 等）
> 审计日期：2026-07-22
> 评估人：UI Designer

## 一、整体评价（先讲好的）

这套 UI **不是"烂摊子"，是有体系但局部纪律松动**。已经做对的关键基建：

- ✅ 统一设计令牌 `AIATheme`（颜色/圆角/阴影全部收敛，深浅自适应 `adaptive(light:dark:)`）
- ✅ 组件库封装到位：`.card()` / `SegmentedPicker` / `Pill` / `RingView` / `DonutView` / `MacroCard` / `EmptyStateView` 复用良好
- ✅ 空态 `EmptyStateView` 严格垂直居中（符合"空状态居中"规范）
- ✅ 导航策略成熟：单 `NavigationStack(path:)` + 单 `.navigationDestination`，规避了 iOS 26 白屏与多 destination 冲突
- ✅ 四宫格"类型色条 + 圆点 + 标签"三处色相统一，靠颜色秒认模块

下面是 8 项可优化点，按优先级排列。

---

## 二、P0 — 必须修（一致性 / 可维护性硬伤）

### ① 死代码 `DashboardView` 完全脱离主题体系
- **位置**：`DashboardView.swift`（96 行）
- **问题**：用 `.orange` / `.green` / `.blue` / `Color.red` / `Color.yellow` / `Color.brown` 硬编码，**完全没有走 `AIATheme`**。主流程首页早已用 `ContentView` 内联宫格替代它，全工程只有 `BillDashboardView`（名字相近但无关）被引用，`DashboardView` 结构体从未被实例化 → **纯死代码**。
- **修复**：直接删除；若想保留"净热量联动"概念，按 `AIATheme.food / over / green` 重写并接到首页或饮食页。

### ② 灰色三态混用（最影响"调过没调过"观感）
- **问题**：`Color.gray` / `.gray` 出现 **96 处**，与令牌 `AIATheme.sub` / `AIATheme.muted` 并存 → 同一屏里出现 **3 套灰阶**。
- **重灾区**：`RecordsViews.swift`(17)、`UIComponents.swift`(6)、`HealthDetailView`/`FoodDetailView`/`BillCategoryView`(各 4)。
- **更要命**：连组件库自己都在用 `.gray`——`RingView`(240)、`MacroCard`(290)、`StatCard`(330)、`CardRow`(354)、`SectionTitle`(371) 内部的次级文字。这等于"地基就没对齐"。
- **说明**：`Color.gray` 虽是自适应灰（深色不崩），但和令牌灰不在同一梯度，深浅切换时三档灰会错位，显得没统一调过。
- **修复**：收口成三档——主文 `.primary`、次要 `AIATheme.sub`、三级 `AIATheme.muted`；**先把组件库里的 `.gray` 改掉**（以身作则），再清理业务页。

---

## 三、P1 — 建议优化（体系完整度）

### ③ 字号无"字体令牌"（22 种字号散写 1000+ 处）
- **数据**：`.system(size: N)` 全工程出现 1000+ 次，字号横跨 **9~44 共 22 种**；同一语义（如次级说明）在不同页用 10/11/12/13 混着来。
- **修复**：在 `AIATheme` 加字体阶梯：
  ```swift
  extension AIATheme {
      enum Font {
          static let title   = Font.system(size: 20, weight: .semibold)
          static let headline= Font.system(size: 16, weight: .medium)
          static let body    = Font.system(size: 14)
          static let caption = Font.system(size: 12)
          static let micro   = Font.system(size: 11)
      }
  }
  ```
  视图统一 `.font(AIATheme.Font.caption)`。先覆盖高频档（11/12/13/14/16/20）即可消除 80% 漂移。

### ④ 账单分类色未纳入主题、缺深色变体
- **位置**：`BillCategoryHelpers.swift` 8 处 `Color(hex:)`（住房紫 / 娱乐粉 / 医疗红 / 教育蓝…）。
- **评价**：按商户名映射分类色本身合理，但散落在业务文件、且 **没有深色 variant**，深色下色相可能漂移。
- **修复**：迁到 `AIATheme` 扩展：
  ```swift
  extension AIATheme {
      static func billCategory(_ name: String) -> Color { /* adaptive(light:dark:) 查表 */ }
  }
  ```
  （`BillImportView` 里支付宝 `#1677ff`、微信 `#07c160` 是品牌色，可保留。）

### ⑤ 卡片封装未完全复用（易漏描边）
- **问题**：`ResultConfirmView` / `RecordsViews` 大量手写 `.background(AIATheme.surface).clipShape(...).overlay(stroke...)`，与 `.card()` 重复，且手写容易漏掉 1px 描边。
- **修复**：列表行统一 `.card(radius: rMD, shadow: false)`（已支持该参数）；带阴影卡片用 `.card()`。

---

## 四、P2 — 体验打磨（动效 / 信息层级）

### ⑥ 首页三重动效叠加 + 气泡与宫格内容重复
- **现象**：宫格入场动画 + 底部 bar 提示轮播(3s) + "今日事项预览"气泡轮播(2s) **同时跑**；且气泡的自然语言摘要（卡路里 / 步数 / 支出 / 待办）与宫格里已展示的数据**重复**。
- **修复（组合拳）**：
  - 气泡改为"首条静态 + 点击展开全部"，或仅在 idle（数秒无操作）才滚动；
  - 轮播间隔拉到 4~5s，并**去掉底部 bar 的提示轮播**（留一处"活"的元素足矣），显著降低视觉噪音。

### ⑦ 底部固定 bar 在列表页的遮挡（需确认）
- **现象**：首页 `AIBottomBar` 高度约 74pt + 安全区。需确认各列表/详情页**没有重复渲染**同款底栏导致末条被遮。
- **修复**：确认子页不重复嵌底栏；如需要，用 `.safeAreaInset(edge: .bottom)` 或底部 padding 留出空间。

### ⑧ 对比度 / 无障碍收尾（整体已达标 AA）
- `Pill` 用 10pt 小字 + `warn.opacity(0.12)` 底，深色下 `AIATheme.warn = #ff6f61` 文字对比足够，但建议立一条"小字最小 11pt"规范。
- 可点行 hit area：宫格用 `Button` + `contentShape` 已正确；确认所有可点行 ≥ 44pt（目前靠 padding 撑，大多达标）。

---

## 五、优先级汇总

| # | 问题 | 位置 | 优先级 | 工作量 |
|---|------|------|--------|--------|
| ① | 死代码 DashboardView 脱离主题 | DashboardView.swift | P0 | 小（删/重写） |
| ② | 灰色三态混用（含组件库自身） | 96 处，重灾 RecordsViews/UIComponents | P0 | 中（全局替换） |
| ③ | 字号无令牌（22 种散写） | 全工程 | P1 | 中 |
| ④ | 账单分类色未入主题、无深色变体 | BillCategoryHelpers.swift | P1 | 小 |
| ⑤ | 卡片封装未复用、易漏描边 | ResultConfirmView/RecordsViews | P1 | 小 |
| ⑥ | 首页三重动效 + 气泡与宫格重复 | ContentView.swift | P2 | 中（体验调优） |
| ⑦ | 底部 bar 遮挡（需确认） | 各列表/详情页 | P2 | 小（确认+补 padding） |
| ⑧ | 小字最小 11pt 规范 | 全局 | P2 | 小 |

---

## 六、建议落地顺序

1. **先做 ① + ②**：死代码清理 + 灰色收口，是"零风险、立竿见影"的一致性修复，且不依赖其他改动。
2. **再做 ③ + ④ + ⑤**：把字体阶梯、分类色、卡片封装补进 `AIATheme`，体系就完整闭环了。
3. **最后 ⑥⑦⑧**：体验层打磨，可单独一轮，最好真机（iPhone 15 Pro Max）上看动效噪音与底部遮挡。

> 注：报告基于静态代码审计。⑦ 的遮挡需真机/模拟器跑一次列表页滚动到底确认；⑥ 的动效观感建议在真机上主观评估后再定方案。
