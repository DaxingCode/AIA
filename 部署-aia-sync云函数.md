# 部署 aia-sync 云函数到 CloudBase

> 配套文件：仓库根目录 `aia-sync-deploy.zip`（已打好包，可直接上传控制台；根目录含 `index.js + package.json`，无需再套文件夹）
> 源码：`云函数/aia-sync/`（index.js / package.json / deploy.sh）
>
> 如果你**之前已经上传过旧版本 zip**，请重新上传当前最新 `aia-sync-deploy.zip`（覆盖函数代码），否则 push 可能出现 `upserted: 0` 的问题。

`aia-sync` 是 App 的云同步后端：把本地 SwiftData 的四条记录（账单/待办/饮食/健康）push/pull 到 CloudBase 的 `aia_records` 集合，实现多设备共享。

⚠️ **本函数已被加固**：App 通过 **HTTP 触发**调用它（`POST JSON`），`event.body` 是 JSON 字符串。`index.js` 已自动解析 HTTP body，并**直接返回 `{ ok, ... }` 对象**（与你的 `recognize` 函数返回结构一致）。请勿把它改成返回 `{statusCode, headers, body}` 包裹体，否则 App 解析失败。

⚠️ **切换环境（重要）**：`recognize` 与 `aia-sync` **必须在同一个 CloudBase 环境**里。当前项目使用的环境是 **`cloud1-d1ga55pizf294dbe9-1445590522`**（上海 `ap-shanghai`）。
- App 端识别/同步地址是**写死在代码里**的：`AIA/AIA/RecognizeService.swift` 和 `AIA/ShareExtension/RecognizeService.swift` 的 `endpoint`。换环境必须改这两处并重新运行 App。
- 两个环境的资源不会自动迁移；如果曾经换过环境，需确保目标环境里存在：`recognize` 函数 + `aia-sync` 函数 + `aia_records` 集合 + `/sync` 触发。
- 当前环境的 `/sync` 地址：`https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/sync`

---

## 前置条件

1. 一个 CloudBase 环境（与已部署的 `recognize` 同环境最佳）。
2. 已部署 `recognize` 云函数且工作正常（说明 HTTP 触发 + 返回结构已验证可用）。
3. 本机装了 Node.js（仅方式二 CLI 需要）。

---

## 方式一：控制台上传 zip（最稳，推荐）

