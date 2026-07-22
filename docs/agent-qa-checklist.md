# AI 助理 · 云端聊天 Agent 接入 · 端到端 QA 场景清单

> QA 工程师：严过关（Edward / Yan）｜ 版本基线：`20260722k-agent-v1`
> 配套测试件：`云函数/recognize/test/agentTools.test.js`、`云函数/recognize/test/agentLoop.test.js`
> 运行（托管版 Node 22，离线 mock，无需真实 CloudBase / 商汤）：
> ```
> NODE=/Users/daxing/.workbuddy/binaries/node/versions/22.22.2/bin/node
> $NODE 云函数/recognize/test/agentTools.test.js
> $NODE 云函数/recognize/test/agentLoop.test.js
> ```

---

## 0. 测试策略与范围

| 项 | 说明 |
|---|---|
| 环境 | 离线、可重放。不依赖真实 CloudBase / 商汤；用 mock 注入假 `@cloudbase/node-sdk` 与假 `https`（拦截 `token.sensenova.cn`）。 |
| mock 注入点 | `@cloudbase/node-sdk` 通过 `Module._load` 在 `require('./agentTools')` 之前注入（其顶部即 `require`，必须预置）；`https.request` 覆盖以驱动 LLM 的 `tool_calls` / `content` / `error`。 |
| 入口 | 全部经 `exports.main({body:{...}})` 触发，最贴近真实链路（handleChat/handleAgent 未单独导出）。 |
| 覆盖 | 只读铁律、工具正确性、Agent 循环、降级闭环（4 种）、向后兼容、前端静态回归。 |
| 已知限制 | 时间范围基于记录顶层 `updatedAt`（秒）过滤，而非事件业务时间（如 `payload.time`）；属 v1 取舍。 |

---

## 1. 提问路由（Question Routing）

**目标**：疑问句走云端 Agent 问答；明确记录意图走本地快捷路径，不被 Agent 误吞。

| 场景 | 步骤 | 预期 | 自动化 |
|---|---|---|---|
| 疑问句 → Agent | `ChatView.isQuestionLike(t)` 命中（含「？/多少/怎么」等）→ `RecognizeService.chat(mode:"agent")` | 云端经 `handleAgent` 返回 `reply` | agentLoop C1/C2/E2 |
| 待办意图 → 本地 | `t="提醒我明天交报表"` → `createTodoLocally` 命中 | 本地建待办，不调 AI | ChatView.swift 静态回归（F） |
| 明确账单意图 → 本地 | `t="记一笔星巴克35"` → `createBillLocally` 命中 | 本地建账单，复用 MerchantMeta 分类 | ChatView.swift 静态回归（F） |
| 食物意图 → 本地优先 | `t="吃了个鸡蛋"` → `isFoodLike` 命中 → `createFoodLocally` | 本地营养库命中直接建；否则云端专项查询 | ChatView.swift 静态回归（F） |

**前端静态回归（F，已验证）**
- `git status`：`ChatView.swift` 工作区**无改动**（仅新增 `AgentChatRequest.swift` 为未跟踪，符合预期）。
- 关键符号均在：`processNext`(L1176)、`isQuestionLike`(L1243)、`createTodoLocally`(L631)、`createBillLocally`(L671)、`isFoodLike`(L653)。
- `processNext` 逻辑未变：疑问句分支调 `RecognizeService.chat`（现 `mode:"agent"`），其余分支保留本地建记录，**Agent 只接管问答分支，未破坏本地快捷路径**。

---

## 2. 自由查询（Free-form Queries via Tools）

**目标**：Agent 通过只读工具按需取数，回答任意自由查询（如「上个月咖啡花了多少」「这周吃了几次火锅」）。

| 场景 | 步骤 | 预期 | 自动化 |
|---|---|---|---|
| 单工具回填 | 第 1 轮 LLM 返回 `tool_calls=[query_bills(...)]`，第 2 轮返回 `content` | `reply` 非空；`toolsUsed` 含 `query_bills` | agentLoop **C1** |
| 多工具一次回填 | 第 1 轮返回 `tool_calls=[query_bills, get_summary]` | `toolsUsed` 同时含两者；第 2 轮给出最终回复 | agentLoop **C2** |
| 账单分类过滤 | `query_bills({category:'餐饮'})` | 仅返回餐饮类；其余分类排除 | agentTools **B1** |
| 收支汇总 | `query_bills` 全量 | `summary.income/expense/count` 正确 | agentTools **B1** |
| 营养汇总 | `query_foods` | `totalCalories/totalProtein/totalCarbs/totalFat` 正确 | agentTools **B2** |
| 健康最新值 | `query_health({metric:'体重'})` | 按 `updatedAt` 取每个 metric 最新一条 | agentTools **B3** |
| 聚合摘要 | `get_summary({range:'last7Days'})` | bills/foods/reminders/health 聚合正确 | agentTools **B4** |

---

## 3. 只读校验（Read-only Enforcement）

**目标**：Agent 工具绝不写库；查询强制 `userId + deleted:false`。

| 场景 | 步骤 | 预期 | 自动化 |
|---|---|---|---|
| 静态写操作扫描 | 正则扫描 `agentTools.js` + `index.js` 的 agent 路径，禁止 `.add/.update/.set/.remove/.doc` | 无 DB 写操作（排除 `map.set`/`hmap.set` 容器方法） | agentTools **A1** |
| 导出面收敛 | 检查 `module.exports` | 仅 `query_bills/query_foods/query_health/get_summary` 4 个函数 | agentTools **A2** |
| 墓碑过滤 | mock 中放 `deleted:true` 记录 | 查询结果**不含**该记录 | agentTools **A3** |
| 越权过滤 | mock 中放他人 `userId` 记录 | 查询结果**不含**他人记录 | agentTools **A3** |
| 超量截断 | 注入 51 条记录（>50） | `truncated=true`，`list` 截断到 50 | agentTools **B5** |

