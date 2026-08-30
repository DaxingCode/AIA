// 云函数 aia-sync（CloudBase / 微信云开发，Node.js）
// 数据集合：aia_records
//   _id:        记录唯一 id（客户端生成，UUID 字符串）
//   userId:     同步账号（客户端生成/可改）
//   type:       bill | reminder | food | health | profile(昵称)
//   updatedAt:  最后修改时间（秒，浮点），冲突按后写胜出
//   deleted:    软删除标记（墓碑）
//   payload:    记录字段对象
//
// 调用方式：HTTP 触发（App 用这种方式，POST JSON），返回结构与 recognize 一致
//          （直接返回 { ok, ... } 对象，不要包 { statusCode, headers, body }，
//           否则 App 解析失败。创建 /sync 触发器时请与 /recognize 触发器设置保持一致）。
// 入参（POST JSON）：
//   { action: "push", userId, records: [{id,type,updatedAt,deleted,payload}] }
//   { action: "pull", userId, since }   // since 为上次同步的 updatedAt（秒）
// 返回：
//   push -> { ok:true, upserted:N, total:M }
//   pull -> { ok:true, records:[...], count:N }

const cloud = require('wx-server-sdk')
cloud.init({ env: cloud.DYNAMIC_CURRENT_ENV })

const db = cloud.database()
const _ = db.command
const COLLECTION = 'aia_records'
const LINKS_COLLECTION = 'aia_user_links'  // Phase 2 账号关联：secondaryUserId -> primaryUserId 映射
const ADS_COLLECTION = 'aia_ads'   // 广告集合（与 aia-ads 云函数共用）
const CONFIG_COLLECTION = 'aia_config'   // 全局配置集合（智能问答开关 + AI 模型）
const CONFIG_DOC_ID = 'global'          // 全局配置固定文档 id
const EVENTS_COLLECTION = 'aia_events'   // 行为埋点集合（登录/启动/页面访问/识别发起等无数据落地的行为）
const DEVICES_COLLECTION = 'aia_devices' // 设备 token 表（APNs 远程推送用，按 userId+deviceId 去重）
const JOBS_COLLECTION = 'aia_broadcast_jobs' // 群发推送 job 表（接单即返回 + 后台分批自调）
const QUOTA_COLLECTION = 'aia_quota_usage' // 免费额度月度计数文档（按 userId:yyyyMM）
const DELETIONS_COLLECTION = 'aia_account_deletions' // 账户注销冷静期登记表（待真删队列）
const DEV_PASSCODE = process.env.DEV_PASSCODE || 'Daxing@0329'

// >>> CHANGE-[2026-08-19 15:32:37]-口令云端化 开始
// 原因: 方案甲——App 端不再存明文口令, 解锁走 devLogin 拿"当日 token", 后续请求带 devToken
// 设计: 无状态 token = 'aia' + DEV_PASSCODE + 东八区当天, 按天自然过期, 无需落库
//       (CloudBase 沙箱加载 require('crypto') 曾致 0 code exit, 故改纯字符串派生, 防明文扫描目的足够)
// 回退: 删除本段 + handle 内 devLogin 分支 + 各处 isDevAuthorized 替换回 !isDevAuthorized(req)
function todayDevToken() {
  // 东八区当天基准（与 entitlement.js 一致；避免 UTC 跨日导致验签基准漂移）
  const day = new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10)
  return 'aia' + DEV_PASSCODE + '|' + day
}
// 双兼容校验：旧客户端带 passcode 仍可用；新客户端带 devToken（当日有效）
function isDevAuthorized(req) {
  if (req.passcode && req.passcode === DEV_PASSCODE) return true
  if (req.devToken && req.devToken === todayDevToken()) return true
  return false
}
// <<< CHANGE-[2026-08-19 15:32:37]-口令云端化 结束

// 读取账户注销冷静期天数（默认 7 天）。优先读 aia_config.global.deleteGraceDays，缺字段/读失败回落 7。
async function getDeleteGraceDays() {
  try {
    const res = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).get()
    const cfg = (res && res.data) ? res.data : {}
    const d = Number(cfg.deleteGraceDays)
    return (d && d > 0) ? d : 7
  } catch (e) {
    return 7
  }
}

// 付费墙服务端判定（白名单 / 免费额度权重计费 / 全局月度熔断）。放在 userId 守卫之前的路由在 ent 内自行鉴权。
const ent = require('./entitlement')(db, _, DEV_PASSCODE)

// 把 CloudBase 两种事件形态归一化成本地 req 对象
// - HTTP 触发：event.body 是 JSON 字符串（或已被解析的对象）
// - 云函数直接调用（SDK）：event 即 { action, userId, records/since }
function parseEvent(event) {
  if (event && (event.httpMethod || event.body !== undefined)) {
    let body = event.body
    if (typeof body === 'string') {
      try { body = JSON.parse(body) } catch (e) { body = {} }
    }
    return body || {}
  }
  return event || {}
}

function makeError(msg) {
  return { ok: false, error: msg }
}

// 广告逻辑（原 aia-ads 云函数，迁入此处以免在 HTTP 网关手动加 /ads 路由被平台拒绝）
// 入参（POST JSON，与 App 端 AdBanner/DeveloperTools 完全对应）：
//   { action: "list" }                                   -> 公开，返回启用且未过期(end>=now)的广告（含待启用/进行中）
//   { action: "listAll", passcode }                       -> 全部（含停用）
//   { action: "upsert", passcode, item }                 -> 新建/更新
//   { action: "delete", passcode, id }                   -> 删除
//   { action: "reorder", passcode, orders: [{id,order}] } -> 只改排序字段
async function handleAds(req) {
  const { action } = req

  if (action === 'list') {
    try {
      const now = Date.now()
      const res = await db.collection(ADS_COLLECTION).where({ enabled: true }).get()
      // 方案 D（本地边界调度）：返回「启用且未过期(end>=now)」的广告，含待启用(pending)与进行中(active)。
      // App 端据此在本地算出下一条边界（到点出现/消失），平时不轮询云端，只有跨边界才拉取一次。
      // 已过期(end<now)的广告不返回，减少 payload。CloudBase 主键 _id -> id 映射避免解码失败。
      const items = (res.data || [])
        .filter(it => {
          const end = it.end ? new Date(it.end).getTime() : Infinity
          return end >= now
        })
        .map(it => ({ ...it, id: it.id || it._id }))
      return { ok: true, items }
    } catch (e) {
      return makeError('list failed: ' + (e && e.message ? e.message : e))
    }
  }

  // 以下操作需口令
  if (!isDevAuthorized(req)) return makeError('unauthorized')

  if (action === 'listAll') {
    try {
      const res = await db.collection(ADS_COLLECTION).orderBy('order', 'asc').get()
      const items = (res.data || []).map(it => ({ ...it, id: it.id || it._id }))
      return { ok: true, items }
    } catch (e) {
      return makeError('listAll failed: ' + (e && e.message ? e.message : e))
    }
  }

  if (action === 'upsert') {
    const item = req.item
    if (!item || !item.id) return makeError('missing item.id')
    const doc = {
      name: item.name || '',
      title: item.title || '',
      subtitle: item.subtitle || '',
      link: item.link || '',
      imageURL: item.imageURL || '',
      imageBase64: item.imageBase64 || '',
      start: item.start || new Date().toISOString(),
      end: item.end || new Date(Date.now() + 7 * 86400000).toISOString(),
      enabled: item.enabled !== false,
      order: Number(item.order) || 0
    }
    try {
      const exist = await db.collection(ADS_COLLECTION).doc(item.id).get().catch(() => null)
      if (exist && exist.data) {
        await db.collection(ADS_COLLECTION).doc(item.id).update({ data: doc })
      } else {
        await db.collection(ADS_COLLECTION).doc(item.id).set({ data: doc })
      }
      return { ok: true, id: item.id }
    } catch (e) {
      return makeError('upsert failed: ' + (e && e.message ? e.message : e))
    }
  }

  if (action === 'delete') {
    const id = req.id
    if (!id) return makeError('missing id')
    try {
      await db.collection(ADS_COLLECTION).doc(id).remove()
      return { ok: true, id }
    } catch (e) {
      return makeError('delete failed: ' + (e && e.message ? e.message : e))
    }
  }

  if (action === 'reorder') {
    const orders = Array.isArray(req.orders) ? req.orders : []
    if (orders.length === 0) return { ok: true }
    try {
      for (const o of orders) {
        if (!o || !o.id) continue
        await db.collection(ADS_COLLECTION).doc(o.id).update({ data: { order: Number(o.order) || 0 } })
      }
      return { ok: true }
    } catch (e) {
      return makeError('reorder failed: ' + (e && e.message ? e.message : e))
    }
  }

  return makeError('unknown action: ' + action)
}

