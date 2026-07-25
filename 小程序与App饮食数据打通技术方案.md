# 小程序「好好吃饭」与 iOS App（AIA）饮食数据打通技术方案

> 目标：在小程序记录的饮食/饮水，在 App 自动展示；反之 App 记录的，在小程序自动展示。**双向 · 饮食 + 饮水**。
> 身份关联方式：**微信 OPENID 自动关联**。
> 文档状态：设计稿（待评审后落地）。

---

## 1. 现状调研结论（已验证）

### 1.1 两套云环境、两套身份

| 维度 | 小程序「好好吃饭」 | App（AIA） |
|---|---|---|
| 云环境 | 微信云开发 `cloud1-d1ga55pizf294dbe9`（appid `wxe41c5143f80ae14e`） | 独立 CloudBase `…-1445590522`（上海） |
| 同步接口 | 微信云函数 `saveData` / `loadData`（同环境内调用） | 公开 HTTP `/sync`：`https://aizhuli-d1ghh20818e926713-1445590522.ap-shanghai.app.tcloudbase.com/sync` |
| 身份标识 | 微信 `OPENID`（云函数内 `cloud.getWXContext().OPENID`） | 自生成 `userId`（登录态 `aia.userId` / 未登录设备级 `aia_sync_user_id`） |
| 饮食库 | `meals` 集合 | `aia_records` 集合（type=`food`） |
| 饮水库 | `water_records` 集合 | `aia_records` 集合（type=`water_log`） |

### 1.2 字段几乎 1:1 对齐（详细映射见 §5）

小程序 `meal`：`{foodName, weight(int克), calories, protein, carbs, fat, sugar, fiber, sodium, mealType, time("HH:MM"), date("YYYY-MM-DD"), score, source}`。
App `FoodEntry` payload：`{name, calories, protein, carbs, fat, fiber, sugar, sodium, weightGram, meal(中文), date(时间戳), ...}`。

### 1.3 App 同步引擎已原生支持饮食/饮水（关键利好）

`CloudSyncManager.swift` 现状（已读源码确认）：
- `buildPushItems`（L208/L310）已推送 `food` 与 `water_log`，payload 字段完整；
- `pull`（L334）→ `applyFood`（L483）/ `applyWaterLog`（L645）已按 `syncId` upsert、后写胜出；
- `aia-sync/index.js` 已支持任意 `userId` 分区、push/pull、墓碑软删、分页拉全。

**但有两个必须解决的 App 端约束**（见 §9）。

### 1.4 小程序写入高度集中（改造面极小）

所有 food/water 写入都经 `app.js` 的 4 个中央方法，页面全部复用：
- `saveMeal(record, cb)` —— `app.js:241`
- `deleteMeal(id, cb)` —— `app.js:272`
- `saveWater(record, cb)` —— `app.js:563`
- `deleteWater(id, date, cb)` —— `app.js:591`

调用点：`camera.js:839`、`calorie-result.js:644`、`meal-edit.js:580/606/823/1030`、`meal-history.js:721`、`records.js:244/263`。
→ **只要在这 4 个方法里插入同步逻辑，即可覆盖 100% 写入落点。**

---

## 2. 整体架构

以 **App 的 `aia_records` 作为跨端唯一共享库**。小程序通过 `wx.request` 直接调用 App 的公开 `/sync` 接口（跨账号可调用，无需新建云函数）。两边落到 `aia_records` 的**同一 `userId` 分区**，即自动共享。

```
┌──────────────────────┐         push/pull (food/water_log)         ┌────────────────────────────┐
│  微信小程序「好好吃饭」 │ ──── wx.request HTTPS ───────────────────▶ │  App 的 CloudBase 环境      │
│  (云开发 env A)       │ ◀─── (公开 /sync，userId 分区) ──────────── │  aia_records 集合 = 共享库  │
│                      │                                            │  (env B, 上海)              │
│  本地主库:            │                                            │                            │
│   meals / water_records│                                          │  iOS App (AIA)             │
│   + globalData 缓存   │ ─── 原生 CloudSyncManager push/pull ──────▶ │  SwiftData:                │
│                      │ ◀────────────────────────────────────────── │   FoodEntry / WaterLog     │
└──────────────────────┘                                            └────────────────────────────┘

   身份关联层（OPENID → 共享 userId）：
   小程序 openid ──派生──▶ 共享码 sharedCode ──(一次扫码/粘贴绑定)──▶ App 采用 sharedCode 作为同步 userId
```

