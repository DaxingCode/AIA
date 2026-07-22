// agentTools.js
// Agent 模式的 4 个只读工具。铁律：只调用 where().get()，绝不增删改任何数据。
const ENV_ID = 'cloud1-d1ga55pizf294dbe9-1445590522';
const COLLECTION = 'aia_records';
const DEFAULT_LIMIT = 50;

let DB = null;

// 懒加载 CloudBase 数据库实例（仅首次查询时初始化，避免冷启动即连库）。
function getDB() {
  if (!DB) {
    const cloudbase = require('@cloudbase/node-sdk');
    DB = cloudbase.init({ env: ENV_ID }).database();
  }
  return DB;
}

function round2(n) {
  return Math.round((Number(n) || 0) * 100) / 100;
}

// 构造查询条件：强制 userId + type + deleted:false，叠加可选的时间范围与等值过滤。
// 返回 { data, count, truncated }。truncated 标记是否达到上限（可能还有更多数据）。
async function queryRecords(userId, type, { from, to, extraFilter = {}, limit = DEFAULT_LIMIT } = {}) {
  const db = getDB();
  const _ = db.command;
  const where = { userId, type, deleted: false };

  if (extraFilter && typeof extraFilter === 'object' && Object.keys(extraFilter).length > 0) {
    Object.assign(where, extraFilter);
  }

  if (typeof from === 'number' || typeof to === 'number') {
    const parts = [];
    if (typeof from === 'number') parts.push(_.gte(from));
    if (typeof to === 'number') parts.push(_.lte(to));
    where.updatedAt = parts.length === 1 ? parts[0] : _.and(...parts);
  }

  const snapshot = await db.collection(COLLECTION).where(where).limit(limit).get();
  const data = Array.isArray(snapshot.data) ? snapshot.data : [];
  return {
    data,
    count: data.length,
    truncated: data.length >= limit,
  };
}

// 计算 Asia/Shanghai 某日的 00:00:00 对应的 Unix 秒级时间戳（北京时间，无夏令时）。
function startOfDayShanghai(date) {
  const ymd = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date); // 形如 'YYYY-MM-DD'
  const [y, m, d] = ymd.split('-').map(Number);
  // 北京时间 = UTC+8，故北京时间 00:00 对应 UTC (y/m/d 00:00 - 8h)
  return Math.floor((Date.UTC(y, m - 1, d, 0, 0, 0) - 8 * 3600 * 1000) / 1000);
}

async function query_bills(args = {}) {
  const extraFilter = {};
  if (typeof args.category === 'string' && args.category.length > 0) {
    extraFilter.category = args.category;
  }
  const { data, count, truncated } = await queryRecords(args.userId, 'bill', {
    from: args.from,
    to: args.to,
    extraFilter,
    limit: args.limit,
  });
  let income = 0;
  let expense = 0;
  for (const r of data) {
    const amt = Number(r.amount) || 0;
    if (r.isIncome) income += amt;
    else expense += amt;
  }
  return {
    code: 0,
    data,
    count,
    truncated,
    message: `查询到 ${count} 条账单记录`,
    summary: { income: round2(income), expense: round2(expense), net: round2(income - expense) },
  };
}

async function query_foods(args = {}) {
  const extraFilter = {};
  if (typeof args.meal === 'string' && args.meal.length > 0) {
    extraFilter.meal = args.meal;
  }
  const { data, count, truncated } = await queryRecords(args.userId, 'food', {
    from: args.from,
    to: args.to,
    extraFilter,
    limit: args.limit,
  });
  const nutrition = { calories: 0, protein: 0, carbs: 0, fat: 0 };
  for (const r of data) {
    nutrition.calories += Number(r.calories) || 0;
    nutrition.protein += Number(r.protein) || 0;
    nutrition.carbs += Number(r.carbs) || 0;
    nutrition.fat += Number(r.fat) || 0;
  }
  return {
    code: 0,
    data,
    count,
    truncated,
    message: `查询到 ${count} 条饮食记录`,
    summary: {
      calories: Math.round(nutrition.calories),
      protein: round2(nutrition.protein),
      carbs: round2(nutrition.carbs),
      fat: round2(nutrition.fat),
    },
  };
}

async function query_health(args = {}) {
  const extraFilter = {};
  if (typeof args.metric === 'string' && args.metric.length > 0) {
    extraFilter.metric = args.metric;
  }
  const { data, count, truncated } = await queryRecords(args.userId, 'health', {
    from: args.from,
    to: args.to,
    extraFilter,
    limit: args.limit,
  });
  // 按 metric 分组，保留每个指标的最新值（列表默认按 updatedAt 升序，故取最后一条）。
  const groups = {};
  for (const r of data) {
    const metric = r.metric || '未知指标';
    groups[metric] = { value: r.value, unit: r.unit || '', updatedAt: r.updatedAt };
  }
  return {
    code: 0,
    data,
    count,
    truncated,
    message: `查询到 ${count} 条健康记录`,
    groups,
  };
}

async function get_summary(args = {}) {
  const range = typeof args.range === 'string' ? args.range : 'today';
  const nowSec = Math.floor(Date.now() / 1000);
  let from;
  let to;
  if (range === 'yesterday') {
    from = startOfDayShanghai(new Date(Date.now() - 86400000));
    to = startOfDayShanghai(new Date()) - 1;
  } else if (range === 'last7Days') {
    from = nowSec - 7 * 86400;
    to = nowSec;
  } else {
    // today
    from = startOfDayShanghai(new Date());
    to = nowSec;
  }

  const bills = await queryRecords(args.userId, 'bill', { from, to, limit: 200 });
  const foods = await queryRecords(args.userId, 'food', { from, to, limit: 200 });

  let income = 0;
  let expense = 0;
  for (const r of bills.data) {
    const amt = Number(r.amount) || 0;
    if (r.isIncome) income += amt;
    else expense += amt;
  }
  const mealCount = {};
  for (const r of foods.data) {
    const m = r.meal || '未知';
    mealCount[m] = (mealCount[m] || 0) + 1;
  }

  return {
    code: 0,
    range,
    message: `已汇总 ${range} 的数据`,
    bills: { count: bills.count, income: round2(income), expense: round2(expense) },
    foods: { count: foods.count, mealCount },
  };
}

module.exports = { query_bills, query_foods, query_health, get_summary };