// 群发通知（方案 A：APNs 远程推送）===============================================
// 依赖 node 内置模块 http2 + crypto，无需引入第三方库。
// 环境变量：APNS_KEY_ID / APNS_TEAM_ID / APNS_P8（私钥 PEM 文本）
const crypto = require('crypto')
const http2 = require('http2')

// 生成 APNs JWT（每 50 分钟需刷新一次；此处每次广播重新生成，足够小频度）。
function makeAPNsJWT() {
  const keyId = process.env.APNS_KEY_ID
  const teamId = process.env.APNS_TEAM_ID
  let p8 = process.env.APNS_P8 || ''
  if (!keyId || !teamId || !p8) {
    throw new Error('APNs 环境变量缺失（APNS_KEY_ID/APNS_TEAM_ID/APNS_P8）')
  }
  // 归一化：兜住控制台粘贴 p8 时常见的 JSON 转义串("...") 或字面量 \n 导致的解码失败。
  if (p8.startsWith('"') && p8.endsWith('"')) {
    try { p8 = JSON.parse(p8) } catch (e) { /* 非 JSON 字符串，保留原样 */ }
  }
  p8 = p8.replace(/\\n/g, '\n').replace(/\r/g, '').trim()
  // 兜底：控制台输入框不支持换行时，PEM 会被压成单行（换行符彻底消失）。
  // 此时 base64 主体里没有任何 \n，OpenSSL 无法解析 → 按 RFC7468 重新拆行。
  if (!p8.includes('\n') && p8.startsWith('-----BEGIN') && p8.endsWith('-----END PRIVATE KEY-----')) {
    const body = p8
      .replace(/^-----BEGIN PRIVATE KEY-----/, '')
      .replace(/-----END PRIVATE KEY-----$/, '')
      .replace(/\s+/g, '') // 去掉可能混入的空格
    const lines = body.match(/.{1,64}/g) || [body]
    p8 = '-----BEGIN PRIVATE KEY-----\n' + lines.join('\n') + '\n-----END PRIVATE KEY-----'
  }
  console.log('[APNs] keyId=', keyId, 'teamId=', teamId,
    'p8.startsWith(BEGIN)=', p8.startsWith('-----BEGIN PRIVATE KEY-----'),
    'p8.endsWith(END)=', p8.endsWith('-----END PRIVATE KEY-----'),
    'p8.firstLine=', p8.split('\n')[0],
    'p8.lastLine=', p8.split('\n').slice(-1)[0],
    'p8.lines=', p8.split('\n').length)
  const header = { alg: 'ES256', kid: keyId }
  const now = Math.floor(Date.now() / 1000)
  const payload = { iss: teamId, iat: now, exp: now + 3600 }
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')
  const signingInput = `${b64(header)}.${b64(payload)}`
  const sign = crypto.createSign('SHA256')
  sign.update(signingInput)
  const signature = sign.sign(p8, 'base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')
  return `${signingInput}.${signature}`
}

// 向单台设备发 APNs（基于 http2 长连接复用）。返回 Promise<ok>
function sendAPNs(client, jwt, deviceToken, notification) {
  return new Promise((resolve) => {
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      'authorization': `bearer ${jwt}`,
      'apns-topic': 'com.daxing.aia.AIA',     // 主 App Bundle ID
      'apns-push-type': 'alert',
      'content-type': 'application/json'
    })
    let respBody = ''
    req.on('response', (headers) => {
      const status = headers[':status']
      req.on('data', (c) => { respBody += c })
      req.on('end', () => resolve({ status, ok: status === 200, body: respBody }))
    })
    req.on('error', (e) => resolve({ status: 0, ok: false, body: String(e) }))
    req.write(JSON.stringify(notification))
    req.end()
  })
}

// 设备上报：已登录用户上传 deviceToken + 环境（sandbox/production）。按 userId+deviceId 去重。
async function handleRegisterDevice(req) {
  const { userId, deviceId, token, apnsEnv } = req
  if (!userId) return makeError('missing userId')
  if (!token || !deviceId) return makeError('missing token/deviceId')
  const doc = {
    userId,
    deviceId,
    token: String(token),
    apnsEnv: apnsEnv === 'production' ? 'production' : 'sandbox',
    updatedAt: Date.now()
  }
  try {
    // aia_devices 以 userId_deviceId 为 _id，upsert
    const id = `${userId}_${deviceId}`
    await db.collection(DEVICES_COLLECTION).doc(id).set({ data: doc })
    return { ok: true }
  } catch (e) {
    return makeError('registerDevice failed: ' + (e && e.message ? e.message : e))
  }
}

// 群发（方案 B：接单即返回 + 后台 job）：
// 校验口令 → 写一条 aia_broadcast_jobs（status=pending, cursor=0）→ 立即 ack 返回 { ok, accepted }。
// 真正的发送在 handleBroadcastTick 里按游标分页 + 并发分批，发完一批用 cloud.callFunction 自调继续，
// 直到 cursor>=total 置 status=done，并给提交者本人（submitterDeviceId）发完成回执。
// 支持筛选：userIds（只发给指定 userId 集合）、envs（只发 production/sandbox 子集）。
async function handleBroadcast(req) {
  if (!isDevAuthorized(req)) return makeError('unauthorized')
  const { title, body, route, userIds, envs } = req
  if (!title || !body) return makeError('missing title/body')

  try {
    // aia_broadcast_jobs 可能尚未建表：wx-server-sdk 对不存在的集合 .add() 会直接 -502005 报错。
    // 自动建表（幂等：已存在则 createCollection 抛错，忽略即可）。
    try {
      await db.createCollection(JOBS_COLLECTION)
      console.log('[broadcast] 自动创建集合', JOBS_COLLECTION)
    } catch (e) {
      // 已存在或并发建表冲突均忽略
    }

    // 先统计目标设备数（用 .count() 避免拉全量），用于 total 与历史展示。
    let targetEnvs = (Array.isArray(envs) && envs.length)
      ? envs.filter(e => e === 'production' || e === 'sandbox')
      : ['production', 'sandbox']
    let query = db.collection(DEVICES_COLLECTION)
    // 按 userId 筛选
    if (Array.isArray(userIds) && userIds.length) {
      query = db.collection(DEVICES_COLLECTION).where({ userId: _.in(Array.from(new Set(userIds.map(String)))) })
    }
    // 按环境筛选
    if (targetEnvs.length < 2) {
      query = query.where({ apnsEnv: _.in(targetEnvs) })
    }
    const countRes = await query.count()
    const total = (countRes && countRes.total) || 0

    const job = {
      title: String(title),
      body: String(body),
      route: route ? String(route) : '',
      userIds: Array.isArray(userIds) ? userIds.map(String) : [],
      envs: targetEnvs,
      status: 'pending',
      sent: 0,
      failed: 0,
      total,
      cursor: 0,
      submitterDeviceId: req.submitterDeviceId ? String(req.submitterDeviceId) : '',
      submitterEnv: req.submitterEnv === 'production' ? 'production' : 'sandbox',
      createdAt: Date.now(),
      finishedAt: 0
    }
    const addRes = await db.collection(JOBS_COLLECTION).add({ data: job })
    const jobId = addRes && addRes._id ? addRes._id : ''
    console.log('[broadcast] 接单 jobId=', jobId, 'total=', total, 'envs=', targetEnvs)

    // 首轮直接在当前调用内同步执行 tick（小批量一轮即发完，避免依赖 cloud.callFunction 自调被环境拦截）。
    // 大批量时 handleBroadcastTick 内部会自行 callFunction 续批。
    const firstTick = await handleBroadcastTick({ jobId })
    console.log('[broadcast] 首轮 tick 结果', JSON.stringify(firstTick))
    if (!firstTick || !firstTick.ok) {
      // tick 执行失败（如 APNs JWT 生成失败、设备查询异常）：透传错误，便于 App 端看到真实原因。
      return makeError('broadcast tick failed: ' + ((firstTick && firstTick.error) || 'unknown'))
    }

    return { ok: true, accepted: total, jobId }
  } catch (e) {
    return makeError('broadcast failed: ' + (e && e.message ? e.message : e))
  }
}