> 注：实测 `index.js` agent 路径无任何写操作；`agentTools.js` 仅有 `map.set`/`hmap.set`（JS Map 容器方法，非 CloudBase 写）。只读铁律在产品代码中成立。

---

## 4. 降级闭环（Degradation Fallback）

**目标**：任何异常都收敛到 `handleChat(context-only)`，保证「始终有回复」，且 `mode:"chat"` 旧路径完整保留。

| 场景 | 触发 | 预期 | 自动化 |
|---|---|---|---|
| 缺 userId | `body` 无 `userId` | 直接降级 `handleChat`，有 `reply` | agentLoop **D1** |
| LLM 网络/解析错误 | mock `https.request` 首次抛错 | 捕获异常 → 降级 `handleChat`，有 `reply` | agentLoop **D2** |
| 工具 / DB 不可用 | 强制 `getDB()` 抛错（5 轮工具均失败） | 循环达上限 → 降级 `handleChat`，有 `reply` | agentLoop **D3** |
| 连续 5 轮 tool_calls | 模型始终返回 `tool_calls`、无最终 `content` | 超过最大轮数 → 降级 `handleChat`，有 `reply` | agentLoop **D4** |

> 判定「走 handleChat 兜底」的依据：mock 对 `callChatRaw`（不含 `tools` 参数）返回标志性内容 `【兜底】handleChat回复`，与 `callWithTools`（含 `tools`）的正常/多工具回复区分，确保降级路径真实命中而非巧合通过。

---

## 5. 向后兼容（Backward Compatibility）

**目标**：`mode:"chat"` 原路径完整保留，与 `mode:"agent"` 并存无冲突。

| 场景 | 步骤 | 预期 | 自动化 |
|---|---|---|---|
| chat 模式 | `body.mode:"chat"` | 返回 `{ok, reply}`，非空 | agentLoop **E1** |
| agent 与 chat 共存 | 先发 `agent` 再发 `chat` | 各自独立返回，互不影响 | agentLoop **E2** |
| 通用回应豁免 | `mode:"agent"` 时通用回应拦截跳过（不改写实现） | agent 分支不被误拦截 | 设计确认（`index.js` 拦截条件 `mode!=='agent'`） |

---

## 6. 端到端链路回归（云函数 + 客户端）

| 环节 | 预期 | 验证方式 |
|---|---|---|
| 客户端请求 | `RecognizeService.chat` 发 `mode:"agent"` + `userId`(CloudSyncManager.userId) + `provider:"sensenovaText"` | RecognizeService.swift L213-224、AgentChatRequest.swift 静态确认 ✓ |
| 云函数路由 | `exports.main` 按 `mode` 分流；`agent` → `handleAgent`，`chat` → `handleChat` | agentLoop C1/E1/E2 ✓ |
| 系统提示 | `AGENT_SYSTEM_PROMPT` 注入「阿宝」角色 + 只读铁律 + `{CURRENT_TIME}` | agentPrompt.js 静态确认 |
| 工具 Schema | `AGENT_TOOLS`（4 个 function-calling 定义）下发给商汤 | agentSchema.js 静态确认 |
| 版本标记 | 返回体含 `ver: '20260722k-agent-v1'` | agentLoop C1 断言 `res.ver` 存在 |

---

## 7. 测试结论（Test Report）

| 套件 | 用例数 | 结果 |
|---|---|---|
| `agentTools.test.js`（A/B：只读铁律 + 工具正确性） | 8 | 全部通过 ✅ |
| `agentLoop.test.js`（C/D/E：循环 + 降级 + 兼容） | 8 | 全部通过 ✅ |
| **合计** | **16** | **16/16 通过，0 失败** |

- **IS_PASS**：✅ 通过。
- **源码 Bug**：未发现。`index.js` / `agentTools.js` / `agentSchema.js` / `agentPrompt.js` / `RecognizeService.swift` / `AgentChatRequest.swift` 实现符合设计（system_design.md §7 只读铁律、§4 降级闭环、§7.8 始终有回复）。
- **测试自身问题（已自修）**：初版运行器用 `Promise.all` 并发执行共享可变 mock 状态（`MOCK` / `CURRENT_MOCK_DB` / `DB_THROW`），导致用例互相污染（B5 截断误判、D3/D4 模式串味）；且 `agentTools.getDB()` 会缓存 DB 句柄，原 mock 在 `init` 时固化数据集/抛错开关，切换不生效。已改为**顺序执行** + **查询时动态读取** `DB_HOLDER`/`DB_THROW` 的 mock，复测全绿。
- **已知限制（v1 取舍）**：
  1. 时间范围基于记录顶层 `updatedAt`（秒）过滤，非 `payload.time` 业务时间；跨时区/历史修正场景需注意。
  2. 工具/DB 异常按「逐轮捕获 → 5 轮超限降级」处理，单轮工具失败不会立即整体降级（仍保证最终有回复，符合降级一致性）。
  3. 测试为离线 mock，未覆盖真实商汤 function-calling 格式细节与真实 CloudBase 查询性能/限流。
