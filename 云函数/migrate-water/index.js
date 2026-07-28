const cloud = require('wx-server-sdk')
cloud.init({ env: cloud.DYNAMIC_CURRENT_ENV })
const db = cloud.database()

// 把 'YYYY-MM-DD' + 'HH:MM' 转成本地秒级时间戳（与小程序/App 两端本地时区一致）
function ymdToTs(dateStr, timeStr) {
  const [y, m, d] = String(dateStr || '').split('-').map(Number)
  const [hh, mm] = String(timeStr || '00:00').split(':').map(Number)
  if (!y || !m || !d) return Math.floor(Date.now() / 1000)
  return Math.floor(new Date(y, m - 1, d, hh || 0, mm || 0).getTime() / 1000)
}

exports.main = async (event, context) => {
  let migrated = 0
  let skipped = 0
  let failed = 0
  let skip = 0
  const PAGE = 100

  while (true) {
    const res = await db.collection('water_records').limit(PAGE).skip(skip).get()
    const list = (res && res.data) || []
    for (const r of list) {
      const openid = r._openid
      if (!openid) { skipped++; continue }
      const amount = Number(r.ml) || Number(r.amount) || 0
      if (!amount) { skipped++; continue }
      const ts = ymdToTs(r.date, r.time)
      const updatedAt = (r.createTime && r.createTime.getTime)
        ? Math.floor(r.createTime.getTime() / 1000)
        : Math.floor(Date.now() / 1000)
      const rec = {
        userId: 'wx_' + openid,
        type: 'water',
        updatedAt: updatedAt,
        deleted: false,
        payload: { amount: amount, date: ts, source: r.source || 'manual' }
      }
      try {
        // 用原 water_records._id 作为 syncId，保证幂等（重复运行不会重复生成）
        await db.collection('aia_records').doc(r._id).set({ data: rec })
        migrated++
      } catch (e) {
        console.error('[migrate-water] 单条失败 _id=', r._id, e)
        failed++
      }
    }
    if (list.length < PAGE) break
    skip += PAGE
  }

  return { ok: true, migrated, skipped, failed }
}
