# 灵动岛（Live Activity）架构骨架 · 设计文档

> 状态：本期只落地「架构骨架 + recognition demo 岛」，sleep / todo 仅预留接入点。
> 最后更新：2026-08-02

## 0. 摘要
从零引入 ActivityKit，建立统一的灵动岛中枢（单一 `ActivityAttributes` + 单例 `LiveActivityManager` + 一个 Widget Extension 承载 UI）。本期跑通可演示的「识别流水线」demo 岛，并预留识别 / 睡眠 / 待办三类业务的接入点（留 TODO，不实现业务）。后续各功能按接入点增量接入，不改骨架。

## 1. 本期范围
**做：**
- 新建 Widget Extension target `AIALiveActivityWidget`，承载 Live Activity UI。
- 定义 `AIALiveAttributes`（通用数据模型，覆盖多场景）。
- 实现 `LiveActivityManager` 单例（启动 / 更新 / 结束 / 查当前）。
- 实现三态 UI（compact / expanded / minimal + 锁屏横幅）。
- 开发者中心「启动 Demo 灵动岛」按钮，真机验证岛 UI。
- 主 App `Info.plist` 注入 `NSSupportsLiveActivities = YES`。

**不做（仅预留接入点）：** 识别流水线真实接入、睡眠计时真实接入、待办倒计时真实接入。

## 2. 技术前提与硬约束
1. **必须 Widget Extension**：Live Activity 界面（`ActivityConfiguration`）只能写在 WidgetKit Extension target 里，主 App 只负责启 / 更 / 停。
2. **共享模型文件**：`AIALiveAttributes.swift` 同时被主 App 与 Widget Extension 编译（主 App 显式 Build File 引用，扩展经同步根目录组自动包含）。
3. **无需判断设备**：灵动岛机型前台显示岛；其余机型自动降级为锁屏横幅。一套代码通吃。
4. **本地更新需 App 进程活跃**：App 被杀后本地 `update` 失效——识别场景的「后台杀进程」走已有系统通知兜底，岛只覆盖 App 活着时的识别。
5. **最长 8 小时**，到期系统强制结束。`sleep`（一觉可能 > 8h）后续需续期 / 到点收尾。
6. **模拟器不显示岛**，只能预览锁屏横幅样式，灵动岛真机验证必需。

## 3. 目录结构与 Target
```
AIA/AIA/LiveActivityManager.swift   // 主 App 单例，import ActivityKit
AIA/AIALiveActivityWidget/          // 新建 Widget Extension target
  AIALiveAttributes.swift           // 主 App + Widget 双 target 编译
  AIALiveActivityWidget.swift       // @main WidgetBundle + ActivityConfiguration（UI 三态）
  Info.plist                        // NSExtensionPointIdentifier = com.apple.widgetkit-extension
```
Bundle id：`com.daxing.aia.AIA.AIALiveActivityWidget`。

## 4. 统一数据模型 `AIALiveAttributes`
一个 Activity 多场景路由，用 `kind` 区分；管理器保证同一 `kind` 不重复启动（已存在则 update），从而睡眠（长）+ 识别（短）可并存。见 `AIALiveAttributes.swift`。

## 5. 中枢 `LiveActivityManager`
主 App 单例，提供 `start / update / end / current`，按 `kind` 路由。见 `LiveActivityManager.swift`。

## 6. Live Activity UI（Widget Extension）
锁屏横幅 + compact（🔍/🧾¥xx）+ expanded（标题 + 阶段 + 提示）+ minimal（图标）。按 `kind` 路由；本期只实现 `recognition` 分支，sleep / todo 留 `TODO` 占位。

## 7. Demo 跑通
开发者中心「启动 Demo 灵动岛」：起 `kind:"recognition"`（phase=ocr）→ 5s 后推进到 `done`（金额 42.5）→ 12s 后 `end`。

## 8. 预留业务接入点（仅 TODO，本期不实现）
| 场景 | 接入位置 | 动作 |
|---|---|---|
| 识别流水线 | `recognizeWithLocalPriority` / `ChatView` 拍照识别 / 快捷指令回前台 | 起 `kind:"recognition"`，阶段切换 `update`，结束 `end` |
| 睡眠计时 | 健康页 `SleepToggleButton` 点「😴 入睡」/「☀️ 醒来」 | 起 / 停 `kind:"sleep"`，expanded 放醒来按钮 |
| 待办临近 | 待办列表 / 通知调度处 | 临近时起 `kind:"todo"`，过期 `end` |

## 9. 风险与边界
- 8h 上限：sleep 一觉可能超 8h → 续期 / 到点收尾（骨架先记录，不实现）。
- 被杀更新失效：识别岛只覆盖 App 活着的识别；后台杀进程截屏识别继续走系统通知。
- 模拟器无岛：灵动岛样式只能真机看。
- Widget 双 target 编译：`AIALiveAttributes` 必须两个 target 都编译，否则编译失败。

## 10. 后续路线图
- A 识别岛：中（接 `update` 阶段 + 点击跳对话页需 Activity 点击深链 → WidgetURL）。
- B 睡眠岛：小（接 SleepSession 状态机）。
- C 待办 / 进度岛：小~中。
