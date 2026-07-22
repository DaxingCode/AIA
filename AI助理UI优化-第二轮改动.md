# AI 助理 App · UI 优化第二轮改动记录

> 日期：2026-07-22 ｜ 执行人：UI Designer ｜ 状态：**BUILD SUCCEEDED**
> 本轮按用户指令「做 ③、⑤、⑧」执行：字号令牌化 + 卡片封装复用 + 小字最小 11pt 规范。

## 改动清单

### ✅ ③ 字号令牌化（`AIATheme.Font` 阶梯）
- **原因**：`.system(size:N)` 散写 1000+ 处、22 种字号(9~44)，无统一令牌，深浅/可读性难控。
- **动作**（`UIComponents.swift` 内 `AIATheme` 新增 `Font` 枚举）：
  - ⚠️ **Swift 命名陷阱**：枚举内不能写 `Font.system(...)`（会解析成枚举自身），必须用 `SwiftUI.Font.system(...)`，否则编译失败。已在代码注释标明。
  - 15 档令牌：`micro(11) → caption(12) → footnote(13) → subhead(14) → callout(15) → body(16) → headline(17) → title3(18) → title2(20) → title1(22) → largeTitle(24) → display(28) → hero(34) → ultra(40)`。
  - 用法 `AIATheme.Font.body.weight(.medium)`，与原 `.system(size:16, weight:.medium)` 完全等价。
- **全量 sweep**（`/tmp/font_sweep.py`，Python 批量替换 37 文件共 **666 处**）：
  - 尺寸吸附到最近档位：9→11、10→11（顺带落实 ⑧ 最小 11pt）、21→20、26→24、30→28、32→34、36→34、44→40。
  - 仅替换普通 `.system(size:N[,weight:W])`；**安全跳过**：动态权重 `? :` 表达式、`.monospaced` 设计、`ChatView` 内分数尺寸(15.5/13.3)、`size*0.44` 比例插画文字。

### ✅ ⑧ 小字最小 11pt 规范
- 由 ③ 的 `micro = 11pt` 统一落地：原 9pt / 10pt 小字全部吸附到 11pt，保证 WCAG 可读性下限。
- 此后新增小字应优先用 `AIATheme.Font.micro`，不得再写 <11pt。

### ✅ ⑤ 卡片封装复用（`.card()` 收口）
- **原因**：多处手写 `.background(AIATheme.surface).clipShape(...).overlay(.stroke(hairline))`，易漏描边、难统一。
- **动作**：把「表面色 + 1px 细描边、无投影」的等价手写块统一替换为 `.card(radius:shadow:false)`（`.card()` 自带 `allowsHitTesting(false)` 描边，比手写更安全）：
  | 文件 | 行 | 半径 |
  |------|----|------|
  | `RecordsViews.swift` | 233 | rMD |
  | `MonthlyReportView.swift` | 311 | rLG |
  | `MonthlyBillListView.swift` | 87 | rLG |
  | `MonthlyBillListView.swift` | 139 | rLG |
- **未改（刻意保留，避免视觉回归）**：其余 10 处 `stroke(AIATheme.hairline)` 实为不同语义——插画 `Shape` 填充描边(`AIAIllustrations`)、头像 `Circle` 描边(`ChatView` lineWidth 0.5)、选中态 `Capsule` 条件描边(`ResultConfirmView`/`MonthlyReportView` 段控)、`Shape.fill` 描边(`TriggerTutorialView`)、`.continuous` 圆角风格(`OnboardingView`)。强制套 `.card()` 会改变圆角样式/描边宽度/线宽条件，故不处理。

### 🔧 编译验证
```
xcodebuild -scheme AIA -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
→ ** BUILD SUCCEEDED **（需关闭沙箱：Swift 宏 @Model/#Preview 依赖 swift-plugin-server，沙箱会拦截报 "Operation not permitted"）
```
- 验证结论：③/⑤/⑧ 三项改动**零编译错误**；`MonthlyBillListView` 仅有 1 条与本次改动无关的预存 warning（line 186 未用 `now`）。

## 涉及文件
`UIComponents.swift`（新增 `AIATheme.Font` 枚举）· `RecordsViews.swift` · `MonthlyReportView.swift` · `MonthlyBillListView.swift` · 以及经 sweep 改动的其余 36 个含 `.system(size:)` 的文件（共 37 文件 666 处）。

## 暂未做（需确认 / 主观项）
- **⑥ 首页三重动效叠加 + 气泡与宫格内容重复**：动效/信息层级主观调优，建议真机（iPhone 15 Pro Max）评估后定方案。
- **⑦ 底部固定 bar 遮挡**：已确认非真实遮挡 bug（AIBottomBar 是 ScrollView 的 VStack 兄弟节点，内容始终在其上方）；真实问题为底部安全区 padding 偏紧 + 详情页冗余显示 bar，需真机滚动确认后微调。
