// agentTools.js
// ============================================================================
// AI 助理 Agent 的「只读数据工具」。
// 所有工具只读取 CloudBase 集合 aia_records，绝不执行任何写操作
// （add / update / set / remove / doc().update 一律不用）。
//
// 设计铁律（见 system_design.md §7 共享知识）：
//   1) 查询条件必须包含 userId（等值匹配）+ deleted:false（墓碑过滤）；
//   2) 只允许 .where().get() 只读查询，绝不写库；
//   3) userId 必须来自客户端 body，本文件不硬编码、不编造；
//   4) query_* 默认最多 50 条明细，超出则 truncated=true，避免超长上下文。
// ============================================================================

const cloudbase = require('@cloudbase/node-sdk');

// 环境 ID 集中常量：同环境云函数内 cloudbase.init({ env }) 通常免密。
// 勿在别处散落，统一在此定义（system_design.md §7.7）。
const ENV_ID = 'cloud1-d1ga55pizf294dbe9-1445590522';
const COLLECTION = 'aia_records';

// query_* 默认每类最多取 50 条明细（超过则 truncated=true）。
const DEFAULT_LIMIT = 50;

// 懒初始化数据库句柄：避免在「非云函数 / 未配置」环境下模块加载即报错。
// 初始化或后续查询抛错时，由调用方（handleAgent）捕获并降级。
let _db = null;
function getDB() {
  if (!_db) {
    const app = cloudbase.init({ env: ENV_ID });
    _db = app.database();
  }
  return _db;
}

// ---------------------------------------------------------------------------
// 通用只读查询：按 userId + type + 时间范围 + 业务过滤，返回原始记录数组。
//
// 参数：
//   userId          用户唯一ID（必填，来自客户端）
//   type            记录类型：bill | food | health | reminder | ...
//   options.from/to 秒级 Unix 时间戳；0 表示不限（基于顶层 updatedAt 过滤）
//   options.extraFilter  额外 where 条件（如 { 'payload.category': '餐饮' }）
//   options.limit   最大返回条数（默认 DEFAULT_LIMIT）
//
// 返回：[{ _id, userId, type, updatedAt, payload, ... }]
// ---------------------------------------------------------------------------
async function queryRecords(userId, type, options = {}) {
  const { from = 0, to = 0, extraFilter = {}, limit = DEFAULT_LIMIT } = options;

  if (!userId) {
    throw new Error('queryRecords 缺少 userId');
  }

  const db = getDB();
  const _ = db.command;

  // 只读铁律：强制 userId + deleted:false（墓碑过滤，绝不返回已删记录）
  const where = { userId, type, deleted: false };

  // 时间范围基于顶层 updatedAt（秒级时间戳）过滤
  if (from > 0 && to > 0) {
    where.updatedAt = _.and([_.gte(from), _.lte(to)]);
  } else if (from > 0) {
    where.updatedAt = _.gte(from);
  } else if (to > 0) {
    where.updatedAt = _.lte(to);
  }

  // 合并业务过滤（如分类、餐次），均为只读等值/包含条件
  Object.keys(extraFilter).forEach((k) => {
    where[k] = extraFilter[k];
  });

  const res = await db.collection(COLLECTION).where(where).limit(limit).get();
  return (res && res.data) || [];
}

// ---------------------------------------------------------------------------
// 工具①：查询账单（支出/收入），按时间范围 + 可选分类过滤
// ---------------------------------------------------------------------------
async function query_bills(args = {}) {
  const { userId, from = 0, to = 0, category } = args;
  const extra = {};
  if (category) extra['payload.category'] = category;

  // 多取 1 条用于判断 truncated
  const rows = await queryRecords(userId, 'bill', {
    from, to, extraFilter: extra, limit: DEFAULT_LIMIT + 1,
  });
  const truncated = rows.length > DEFAULT_LIMIT;
  const list = rows.slice(0, DEFAULT_LIMIT).map((r) => {
    const p = r.payload || {};
    return {
      merchant: p.merchant ?? '',
      amount: Number(p.amount ?? 0),
      currency: p.currency ?? 'CNY',
      category: p.category ?? '',
      time: p.time ?? '',
      note: p.note ?? '',
      isIncome: !!p.isIncome,
    };
  });

  let income = 0;
  let expense = 0;
  for (const it of list) {
    if (it.isIncome) income += it.amount;
    else expense += it.amount;
  }

  return {
    code: 0,
    data: {
      list,
      summary: { income, expense, count: list.length },
      count: list.length,
      truncated,
    },
    message: 'ok',
  };
}

// ---------------------------------------------------------------------------
// 工具②：查询饮食记录，按时间范围 + 可选餐次过滤，附营养汇总
// ---------------------------------------------------------------------------
async function query_foods(args = {}) {
  const { userId, from = 0, to = 0, meal } = args;
  const extra = {};
  if (meal) extra['payload.meal'] = meal;

  const rows = await queryRecords(userId, 'food', {
    from, to, extraFilter: extra, limit: DEFAULT_LIMIT + 1,
  });
  const truncated = rows.length > DEFAULT_LIMIT;
  const list = rows.slice(0, DEFAULT_LIMIT).map((r) => {
    const p = r.payload || {};
    return {
      name: p.name ?? '',
      calories: Number(p.calories ?? 0),
      protein: Number(p.protein ?? 0),
      carbs: Number(p.carbs ?? 0),
      fat: Number(p.fat ?? 0),
      portion: p.portion ?? '',
      meal: p.meal ?? '',
      date: p.date ?? '',
    };
  });

  const summary = {
    totalCalories: list.reduce((s, x) => s + x.calories, 0),
    totalProtein: list.reduce((s, x) => s + x.protein, 0),
    totalCarbs: list.reduce((s, x) => s + x.carbs, 0),
    totalFat: list.reduce((s, x) => s + x.fat, 0),
    count: list.length,
  };

  return {
    code: 0,
    data: { list, summary, count: list.length, truncated },
    message: 'ok',
  };
}

