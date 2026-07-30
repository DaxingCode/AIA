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
const DEV_PASSCODE = process.env.DEV_PASSCODE || 'Daxing@0329'

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
  if (req.passcode !== DEV_PASSCODE) return makeError('unauthorized')

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

// 全局配置（智能问答开关 + AI 模型）。权威来源在云端，开发者可写、所有用户只读跟随。
// 入参（POST JSON）：
//   { action: "getConfig" }              -> 公开，返回全局配置 { agentEnabled, modelProvider, visionModelProvider }
//   { action: "setConfig", passcode, agentEnabled, modelProvider, visionModelProvider } -> 开发者写入
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
        visionModelProvider: typeof cfg.visionModelProvider === 'string' && cfg.visionModelProvider ? cfg.visionModelProvider : 'glm'
      }
    } catch (e) {
      // 文档不存在时返回默认配置（不视为错误，保证首次启动 App 不崩）
      return { ok: true, agentEnabled: false, modelProvider: 'glm', visionModelProvider: 'glm' }
    }
  }

  if (action === 'setConfig') {
    if (req.passcode !== DEV_PASSCODE) return makeError('unauthorized')
    const cfg = {
      agentEnabled: req.agentEnabled === true,
      modelProvider: typeof req.modelProvider === 'string' && req.modelProvider ? req.modelProvider : 'glm',
      visionModelProvider: typeof req.visionModelProvider === 'string' && req.visionModelProvider ? req.visionModelProvider : 'glm'
    }
    try {
      const exist = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).get().catch(() => null)
      if (exist && exist.data) {
        await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).update({ data: cfg })
      } else {
        await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).set({ data: cfg })
      }
      return { ok: true }
    } catch (e) {
      return makeError('setConfig failed: ' + (e && e.message ? e.message : e))
    }
  }

  return makeError('unknown action: ' + action)
}

// Phase 2 账号关联 -----------------------------------------------------------------
// 数据记录（随机 syncId，重写 userId 安全）：bill/reminder/food/health/manualHealth/merchant/recurring/recognition
// 派生 id 记录（id 由 userId 算出，重写会产生孤儿）：setting/profileHealth/profile —— 直接删除，由客户端以主账号 id 重新推送
const LINK_DATA_TYPES = ['bill','reminder','food','health','manualHealth','merchant','recurring','recognition']
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

// 核心逻辑（与调用方式无关）
async function handle(req) {
  const { action, userId } = req

  // ---------- 广告（开发者端，口令鉴权，与 userId 无关）----------
  // 注意：必须放在 userId 校验之前，否则 list/listAll/upsert/delete 会被『missing userId』拦掉
  if (action === 'list' || action === 'listAll' || action === 'upsert' || action === 'delete' || action === 'reorder') {
    return await handleAds(req)
  }

  // ---------- 全局配置（开发者可写，所有用户只读跟随，与 userId 无关）----------
  if (action === 'getConfig' || action === 'setConfig') {
    return await handleConfig(req)
  }

  // ---------- 账号关联（Phase 2：跨身份提供方合并，如 手机号↔Apple↔微信同步码）----------
  // 不依赖单 userId 守卫（自身携带 primaryUserId/secondaryUserId），须放在 userId 校验之前。
  if (action === 'link') return await handleLink(req)
  if (action === 'resolve') return await handleResolve(req)
  if (action === 'unlink') return await handleUnlink(req)

  if (!userId) return makeError('missing userId')
  if (!action) return makeError('missing action')

  // ---------- 上传 ----------
  if (action === 'push') {
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
