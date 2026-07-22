// 云函数 aia-sync（CloudBase / 微信云开发，Node.js）
// 数据集合：aia_records
//   _id:        记录唯一 id（客户端生成，UUID 字符串）
//   userId:     同步账号（客户端生成/可改）
//   type:       bill | reminder | food | health
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

// 核心逻辑（与调用方式无关）
async function handle(req) {
  const { action, userId } = req
  if (!userId) return makeError('missing userId')
  if (!action) return makeError('missing action')

  // ---------- 上传 ----------
  if (action === 'push') {
    let upserted = 0
    const list = Array.isArray(req.records) ? req.records : []
    for (const r of list) {
      if (!r || !r.id || !r.type) continue
      const base = {
        userId,
        type: r.type,
        updatedAt: Number(r.updatedAt) || 0,
        deleted: !!r.deleted,
        payload: r.payload || {}
      }
      try {
        const exist = await db.collection(COLLECTION).doc(r.id).get()
        if (exist && exist.data) {
          // 后写胜出：仅当传入更新时间 >= 云端时才覆盖
          if (base.updatedAt >= exist.data.updatedAt) {
            const { userId: _u, ...updateData } = base // 不更新 userId
            await db.collection(COLLECTION).doc(r.id).update({ data: updateData })
            upserted++
          }
        } else {
          await db.collection(COLLECTION).doc(r.id).set({ data: { _id: r.id, ...base } })
          upserted++
        }
      } catch (e) {
        console.error('push 单条失败', r.id, e)
      }
    }
    return { ok: true, upserted, total: list.length }
  }

  // ---------- 拉取 ----------
  if (action === 'pull') {
    const ts = Number(req.since) || 0
    try {
      // CloudBase 单次 get 最多返回 100 条，必须分页拉全。
      // 重装恢复场景 since=0，需要把该用户全部记录一次性拿回，否则会静默丢数据。
      let all = []
      let skip = 0
      const PAGE = 100
      while (true) {
        const res = await db.collection(COLLECTION)
          .where({ userId, updatedAt: _.gt(ts) })
          .orderBy('updatedAt', 'asc')
          .skip(skip)
          .limit(PAGE)
          .get()
        const data = (res && res.data) || []
        all = all.concat(data)
        if (data.length < PAGE) break
        skip += PAGE
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
