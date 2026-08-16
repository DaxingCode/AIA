// entitlement.js — 付费墙服务端判定（aia-sync / recognize 共用一份逻辑）
// 用法：const ent = require('./entitlement')(db, _, DEV_PASSCODE)
// 设计要点：
//  - 测试白名单（aia_testers）：开发者口令增删，审核/内部账号走这里，绕过一切付费限制。
//  - 免费额度（aia_quota_usage）：按 userId 每月计数，权重可配；服务端强计数，客户端不可信。
//  - 全局月度总额度（成本熔断）：GLOBAL:yyyyMM 聚合，触顶则全平台关闭免费额度。
//  - checkEntitlement 既做「判定」也做「计费」；App 端状态查询传 dryRun:true 不计费。
const CN_OFFSET_MS = 8 * 3600 * 1000
const TESTERS_COLLECTION = 'aia_testers'
const QUOTA_COLLECTION = 'aia_quota_usage'
const CONFIG_COLLECTION = 'aia_config'
const CONFIG_DOC_ID = 'global'

// 受付费墙管控的「云功能」
const PAID_FEATURES = [
  'cloudVision',    // 图片视觉识别
  'cloudTextParse', // 纯文本意图解析
  'cloudChat',      // 云端对话
  'cloudFoodQuery', // 云端食物营养查询
  'cloudAgent',     // 智能问答 Agent
  'cloudSyncPush',  // 云同步上传
]

function monthKeyCN(ms) {
  const d = new Date((ms || Date.now()) + CN_OFFSET_MS)
  return d.getUTCFullYear() * 100 + (d.getUTCMonth() + 1) // yyyyMM
}
function dayKeyCN(ms) {
  const d = new Date((ms || Date.now()) + CN_OFFSET_MS)
  return d.getUTCFullYear() * 10000 + (d.getUTCMonth() + 1) * 100 + d.getUTCDate()
}
function nowMS() { return Date.now() }

