# CloudBase 部署检查清单

> 每次改完云函数代码，照这份清单从上到下勾一遍即可。**「上传」不等于「发布」**，最容易漏的就是发布和「集成响应」开关。

---

## 0. 环境信息（当前唯一有效环境）

| 项 | 值 |
|---|---|
| 环境 ID | `cloud1-d1ga55pizf294dbe9-1445590522` |
| 地域 | 上海 ap-shanghai |
| 识别函数 | `recognize` |
| 识别地址 | `https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/recognize` |
| 同步地址 | 同上，把 `/recognize` 换成 `/sync`（App 端自动派生） |
| 同步集合 | `aia_records` |
| 环境变量 | `DASHSCOPE_API_KEY`（通义千问视觉 Key） |

> ⚠️ 换环境 = 云端资源不自动迁移，必须在新环境重建「函数 + 集合 + 触发」，并同步改代码里两处 endpoint：
> - `AIA/AIA/RecognizeService.swift`
> - `AIA/ShareExtension/RecognizeService.swift`
> （`CloudSyncManager.syncEndpoint` 会从 `/recognize` 自动派生成 `/sync`，无需单独改。）

---

## 1. 打包（改完 index.js 后）

```
cd 原生代码脚手架/cloudfunctions/recognize
node --check index.js          # 先验证语法，报错就别打包
rm -f 归档.zip
zip -X 归档.zip index.js package.json
unzip -l 归档.zip               # 确认根目录扁平：只有 index.js + package.json
```

- [ ] `node --check` 通过（无输出即 OK）
- [ ] `unzip -l` 显示 **根目录**就是 `index.js` + `package.json`，**没有套一层文件夹**（套了 CloudBase 找不到入口会报错）

---

## 2. 上传 + 发布（recognize 函数）

在 CloudBase 控制台 → 云函数 → `recognize`：

- [ ] **上传** `归档.zip`
- [ ] 点 **「保存并安装依赖」/「发布」**（上传 ≠ 发布，不点新代码不生效）
- [ ] 等待部署完成状态变绿

---

## 3. HTTP 触发配置（最关键，配错直接 HTTP 400）

在 `recognize` 函数 → 触发管理 / HTTP 访问服务：

- [ ] HTTP 触发路径为 `/recognize`
- [ ] **「集成响应」必须关闭**（开着的话 App 调用会报 HTTP 400 / 返回体解析失败）
- [ ] `/sync` 的 HTTP 触发设置须与 `/recognize` **完全一致**（尤其集成响应也要关）

---

## 4. 环境变量

- [ ] `DASHSCOPE_API_KEY` 已配置且有效（通义千问视觉 Qwen-VL 的 Key）
- [ ] API Key **只在云端环境变量里**，绝不写进 App 前端

---

## 5. 数据库集合

- [ ] 存在集合 `aia_records`（同步用）
- [ ] 权限规则允许云函数读写

---

## 6. 发布后验证

### 6.1 curl 快速验证识别
```
curl -X POST "https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/recognize" \
  -H "Content-Type: application/json" \
  -d '{"text":"中午吃了两个包子"}'
```
- [ ] 返回结构化 JSON（含 `types`），非 400 / 非报错

### 6.2 App 内验证规则 10/11（本次重点）
真机发以下消息，验证**不再重复建待办**：
- [ ] 先建一条待办（如「提醒我明天写代码」）→ 正常建
- [ ] 再发「好的」→ 应只回聊天、**不再建第二条「写代码」**
- [ ] 发「你是谁」→ 应只走 AI 聊天、**不建任何记录**

### 6.3 排查「返回 ok 但 upserted=0」
- [ ] 展开 CloudBase 函数**日志**看单条 `console.error`（App 端返回看不出根因）
- [ ] 注意：`doc().set()` 不允许 data 里写 `_id`（会报 -501007），`set` 用 `{data: base}`

---

## 常见坑速查

| 现象 | 原因 | 处理 |
|---|---|---|
| App 调用报 HTTP 400 | 集成响应开着 | 关闭 `/recognize` 和 `/sync` 的集成响应 |
| 新代码不生效 | 只上传没发布 | 重新点发布 |
| 找不到函数入口 | zip 套了文件夹 | 用 `zip -X 归档.zip index.js package.json` 扁平打包 |
| 「好的/你是谁」还在重复建待办 | 规则 10/11 未部署 | 重新上传发布本次的 `归档.zip` |
| 同步 upserted=0 | 看不到根因 | 展开云函数日志看 console.error |
| set 报 -501007 | data 里带了 _id | 改成 `{data: base}` |