---

## 3. 身份关联方案（OPENID 自动关联）

### 3.1 客观约束（必须正视）

纯"零绑定"的 OPENID 自动关联，**要求 App 也能拿到该微信用户的身份**（unionid/openid）。但当前 App：
- 没有微信登录能力（无微信开放平台账号、未集成 iOS 微信 SDK）；
- 用户当前无 Apple 付费开发者账号（真机调试/上架受限）。

因此"App 在小程序打开时自动认出同一人"需要一个桥接点：**首次绑定一次**，之后全自动。这正是下方推荐落地方案。

### 3.2 推荐落地：OPENID 派生「共享码」+ 一次扫码/粘贴绑定

`sharedCode` 即"该微信用户在跨端体系里的化身"，技术上等价于 OPENID 关联，只是首次需一次绑定动作（绑定后永久自动，符合"自动关联"的体验预期）。

1. **小程序侧取 OPENID**：新增极简云函数 `getOpenid`（3 行，返回 `cloud.getWXContext().OPENID`）；或在现有 `saveData` 成功返回里附加 `openid` 字段（改动更小）。
2. **派生共享码**：`sharedCode = 'wx_' + openid`（openid 是合法字符串，可直接作为 `userId` 分区键）。缓存到 `wx.setStorageSync('sharedCode', ...)`。
3. **小程序设置页**：展示 `sharedCode` 的**二维码 + 复制按钮**，文案"在 App 设置→微信绑定中扫描/粘贴此码，即可双向同步饮食"。
4. **App 侧绑定**：设置页新增「绑定微信小程序」入口（扫码或粘贴 `sharedCode`），写入 `UserDefaults["aia_bound_user_id"]`。
5. **生效**：App `CloudSyncManager.userId` 优先级增加"已绑定小程序则用 `aia_bound_user_id`"（见 §9.1）。从此 App 与小程序落到 `aia_records` 同一分区 → 双向自动共享。

> 为何不用 App 随机 userId 反填给小程序？因为 OPENID 只有微信侧有，App 无法反推；让"微信侧生成、App 侧绑定"是单向可达的唯一稳定路径。

### 3.3 进阶路线（真正零绑定，标注前置条件）

App 接入**微信开放平台登录**（同主体 UnionID）：
- App 集成微信 iOS SDK，`WXApi` 拿到 `code` → 后端换 `unionid`；
- 以 `unionid` 作为 `aia_records` 的 `userId` 分区键；
- 小程序侧用同一开放平台下的 `unionid`（需小程序与 App 同开放平台主体）映射到同一分区。

**前置成本**：微信开放平台企业/个人认证账号、iOS 微信 SDK 集成、Apple 付费开发者账号（真机/上架）。当前环境受限，**建议先落地 §3.2，§3.3 作为后续增强**。

---

## 4. 数据模型与字段映射

### 4.1 饮食：`meal` ↔ `FoodEntry`

| 小程序 `meal` | App `FoodEntry` payload | 转换规则 |
|---|---|---|
| `foodName` | `name` | 直接 |
| `weight` (int 克) | `weightGram` (Double) | `Double(weight)` |
| `calories/protein/carbs/fat/sugar/fiber/sodium` | 同名字段 | 直接（App 全 Double） |
| `mealType` (`breakfast/lunch/dinner/snack`) | `meal` (`早餐/午餐/晚餐/加餐`) | 枚举映射（见下） |
| `date`("YYYY-MM-DD") + `time`("HH:MM") | `date` (时间戳) | 组合成本地时区 `Date`（`new Date(date+'T'+time)`） |
| `score` | （App 无对应，忽略） | 不映射 |
| `source` | （App 无对应） | 写入 `payload._src='mp'` 便于排查（可选） |
| — | `waterIntake` | 小程序 meal 不含饮水 → 传 `0` |
| — | `portion` / `base*`（baseCalories 等） | 小程序无 → 留空（App 端可空） |

