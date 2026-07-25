// aia-dedup-check / audit.js
// 用途：本地跑一次，核对云端 aia_records 集合里「账单重复记录」的 _id 是否互不相同。
//       若同一业务内容（商户+金额+分类+收支）下的多条记录 _id 各不相同
//       => 100% 证明是本地多次 insert（每次生成新的 syncId），与云同步无关。
//
// 运行方式（需你自己的腾讯云/CloudBase 密钥，切勿提交进仓库）：
//   export TCB_SECRET_ID=你的secretId
//   export TCB_SECRET_KEY=你的secretKey
//   export TCB_ENV=aizhuli-d1ghh20818e926713-1445590522
//   cd 云函数/aia-dedup-check
//   npm install
//   node audit.js

const cloud = require('wx-server-sdk')

const SECRET_ID = process.env.TCB_SECRET_ID
const SECRET_KEY = process.env.TCB_SECRET_KEY
const ENV = process.env.TCB_ENV || 'aizhuli-d1ghh20818e926713-1445590522'

if (!SECRET_ID || !SECRET_KEY) {
  console.error('缺少环境变量 TCB_SECRET_ID / TCB_SECRET_KEY，请先 export 后再运行。')
  process.exit(1)
}

cloud.init({ secretId: SECRET_ID, secretKey: SECRET_KEY, env: ENV })
const db = cloud.database()
const _ = db.command
const $ = db.command.aggregate

function fmtTime(ts) {
  if (typeof ts !== 'number' || !isFinite(ts)) return String(ts)
  // payload.time 是秒（自 1970），Date 用毫秒
  const d = new Date(ts * 1000)
  return d.toISOString().replace('T', ' ').slice(0, 19)
}

;(async () => {
  const res = await db.collection('aia_records')
    .aggregate()
    .match({ type: 'bill' }) // 含 deleted 一起看，更全面
    .group({
      _id: {
        merchant: '$payload.merchant',
        amount: '$payload.amount',
        category: '$payload.category',
        isIncome: '$payload.isIncome'
      },
      count: $.sum(1),
      ids: $.push('$_id'),
      times: $.push('$payload.time'),
      deletedFlags: $.push('$deleted')
    })
    .match({ count: _.gt(1) })
    .sort({ count: -1 })
    .end()

  const groups = (res && res.data) || []
  console.log(`\n=== aia_records bill 重复组审计（env=${ENV}）===\n`)
  console.log(`发现重复组数量：${groups.length}\n`)

  if (groups.length === 0) {
    console.log('未发现任何重复账单组。\n')
    return
  }

  let distinctIdGroups = 0
  let sameIdGroups = 0

  for (const g of groups) {
    const ids = g.ids || []
    const uniqueIds = new Set(ids.map(String))
    const isDistinct = uniqueIds.size === ids.length
    if (isDistinct) distinctIdGroups++
    else sameIdGroups++

    console.log('────────────────────────────────────────')
    console.log(`商户: ${g._id.merchant ?? '(空)'} | 金额: ${g._id.amount} | 分类: ${g._id.category} | 收支: ${g._id.isIncome ? '收入' : '支出'}`)
    console.log(`重复条数: ${g.count} | _id 互不相同: ${isDistinct ? '是 ✅ (本地多次 insert)' : '否 ❌ (疑似同步bug)'}`)
    ids.forEach((id, i) => {
      const del = g.deletedFlags && g.deletedFlags[i] ? ' [已软删]' : ''
      console.log(`   ${i + 1}. ${id}${del}  time=${fmtTime(g.times && g.times[i])}`)
    })
  }

  console.log('\n────────────────────────────────────────')
  console.log('【结论】')
  console.log(`  互不相同 _id 的重复组: ${distinctIdGroups}`)
  console.log(`  相同 _id 的重复组:     ${sameIdGroups}`)
  if (sameIdGroups === 0 && distinctIdGroups > 0) {
    console.log('  => 全部重复组 _id 均不同，100% 证明是本地多次 insert（每次新 syncId），与云同步无关。')
  } else if (sameIdGroups > 0) {
    console.log('  => 存在 _id 相同的重复组，需进一步排查云同步 push/pull（疑似按 id 幂等失效）。')
  } else {
    console.log('  => 无重复。')
  }
  console.log('')
})().catch(e => {
  console.error('审计脚本执行失败:', e)
  process.exit(1)
})