// 异步触发 handleBroadcastTick（fire-and-forget）。
async function triggerBroadcastTick(jobId) {
  try {
    // cloud.callFunction 自调自身；函数名取当前环境上下文。
    const ctx = cloud.getWXContext()
    const fnName = ctx && ctx.FunctionName ? ctx.FunctionName : ''
    await cloud.callFunction({
      name: fnName,
      data: { action: 'broadcastTick', jobId }
    })
  } catch (e) {
    console.error('[broadcast] triggerBroadcastTick 失败 jobId=', jobId, e)
  }
}

// 后台分批发送：按 job.cursor 游标分页取设备批 → 并发发一批 → 更新 job → 未发完则自调继续。
async function handleBroadcastTick(req) {
  const { jobId } = req
  if (!jobId) return makeError('missing jobId')
  let job
  try {
    const jobDoc = await db.collection(JOBS_COLLECTION).doc(jobId).get()
    job = jobDoc && jobDoc.data ? jobDoc.data : null
    if (!job) return makeError('job not found: ' + jobId)
    if (job.status === 'done') return { ok: true, done: true }

    // 标记为 sending（首轮）
    if (job.status === 'pending') {
      await db.collection(JOBS_COLLECTION).doc(jobId).update({ data: { status: 'sending' } })
    }

    // 取本批设备：游标分页，按 userId/envs 过滤。
    const BATCH = 1500
    let query
    if (Array.isArray(job.userIds) && job.userIds.length) {
      query = db.collection(DEVICES_COLLECTION).where({ userId: _.in(job.userIds) })
    } else {
      query = db.collection(DEVICES_COLLECTION)
    }
    if (Array.isArray(job.envs) && job.envs.length && job.envs.length < 2) {
      query = query.where({ apnsEnv: _.in(job.envs) })
    }
    const batch = await query.skip(job.cursor).limit(BATCH).get()
    const devices = (batch && batch.data) || []

    let jwt
    try { jwt = makeAPNsJWT() } catch (e) {
      return makeError('APNs JWT 生成失败：' + e.message)
    }

    const aps = {
      alert: { title: job.title, body: job.body },
      sound: 'default',
      badge: 1
    }
    const payload = { aps }
    if (job.route) payload.route = String(job.route)

    let sentThisBatch = 0, failedThisBatch = 0
    // 按环境分组，每组一条 http2 长连接并发发。
    const envGroups = {}
    for (const d of devices) {
      if (!d.token || !d.apnsEnv) continue
      const env = d.apnsEnv === 'production' ? 'production' : 'sandbox'
      ;(envGroups[env] = envGroups[env] || []).push(d)
    }

    const sendOneEnv = async (env, devs) => {
      const host = env === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'
      const client = http2.connect(`https://${host}`)
      try {
        await Promise.all(devs.map(async (d) => {
          const r = await sendAPNs(client, jwt, d.token, payload)
          if (r.ok) { sentThisBatch++ } else {
            failedThisBatch++
            if (r.status === 410) {
              // token 失效（卸载 App）：清理该设备
              await db.collection(DEVICES_COLLECTION).doc(`${d.userId}_${d.deviceId}`).remove().catch(() => {})
            }
          }
        }))
      } finally {
        client.close()
      }
    }

    await Promise.all(Object.entries(envGroups).map(([env, devs]) => sendOneEnv(env, devs)))

    const newCursor = job.cursor + devices.length
    const newSent = (job.sent || 0) + sentThisBatch
    const newFailed = (job.failed || 0) + failedThisBatch
    const done = newCursor >= (job.total || 0) || devices.length === 0

    await db.collection(JOBS_COLLECTION).doc(jobId).update({
      data: {
        cursor: newCursor,
        sent: newSent,
        failed: newFailed,
        status: done ? 'done' : 'sending',
        finishedAt: done ? Date.now() : 0
      }
    })
    console.log('[broadcast] tick jobId=', jobId, 'cursor=', newCursor, '/', job.total, 'sent=', newSent, 'failed=', newFailed, 'done=', done)

    if (done) {
      // 给提交者本人发完成回执（仅当记录了 submitterDeviceId）。
      if (job.submitterDeviceId) {
        try {
          const ctx = cloud.getWXContext()
          const submitterRes = await db.collection(DEVICES_COLLECTION)
            .where({ token: job.submitterDeviceId }).limit(1).get()
          const subDoc = (submitterRes && submitterRes.data && submitterRes.data[0]) || null
          if (subDoc && subDoc.token) {
            const recJwt = makeAPNsJWT()
            const recAps = {
              alert: { title: '✅ 推送完成', body: `成功 ${newSent} 台，失败 ${newFailed} 台` },
              sound: 'default'
            }
            await sendAPNs(http2.connect(subDoc.apnsEnv === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com'), recJwt, subDoc.token, { aps: recAps })
          }
        } catch (e) {
          console.error('[broadcast] 完成回执发送失败', e)
        }
      }
      return { ok: true, done: true, sent: newSent, failed: newFailed }
    }

    // 未发完：fire-and-forget 自调下一批（授权数约 1000ms 窗口足够，外层不 await）。
    triggerBroadcastTick(jobId).catch(e => console.error('[broadcast] 续批触发失败', e))
    return { ok: true, done: false, cursor: newCursor }
  } catch (e) {
    return makeError('broadcastTick failed: ' + (e && e.message ? e.message : e))
  }
}

// 列出历史 job（开发者口令，按 createdAt 倒序，最多 50 条）。供 App 端「推送记录」页展示。
async function handleListBroadcastJobs(req) {
  if (!isDevAuthorized(req)) return makeError('unauthorized')
  try {
    const res = await db.collection(JOBS_COLLECTION)
      .orderBy('createdAt', 'desc')
      .limit(50)
      .get()
    const jobs = (res && res.data) || []
    return { ok: true, jobs }
  } catch (e) {
    return makeError('listBroadcastJobs failed: ' + (e && e.message ? e.message : e))
  }
}

// 列出已上报 token 的设备（去重 userId + 设备数）。开发者口令，供 App 端「按账号筛选推送」展示可选项。
async function handleListDevices(req) {
  if (!isDevAuthorized(req)) return makeError('unauthorized')
  try {
    const res = await db.collection(DEVICES_COLLECTION).limit(1000).get()
    const devices = (res && res.data) || []
    // 按 userId 去重，统计每台设备的环境。
    const byUser = {}
    for (const d of devices) {
      const u = String(d.userId || '')
      if (!u) continue
      if (!byUser[u]) byUser[u] = { userId: u, count: 0, envs: new Set() }
      byUser[u].count++
      if (d.apnsEnv) byUser[u].envs.add(d.apnsEnv)
    }
    const users = Object.values(byUser)
      .map(u => ({ userId: u.userId, count: u.count, envs: Array.from(u.envs) }))
      .sort((a, b) => a.userId.localeCompare(b.userId))
    return { ok: true, total: devices.length, users }
  } catch (e) {
    return makeError('listDevices failed: ' + (e && e.message ? e.message : e))
  }
}

// 全局配置（智能问答开关 + AI 模型）。权威来源在云端，开发者可写、所有用户只读跟随。
// 入参（POST JSON）：
//   { action: "getConfig" }              -> 公开，返回全局配置 { agentEnabled, modelProvider, visionModelProvider, privacyPolicyUrl, userAgreementUrl, featureIntroUrl, appStoreUrl, latestVersion }
//   { action: "setConfig", passcode, agentEnabled, modelProvider, visionModelProvider, privacyPolicyUrl, userAgreementUrl, featureIntroUrl, appStoreUrl, latestVersion } -> 开发者写入
async function handleConfig(req) {
  const { action } = req

  if (action === 'getConfig') {
    try {
      const res = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).get()
      const cfg = (res && res.data) ? res.data : {}
      return {
        ok: true,
        agentEnabled: cfg.agentEnabled === true,
        modelProvider: typeof cfg.modelProvider === 'string' && cfg.modelProvider ? cfg.modelProvider : 'glm',
        visionModelProvider: typeof cfg.visionModelProvider === 'string' && cfg.visionModelProvider ? cfg.visionModelProvider : 'glm',
        // —— 免费额度（付费墙）——
        freeQuotaEnabled: cfg.freeQuotaEnabled === true,
        freeQuotaPerMonth: Number(cfg.freeQuotaPerMonth) || 0,
        freeQuotaWeights: (cfg.freeQuotaWeights && typeof cfg.freeQuotaWeights === 'object') ? cfg.freeQuotaWeights : {},
        freeQuotaDailyCap: Number(cfg.freeQuotaDailyCap) || 0,
        freeQuotaGlobalMonthly: Number(cfg.freeQuotaGlobalMonthly) || 0,
        // —— 免费试用天数（全局下发，所有用户跟随；缺省默认 7）——
        trialDays: Number(cfg.trialDays) > 0 ? Number(cfg.trialDays) : 7,
        // 公告：缺字段时返回 null（无公告）
        announcement: (cfg.announcement && typeof cfg.announcement === 'object') ? cfg.announcement : null,
        // —— 协议链接（云端下发，App 端带本地兜底，缺字段时返回空串）——
        privacyPolicyUrl: typeof cfg.privacyPolicyUrl === 'string' ? cfg.privacyPolicyUrl : '',
        userAgreementUrl: typeof cfg.userAgreementUrl === 'string' ? cfg.userAgreementUrl : '',
        // 首页灯泡按钮「App 功能介绍」链接（缺字段时返回空串，App 端回退默认微信文章）
        featureIntroUrl: typeof cfg.featureIntroUrl === 'string' ? cfg.featureIntroUrl : '',
        // —— App Store 下载页链接（云端下发，App 端带本地兜底；缺字段返回空串）——
        appStoreUrl: typeof cfg.appStoreUrl === 'string' ? cfg.appStoreUrl : '',
        // —— 建议更新版本号（云端下发；低于此版本且未被用户忽略时 App 弹更新提示；缺字段返回空串）——
        latestVersion: typeof cfg.latestVersion === 'string' ? cfg.latestVersion : ''
      }
    } catch (e) {
      // 文档不存在时返回默认配置（不视为错误，保证首次启动 App 不崩）
      return { ok: true, agentEnabled: false, modelProvider: 'glm', visionModelProvider: 'glm', freeQuotaEnabled: false, freeQuotaPerMonth: 0, freeQuotaWeights: {}, freeQuotaDailyCap: 0, freeQuotaGlobalMonthly: 0, trialDays: 7, announcement: null, privacyPolicyUrl: '', userAgreementUrl: '', featureIntroUrl: '', appStoreUrl: '', latestVersion: '' }
    }
  }

  if (action === 'setConfig') {
    if (!isDevAuthorized(req)) return makeError('unauthorized')
    const cfg = {
      agentEnabled: req.agentEnabled === true,
      modelProvider: typeof req.modelProvider === 'string' && req.modelProvider ? req.modelProvider : 'glm',
      visionModelProvider: typeof req.visionModelProvider === 'string' && req.visionModelProvider ? req.visionModelProvider : 'glm',
      // —— 免费额度（付费墙）——
      freeQuotaEnabled: req.freeQuotaEnabled === true,
      freeQuotaPerMonth: Number(req.freeQuotaPerMonth) || 0,
      freeQuotaWeights: (req.freeQuotaWeights && typeof req.freeQuotaWeights === 'object') ? req.freeQuotaWeights : {},
      freeQuotaDailyCap: Number(req.freeQuotaDailyCap) || 0,
      freeQuotaGlobalMonthly: Number(req.freeQuotaGlobalMonthly) || 0,
      // —— 免费试用天数（全局下发；>0 才写入，否则默认 7）——
      trialDays: Number(req.trialDays) > 0 ? Number(req.trialDays) : 7,
      // 公告：null 表示撤销（删除字段），Object 表示写入
      announcement: (req.announcement === null || req.announcement === undefined)
        ? null
        : (req.announcement && typeof req.announcement === 'object' ? req.announcement : null),
      // —— 协议链接（空串表示沿用 App 端兜底默认值）——
      privacyPolicyUrl: typeof req.privacyPolicyUrl === 'string' ? req.privacyPolicyUrl : '',
      userAgreementUrl: typeof req.userAgreementUrl === 'string' ? req.userAgreementUrl : '',
      // 首页灯泡「App 功能介绍」链接（空串表示沿用 App 端兜底默认值）
      featureIntroUrl: typeof req.featureIntroUrl === 'string' ? req.featureIntroUrl : '',
      // —— App Store 下载页链接（空串表示沿用 App 端兜底默认值）——
      appStoreUrl: typeof req.appStoreUrl === 'string' ? req.appStoreUrl : '',
      // —— 建议更新版本号（空串表示不提示更新）——
      latestVersion: typeof req.latestVersion === 'string' ? req.latestVersion : ''
    }
    try {
      const exist = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).get().catch(() => null)
      if (exist && exist.data) {
        // 撤销公告：剔除 announcement 字段再更新（CloudBase update 不会自动删字段）
        if (cfg.announcement === null) {
          const { announcement, ...rest } = cfg
          await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).update({ data: rest })
        } else {
          await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).update({ data: cfg })
        }
      } else {
        if (cfg.announcement === null) {
          const { announcement, ...rest } = cfg
          await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).set({ data: rest })
        } else {
          await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).set({ data: cfg })
        }
      }
      return { ok: true }
    } catch (e) {
      return makeError('setConfig failed: ' + (e && e.message ? e.message : e))
    }
  }

  return makeError('unknown action: ' + action)
}