**餐别映射**：
```
breakfast→早餐, lunch→午餐, dinner→晚餐, snack→加餐
反向：早餐→breakfast, 午餐→lunch, 晚餐→dinner, 加餐→snack
```

### 4.2 饮水：`water_records` ↔ `WaterLog`

| 小程序 `water_records` | App `WaterLog` payload | 转换 |
|---|---|---|
| `date`("YYYY-MM-DD") | `date` (时间戳) | 当天 0 点 `Date`（或记录时刻，二选一并两边一致） |
| `amount` (ml) | `amount` (ml) | 直接 |
| `createTime` / `_id` | `syncId` | 小程序生成稳定 UUID 作 syncId |

> 约定：小程序饮水 `date` 为"某天"语义，构造时间戳时用当天 0 点（本地时区），App 端 `WaterLog.date` 同理对齐，避免"同一杯水在两端算成不同日期"。

---

## 5. 同步协议（复用现有 `/sync`）

入参（POST JSON，已确认 `aia-sync/index.js` 支持）：
```json
// push
{ "action":"push", "userId":"<sharedCode>",
  "records":[ { "id":"<UUID>", "type":"food|water_log",
                "updatedAt": <秒时间戳>, "deleted": false, "payload":{...} } ] }
// pull
{ "action":"pull", "userId":"<sharedCode>", "since": <上次同步秒时间戳> }
```
返回：`push → {ok,upserted,total}`；`pull → {ok,records:[{id,type,updatedAt,deleted,payload}],count}`。

小程序用 `wx.request({url: SYNC_URL, method:'POST', data, ...})`，`SYNC_URL` = 上方 `/sync` 域名。

---

## 6. 双向同步机制

### 6.1 写入路径（小程序 → 共享库）

在 `app.js` 的 4 个中央方法里，**写自己库之后追加一次** `pushToApp`：
- `saveMeal`：为 `record` 补 `record.syncId`（若无，生成 UUID 并缓存进"已知 syncId 集合"）；`pushToApp('food', foodPayload, record.syncId, false)`。
- `deleteMeal`：`pushToApp('food', {}, syncId, true)`（墓碑）。
- `saveWater` / `deleteWater`：同理 push `water_log`（带 `syncId`）。
- 失败静默忽略（小程序自有库为主，不阻塞用户）；网络恢复后由"已知 syncId 集合"做增量补推。

### 6.2 读取/合并路径（共享库 → 小程序）

- 小程序 `onLaunch` 与「切前台」时调用 `pullFromApp()`：
  - `wx.request` pull（userId=sharedCode, since=本地存储的 `lastPullAt`）；
  - 遍历 `records`，**只吸收 `id` 不在"已知 syncId 集合"的记录**（即 App 侧产生的，避免把小程序自己 push 的再拉回来造成重复）；
  - 转换为 `meal`/`water` 结构，合并进 `globalData.meals` / `waterCache`，并 `setData`/通知页面（`_notifyDataChange`）。
  - 记录 `lastPullAt = Date.now()/1000`。

### 6.3 去重与防循环（核心，务必遵守）

- **App 侧天然不重复**：`aia_records` 与 SwiftData 通过 `syncId` 一一对应，`applyFood/applyWaterLog` 按 `syncId` upsert，绝不会新增重复。✅
- **小程序侧防循环**：维护 `wx.setStorageSync('knownSyncIds', [...])`。
  - 小程序自己 push 的记录，`syncId` 记入集合 → pull 时跳过；
  - App 产生的记录 `syncId` 不在集合 → 吸收并记入集合；
  - 此后 App 更新该记录（新 `updatedAt`）→ 小程序 pull 命中集合 → 更新而非新增。
- **循环验证**：App pull 到小程序 push 的记录（syncId 已知于 App）→ App push 同 syncId 回库（updatedAt 不变）→ 小程序 pull 命中已知集合 → 跳过。**无无限循环，无重复。** ✅

### 6.4 冲突解决

统一**后写胜出**（与 App 现有策略一致）：`aia-sync` 仅在 `updatedAt >= 云端` 时覆盖；App `apply*` 仅在 `syncUpdatedAt < remoteDate` 时更新。两端一致，无需额外逻辑。

