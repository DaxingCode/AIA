---
name: records-swipe-delete-multiselect
overview: 为各记录列表页添加左滑删除和长按多选删除功能，不与现有点击编辑冲突
todos:
  - id: 1-new-safe-delete
    content: 在 SafeDelete 中补充 waterLog 方法（直接设置 syncDeleted=true + syncUpdatedAt），以及 waterLogByID 版本
    status: completed
  - id: 2-swipe-delete
    content: 为 BillListView、FoodListView、ReminderListView、HealthListView、MonthlyBillListView 各记录行添加 .swipeActions(edge:.trailing, allowsFullSwipe:true) 左滑删除
    status: completed
  - id: 3-selectable-rows-views
    content: 在 RecordsViews.swift 的 BillListView/FoodListView/ReminderListView/HealthListView 中分别添加 multiSelectMode + selectedIDs 状态、长按进入多选、行选择复选框、toolbar 批量删除
    status: completed
  - id: 4-selectable-rows-monthly
    content: 在 MonthlyBillListView 中添加相同的多选删除功能（复用同一模式的 @State 和 toolbar 逻辑）
    status: completed
    dependencies:
      - 3-selectable-rows-views
---

## 功能概述

为应用中的所有记录列表页面增加两种记录操作方式——左滑删除和长按多选批量删除，且不能与现有点击编辑功能冲突。

### 核心功能

1. **左滑删除**：在每个记录行上，向左滑动露出红色删除按钮，点击可删除该记录；支持全滑直接删除。与点击编辑互不干扰。
2. **长按多选批量删除**：长按任意记录行进入多选模式，此时可点选多条记录（显示复选框），然后通过工具栏按钮批量删除已选项；再次点击"取消"退出多选模式恢复点击编辑。长按是多选的唯一入口，不影响正常点击编辑。

### 涉及页面（共 5 个）

- 账单列表（BillListView）—— RecordsViews.swift
- 月度账单明细（MonthlyBillListView）—— MonthlyBillListView.swift
- 食物记录列表（FoodListView）—— RecordsViews.swift
- 待办事项列表（ReminderListView）—— RecordsViews.swift
- 健康记录列表（HealthListView）—— RecordsViews.swift

已有删除功能的页面（BillCategoryView、MerchantRuleListView、RecurringRuleListView、AllRecordsView、RecognitionRecordsView）本次不做改动。

## 技术方案

### 技术栈

- 沿用现有 Swift + SwiftUI + SwiftData
- iOS 17+（与项目最低版本一致）
- 删除复用现有 SafeDelete 工具

### 实现策略

#### 1. 左滑删除 —— 原生 `.swipeActions`

使用 SwiftUI 原生 `.swipeActions(edge: .trailing, allowsFullSwipe: true)` 修饰符，添加到各页面每行外层容器上（Button / ZStack / NavigationLink 均可）。这一步改动量小、风险低、已有 BillCategoryView 先例。

对于 5 个目标页面：

- BillListView / FoodListView / MonthlyBillListView：行被 `Button { editX = X }` 包裹，`.swipeActions` 加在 Button 外层或 ForEach item 上，与 Button 的 tap 不冲突（swipe 手势优先级高于 tap，滑动时不触发点击）。
- ReminderListView：行是 ZStack 分层，`.swipeActions` 加在 ZStack 外层，与 `.onTapGesture` 共存。
- HealthListView：行使用 `ValueSelectableCard`（内含 NavigationLink），`.swipeActions` 加在 ForEach item 层。

**删除动作**：用 SafeDelete.bill/food/reminder/health 做软删（标记 `syncDeleted=true`），与现有删除逻辑一致。

#### 2. 长按多选删除 —— 通用 `SelectableRow` ViewModifier 方案

创建一个可复用的 `SelectableRowModifier` ViewModifier，核心状态管理在每个页面独立维持：

```
@State private var multiSelectMode = false
@State private var selectedIDs = Set<PersistentModelID>()
```

**ViewModifier 职责**：

- 非选择模式：在 `content` 上附加长按手势（长按 0.5s 触觉反馈 → 进入选择模式，将持有该行的 `modelID` 加入选中集并设置 `multiSelectMode = true`）
- 选择模式：在 `content` 前附加一个圆形复选框（`circle` / `checkmark.circle.fill`），点击切换选中状态，同时阻止原有 tap 响应
- 支持传入 `modelKeyPath` 以获取 `PersistentModelID` 用于选中标识

**各页面额外改动**：

- 添加 `@State private var multiSelectMode = false` 和 `selectedIDs`
- 在 `.toolbar` 中根据 `multiSelectMode` 动态添加批量删除按钮
- 点击删除时，用 `selectedIDs.forEach { SafeDelete.xxxByID($0, in: context) }` 批量删除

**多选模式视觉与交互规则**：

- 进入多选模式：触觉反馈 + toolbar 变为"取消"+"删除 N 条"
- 选择模式中：每行左侧显示圆形选择框，点击行切换选中状态，选中时高亮背景
- 取消选择模式：`selectedIDs.removeAll(); multiSelectMode = false`
- 删除确认：系统 Alert 确认
- 删除完成：自动退出选择模式
- 滑动删除在多选模式下隐藏

#### 3. 与点击编辑的冲突解决

| 交互 | 非选择模式 | 多选模式 |
| --- | --- | --- |
| **点击行** | 打开编辑 sheet（现有逻辑不变） | 切换选中状态（不打开编辑） |
| **长按行** | 进入多选模式（新增） | 无操作（已处于多选模式） |
| **左滑** | 显示删除按钮（新增） | 禁用滑动（检查 `!multiSelectMode`） |
| **箭头/返回** | 正常导航 | 正常导航 |
| **保存/修改** | 无影响 | 无影响 |


#### 4. 新增 SafeDelete 方法

WaterLog 模型有 `syncDeleted` 字段但缺 SafeDelete 方法。在 FoodListView 中删除水杯记录（单个 WaterLog）时也需要走软删路径，需要补充 `SafeDelete.waterLog`（直接标记 `syncDeleted=true`）和方法。

### 性能考虑

- 多选状态使用 `@State` 不会引起整页重渲染，选中变化通过 modifier 局部更新
- 批量删除用 `for id in selectedIDs { SafeDelete.xxxByID(id, in: context) }`，而非单次 fetch
- `.swipeActions` 延迟加载，不影响列表初始渲染性能

### 架构决策

- 不引入新的协议/抽象层——多选状态每个 View 独立持有，通过 `@ViewBuilder` helper 函数共享样式代码
- 不修改 SafeDelete 接口，复用已有 `*ByID` 方法
- 利用现有的 SwipeToDeleteCard 自定义组件（不覆盖，仅在未实现页面新增 `.swipeActions`）

## Agent Extensions

### code-explorer

- **Purpose**: 在实现阶段用于精确查找各页面的行结构、修改点、以及 SafeDelete 调用模式
- **Expected outcome**: 提供每个修改页面中精确的行号位置和当前代码片段，确保修改精准不破坏现有逻辑

### skill:docx

- **Purpose**: 在方案确认后生成详细的实现文档，供团队同步
- **Expected outcome**: 输出一份结构化的 .docx 文档，记录所有改动点、页面映射关系、冲突处理策略