1. 下载仓库根的 **`aia-sync-deploy.zip`**（不要解压，直接上传 zip）。
2. 打开 [CloudBase 控制台](https://console.cloud.tencent.com/tcb) → 进入你的环境。
3. **云函数** → **新建**（或「函数」→「新建云函数」）：
   - 函数名称：**`aia-sync`**
   - 运行环境：**Node.js 16+**（选最高版本）
   - 创建方式：**上传 zip 包** → 直接选择仓库根的 **`aia-sync-deploy.zip`**（不需要提前解压，zip 根目录就是 `index.js` + `package.json`）
   - 点击「完成 / 创建」
4. 创建成功后，进入 `aia-sync` → **函数代码**：确认左侧文件树根目录直接看到 `index.js` 和 `package.json`，而不是嵌套在另一个文件夹里。若看到 `云函数/aia-sync/index.js` 这种路径，说明 zip 包格式错误，请重新用仓库根的新 zip 上传。
5. **依赖安装**：CloudBase 会自动 `npm install wx-server-sdk`（如未自动，点「在线安装依赖」或本地 `npm install` 后重传 zip）。
6. **必须做 A — 建集合**：左侧「云数据库」→「新建集合」→ 名称 **`aia_records`**。
   - 权限：开发期可选「所有用户可读写」；上线前建议改为「仅创建者可读写」并通过云端校验。
7. **必须做 B — 建 HTTP 触发**：`aia-sync` →「触发方式 / HTTP 触发」→ 新建：
   - 路径：**`/sync`**
   - **触发器设置与你的 `/recognize` 触发器保持一致**（尤其是「**集成响应**」开关要相同；recognize 能用，sync 用同款设置就一定能用）
   - 鉴权：无需登录（与 recognize 一致）
   - 保存后复制得到的 **HTTP 触发地址**。
8. 该地址 = `recognize` 地址把末尾 `/recognize` 换成 `/sync`。App 端 `CloudSyncManager.syncEndpoint` 已自动做此替换，**无需改代码**。

---

## 方式二：CLI 脚本（适合熟悉命令行的同学）

1. 进入源码目录 `云函数/aia-sync`（本地仓库已有，不需要解压 zip）。
2. 终端运行：

```bash
./deploy.sh <你的CloudBase环境ID>
```

- 环境 ID 在控制台「环境 / 总览」查看，形如 `cloud1-xxxxxxxx`。
- 脚本会安装 `@cloudbase/cli`、打开浏览器让你扫码登录、然后部署函数。
- 部署完成后，**集合 `aia_records` 与 HTTP 触发 `/sync` 仍需按方式一步骤 5、6 在控制台手动建**（CLI 不易一步到位，已在脚本末尾提示）。

---

## 验证（部署后必做）

拿到 `/sync` 的 HTTP 地址后，用 curl 测一下（把 URL 换成你的）：

```bash
curl -X POST https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/sync \
  -H 'Content-Type: application/json' \
  -d '{"action":"pull","userId":"test","since":0}'
```

预期返回（集合为空时）：

```json
{"ok":true,"records":[],"count":0}
```

再测一次 push：

```bash
curl -X POST https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/sync \
  -H 'Content-Type: application/json' \
  -d '{"action":"push","userId":"test","records":[{"id":"11111111-1111-1111-1111-111111111111","type":"bill","updatedAt":1750000000,"deleted":false,"payload":{"merchant":"测试店","amount":12.5,"currency":"CNY","category":"其他"}}]}'
```

预期：`{"ok":true,"upserted":1,"total":1}`

---

## App 端配置（免费账号即可验）

1. 真机运行 App，点首页左上角 **⚙ → 设置**。
2. **同步账号**：默认随机 UUID（仅本机）。多台设备填**同一个值**，即共享同一份数据。
3. **自动同步**：打开后 App 启动自动同步一次；或点 **立即同步**。
4. 状态栏会显示「已同步 · 上传 N 条 / 更新 M 条」。

---

## 排错

| 现象 | 原因 / 解决 |
|---|---|
| 创建函数报错 `zip code format error` / `filename not matched: index.js` / `mjs: command not found` | **zip 包里文件不在根目录**。CloudBase 要求 zip 根目录直接是 `index.js` + `package.json`，不能套一层 `aia-sync/` 文件夹。请使用仓库根重新打包的 `aia-sync-deploy.zip`，不要自己手动压缩整个文件夹。 |
| 同步失败：HTTP 4xx | `/sync` 地址填错，或函数未部署/未开 HTTP 触发。核对地址（把 recognize 末尾 `/recognize` 换成 `/sync`）。 |
| 返回 `{"ok":false,"error":"missing userId"}` | 函数收到了请求但 body 没解析到。确认 **`/sync` 触发器的「集成响应」开关与 `/recognize` 完全一致**（本项目已修好 body 解析，但仍需触发器设置匹配）。 |
| `pull failed: ...` 或 push 全失败 | 集合 `aia_records` 没建。去云数据库新建该集合。 |
| 同步后其它设备看不到 | 多设备「同步账号」没填成同一个值；或删除暂不跨设备传播（MVP 已知限制，墓碑同步待做）。 |
| `wx-server-sdk` 报错 require 失败 | 函数依赖没装。控制台「在线安装依赖」或本地 `npm install` 后重传 zip。 |

---

## 安全说明（MVP 简化）

`/sync` 不鉴权，靠「同步账号」字符串的不可猜性（UUID）隔离数据。他人若拿到你的同步账号可读写该账号数据，**请勿泄露**。要更严可在云函数加共享 Token 校验（请求头带 `x-aia-token` 与云端常量比对）。
