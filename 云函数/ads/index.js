// 云函数 ads（CloudBase / 微信云开发，Node.js）
// 数据集合：aia_ads
//   _id:       广告 id（开发者端生成，UUID）
//   title/subtitle/link/imageURL/imageBase64/start/end/enabled/order
// 调用：HTTP 触发 POST JSON，直接返回 { ok, ... }（不要包 {statusCode,headers,body}）。
// 入参：
//   { action: "list" }                                   -> 公开，返回启用且在时间窗内的广告
//   { action: "listAll", passcode }                       -> 全部（含停用）
//   { action: "upsert", passcode, item }                 -> 新建/更新（item 含 id）
//   { action: "delete", passcode, id }                   -> 删除
const cloud = require('wx-server-sdk')
cloud.init({ env: cloud.DYNAMIC_CURRENT_ENV })

const db = cloud.database()
const _ = db.command
const COLLECTION = 'aia_ads'
// 服务端口令：优先读环境变量，fallback 硬编码常量（防抓包伪造）。
const DEV_PASSCODE = process.env.DEV_PASSCODE || 'Daxing@0329'

// >>> CHANGE-[2026-08-19 15:32:37]-口令云端化 开始
// 原因: 方案甲——App 端不再存明文口令, 解锁走 devLogin 拿"当日 token", 后续请求带 devToken
// 设计: 纯字符串派生(不依赖 crypto, CloudBase 沙箱加载 crypto 曾致 0 code exit)
// 回退: 删除本段 + devLogin 分支 + isDevAuthorized 替换回 req.passcode !== DEV_PASSCODE
function todayDevToken() {
  // 东八区当天基准（与 aia-sync/entitlement.js 一致；避免 UTC 跨日导致验签基准漂移）
  const day = new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10)
  return 'aia' + DEV_PASSCODE + '|' + day
}
function isDevAuthorized(req) {
  if (req.passcode && req.passcode === DEV_PASSCODE) return true
  if (req.devToken && req.devToken === todayDevToken()) return true
  return false
}
async function handleDevLogin(req) {
  if (req.passcode !== DEV_PASSCODE) return makeError('unauthorized')
  return { ok: true, token: todayDevToken(), expiresIn: '86400' }
}
// <<< CHANGE-[2026-08-19 15:32:37]-口令云端化 结束

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

function inWindow(item, now) {
  const start = item.start ? new Date(item.start).getTime() : 0
  const end = item.end ? new Date(item.end).getTime() : now + 1
  return now >= start && now <= end
}

async function handle(req) {
  const { action } = req

  // 开发者解锁：校验口令签发当日 token（无 userId，须放最前）
  if (action === 'devLogin') return await handleDevLogin(req)

  // 公开：仅返回已启用且在时间窗内的广告（首页展示用）
  if (action === 'list') {
    try {
      const now = Date.now()
      const res = await db.collection(COLLECTION).where({ enabled: true }).get()
      const items = (res.data || []).filter(it => inWindow(it, now))
      return { ok: true, items }
    } catch (e) {
      return makeError('list failed: ' + (e.message || e))
    }
  }

  // 以下操作需口令（passcode 或当日 devToken 皆可）
  if (!isDevAuthorized(req)) return makeError('unauthorized')

  if (action === 'listAll') {
    try {
      const res = await db.collection(COLLECTION).orderBy('order', 'asc').get()
      return { ok: true, items: res.data || [] }
    } catch (e) {
      return makeError('listAll failed: ' + (e.message || e))
    }
  }

  if (action === 'upsert') {
    const item = req.item
    if (!item || !item.id) return makeError('missing item.id')
    const doc = {
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
      const exist = await db.collection(COLLECTION).doc(item.id).get().catch(() => null)
      if (exist && exist.data) {
        await db.collection(COLLECTION).doc(item.id).update({ data: doc })
      } else {
        await db.collection(COLLECTION).doc(item.id).set({ data: doc })
      }
      return { ok: true, id: item.id }
    } catch (e) {
      return makeError('upsert failed: ' + (e.message || e))
    }
  }

  if (action === 'delete') {
    const id = req.id
    if (!id) return makeError('missing id')
    try {
      await db.collection(COLLECTION).doc(id).remove()
      return { ok: true, id }
    } catch (e) {
      return makeError('delete failed: ' + (e.message || e))
    }
  }

  return makeError('unknown action: ' + action)
}

exports.main = async (event) => {
  if (event && event.httpMethod === 'OPTIONS') return { ok: true }
  try {
    const req = parseEvent(event)
    return await handle(req)
  } catch (e) {
    return makeError('server error: ' + (e.message || e))
  }
}
