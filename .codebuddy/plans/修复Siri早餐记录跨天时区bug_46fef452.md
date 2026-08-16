---
name: 修复Siri早餐记录跨天时区bug
overview: Siri/聊天记饮食在清晨（上海0:00–8:00）被记到前一天的根因是 AppFormat.isoDate 未设时区（默认UTC）。修复：给 isoDate 设置上海时区，统一所有饮食入口的本地日期语义。
todos:
  - id: fix-iso-date-tz
    content: 在 AppFormat.swift 给 isoDate 加上海时区，修复 Siri 清晨饮食跨天
    status: completed
  - id: verify-build
    content: 重新构建主 App 并验证 isoDate 改动无编译回归
    status: completed
    dependencies:
      - fix-iso-date-tz
  - id: verify-siri-date
    content: 实机复测早餐/午餐记录归当天、跨 UTC 午夜不再掉前一天
    status: completed
    dependencies:
      - verify-build
---

## 用户需求

排查并修复：用户 8 月 11 日通过 Siri 说「早餐吃了一个苹果」，App 却把这条饮食记录到了 8 月 10 日（前一天）的问题。

## 产品概述

Siri 一句话饮食记录链路（TellAIAIntent → LocalQuickParse → RecognitionSaver）在「没有具体时刻词」的场景下，会把当前日期序列化成「前一天」，导致清晨（上海 0:00–8:00）记录的饮食被分到昨天。

## 核心问题

- 根因：`AIAKit/AppFormat.swift` 里的 `isoDate` 格式化器（`.withFullDate`）**未设置时区，默认使用 UTC**；而上海比 UTC 早 8 小时。
- 当 Siri 说「早餐吃苹果」这类无具体时刻的语句时，代码走 `AppFormat.isoDate.string(from: foodDate)` 序列化纯日期串，上海当天 0:00–8:00 的绝对时间点被 UTC 格式化成「前一天」的 yyyy-MM-dd。
- 下游 `RecognitionSaver` 解析该日期串并按上海时区归组，于是落在昨天。
- 中午 12 点之后记录不受影响（不会跨 UTC 日界线）。
- 同类入口（ChatView 对话页饮食记录）使用完全相同的序列化模式，同样隐患，一并修复。

## 修复目标

让饮食（及账单 dueString 等）纯日期串统一按上海时区生成与解析，彻底消除清晨记录的跨天偏差；保证「早餐/午餐/晚餐」等无时刻语句正确落到说话当天。

## 技术栈

- 纯 Swift + SwiftUI + SwiftData（iOS 17）
- 涉及文件均在主 App 的 `AIA/AIA` 与共享框架 `AIA/AIAKit`

## 实现方案

### 根因定位

1. `AIA/AIAKit/AppFormat.swift:13-17`：`isoDate` 仅设 `.withFullDate`，**未设 timeZone → 默认 UTC**。
2. `AIA/AIA/LocalQuickParse.swift:72-73`：无时刻词时 `foodHasTime=false` → 走 `isoDate` 纯日期序列化。
3. 上海比 UTC 早 8 小时，上海当天 0:00–8:00 区间的绝对时刻被 UTC 格式化成「前一天」。
4. `AIA/AIA/RecognitionSaver.swift:313` 用 `AppFormat.isoDate.date(from:)` 解析该串并按餐次补默认时刻，最终分组到昨天。

### 关键决策

- **最小改动、根因级修复**：在 `isoDate` 定义处加 `f.timeZone = TimeZone(identifier: "Asia/Shanghai")`，与已有的 `isoLocal`（已设 `.current`）保持一致口径。
- 该 formatter 的全部使用点语义均为「本地日期」：
- `RecognitionSaver.swift:75`（dueString 解析）
- `RecognitionTypes.swift:112`（RecognitionResult.date 回退解析）
- `ResultRowCard.swift:1008`（卡片日期解析）
- `LocalQuickParse.swift:73` / `ChatView.swift:1937,2124,2187`（饮食日期序列化）
统一上海时区后更安全一致，不会破坏 `RecognitionSaver` 餐次默认时刻逻辑（该逻辑基于 `Calendar.current` 上海口径，在已解析到的「当天日期」上加 8/12/18 点，无需改动）。
- 不改动 `iso`（带完整时刻+时区，已有 `withInternetDateTime`）与 `isoLocal`（已 `.current`），避免副作用扩散。

### 性能与可靠性

- 仅修改一个格式化器时区属性，零运行时开销、零新增分支。
- 不改变任何数据流结构，仅修正序列化口径，修复范围精准（只惠及清晨记录，不影响中午及之后的记录）。

## 实施备注

- 改动落在共享框架 `AIAKit`，主 App 与 Widget 共用，需重新构建主 App（Widget 若引用 `isoDate` 同样受益）。
- 修复后务必实机复测：①「早餐吃苹果」「午餐吃苹果」归当天；②模拟器/真机把系统时间切到「上海凌晨」（UTC 午夜前后）验证不再掉前一天；③账单 dueString、对话页饮食记录一并验证无回归。
- 复用现有 `TimeZone(identifier: "Asia/Shanghai")` 写法，与项目其它日期工具保持一致。

## 目录结构

```
AIA/AIAKit/
└── AppFormat.swift   # [MODIFY] 给 isoDate 格式化器加 f.timeZone = TimeZone(identifier: "Asia/Shanghai")，与 isoLocal 口径对齐，修复清晨饮食/账单跨天 bug
```

（仅需改动此一个文件，其余使用点自动受益，无需逐文件修改。）

## 架构说明

本改动不涉及架构调整，仅修正一处共享日期工具的时区默认值。所有上游入口（Siri TellAIAIntent、ChatView 对话页、RecognitionSaver 入库、ResultRowCard 展示）通过统一引用 `AppFormat.isoDate` 即时获得修复，符合项目「单一数据源 / DRY」既有约定。