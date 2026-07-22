# AI 助理 · 原生代码脚手架（纯 Swift + SwiftUI）

按「纯 Swift + SwiftUI」+「通义千问视觉 Qwen-VL」+「CloudBase 云函数代理」方案生成的 MVP 脚手架。
含：截图识别闭环（选图/后台识别 → 结果确认 → 存入本地库）。

## 目录结构

```
原生代码脚手架/
├── iOS/                           # Xcode 工程要放进去的 Swift 源文件
│   ├── AIAApp.swift               # App 入口 + SwiftData 容器
│   ├── ContentView.swift          # 首页（四模块宫格）+ 测试识别 + 云同步自动触发
│   ├── ResultConfirmView.swift    # 识别结果确认页（存入 + 同步写 HealthKit）
│   ├── NutritionLibrary.swift     # 本地营养参考库（按名称匹配，校正食物热量/宏量）
│   ├── RecordsViews.swift         # 四个模块的「记录列表」页（饮食/账单/健康/待办）
│   ├── HealthManager.swift        # HealthKit 封装（授权/读步数·活动消耗/写体重热量等）
│   ├── DashboardView.swift        # 首页「净热量联动」卡片（摄入−消耗=净热量 + 宏量营养素）
│   ├── CloudSyncManager.swift     # 云同步：push/pull 四类型记录到 CloudBase
│   ├── SettingsView.swift         # 设置页：同步账号 / 自动同步 / 立即同步
│   ├── Models.swift               # 本地数据库模型（含 syncId/updatedAt/deleted 同步字段）
│   ├── RecognitionTypes.swift     # 识别结果 JSON 解码结构
│   ├── RecognizeService.swift     # 调云函数的网络层（识别 + 同步端点）
│   ├── ScreenshotStore.swift      # App Group 共享存储（后台↔主App↔扩展）
│   ├── ScreenshotIntent.swift     # App Intents：无感截图意图（含相册兜底）
│   ├── ImagePicker.swift          # 选图器（测试用）
│   └── ShareExtension/            # 分享扩展（手动导入兜底）
│       ├── ShareViewController.swift
│       ├── Info.plist
│       ├── RecognizeService.swift # 同主 App，复制进扩展 target 编译
│       ├── ScreenshotStore.swift
│       └── RecognitionTypes.swift
└── 云函数/
    └── aia-sync/                  # 云同步云函数：读写 aia_records 集合
        ├── index.js               # action=push(upsert) / action=pull(按 userId+since)；已支持 HTTP 触发 body 解析
        ├── package.json           # 依赖 wx-server-sdk
        └── deploy.sh              # CLI 一键部署脚本（./deploy.sh <环境ID>）
```
> 云端「识别」云函数（`recognize`，调 Qwen-VL）不在此仓库，需单独部署到你的 CloudBase 环境（详见「一」），与 `aia-sync` 共用同一环境。

## 一、先把云端「大脑」跑起来（约 10 分钟）