// ---------------------------------------------------------------------------
// 工具③：查询健康指标最新值，可选指标名
// 按 metric 分组，每组取 updatedAt 最新的一条。
// ---------------------------------------------------------------------------
async function query_health(args = {}) {
  const { userId, metric } = args;
  const rows = await queryRecords(userId, 'health', { limit: 200 });

  const map = new Map();
  for (const r of rows) {
    const p = r.payload || {};
    const m = p.metric ?? '';
    if (metric && m !== metric) continue; // 指定指标则只保留该指标
    const cur = map.get(m);
    if (!cur || (r.updatedAt || 0) > (cur.updatedAt || 0)) {
      map.set(m, {
        updatedAt: r.updatedAt || 0,
        item: { metric: m, value: p.value ?? '', unit: p.unit ?? '', date: p.date ?? '' },
      });
    }
  }
  const list = Array.from(map.values()).map((x) => x.item);

  return {
    code: 0,
    data: { list, count: list.length },
    message: 'ok',
  };
}

// ---------------------------------------------------------------------------
// 工具④：生成 today / yesterday / last7Days 聚合摘要（云端重算 buildContext）
// 优先返回聚合而非明细，避免超长上下文。
// ---------------------------------------------------------------------------

// 把 today/yesterday/last7Days 转换为上海时区（UTC+8，无夏令时）的秒级时间戳区间。
function rangeBounds(range) {
  const now = new Date();
  const nowSec = Math.floor(now.getTime() / 1000);

  // 取当前上海"日期部分"（年/月/日），用 Intl 指定时区，避免受运行时本地时区影响
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(now);
  const get = (t) => parts.find((x) => x.type === t)?.value;
  const y = Number(get('year'));
  const m = Number(get('month'));
  const d = Number(get('day'));
  // 上海当天 00:00 对应的 UTC epoch 秒 = Date.UTC(y, m-1, d) - 8h
  const dayStartSec = Math.floor(Date.UTC(y, m - 1, d, 0, 0, 0) / 1000) - 8 * 3600;

  if (range === 'today') return { from: dayStartSec, to: nowSec };
  if (range === 'yesterday') return { from: dayStartSec - 86400, to: dayStartSec };
  // 最近7天：滚动窗口（now-7d .. now），语义最清晰，不会因"今天已过的时长"而扩成 8 天
  if (range === 'last7Days') return { from: nowSec - 7 * 86400, to: nowSec };
  return { from: 0, to: nowSec };
}

async function get_summary(args = {}) {
  const { userId, range } = args;
  const { from, to } = rangeBounds(range);

  // 账单聚合（聚合用较大 limit，保证汇总完整）
  const bills = await queryRecords(userId, 'bill', { from, to, limit: 500 });
  let income = 0;
  let expense = 0;
  for (const r of bills) {
    const p = r.payload || {};
    const amt = Number(p.amount || 0);
    if (p.isIncome) income += amt;
    else expense += amt;
  }

  // 饮食聚合
  const foods = await queryRecords(userId, 'food', { from, to, limit: 500 });
  const fList = foods.map((r) => r.payload || {});
  const foodsSummary = {
    totalCalories: fList.reduce((s, p) => s + Number(p.calories || 0), 0),
    totalProtein: fList.reduce((s, p) => s + Number(p.protein || 0), 0),
    totalCarbs: fList.reduce((s, p) => s + Number(p.carbs || 0), 0),
    totalFat: fList.reduce((s, p) => s + Number(p.fat || 0), 0),
    count: fList.length,
  };

  // 待办（reminder 类型）
  const remindersRaw = await queryRecords(userId, 'reminder', { from, to, limit: 200 });
  const reminders = remindersRaw.map((r) => {
    const p = r.payload || {};
    return { title: p.title ?? '', due: p.due ?? '', done: !!p.done };
  });

  // 健康最新指标（不限定时间范围，取每个指标最新值）
  const healthRaw = await queryRecords(userId, 'health', { limit: 200 });
  const hmap = new Map();
  for (const r of healthRaw) {
    const p = r.payload || {};
    const m = p.metric ?? '';
    const cur = hmap.get(m);
    if (!cur || (r.updatedAt || 0) > (cur.updatedAt || 0)) {
      hmap.set(m, { metric: m, value: p.value ?? '', unit: p.unit ?? '' });
    }
  }
  const health = Array.from(hmap.values());

  return {
    code: 0,
    data: {
      range,
      bills: { income, expense, count: bills.length },
      foods: foodsSummary,
      reminders,
      health,
    },
    message: 'ok',
  };
}

// 导出 4 个只读工具（供 index.js 的 Agent 循环按 tool_calls 派发）。
// 注意：本模块绝不导出任何写操作函数。
module.exports = { query_bills, query_foods, query_health, get_summary };