### 6.5 删除 / 墓碑

- 小程序删除 → push `deleted:true`（共享库软删）；App pull 时 `apply*` 命中 `deleted` → 本地删。
- App 删除 → 已有 `syncDeleted` + `cleanupSyncedTombstones`，push 到共享库；小程序 pull 命中已知集合且 `deleted` → 从 `globalData.meals` 移除。

---

## 7. 小程序端改造清单（精确到文件/方法）

**新增文件**
- `syncBridge.js`：封装 `getSharedCode()` / `pushToApp(type,payload,syncId,deleted)` / `pullFromApp()` / `knownSyncIds` 读写。

**改动 `app.js`**
- `saveMeal`(L241)：写库成功后 `pushToApp('food', toFoodPayload(record), record.syncId, false)`。
- `deleteMeal`(L272)：成功后 `pushToApp('food', {}, syncId, true)`。
- `saveWater`(L563)：成功后 `pushToApp('water_log', toWaterPayload(record), record.syncId, false)`。
- `deleteWater`(L591)：成功后 `pushToApp('water_log', {}, syncId, true)`。
- `onLaunch`(L3) / `_loadCloudData`(L33)：末尾调用 `pullFromApp()`（需先确保已取得 `sharedCode`）。
- 新增 `toFoodPayload` / `toWaterPayload` 字段转换函数（依据 §4）。

**改动页面（仅设置页新增 UI）**
- `pages/profile` 或 `pages/login`：新增「微信绑定 / 同步码」区块，展示 sharedCode 二维码 + 复制按钮 + 说明。

**新增云函数（极小）**
- `getOpenid/index.js`：返回 `cloud.getWXContext().OPENID`（或在 `saveData` 成功返回附加 `openid`，二选一）。

**配置**
- 微信公众平台后台 → 开发设置 → request 合法域名：新增 `https://aizhuli-d1ghh20818e926713-1445590522.ap-shanghai.app.tcloudbase.com`。

---

## 8. App 端改造清单（必要，因 OPENID 关联 + 实时性）

### 8.1 同步账号优先级（必改）
`CloudSyncManager.userId`（L23）增加最高优先级：若 `UserDefaults["aia_bound_user_id"]` 存在且非空，**优先返回它**（覆盖登录态/设备级）。绑定小程序即切换饮食同步分区。

### 8.2 同步频率提升（必改，否则"自动展示"不成立）
当前 `syncAfterLocalChange`(L91) 已废弃、仅每日 0 点同步一次（L100）。需新增：
- `syncIfStale(context:)`：`lastSyncAt` 距现在 > N 分钟（建议 3~5 分钟）或有本地变更时触发一次 `sync()`（带节流）；
- 在饮食/饮水相关页面 `onAppear`、App 回到前台（`scenePhase .active`）时调用 `syncIfStale`；
- 这样小程序新记录能在 App 进入饮食页/回到前台时数秒内拉到。

### 8.3 绑定 UI（配合 §3.2）
设置页新增「绑定微信小程序」：扫码或粘贴 `sharedCode` → 写入 `aia_bound_user_id` → 触发一次 `syncAfterLogin`（先全量 pull 再 push，避免分区切换丢数据）。

### 8.4 历史 FoodEntry 迁移（可选）
绑定后 App 原分区饮食数据不在新分区。提供「迁移」：绑定前先把当前本地 `FoodEntry/WaterLog` 以**新 userId** push 一次（保留 syncId），再切分区并 pull。避免老数据"消失"。

### 8.5 food/water_log payload 标记（可选）
`buildPushItems` 的 food/water_log payload 可加 `_src:'app'`（便于排查，非必需，去重靠 syncId 已足够）。

> App 端 `aia-sync/index.js` **无需改动**（已支持任意 userId、food/water_log、墓碑、分页）。

---

## 9. 历史数据迁移（打通前存量）

- **打通后的新数据**：自动双向同步（§6）。
- **小程序老 `meals/water_records`**：不进 `aia_records`，App 看不到。
  - 方案：小程序设置页加「迁移历史到 App」按钮，批量给老记录补 `syncId` 并 `pushToApp`，使 App 也能拉到。