1. 注册并登录 [阿里云百炼（DashScope）](https://dashscope.console.aliyun.com/)，开通「通义千问视觉」模型，拿到 **API Key**。
2. 登录 [CloudBase 控制台](https://console.cloud.tencent.com/tcb)，新建环境。
3. 新建「云函数」：
   - 函数名：`recognize`
   - 运行环境：Node.js 16+（选最高版本）
   - 上传 `cloudfunctions/recognize/` 整个目录
4. 在云函数的「环境变量」里加：`DASHSCOPE_API_KEY = 你的key`
5. 开启「HTTP 触发」，拿到触发地址，形如 `https://xxx.apigw.tencentcs.com/release/recognize`
6. 把地址填进 `iOS/RecognizeService.swift` 的 `endpoint`。

> 想换模型/回落？云函数已预留 doubao / glm 配置，调用时传 `provider` 即可，App 不用改。

## 二、建 Xcode 工程并贴入代码（约 5 分钟）

1. 打开 Xcode → New Project → iOS → **App**
   - Product Name：`AI助理`
   - Interface：**SwiftUI**
   - Language：**Swift**
   - 取消勾选 Core Data（我们用 SwiftData）
2. 把 `iOS/` 里的 `.swift` 文件**全选拖进**项目导航栏（勾选「Copy if needed」、加进主 App target）。
   新增文件：`RecordsViews.swift`、`HealthManager.swift`、以及 `ShareExtension/` 整个文件夹。
3. 删掉 Xcode 自动生成的 `ContentView.swift` 和 `AI助理App.swift`（和我们的重名），用我们的版本。
4. 改 `iOS/ScreenshotStore.swift` 和 `iOS/ShareExtension/ScreenshotStore.swift` 里的 `AppGroup.id` 为你的真实 App Group（两处要一致）。

> 想省事：本仓库已带 `AIA.xcodeproj`（已含 Share Extension target 与所有文件），直接打开 `AIA/AIA.xcodeproj` 即可，跳过「新建工程 + 拖文件」，只做下面的能力配置。

## 三、配能力（关键，不然跑不通）

在 Xcode 选中**主 App target** → **Signing & Capabilities**：

- 加 **App Groups**，勾选/新建一个组（如 `group.com.yourapp.aia`），与 `ScreenshotStore.swift` 里的 `id` 一致。
- 加 **HealthKit**（健康管理模块用：读步数、写体重/摄入热量）。
- 加 **Background Modes** → 勾 **Remote notifications**（通知提醒用）。

再选中 **ShareExtension target** → **Signing & Capabilities**：

- 加 **App Groups**，勾选**同一个**组（必须与主 App 完全一致，否则 App Group 共享读不到）。

> 隐私文案已通过 `INFOPLIST_KEY_NS*` 写进主 App 的 Build Settings（HealthKit 读/写、相册），
> 无需手动改 Info.plist。Share Extension 不需要这些隐私文案（它从分享上下文拿图，不读相册）。

> 真机调试：用你的 Apple ID（免费账号即可）签名，插上 iPhone 运行。
> ⚠️ HealthKit、「快捷指令截屏自动化」、真实 PhotoKit 截图在**模拟器不可用**，必须真机。

## 四、先跑通「测试识别」（不用快捷指令）

1. 真机运行 App，点右上角「**测试识别**」→ 选一张账单/食物/待办截图。
2. 等「识别中…」→ 弹出「确认识别结果」页（字段已预填）。
3. 改改字段，点「**存入**」。
4. 回到首页，对应模块的数字应更新（如账单本月总额、待办待完成数）。

这就是 MVP 闭环：**截图 → 云端识别 → 确认 → 入库**。

## 五、再进阶：无感截图（App Intents + 快捷指令）+ 分享扩展兜底

1. 在 Xcode 选中主 App target → Signing & Capabilities → 加 **App Intents**（Xcode 16+ 默认支持）。
2. `ScreenshotIntent.swift` 的 `ProcessScreenshotIntent` 已写好，并支持两种触发：
   - 推荐：快捷指令里用「**获取最新截图**」动作把图片传给本意图（最稳）；
   - 兜底：直接运行本意图且不传图时，自动从相册读最近一张「截图」（需相册权限）。
3. 手机打开「快捷指令」App → 自动化 → 新建「**截屏**」个人自动化：
   - 动作：搜索你 App 的「**识别截图**」意图并添加
   - 关闭「运行前询问」→ 实现截图后后台自动识别
4. 截一张图，稍后点开 App，会自动弹出上次识别的确认页。

**分享扩展（手动导入兜底，M1 已完成）**：任何 App 里看到截图 → 点「分享」→ 选「AI 助理」
→ 后台识别 → 下次打开 App 弹出确认页。需在主 App 和 ShareExtension **两个 target** 都开同一个 App Group。

## 六、云同步（M5 · 多设备共享数据）

把本地 SwiftData 的四条记录（账单/待办/饮食/健康）同步到 CloudBase，换手机或多台设备填同一个「同步账号」即可共享同一份数据。

> ✅ **2026-07-17 真机验证通过**：免费 Apple ID + 真机，App「立即同步」显示「上传 6 条 / 更新 0 条」，curl 单测 push 返回 `upserted:1`、pull 能取回，本地↔云端双向链路已通。

### 1. 部署同步云函数

> 已打好包：仓库根 `aia-sync-deploy.zip`（含 `index.js` + `package.json` + `deploy.sh`），可直接上传控制台。完整步骤见仓库根 **`部署-aia-sync云函数.md`**。

**函数已加固**：App 经 HTTP 触发（`POST JSON`）调用，云函数自动解析 `event.body`，并直接返回 `{ ok, ... }` 对象（与 `recognize` 一致）。建 `/sync` 触发器时，**「集成响应」开关必须与你的 `/recognize` 触发器保持一致**，否则 App 解析失败。

- **控制台（推荐）**：新建云函数 `aia-sync`（Node.js 16+，上传 `aia-sync-deploy.zip`）；建集合 `aia_records`；建 HTTP 触发路径 `/sync`，无需登录。
- **CLI**：解压 zip 后 `./deploy.sh <环境ID>`（自动装 `@cloudbase/cli`、登录、部署）。

> 同步地址 = `识别地址` 把末尾 `/recognize` 改成 `/sync`，`CloudSyncManager.syncEndpoint` 已自动替换，**无需改代码**。

### 2. 验证（部署后必做）

```bash
curl -X POST https://你的环境.ap-shanghai.app.tcloudbase.com/sync \
  -H 'Content-Type: application/json' \
  -d '{"action":"pull","userId":"test","since":0}'
# 预期：{"ok":true,"records":[],"count":0}
```

### 2. App 端使用
- 首页左上角「⚙」→ 设置页：
  - **同步账号**：默认随机 UUID（仅本机）。多台设备填**同一个值**，即共享同一份数据。
  - **自动同步**：打开后，App 启动自动同步一次。
  - **立即同步**：手动触发（先推本地变更，再拉取远端变更并合并）。
- 冲突规则：以 `updatedAt` 后写胜出（最后修改的覆盖旧的）。
- 删除：本地删除是即时硬删；**删除目前不会传播到其它设备**（墓碑同步是后续迭代点），其余增改实时双向同步。

### 4. 部署踩坑（已修复，记录备查）
- **`doc().set()` 报 `-501007 不能更新_id的值`**：云函数早期版本在 `set({data:{_id:r.id,...}})` 里多写了 `_id`。CloudBase / 微信云开发的 `doc().set()` **不允许 data 内再写 `_id`**（与部分 MongoDB 驱动不同，`doc(r.id)` 已指定 id），多写即报错导致写入失败、`upserted` 恒为 0。**修复**：`set({data: base})`（base 不含 `_id`）。排查此类「函数返回 ok 但 upserted=0」必须展开 CloudBase 函数日志看单条 `console.error`，App 端返回看不出原因。
- **`/sync` 与 `/recognize` 须同环境 + 同触发设置**：`/sync` 的「集成响应」开关要和 `/recognize` 一致，否则 App 解析返回失败。

### 3. 安全说明（MVP 简化）
云函数 `/sync` 不鉴权，靠「同步账号」的不可猜性（UUID）隔离数据。他人若拿到你的同步账号字符串，可读写该账号数据。**请勿把同步账号泄露给他人**；如需更严格，可在云函数加一个共享 Token 校验（请求头带 `x-aia-token`，与云端常量比对），README 暂不展开。

## 七、已知简化（后续迭代点）

- 食物营养库 `NutritionLibrary` 为**内置静态表**（约 100 种常见食物，每 100g 热量/蛋白/碳水/脂肪），识别后自动按名称匹配校正；匹配不到时回退模型估算。后续可：① 接入云端营养库（薄荷健康/USDA）扩充覆盖；② 支持用户本地新增/修正食物。
- 待办时间默认值规则已修正：**图片有日期用日期、有显式时间用时间；图片没时间（模型常返回 00:00）一律默认 8:00**，避免列表显示 00:00。
- 首页为简化宫格，完整 UI 见 `UI完整页面流.html` 原型。
- HealthKit 已接「写」（体重/身高/心率/摄入热量）与「读步数·活动消耗」；**首页净热量联动卡片已完成**（摄入来自 SwiftData 食物 − 消耗来自 HealthKit 活动能量 = 净热量，含三大宏量营养素堆叠条）。
- **云同步（M5）已完成并真机验证通过（2026-07-17）**：`CloudSyncManager` 把四类型记录 push/pull 到 CloudBase 的 `aia_records` 集合，按 `syncId` upsert、按 `updatedAt` 后写胜出；设置页可改「同步账号」实现多设备共享。已知限制：本地删除暂不跨设备传播（墓碑同步待做）。

按 MVP 顺序推进：~~M1 分享扩展~~ ✓ → ~~M2 无感截图~~ ✓ → ~~M3 食物库校正~~ ✓ → ~~M4 HealthKit~~ ✓(写入) → **M5 净热量联动** ✓（首页卡片）＋ **云同步** ✓。
（记录列表页已随 M3 一并完成：首页四宫格可点进查看/删除明细。）

## 八、未来可切换 iCloud 同步（迁移方案）

**结论**：现在用 CloudBase 是当前（免费账号）唯一能验的云同步路径；等上架或主力在 Apple 生态时，可平滑切到 **CloudKit**，且当前架构已为此铺好路（见下方「为什么好切」）。

> iCloud / CloudKit 整库同步属 **Apple Developer Program（付费 $99/年）专属能力**，免费账号无法开启 iCloud 容器、部署 CloudKit schema。想绕开付费门槛做云同步，CloudBase 恰是正确选择 —— 不用切方案。

### 1. 三种未来姿态（改动量从小到大）

| 姿态 | 做法 | 适用 |
|---|---|---|
| **A. 继续用 CloudBase** | 不动 | 想保留服务端、跨平台（未来安卓/网页复用） |
| **B. 双方案并存** | 保留 CloudBase，另开 iCloud 通道给纯 Apple 用户零配置同步 | 多数用户在 iPhone/iPad/Mac，又想留服务端 |
| **C. 完全切 iCloud（CloudKit）** | 删手写同步代码，SwiftData+CloudKit 一行接管 | 上架 + 用户集中在 Apple 生态 |

### 2. 切到 iCloud（姿态 C）具体要改什么

| 环节 | 现状（CloudBase） | 切 iCloud 后 |
|---|---|---|
| **能力** | 无（普通网络） | 付费会员 → 主 App target 开 **iCloud + CloudKit**，建 CloudKit 容器 |
| **同步引擎** | `CloudSyncManager.swift`（手写 push/pull/冲突合并） | **整文件删除**，改 `AIAApp.swift` 容器配置： |
| **设置页** | `SettingsView` 手填同步账号 | **删除账号逻辑**，iCloud 自动用登录的 Apple ID |
| **云函数** | `云函数/aia-sync` | 不再需要（可留给非 Apple 端） |
| **数据模型** | 已有 `syncId / syncUpdatedAt / syncDeleted` | 微调：CloudKit 要求所有非可选属性有默认值（你现在基本满足） |

`AIAApp.swift` 容器配置改为（CloudKit 接管同步）：

```swift
let config = ModelConfiguration(
    schema: schema,
    cloudKitDatabase: .automatic   // 一行开启整库同步
)
container = try ModelContainer(for: schema, configurations: [config])
```

> 注意：当前 `AIAApp.swift` 用的是显式 `url: storeURL` 自愈重建逻辑。切 CloudKit 后把 `url` 去掉、改用 `.automatic` 即可；自愈删除重建逻辑可移除（CloudKit 不依赖本地固定 store 文件）。

### 3. 为什么现在就好切（关键设计铺垫）

当初给四个模型加 `syncId / syncUpdatedAt / syncDeleted` 不只是给 CloudBase 用，也是为 iCloud 迁移兜底：
- **迁移时不丢数据**：本地已有记录会被 CloudKit 首次上传到 iCloud，一般不会丢；
- **双源不自动合并**：CloudBase 里的历史记录**不会**自动跑进 iCloud，两套云端数据各自独立。

### 4. 唯一要注意的坑：老数据迁移时机

- **最佳切换时机**：产品早期用户少时直接切；或
- **一次性迁移**：写一个脚本把 CloudBase 历史 `pull` 一遍写回本地，再让 CloudKit 接管上传（避免两朵云各存一份历史）。

### 5. 建议

现在**别切**，先用 CloudBase 跑通验证（免费账号唯一可行路径）。等你：① 决定上架 App Store（本来就得付 $99）；② 用户主要在 Apple 生态 —— 那时切 iCloud 最划算（手写同步代码全删掉）。切换时我可帮你做「`CloudSyncManager` → CloudKit」改造 + 一次性迁移脚本。