// 使用统计 -------------------------------------------------------------------------
// 数据来源两条腿：
//   ① aia_records：已同步的业务数据（bill/reminder/food/health/recognition/chat/water/...），
//      能直接算出「谁在用哪个功能、用了多少」。
//   ② aia_events：行为埋点（登录/启动/页面访问/识别发起/导出等本身不落数据的行为），
//      由 App 的 UsageAnalytics fire-and-forget 上报，补齐纯行为类活跃度。

const CN_OFFSET_MS = 8 * 3600 * 1000   // 统计统一按北京时间分日

// 把 updatedAt（秒或毫秒都可能）归一化成毫秒时间戳
function toMillis(v) {
  const n = Number(v)
  if (!isFinite(n) || n <= 0) return 0
  return n > 1e11 ? n : n * 1000   // > 1e11 视为毫秒
}

function dayKey(ms) {
  if (!ms) return ''
  return new Date(ms + CN_OFFSET_MS).toISOString().slice(0, 10)
}

function csvEscape(v) {
  const s = (v === null || v === undefined) ? '' : String(v)
  if (s.indexOf(',') >= 0 || s.indexOf('"') >= 0 || s.indexOf('\n') >= 0) {
    return '"' + s.replace(/"/g, '""') + '"'
  }
  return s
}

// rows: 二维数组，第一行为表头。首格加 BOM 让 Excel 正确识别 UTF-8 中文。
function toCSV(rows) {
  return '\uFEFF' + rows.map(r => r.map(csvEscape).join(',')).join('\n')
}

function round(n, d) {
  const p = Math.pow(10, d === undefined ? 2 : d)
  return Math.round((Number(n) || 0) * p) / p
}

// 分页全量扫描一个集合（CloudBase 单次 limit 上限 1000）
async function scanAll(collection, where, maxDocs) {
  const LIMIT = 1000
  const cap = maxDocs || 50000
  let out = []
  let skip = 0
  while (out.length < cap) {
    let q = db.collection(collection)
    if (where) q = q.where(where)
    const res = await q.skip(skip).limit(LIMIT).get()
    const data = (res && res.data) || []
    out = out.concat(data)
    if (data.length < LIMIT) break
    skip += LIMIT
  }
  return out
}

// 幂等确保集合存在（首次埋点/统计前自动建，避免「集合未创建导致静默丢数据」）。
// 已存在或并发创建竞态都会抛错，忽略即可。
async function ensureCollection(name) {
  try {
    await db.createCollection(name)
  } catch (e) { /* 已存在/并发创建，忽略 */ }
}

// 记录 type -> 中文功能名（只统计"用户主动产生"的业务数据；profile/setting 等派生记录不计）
const FEATURE_NAMES = {
  bill: '账单',
  reminder: '待办',
  food: '饮食',
  health: '健康',
  manualHealth: '健康(手动录入)',
  recognition: '截图识别',
  chat: 'AI 对话',
  water: '饮水',
  merchant_meta: '商户规则',
  recurring_rule: '周期账单',
  sleep: '睡眠'
}
const IGNORE_TYPES = ['profile', 'setting', 'profileHealth']

// 埋点上报：不鉴权（与 /sync 现有信任模型一致），失败不影响客户端主流程。
// 入参：{ action:'logEvent', userId, event, ts, meta }
//   或 { action:'logEvent', userId, events:[{event, ts, meta}] }（批量）
async function handleLogEvent(req) {
  const userId = req.userId
  if (!userId) return makeError('logEvent 缺少 userId')
  let list = Array.isArray(req.events) ? req.events : (req.event ? [{ event: req.event, ts: req.ts, meta: req.meta }] : [])
  list = list.filter(e => e && e.event).slice(0, 100)   // 单次最多 100 条，防滥用
  if (list.length === 0) return { ok: true, inserted: 0 }
  await ensureCollection(EVENTS_COLLECTION)   // 自动建集合，避免首次上报静默丢数据
  let inserted = 0, failed = 0
  const appVersion = req.appVersion || ''
  const platform = req.platform || 'ios'
  for (const e of list) {
    const ts = toMillis(e.ts) || Date.now()
    try {
      await db.collection(EVENTS_COLLECTION).add({
        data: {
          userId,
          event: String(e.event).slice(0, 64),
          ts,
          day: dayKey(ts),
          platform,
          appVersion,
          meta: (e.meta && typeof e.meta === 'object') ? e.meta : {}
        }
      })
      inserted++
    } catch (err) {
      failed++
      console.error('logEvent 单条失败', e.event, err)
    }
  }
  return { ok: true, inserted, failed }
}

// 跨用户使用统计（开发者专用，需口令）。返回 summary + 多张 CSV 文本。
// 入参：{ action:'stats', passcode, days }   days 可选，默认 90（限制日活趋势表长度）
async function handleStats(req) {
  if (!isDevAuthorized(req)) return makeError('unauthorized')
  const trendDays = Math.min(Math.max(Number(req.days) || 90, 7), 365)
  const now = Date.now()

  let records = []
  let events = []
  try {
    records = await scanAll(COLLECTION, null, 50000)
  } catch (e) {
    return makeError('stats 读取 aia_records 失败: ' + (e && e.message ? e.message : e))
  }
  try {
    events = await scanAll(EVENTS_COLLECTION, null, 50000)
  } catch (e) {
    events = []   // 集合尚未创建（还没有任何埋点）时视为空，不算错误
  }

  // ---- 预处理：过滤软删与派生记录 ----
  const live = records.filter(r => r && r.deleted !== true && IGNORE_TYPES.indexOf(r.type) < 0)

  const users = new Set()
  const userStat = new Map()   // userId -> { first, last, total, byType:{} }
  const typeCount = new Map()  // type -> 条数
  const typeUsers = new Map()  // type -> Set(userId)
  const dayMap = new Map()     // day -> { users:Set, records:0, events:0 }

  function touchDay(day) {
    if (!dayMap.has(day)) dayMap.set(day, { users: new Set(), records: 0, events: 0 })
    return dayMap.get(day)
  }
  function touchUser(uid) {
    if (!userStat.has(uid)) userStat.set(uid, { first: 0, last: 0, total: 0, byType: {} })
    return userStat.get(uid)
  }

  let earliest = 0, latest = 0
  for (const r of live) {
    const uid = r.userId || '(unknown)'
    const ms = toMillis(r.updatedAt)
    users.add(uid)
    const us = touchUser(uid)
    us.total++
    us.byType[r.type] = (us.byType[r.type] || 0) + 1
    if (ms) {
      if (!us.first || ms < us.first) us.first = ms
      if (ms > us.last) us.last = ms
      if (!earliest || ms < earliest) earliest = ms
      if (ms > latest) latest = ms
      const d = touchDay(dayKey(ms))
      d.users.add(uid)
      d.records++
    }
    typeCount.set(r.type, (typeCount.get(r.type) || 0) + 1)
    if (!typeUsers.has(r.type)) typeUsers.set(r.type, new Set())
    typeUsers.get(r.type).add(uid)
  }

  // ---- 事件 ----
  const eventCount = new Map()
  const eventUsers = new Map()
  for (const e of events) {
    const uid = e.userId || '(unknown)'
    const ms = toMillis(e.ts)
    users.add(uid)
    const us = touchUser(uid)
    if (ms) {
      if (!us.first || ms < us.first) us.first = ms
      if (ms > us.last) us.last = ms
      if (!earliest || ms < earliest) earliest = ms
      if (ms > latest) latest = ms
      const d = touchDay(dayKey(ms))
      d.users.add(uid)
      d.events++
    }
    eventCount.set(e.event, (eventCount.get(e.event) || 0) + 1)
    if (!eventUsers.has(e.event)) eventUsers.set(e.event, new Set())
    eventUsers.get(e.event).add(uid)
  }

  const totalUsers = users.size
  const d7 = now - 7 * 86400000
  const d30 = now - 30 * 86400000
  let active7 = 0, active30 = 0
  for (const [, s] of userStat) {
    if (s.last >= d7) active7++
    if (s.last >= d30) active30++
  }

  // 最受欢迎功能：按「使用该功能的用户数」排，同数再比记录数（用户数更能代表受欢迎程度）
  let topFeature = '-', topFeatureUsers = 0, topFeatureRecords = 0
  for (const [t, set] of typeUsers) {
    if (!FEATURE_NAMES[t]) continue
    const c = typeCount.get(t) || 0
    if (set.size > topFeatureUsers || (set.size === topFeatureUsers && c > topFeatureRecords)) {
      topFeature = FEATURE_NAMES[t]; topFeatureUsers = set.size; topFeatureRecords = c
    }
  }

  const csvs = {}

  // ① 用户总览
  csvs['1_用户总览.csv'] = toCSV([
    ['指标', '值'],
    ['总用户数', totalUsers],
    ['近 7 天活跃用户', active7],
    ['近 30 天活跃用户', active30],
    ['30 天活跃率', totalUsers ? round(active30 * 100 / totalUsers) + '%' : '0%'],
    ['业务记录总数', live.length],
    ['行为事件总数', events.length],
    ['人均记录数', totalUsers ? round(live.length / totalUsers) : 0],
    ['最受欢迎功能', topFeature],
    ['最受欢迎功能使用人数', topFeatureUsers],
    ['数据最早时间', earliest ? new Date(earliest + CN_OFFSET_MS).toISOString().replace('T', ' ').slice(0, 19) : '-'],
    ['数据最新时间', latest ? new Date(latest + CN_OFFSET_MS).toISOString().replace('T', ' ').slice(0, 19) : '-'],
    ['统计生成时间', new Date(now + CN_OFFSET_MS).toISOString().replace('T', ' ').slice(0, 19)]
  ])

  // ② 日活趋势（近 trendDays 天，倒序：最新在上）
  const trendRows = [['日期', '活跃用户数', '业务记录数', '行为事件数']]
  const cutoffDay = dayKey(now - (trendDays - 1) * 86400000)
  const days = Array.from(dayMap.keys()).filter(d => d && d >= cutoffDay).sort().reverse()
  for (const d of days) {
    const v = dayMap.get(d)
    trendRows.push([d, v.users.size, v.records, v.events])
  }
  csvs['2_日活趋势.csv'] = toCSV(trendRows)

  // ③ 功能渗透率
  const featRows = [['功能', '记录数', '使用用户数', '渗透率', '人均记录数']]
  const featList = Object.keys(FEATURE_NAMES)
    .map(t => ({ t, c: typeCount.get(t) || 0, u: (typeUsers.get(t) || new Set()).size }))
    .sort((a, b) => (b.u - a.u) || (b.c - a.c))
  for (const f of featList) {
    featRows.push([
      FEATURE_NAMES[f.t], f.c, f.u,
      totalUsers ? round(f.u * 100 / totalUsers) + '%' : '0%',
      f.u ? round(f.c / f.u) : 0
    ])
  }
  csvs['3_功能渗透率.csv'] = toCSV(featRows)

  // ④ 行为事件统计（埋点）
  const evRows = [['事件', '触发次数', '触发用户数', '人均次数']]
  const evList = Array.from(eventCount.entries()).sort((a, b) => b[1] - a[1])
  for (const [name, c] of evList) {
    const u = (eventUsers.get(name) || new Set()).size
    evRows.push([name, c, u, u ? round(c / u) : 0])
  }
  if (evList.length === 0) evRows.push(['(暂无埋点数据)', 0, 0, 0])
  csvs['4_行为事件统计.csv'] = toCSV(evRows)

  // ⑤ 识别使用情况（recognition 记录的 types 字段 = 本次识别命中的业务类型）
  const recTypeCount = new Map()
  let recTotal = 0
  const recUsers = new Set()
  for (const r of live) {
    if (r.type !== 'recognition') continue
    recTotal++
    recUsers.add(r.userId || '(unknown)')
    const ts = (r.payload && r.payload.types) || []
    const arr = Array.isArray(ts) ? ts : String(ts).split(',')
    for (const t of arr) {
      const k = String(t).trim()
      if (!k) continue
      recTypeCount.set(k, (recTypeCount.get(k) || 0) + 1)
    }
  }
  const recRows = [['识别类型', '命中次数', '占比']]
  const recSum = Array.from(recTypeCount.values()).reduce((a, b) => a + b, 0)
  const RECOG_CN = { bill: '账单', food: '饮食', health: '健康', todo: '待办', reminder: '待办' }
  for (const [k, c] of Array.from(recTypeCount.entries()).sort((a, b) => b[1] - a[1])) {
    recRows.push([RECOG_CN[k] || k, c, recSum ? round(c * 100 / recSum) + '%' : '0%'])
  }
  recRows.push(['—— 识别总次数', recTotal, ''])
  recRows.push(['—— 使用识别的用户数', recUsers.size, ''])
  csvs['5_识别使用情况.csv'] = toCSV(recRows)

  // ⑥ 账单分类分布
  const catCount = new Map()
  const catAmount = new Map()
  let billTotal = 0, billAuto = 0, incomeCount = 0
  for (const r of live) {
    if (r.type !== 'bill') continue
    const p = r.payload || {}
    billTotal++
    if (p.confirmed === false) billAuto++    // 未确认 = 识别自动生成、用户未复核
    if (p.isIncome === true) incomeCount++
    const cat = p.category || '未分类'
    catCount.set(cat, (catCount.get(cat) || 0) + 1)
    catAmount.set(cat, round((catAmount.get(cat) || 0) + (Number(p.amount) || 0)))
  }
  const catRows = [['分类', '笔数', '总金额', '笔数占比']]
  for (const [k, c] of Array.from(catCount.entries()).sort((a, b) => b[1] - a[1])) {
    catRows.push([k, c, round(catAmount.get(k) || 0), billTotal ? round(c * 100 / billTotal) + '%' : '0%'])
  }
  catRows.push(['—— 账单总笔数', billTotal, '', ''])
  catRows.push(['—— 收入笔数', incomeCount, '', billTotal ? round(incomeCount * 100 / billTotal) + '%' : '0%'])
  catRows.push(['—— 未确认(自动识别待复核)', billAuto, '', billTotal ? round(billAuto * 100 / billTotal) + '%' : '0%'])
  csvs['6_账单分类分布.csv'] = toCSV(catRows)

  // ⑦ 待办完成率
  let todoTotal = 0, todoDone = 0, todoOverdue = 0, todoRepeat = 0, todoNoDue = 0
  const prio = new Map()
  for (const r of live) {
    if (r.type !== 'reminder') continue
    const p = r.payload || {}
    todoTotal++
    if (p.done === true) todoDone++
    const dueMs = toMillis(p.due)
    if (p.dueNil === true || !dueMs) todoNoDue++
    else if (p.done !== true && dueMs < now) todoOverdue++
    if (p.repeatRule && p.repeatRule !== 'none' && p.repeatRule !== '') todoRepeat++
    const pk = String(p.priority === undefined ? '未设置' : p.priority)
    prio.set(pk, (prio.get(pk) || 0) + 1)
  }
  const todoRows = [['指标', '值']]
  todoRows.push(['待办总数', todoTotal])
  todoRows.push(['已完成', todoDone])
  todoRows.push(['完成率', todoTotal ? round(todoDone * 100 / todoTotal) + '%' : '0%'])
  todoRows.push(['已逾期未完成', todoOverdue])
  todoRows.push(['未设置截止时间', todoNoDue])
  todoRows.push(['使用重复规则', todoRepeat])
  todoRows.push(['重复规则使用率', todoTotal ? round(todoRepeat * 100 / todoTotal) + '%' : '0%'])
  for (const [k, c] of Array.from(prio.entries()).sort((a, b) => b[1] - a[1])) {
    todoRows.push(['优先级 ' + k, c])
  }
  csvs['7_待办完成率.csv'] = toCSV(todoRows)

  // ⑧ 饮食与饮水
  let foodCount = 0, cal = 0, pro = 0, carb = 0, fat = 0
  const mealMap = new Map()
  const foodDays = new Set()
  for (const r of live) {
    if (r.type !== 'food') continue
    const p = r.payload || {}
    foodCount++
    cal += Number(p.calories) || 0
    pro += Number(p.protein) || 0
    carb += Number(p.carbs) || 0
    fat += Number(p.fat) || 0
    const meal = p.meal || '未标注'
    mealMap.set(meal, (mealMap.get(meal) || 0) + 1)
    const dms = toMillis(p.date)
    if (dms) foodDays.add((r.userId || '') + '|' + dayKey(dms))
  }
  let waterCount = 0, waterAmount = 0
  const waterUsers = new Set()
  for (const r of live) {
    if (r.type !== 'water') continue
    waterCount++
    waterAmount += Number((r.payload || {}).amount) || 0
    waterUsers.add(r.userId || '(unknown)')
  }
  const dietRows = [['指标', '值']]
  dietRows.push(['饮食记录总条数', foodCount])
  dietRows.push(['有饮食记录的「用户×天」数', foodDays.size])
  dietRows.push(['单条平均热量(kcal)', foodCount ? round(cal / foodCount, 1) : 0])
  dietRows.push(['人日均热量(kcal)', foodDays.size ? round(cal / foodDays.size, 1) : 0])
  dietRows.push(['人日均蛋白质(g)', foodDays.size ? round(pro / foodDays.size, 1) : 0])
  dietRows.push(['人日均碳水(g)', foodDays.size ? round(carb / foodDays.size, 1) : 0])
  dietRows.push(['人日均脂肪(g)', foodDays.size ? round(fat / foodDays.size, 1) : 0])
  for (const [k, c] of Array.from(mealMap.entries()).sort((a, b) => b[1] - a[1])) {
    dietRows.push(['餐次 ' + k, c])
  }
  dietRows.push(['饮水记录条数', waterCount])
  dietRows.push(['饮水总量(ml)', round(waterAmount, 0)])
  dietRows.push(['使用饮水的用户数', waterUsers.size])
  csvs['8_饮食与饮水.csv'] = toCSV(dietRows)

  // ⑨ 用户明细（逐用户看留存与偏好）
  const userRows = [['用户ID', '首次活跃', '最后活跃', '活跃天数跨度', '记录总数']]
  const featKeys = Object.keys(FEATURE_NAMES)
  for (const t of featKeys) userRows[0].push(FEATURE_NAMES[t])
  const sortedUsers = Array.from(userStat.entries()).sort((a, b) => b[1].last - a[1].last)
  for (const [uid, s] of sortedUsers) {
    const row = [
      uid,
      s.first ? dayKey(s.first) : '-',
      s.last ? dayKey(s.last) : '-',
      (s.first && s.last) ? Math.round((s.last - s.first) / 86400000) + 1 : 0,
      s.total
    ]
    for (const t of featKeys) row.push(s.byType[t] || 0)
    userRows.push(row)
  }
  csvs['9_用户明细.csv'] = toCSV(userRows)

  return {
    ok: true,
    summary: {
      totalUsers,
      activeUsers7d: active7,
      activeUsers30d: active30,
      totalRecords: live.length,
      totalEvents: events.length,
      topFeature,
      topFeatureUsers,
      dateSpanStart: earliest ? dayKey(earliest) : '',
      dateSpanEnd: latest ? dayKey(latest) : '',
      generatedAt: new Date(now).toISOString()
    },
    csvs
  }
}

// Phase 2 账号关联 -----------------------------------------------------------------
// 数据记录（随机 syncId，重写 userId 安全）：bill/reminder/food/health/manualHealth/merchant/recurring/recognition
// 派生 id 记录（id 由 userId 算出，重写会产生孤儿）：setting/profileHealth/profile —— 直接删除，由客户端以主账号 id 重新推送
const LINK_DATA_TYPES = ['bill','reminder','food','health','manualHealth','merchant','recurring','recognition','sleep']
const LINK_DERIVED_TYPES = ['setting','profileHealth','profile']

// 关联：把 secondaryUserId 的云数据并入 primaryUserId 分区，并建立映射
async function handleLink(req) {
  const { primaryUserId, secondaryUserId } = req
  if (!primaryUserId || !secondaryUserId) return makeError('link 缺少 primaryUserId/secondaryUserId')
  if (primaryUserId === secondaryUserId) return { ok: true, message: '同一账号无需关联' }
  try {
    // 1) 迁移数据记录：userId 由 secondary 改写为 primary
    await db.collection(COLLECTION)
      .where({ userId: secondaryUserId, type: _.in(LINK_DATA_TYPES) })
      .update({ data: { userId: primaryUserId } })
    // 2) 清理 secondary 的派生-id 记录（避免主账号分区出现重复/冲突），客户端会以主账号 id 重新推送
    await db.collection(COLLECTION)
      .where({ userId: secondaryUserId, type: _.in(LINK_DERIVED_TYPES) })
      .remove()
    // 3) 记录映射（以 secondaryUserId 为 doc id，幂等 upsert）
    const linkId = 'link_' + secondaryUserId
    const exist = await db.collection(LINKS_COLLECTION).doc(linkId).get().catch(() => null)
    const doc = { primaryUserId, secondaryUserId, createdAt: Date.now() }
    if (exist && exist.data) {
      await db.collection(LINKS_COLLECTION).doc(linkId).update({ data: doc })
    } else {
      await db.collection(LINKS_COLLECTION).doc(linkId).set({ data: doc })
    }
    return { ok: true, primaryUserId }
  } catch (e) {
    return makeError('link failed: ' + (e && e.message ? e.message : e))
  }
}

// 解析某 userId 对应的主账号（未关联则返回自身；出错/离线回落自身，保证可用）
// 同时返回已关联到该主账号的所有 secondary（用于前端展示「已关联的方式」列表）
async function handleResolve(req) {
  const { userId } = req
  if (!userId) return makeError('resolve 缺少 userId')
  try {
    const res = await db.collection(LINKS_COLLECTION).where({ secondaryUserId: userId }).limit(1).get()
    const list = (res && res.data) || []
    let primaryUserId = userId
    if (list.length > 0) primaryUserId = list[0].primaryUserId
    // 反查所有映射到该 primary 的 secondary（即「已关联的方式」）
    let linkedMethods = []
    try {
      const all = await db.collection(LINKS_COLLECTION).where({ primaryUserId }).get()
      linkedMethods = (all.data || []).map(d => d.secondaryUserId)
    } catch (e) { /* 离线/出错回落空列表，不影响主流程 */ }
    return { ok: true, primaryUserId, linkedMethods }
  } catch (e) {
    return { ok: true, primaryUserId: userId, linkedMethods: [] }
  }
}

// 解除关联：仅删除映射；已并入主账号的数据无法自动回退（MVP 已知限制）
async function handleUnlink(req) {
  const { secondaryUserId } = req
  if (!secondaryUserId) return makeError('unlink 缺少 secondaryUserId')
  try {
    await db.collection(LINKS_COLLECTION).doc('link_' + secondaryUserId).remove().catch(() => null)
    return { ok: true }
  } catch (e) {
    return makeError('unlink failed: ' + (e && e.message ? e.message : e))
  }
}

// 真删账号分区数据（冷静期到期由定时器 handleDeleteTick 调用，或被 cancelDelete 时超期顺手清）。
// 安全边界：仅删除传入 userId 自身分区，绝不跨删其它用户数据（含已绑定的小程序原生分区——
// 小程序数据由小程序侧管理，App 注销不连带删除小程序账号数据）。
async function purgeAccountData(userId) {
  // 1) 业务主数据（bill/reminder/food/health/recognition/chat/water/sleep/recurring/profile/setting…）
  await db.collection(COLLECTION).where({ userId }).remove()
  // 2) 行为埋点
  await db.collection(EVENTS_COLLECTION).where({ userId }).remove().catch(() => {})
  // 3) 设备 token
  await db.collection(DEVICES_COLLECTION).where({ userId }).remove().catch(() => {})
  // 4) 用户关联映射（无论本账号是主还是从，都解除）
  await db.collection(LINKS_COLLECTION).where({ primaryUserId: userId }).remove().catch(() => {})
  await db.collection(LINKS_COLLECTION).where({ secondaryUserId: userId }).remove().catch(() => {})
  // 5) 免费额度月度文档
  await db.collection(QUOTA_COLLECTION).where({ userId }).remove().catch(() => {})
}

// 账户删除（用户注销）：改为「标记待删 + 冷静期」。
// 业务主数据保留 N 天（默认 7，可由 aia_config.global.deleteGraceDays 调），本地照常清空+退登。
// N 天内同账号重新登录 → 走 cancelDelete 撤销待删标记 → 云端数据原样全量拉回（即自动反悔恢复）。
// N 天后由定时器 handleDeleteTick 调 purgeAccountData 真正抹掉。安全边界同上，绝不跨删其它用户。
async function handleDeleteAccount(req) {
  const { userId } = req
  if (!userId) return makeError('missing userId')
  try {
    const graceDays = await getDeleteGraceDays()
    const now = Date.now()
    const deleteAt = now + graceDays * 24 * 60 * 60 * 1000
    // 幂等：已存在待删记录则重置冷静期（再点一次删除 = 重新给 N 天反悔时间）
    const existing = await db.collection(DELETIONS_COLLECTION).where({ userId }).get()
    if (existing.data && existing.data.length > 0) {
      await db.collection(DELETIONS_COLLECTION).where({ userId }).update({ requestedAt: now, deleteAt })
    } else {
      await db.collection(DELETIONS_COLLECTION).add({ userId, requestedAt: now, deleteAt })
    }
    // 立即清设备 token（退登后不再收推送；重登会自动重新上报）
    await db.collection(DEVICES_COLLECTION).where({ userId }).remove().catch(() => {})
    console.log('[deleteAccount] 已标记待删 userId=', userId, 'graceDays=', graceDays, 'deleteAt=', new Date(deleteAt).toISOString())
    return { ok: true, pending: true, deleteAt }
  } catch (e) {
    return makeError('deleteAccount failed: ' + (e && e.message ? e.message : e))
  }
}

// 撤销待删（冷静期内重新登录时由 App 先调）：删除待删登记记录即视为撤销，业务数据自然保留。
// 若已超期则顺手真删（双保险），返回 purged:true。
async function handleCancelDelete(req) {
  const { userId } = req
  if (!userId) return makeError('missing userId')
  try {
    const res = await db.collection(DELETIONS_COLLECTION).where({ userId }).get()
    if (!res.data || res.data.length === 0) {
      // 没有待删记录：要么从未删、要么已真删。App 正常走全量同步即可。
      return { ok: true, restored: false }
    }
    const rec = res.data[0]
    const now = Date.now()
    if (rec.deleteAt && now >= rec.deleteAt) {
      // 已超期：顺手真删
      await purgeAccountData(userId)
      await db.collection(DELETIONS_COLLECTION).where({ userId }).remove().catch(() => {})
      console.log('[cancelDelete] 待删已超期，直接真删 userId=', userId)
      return { ok: true, restored: false, purged: true }
    }
    // 未超期：撤销待删标记，数据自然保留
    await db.collection(DELETIONS_COLLECTION).where({ userId }).remove().catch(() => {})
    console.log('[cancelDelete] 已撤销待删，数据保留 userId=', userId)
    return { ok: true, restored: true, deleteAt: rec.deleteAt }
  } catch (e) {
    return makeError('cancelDelete failed: ' + (e && e.message ? e.message : e))
  }
}

// 定时器（每天触发）：扫描待删表里 deleteAt 已到期的记录，逐条真删其分区全部数据并清登记记录。
// 云函数自身不能躺 7 天，靠 CloudBase 定时触发器每天调一次本 action 当发动机。
async function handleDeleteTick(req) {
  try {
    const now = Date.now()
    const res = await db.collection(DELETIONS_COLLECTION).where({ deleteAt: _.lte(now) }).get()
    const list = (res.data || [])
    let purged = 0
    for (const rec of list) {
      const uid = rec.userId
      if (!uid) continue
      await purgeAccountData(uid)
      await db.collection(DELETIONS_COLLECTION).doc(rec._id).remove().catch(() => {})
      purged++
    }
    console.log('[deleteTick] 已真删超期账号数=', purged)
    return { ok: true, purged }
  } catch (e) {
    return makeError('deleteTick failed: ' + (e && e.message ? e.message : e))
  }
}

// >>> CHANGE-[2026-08-19 15:32:37]-口令云端化 开始
// 原因: App 端解锁口令改为云端校验, 校验通过签发当日 token 返回给 App 存 Keychain
// 回退: 删除本 handler + handle() 内 devLogin 分支
async function handleDevLogin(req) {
  if (req.passcode !== DEV_PASSCODE) return makeError('unauthorized')
  return { ok: true, token: todayDevToken(), expiresIn: '86400' }
}
// <<< CHANGE-[2026-08-19 15:32:37]-口令云端化 结束

// 核心逻辑（与调用方式无关）
async function handle(req) {
  const { action, userId } = req

  // ---------- 开发者解锁（devLogin 无 userId，须放最前）----------
  if (action === 'devLogin') return await handleDevLogin(req)

  // ---------- 广告（开发者端，口令鉴权，与 userId 无关）----------
  // 注意：必须放在 userId 校验之前，否则 list/listAll/upsert/delete 会被『missing userId』拦掉
  if (action === 'list' || action === 'listAll' || action === 'upsert' || action === 'delete' || action === 'reorder') {
    return await handleAds(req)
  }

  // ---------- 全局配置（开发者可写，所有用户只读跟随，与 userId 无关）----------
  if (action === 'getConfig' || action === 'setConfig') {
    return await handleConfig(req)
  }

  // ---------- 群发通知（方案 A：APNs 远程推送）----------
  // registerDevice：已登录用户上报 deviceToken（无口令，靠登录态守卫）
  // broadcast：开发者口令群发（遍历设备表逐台发 APNs）
  if (action === 'registerDevice') return await handleRegisterDevice(req)
  if (action === 'broadcast') return await handleBroadcast(req)
  if (action === 'broadcastTick') return await handleBroadcastTick(req)
  if (action === 'listBroadcastJobs') return await handleListBroadcastJobs(req)
  if (action === 'listDevices') return await handleListDevices(req)
  // 账户注销冷静期：定时触发器（每天）调本 action 真删超期账号；无需 userId 守卫（定时器不带登录态）。
  if (action === 'deleteTick') return await handleDeleteTick(req)

  // ---------- 使用统计（stats 需口令；logEvent 自带 userId，两者都不走下面的 userId 守卫）----------
  if (action === 'stats') return await handleStats(req)
  if (action === 'logEvent') return await handleLogEvent(req)

  // ---------- 账号关联（Phase 2：跨身份提供方合并，如 手机号↔Apple↔微信同步码）----------
  // 不依赖单 userId 守卫（自身携带 primaryUserId/secondaryUserId），须放在 userId 校验之前。
  if (action === 'link') return await handleLink(req)
  if (action === 'resolve') return await handleResolve(req)
  if (action === 'unlink') return await handleUnlink(req)

  // ---------- 测试账号白名单（开发者口令，须放在 userId 守卫之前，否则过期后无法进管理页加白名单→彻底锁死）----------
  if (action === 'listTesters' || action === 'upsertTester' || action === 'deleteTester') {
    return await ent.handleTesters(req)
  }
  // ---------- 付费墙状态查询（App 拉取 plan/剩余额度，dryRun 不计费；无口令）----------
  if (action === 'entitlement') {
    return await ent.checkEntitlement(req)
  }

  if (!userId) return makeError('missing userId')
    if (!action) return makeError('missing action')

    // ---------- 账户删除（用户注销：删除该账号分区的全部好记数据 + 关联映射）----------
    if (action === 'deleteAccount') return await handleDeleteAccount(req)
    // ---------- 撤销待删（冷静期内重新登录时，App 在首次全量同步前先调，自动恢复数据）----------
    if (action === 'cancelDelete') return await handleCancelDelete(req)

    // ---------- 上传 ----------
  if (action === 'push') {
    // 付费墙：云同步 push 由订阅/试用/白名单管控，免费额度不覆盖。到期未付费 → 停 push（pull 不受影响）。
    const entR = await ent.checkEntitlement({
      feature: 'cloudSyncPush',
      userId, deviceId: req.deviceId, userPhone: req.userPhone,
      isPaid: !!req.isPaid, trialActive: !!req.trialActive
    })
    if (!entR.allowed) {
      return { ok: false, error: 'sync_push_blocked', code: entR.reason || 'expired', plan: entR.plan }
    }
    let upserted = 0
    let list = Array.isArray(req.records) ? req.records : []
    // 过滤非法记录（原循环内校验提前到批量查询之前）
    list = list.filter(r => r && r.id && r.type)
    console.log('push 收到 records 数量:', list.length, '第一条样本:', JSON.stringify(list[0]))

    // P0 优化：一次性批量查存在性（N 次 doc(id).get() → 1~k 次 where(_id:_.in)），再内存比对。
    // App 端已按 50 分批，这里再保险拆 ≤100（CloudBase _.in 单次上限约 100）。
    const existMap = new Map()
    if (list.length > 0) {
      const ids = list.map(r => r.id)
      try {
        const CHUNK = 100
        for (let i = 0; i < ids.length; i += CHUNK) {
          const chunkIds = ids.slice(i, i + CHUNK)
          const exRes = await db.collection(COLLECTION)
            .where({ _id: _.in(chunkIds), userId })
            .get()
          for (const d of (exRes && exRes.data) || []) {
            existMap.set(d._id || d.id, d)
          }
        }
        console.log('push 批量存在性查询命中:', existMap.size, '/', ids.length)
      } catch (e) {
        // 批量查询失败则降级：existMap 为空 → 后续逐条按"不存在"处理（set 幂等覆盖），保证写入不丢。
        console.error('push 批量存在性查询失败，降级为全量 set:', e)
      }
    }

    for (const r of list) {
      const base = {
        userId,
        type: r.type,
        updatedAt: Number(r.updatedAt) || 0,
        deleted: !!r.deleted,
        payload: r.payload || {}
      }
      try {
        const exist = existMap.get(r.id)
        if (exist) {
          // 后写胜出：仅当传入更新时间 >= 云端时才覆盖
          if (base.updatedAt >= exist.updatedAt) {
            const { userId: _u, ...updateData } = base // 不更新 userId
            await db.collection(COLLECTION).doc(r.id).update({ data: updateData })
            upserted++
          } else {
            console.log('push 跳过旧记录:', r.id, '本地', base.updatedAt, '< 云端', exist.updatedAt)
          }
        } else {
          // CloudBase 不允许在 data 里写 _id（doc(r.id) 已指定），否则报 -501007
          await db.collection(COLLECTION).doc(r.id).set({ data: base })
          upserted++
        }
      } catch (e) {
        console.error('push 单条失败', r.id, e)
      }
    }
    console.log('push 完成 upserted:', upserted, 'total:', list.length)
    return { ok: true, upserted, total: list.length }
  }

  // ---------- 拉取 ----------
  if (action === 'pull') {
    const ts = Number(req.since) || 0
    try {
      // P1 优化：游标分页替代 skip 分页——用上一批最大 updatedAt 当游标推进（_.gt），
      // 避免大偏移 skip 重复扫描全表（重装全量同步场景收益明显）。内存按 id 去重防跨页回带。
      // 游标单调递增（本批记录 updatedAt 均 > 上批游标），不会死循环；updatedAt 精确到毫秒，
      // 个人规模下「同一毫秒 100+ 条挤满一页」概率可忽略，故不做复合游标。
      let all = []
      const seen = new Set()
      let cursor = ts
      const PAGE = 100
      while (true) {
        const res = await db.collection(COLLECTION)
          .where({ userId, updatedAt: _.gt(cursor) })
          .orderBy('updatedAt', 'asc')
          .limit(PAGE)
          .get()
        const data = (res && res.data) || []
        let maxU = cursor
        for (const r of data) {
          const rec = { ...r, id: r.id || r._id }
          if (seen.has(rec.id)) continue
          seen.add(rec.id)
          all.push(rec)
          if (rec.updatedAt > maxU) maxU = rec.updatedAt
        }
        if (data.length < PAGE) break
        cursor = maxU
      }
      return { ok: true, records: all, count: all.length }
    } catch (e) {
      return makeError('pull failed: ' + (e && e.message ? e.message : e))
    }
  }

  return makeError('unknown action: ' + action)
}

exports.main = async (event) => {
  // 选项预检（浏览器跨域时才发；原生 App 不发，这里无害处理）
  if (event && event.httpMethod === 'OPTIONS') {
    return { ok: true }
  }
  try {
    const req = parseEvent(event)
    return await handle(req)
  } catch (e) {
    return makeError('server error: ' + (e && e.message ? e.message : e))
  }
}
