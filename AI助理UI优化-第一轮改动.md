# AI 助理 App · UI 优化第一轮改动记录

> 日期：2026-07-22 ｜ 执行人：UI Designer ｜ 状态：**BUILD SUCCEEDED**
> 本轮只做审计报告中「零风险、立竿见影」的 P0 + P1-④ 项，未触碰任何功能逻辑。

## 改动清单

### ✅ P0-① 删除死代码 `DashboardView.swift`
- **原因**：类型 `DashboardView` 全工程从未被实例化（仅 `BillDashboardView` 名字相近但无关），且不在 Xcode 编译列表；内部用 `.orange / .green / Color.red / Color.yellow / Color.brown` 硬编码，完全脱离 `AIATheme`。
- **动作**：已删除文件。编译不受影响（无引用）。

### ✅ P0-② 灰色令牌统一收口（消除三套灰阶）
- **原因**：`Color.gray` / `.gray` 与 `AIATheme.sub` / `AIATheme.muted` 并存，同屏出现 3 套灰阶，深浅切换时错位，显得没统一调过。
- **动作**：
  - 38 处 `foregroundStyle(.gray)` → `foregroundStyle(AIATheme.sub)`
  - 组件库内部小字（`RingView`/`MacroCard`/`StatCard`/`CardRow`/`SectionTitle`）→ `AIATheme.muted`
  - `LoginView`/`PhoneLoginView` 禁用态底色 `Color.gray.opacity(0.35)` → `AIATheme.muted.opacity(0.35)`
  - `TriggerTutorialView` 图标灰 `Color.gray` → `AIATheme.iconInactive`
- **结果**：灰阶从 3 套收敛为 2 套（`sub` 次要 + `muted` 三级），与 `AIATheme` 体系一致。

### ✅ P1-④ 账单分类色纳入主题 + 补深色变体
- **原因**：`BillCategoryHelpers.color(for:)` 中 8 个 `Color(hex:)` 散落在业务文件，无深色变体，深色模式下色相可能漂移。
- **动作**：8 个分类色改为 `Color.adaptive(light:dark:)`，各配深色变体：
  | 分类 | 浅色 | 深色 |
  |------|------|------|
  | 住房 | `0x8B5CF6` | `0xA78BFA` |
  | 娱乐 | `0xEC4899` | `0xF472B6` |
  | 医疗 | `0xEF4444` | `0xF87171` |
  | 教育 | `0x3B82F6` | `0x60A5FA` |
  | 通讯 | `0x06B6D4` | `0x22D3EE` |
  | 保险 | `0xF97316` | `0xFB923C` |
  | 云服务 | `0x0EA5E9` | `0x38BDF8` |
- **调用点不变**（仍返回 `Color`），账单 donut 图、分类列表、规则页图标底色自动获得深色适配。

### 🔧 编译验证
```
xcodebuild -scheme AIA -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
→ ** BUILD SUCCEEDED **
```

## 涉及文件
`DashboardView.swift`(删) · `UIComponents.swift` · `RecordsViews.swift` · `BillDashboardView.swift` · `BillCategoryView.swift` · `FoodDetailView.swift` · `HealthDetailView.swift` · `WeightTrendView.swift` · `LoginView.swift` · `PhoneLoginView.swift` · `TriggerTutorialView.swift` · `BillCategoryHelpers.swift`

## 暂未做（需确认 / 主观项）
- **③ 字号令牌化**：`.system(size:N)` 散写 1000+ 处、22 种字号(9~44)。建议新增 `AIATheme.Font` 阶梯后做一次全量 sweep，未盲改以免引入偏差。
- **⑤ 卡片封装复用**：`ResultConfirmView`/`RecordsViews` 手写 `.background+.clipShape+.overlay` 可统一改 `.card()`，需逐处核对描边与 padding，避免视觉变化。
- **⑥ 首页三重动效叠加 + 气泡与宫格内容重复**：动效/信息层级的主观调优，建议真机（iPhone 15 Pro Max）评估后定方案。
- **⑦ 底部固定 bar 遮挡**：需在真机滚动列表到底确认是否有末条被遮。
- **⑧ 小字最小 11pt 规范**：立一条设计规范即可。

> 下一步：确认是否继续做 ③ / ⑤ / ⑥。