- **App 老 `FoodEntry/WaterLog`**：绑定小程序时按 §8.4 迁移到共享分区。
- 若存量不大，可仅提示"仅同步绑定后的新记录"，迁移按钮作为可选。

---

## 10. 部署与配置清单

| 项 | 操作 | 位置 |
|---|---|---|
| 小程序 request 域名白名单 | 加 `https://aizhuli-d1ghh20818e926713-1445590522.ap-shanghai.app.tcloudbase.com` | 微信公众平台 → 开发设置 |
| 新增 `getOpenid` 云函数 | 部署到小程序云环境 | 小程序 `cloudfunctions/` |
| 小程序同步码 UI | 设置页展示二维码+复制 | `pages/profile` |
| App 绑定 UI + userId 优先级 + 同步频率 | 改 `CloudSyncManager.swift` + 设置页 | App |
| `aia-sync` 云函数 | **无需改动**（已就绪） | App 云环境 |

---

## 11. 异常处理与边界

- **小程序未绑定**：`sharedCode` 缺失时不调 `/sync`（保持原有小程序内体验），不报错。
- **App 未联网 / `/sync` 失败**：写入静默失败，本地库正常；下次 `syncIfStale` 重试。
- **时区**：日期构造统一用本地时区 `Date`，避免"今天 23:30"被算成次日。
- **字段缺失**：App `apply*` 对空字段有 `?? 默认值` 兜底；小程序 `toFoodPayload` 对 `undefined` 给 `0/''`。
- **超大批量**：`pull` 已分页（PAGE=100），小程序 pull 也按 `since` 增量，避免首拉卡顿。
- **误绑不同小程序**：App 换绑 `aia_bound_user_id` 即可切换分区，旧分区数据保留云端。

---

## 12. 风险、安全与回滚

- **安全**：`/sync` 当前不鉴权（靠 userId 不可猜性，App 既有设计）。打通后 `userId=sharedCode(含openid)`，猜解难度不变，属 MVP 可接受；后续可对 `/sync` 增加 `sharedCode` 签名校验升级。
- **数据污染**：因 `syncId` 去重 + 来源过滤，不会双向互写导致重复。
- **回滚**：小程序删除 `syncBridge` 调用即退回纯本地；App 清 `aia_bound_user_id` 即退回原账号分区。改动均局部、可一键撤销。
- **Schema/迁移**：App 端仅改 `CloudSyncManager`（非 `@Model`），不影响 SwiftData schema，无迁移风险。

---

## 13. 落地里程碑（建议顺序）

1. **M1 小程序写入桥接**：`syncBridge.js` + `app.js` 4 方法 hook + `getOpenid` 云函数 + 字段转换。验证：小程序记饮食，手工 POST `/sync` 能看到 `type:'food'`。
2. **M2 小程序读取合并**：`pullFromApp` + 已知 syncId 集合 + `onLaunch`/切前台触发。验证：App 手动 push 一条 food，小程序能拉到并去重。
3. **M3 App 身份与频率**：`userId` 绑定优先级 + `syncIfStale` + 绑定 UI。验证：App 设置绑定 sharedCode 后，两边落到同一分区。
4. **M4 配置与联调**：request 域名白名单、双向实时联调、冲突/删除/墓碑全链路。
5. **M5 历史迁移（可选）**：批量迁移按钮 + App 老数据迁移。
6. **M6（进阶）**：App 微信登录 UnionID 自动关联（§3.3，需开放平台/付费账号就绪后）。

---

## 附：关键文件索引
- 小程序：`/Volumes/MacBook/三好 AI 健康管家/好好吃饭 AI 助理/app.js`
- 小程序云函数：`/Volumes/MacBook/三好 AI 健康管家/好好吃饭 AI 助理/cloudfunctions/saveData|loadData`
- App 同步引擎：`/Volumes/MacBook/Workbuddy/AI助理/AIA/AIA/CloudSyncManager.swift`
- App `/sync` 云函数：`/Volumes/MacBook/Workbuddy/AI助理/云函数/aia-sync/index.js`
- App `/sync` 域名：`RecognizeService.swift` L55 的 endpoint 替换 `/recognize`→`/sync`