module.exports = function (db, _, DEV_PASSCODE) {
  const TESTER_CACHE_TTL = 60 * 1000
  let _testerCache = { at: 0, data: [] }

  async function getConfig() {
    try {
      const res = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).get()
      const c = (res && res.data) ? res.data : {}
      const gMonthly = Number(c.freeQuotaGlobalMonthly) || 0
      const gUsed = await getGlobalQuotaUsed(monthKeyCN())   // 当月全平台已用
      return {
        freeQuotaEnabled: !!c.freeQuotaEnabled,
        freeQuotaPerMonth: Number(c.freeQuotaPerMonth) || 0,
        freeQuotaWeights: (c.freeQuotaWeights && typeof c.freeQuotaWeights === 'object') ? c.freeQuotaWeights : {},
        freeQuotaDailyCap: Number(c.freeQuotaDailyCap) || 0,
        freeQuotaGlobalMonthly: gMonthly,
        freeQuotaGlobalUsed: gUsed,
        // 剩余：-1 表示未设全局上限；否则 max(0, 总额度 - 已用)
        freeQuotaGlobalRemaining: gMonthly > 0 ? Math.max(0, gMonthly - gUsed) : -1,
      }
    } catch (e) {
      return { freeQuotaEnabled: false, freeQuotaPerMonth: 0, freeQuotaWeights: {}, freeQuotaDailyCap: 0, freeQuotaGlobalMonthly: 0, freeQuotaGlobalUsed: 0, freeQuotaGlobalRemaining: -1 }
    }
  }

  async function loadTestersCache() {
    if (nowMS() - _testerCache.at < TESTER_CACHE_TTL && _testerCache.data.length) return _testerCache.data
    try {
      const res = await db.collection(TESTERS_COLLECTION).where({ enabled: true }).limit(500).get()
      _testerCache = { at: nowMS(), data: (res && res.data) || [] }
    } catch (e) {
      _testerCache.data = _testerCache.data || []
    }
    return _testerCache.data
  }

  // 命中测试白名单即视为「全功能可用」（含审核/内部账号）。优先于订阅/试用/额度。
  async function matchTester(ids) {
    const now = nowMS()
    const list = await loadTestersCache()
    for (const t of list) {
      const v = t.idType === 'phone' ? ids.userPhone
        : (t.idType === 'userId' ? ids.userId : ids.deviceId)
      if (v && t.idValue === v && (!t.expireAt || t.expireAt === 0 || t.expireAt > now)) return t
    }
    return null
  }

  async function handleTesters(req) {
    if (req.passcode !== DEV_PASSCODE) return { ok: false, error: 'unauthorized' }
    const { action } = req
    if (action === 'listTesters') {
      try {
        const res = await db.collection(TESTERS_COLLECTION).orderBy('createdAt', 'desc').limit(500).get()
        return { ok: true, items: (res && res.data) || [] }
      } catch (e) { return { ok: false, error: String(e && e.message ? e.message : e) } }
    }
    if (action === 'upsertTester') {
      const { idType, idValue, note, kind, enabled, expireAt } = req
      if (!idType || !idValue) return { ok: false, error: 'idType/idValue required' }
      if (!['phone', 'userId', 'deviceId'].includes(idType)) return { ok: false, error: 'bad idType' }
      const docId = 'tester_' + idType + '_' + idValue
      const doc = {
        idType, idValue,
        note: note || '',
        kind: ['tester', 'review', 'internal'].includes(kind) ? kind : 'tester',
        enabled: enabled !== false,
        expireAt: Number(expireAt) || 0,
        updatedAt: nowMS(),
      }
      try {
        let existData = null
        try {
          const exist = await db.collection(TESTERS_COLLECTION).doc(docId).get()
          existData = exist && exist.data ? exist.data : null
        } catch (_) {
          // 文档不存在时 doc().get() 在某些权限模式下会抛异常，吞掉后按"不存在"处理
          existData = null
        }
        if (existData) {
          await db.collection(TESTERS_COLLECTION).doc(docId).update({ data: doc })
        } else {
          doc.createdAt = nowMS()
          await db.collection(TESTERS_COLLECTION).doc(docId).set({ data: doc })
        }
        _testerCache = { at: 0, data: [] }
        return { ok: true, id: docId }
      } catch (e) { return { ok: false, error: String(e && e.message ? e.message : e) } }
    }
    if (action === 'deleteTester') {
      const { id } = req
      if (!id) return { ok: false, error: 'id required' }
      try {
        await db.collection(TESTERS_COLLECTION).doc(id).remove().catch(() => null)
        _testerCache = { at: 0, data: [] }
        return { ok: true }
      } catch (e) { return { ok: false, error: String(e && e.message ? e.message : e) } }
    }
    return { ok: false, error: 'unknown tester action' }
  }

  async function getGlobalQuotaUsed(mk) {
    try {
      const res = await db.collection(QUOTA_COLLECTION).doc('GLOBAL:' + mk).get()
      const d = (res && res.data) ? res.data : {}
      return Number(d.used) || 0
    } catch (e) { return 0 }
  }

  async function peekUsed(userId) {
    try {
      const res = await db.collection(QUOTA_COLLECTION).doc(userId + ':' + monthKeyCN()).get()
      const d = (res && res.data) ? res.data : {}
      return Number(d.used) || 0
    } catch (e) { return 0 }
  }

  // 计费（服务端强计数 + 权重 + 单日/月度上限 + 全局熔断累加）
  async function consumeQuota(userId, feature, weight, cfg) {
    const mk = monthKeyCN()
    const docId = userId + ':' + mk
    const dailyKey = 'd' + dayKeyCN()
    try {
      const res = await db.collection(QUOTA_COLLECTION).doc(docId).get()
      const exists = res && res.data
      const d = exists ? res.data : { used: 0, byFeature: {}, byDay: {} }
      const used = Number(d.used) || 0
      const byFeature = d.byFeature || {}
      const byDay = d.byDay || {}
      const dayUsed = Number(byDay[dailyKey]) || 0
      if (cfg.freeQuotaPerMonth > 0 && used + weight > cfg.freeQuotaPerMonth) {
        return { ok: false, reason: 'quota_exhausted', remaining: Math.max(0, cfg.freeQuotaPerMonth - used) }
      }
      if (cfg.freeQuotaDailyCap > 0 && dayUsed + weight > cfg.freeQuotaDailyCap) {
        return { ok: false, reason: 'daily_cap', remaining: Math.max(0, cfg.freeQuotaDailyCap - dayUsed) }
      }
      const newUsed = used + weight
      const newByFeature = Object.assign({}, byFeature)
      newByFeature[feature] = (Number(newByFeature[feature]) || 0) + weight
      const newByDay = Object.assign({}, byDay)
      newByDay[dailyKey] = dayUsed + weight
      const update = { used: newUsed, byFeature: newByFeature, byDay: newByDay, updatedAt: nowMS() }
      if (exists) {
        await db.collection(QUOTA_COLLECTION).doc(docId).update({ data: update })
      } else {
        await db.collection(QUOTA_COLLECTION).doc(docId).set({ data: Object.assign({ userId, month: mk }, update) })
      }
      if (cfg.freeQuotaGlobalMonthly > 0) {
        try {
          const gres = await db.collection(QUOTA_COLLECTION).doc('GLOBAL:' + mk).get()
          if (gres && gres.data) {
            await db.collection(QUOTA_COLLECTION).doc('GLOBAL:' + mk).update({ data: { used: _.inc(weight), updatedAt: nowMS() } })
          } else {
            await db.collection(QUOTA_COLLECTION).doc('GLOBAL:' + mk).set({ data: { used: weight, updatedAt: nowMS() } })
          }
        } catch (e) { /* 全局计数失败不阻断主流程 */ }
      }
      return { ok: true, remaining: (cfg.freeQuotaPerMonth > 0 ? Math.max(0, cfg.freeQuotaPerMonth - newUsed) : -1) }
    } catch (e) {
      // 计数失败 → fail-open 放行（避免误伤真实用户）+ 打印（成本风险由全局熔断兜底）
      console.error('consumeQuota failed, fail-open:', e)
      return { ok: true, remaining: -1 }
    }
  }

  async function bumpTesterLastSeen(tester) {
    try {
      const id = tester._id || ('tester_' + tester.idType + '_' + tester.idValue)
      await db.collection(TESTERS_COLLECTION).doc(id).update({ data: { lastSeenAt: nowMS() } }).catch(() => null)
    } catch (e) { /* ignore */ }
  }

  // 判定链：白名单 → 订阅 → 试用 → 免费额度（含全局熔断）→ 过期
  // dryRun=true 时只判定、不计费（供 App 拉取状态）。
  async function checkEntitlement(req) {
    const feature = req.feature
    if (!PAID_FEATURES.includes(feature)) return { plan: 'free', allowed: true, feature }

    const tester = await matchTester({ userId: req.userId, deviceId: req.deviceId, userPhone: req.userPhone })
    if (tester) {
      if (!req.dryRun) await bumpTesterLastSeen(tester)
      return { plan: 'tester', allowed: true, feature, tester: true }
    }
    if (req.isPaid) return { plan: 'paid', allowed: true, feature }
    if (req.trialActive) return { plan: 'trial', allowed: true, feature }

    // 云同步 push 不在免费额度覆盖范围内（试用/订阅到期即停 push，pull 保留）
    if (feature === 'cloudSyncPush') {
      return { plan: 'expired', allowed: false, feature, reason: 'sync_not_covered' }
    }

    const cfg = await getConfig()
    if (!cfg.freeQuotaEnabled) return { plan: 'expired', allowed: false, feature, reason: 'trial_expired' }

    // 全局月度总额度（成本熔断）：触顶则全平台关闭免费额度
    if (cfg.freeQuotaGlobalMonthly > 0) {
      const gUsed = await getGlobalQuotaUsed(monthKeyCN())
      if (gUsed >= cfg.freeQuotaGlobalMonthly) {
        return { plan: 'expired', allowed: false, feature, reason: 'global_quota_exhausted', remaining: 0 }
      }
    }

    const weight = Number(cfg && cfg.freeQuotaWeights && cfg.freeQuotaWeights[feature]) || 1
    if (req.dryRun) {
      const used = await peekUsed(req.userId)
      const remaining = (cfg.freeQuotaPerMonth > 0) ? Math.max(0, cfg.freeQuotaPerMonth - used) : -1
      return { plan: 'freeQuota', allowed: true, feature, dryRun: true, remaining, weight }
    }

    const consumed = await consumeQuota(req.userId, feature, weight, cfg)
    if (!consumed.ok) {
      return { plan: 'expired', allowed: false, feature, reason: consumed.reason, remaining: consumed.remaining }
    }
    return { plan: 'freeQuota', allowed: true, feature, remaining: consumed.remaining, weight }
  }

  return { PAID_FEATURES, monthKeyCN, dayKeyCN, getConfig, matchTester, handleTesters, consumeQuota, checkEntitlement }
}
