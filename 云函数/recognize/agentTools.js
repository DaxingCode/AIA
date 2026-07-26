// agentTools.js
// Agent 模式工具集：查询（只读）+ 写入/修改（upsert 合并）+ 删除（软删）+ 跨类搜索/报告/批量。
const ENV_ID = 'cloud1-d1ga55pizf294dbe9-1445590522';
const COLLECTION = 'aia_records';
const DEFAULT_LIMIT = 50;
const crypto = require('crypto');

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

async function query_reminders(args = {}) {
  const extraFilter = {};
  if (typeof args.done === 'boolean') extraFilter.done = args.done;
  const { data, count, truncated } = await queryRecords(args.userId, 'reminder', {
    from: args.from,
    to: args.to,
    extraFilter,
    limit: args.limit,
  });
  return {
    code: 0,
    data,
    count,
    truncated,
    message: `查询到 ${count} 条待办记录`,
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

// —— 写入工具：agent 直接写 aia_records（格式与 App 端 push 完全一致）——
// 注意：id 必须是有效 UUID，App 端 pull 用 UUID(uuidString:) 解析；
// userId 由 agentHandler 在调用前注入（args.userId）。
// 支持 upsert：传 args.id 表示更新已有记录（用于「把刚记的那条改成 50g」类修改意图）。

// 剥离写入类命令动词前缀（记/记录/添加/增加/创建/新建/设置/录入/保存/帮我/给我…），
// 与 App 端 ChatView.commandVerbPrefixes 保持一致，作为开启「智能问答 Agent」开关时的兜底。
// 只剥前缀、循环剥离，避免名字里正常的「记/添加」被误删（如「记号笔」「添加剂」）。
function normalizeCommandVerb(name) {
  if (!name) return name;
  let t = String(name);
  const prefixes = [
    '帮我记一笔', '给我记一笔', '帮我记录一笔', '给我记录一笔',
    '帮我记一下', '给我记一下', '帮我记个', '给我记个', '帮我记下来', '给我记下来',
    '帮我记账', '给我记账',
    '记一笔', '记一下', '记个', '记下来', '记账', '记录下', '记录了', '记录', '记',
    '帮我记', '给我记', '帮我记录', '给我记录',
    '帮我增加一笔', '给我增加一笔', '帮我添加一笔', '给我添加一笔',
    '增加一笔', '添加一笔', '加一笔', '来一笔',
    '帮我增加', '给我增加', '帮我添加', '给我添加',
    '增加', '添加',
    '帮我创建一个', '给我创建一个', '帮我新建一个', '给我新建一个', '帮我设置一个', '给我设置一个',
    '帮我创建', '给我创建', '帮我新建', '给我新建', '帮我设置', '给我设置',
    '创建', '新建', '设置',
    '帮我录入', '给我录入', '录入',
    '帮我保存', '给我保存', '保存',
    '帮我', '给我'
  ];
  const measures = ['一个', '一条', '一项', '一件', '这台', '这部', '这张', '这把', '那只', '那个', '这个'];
  let changed = true;
  while (changed) {
    changed = false;
    for (const p of prefixes) { if (t.startsWith(p)) { t = t.slice(p.length); changed = true; break; } }
    for (const m of measures) { if (t.startsWith(m)) { t = t.slice(m.length); changed = true; break; } }
  }
  return t;
}

async function create_bill(args = {}) {
  const merchant = normalizeCommandVerb((args.merchant || '').toString().trim());
  const amountRaw = Number(args.amount);
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);

  // —— 修改模式：传 id 则合并更新（仅覆盖有值的字段，保留其余原值）——
  if (args.id && String(args.id).trim()) {
    const id = String(args.id).trim();
    const res = await coll.where({ id, userId: args.userId, type: 'bill', deleted: false }).limit(1).get();
    const docs = res && res.data ? res.data : [];
    if (!docs.length) return { code: -1, message: '未找到要修改的账单' };
    const ex = docs[0].payload || {};
    const payload = Object.assign({}, ex, {
      merchant: merchant || ex.merchant,
      amount: (typeof args.amount === 'number' && amountRaw > 0) ? round2(amountRaw) : ex.amount,
      category: (args.category || '').toString().trim() || ex.category || '其他',
      isIncome: typeof args.isIncome === 'boolean' ? args.isIncome : ex.isIncome,
      time: typeof args.time === 'number' ? args.time : ex.time,
      note: typeof args.note === 'string' ? args.note : ex.note,
    });
    payload.currency = ex.currency || 'CNY';
    payload.confirmed = ex.confirmed !== undefined ? ex.confirmed : true;
    await coll.where({ id, userId: args.userId, type: 'bill' }).update({ payload, updatedAt: nowSec });
    return { code: 0, id, action: 'updated', message: `已更新账单：${payload.merchant} ¥${payload.amount}` };
  }

  // —— 新建模式 ——
  if (!merchant || !(amountRaw > 0)) {
    return { code: -1, message: '账单缺少有效商户或金额' };
  }
  const id = crypto.randomUUID();
  const payload = {
    merchant,
    amount: round2(amountRaw),
    category: (args.category || '').toString().trim() || '其他',
    isIncome: !!args.isIncome,
    time: typeof args.time === 'number' ? args.time : nowSec,
    note: (args.note || '').toString(),
    currency: 'CNY',
    confirmed: true,
  };
  await coll.add({
    id, userId: args.userId, type: 'bill', updatedAt: nowSec, deleted: false, payload,
  });
  return { code: 0, created: id, action: 'created', message: `已记录${payload.isIncome ? '收入' : '支出'}：${merchant} ¥${payload.amount}` };
}

async function create_food(args = {}) {
  const name = normalizeCommandVerb((args.name || '').toString().trim());
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);

  // —— 修改模式：传 id 合并更新 ——
  if (args.id && String(args.id).trim()) {
    const id = String(args.id).trim();
    const res = await coll.where({ id, userId: args.userId, type: 'food', deleted: false }).limit(1).get();
    const docs = res && res.data ? res.data : [];
    if (!docs.length) return { code: -1, message: '未找到要修改的饮食' };
    const ex = docs[0].payload || {};
    const payload = Object.assign({}, ex, {
      name: name || ex.name,
      calories: (typeof args.calories === 'number' && args.calories > 0) ? Math.round(args.calories * 10) / 10 : ex.calories,
      meal: (args.meal || '').toString().trim() || ex.meal || '加餐',
      portion: typeof args.portion === 'string' ? args.portion : ex.portion,
      weightGram: typeof args.weightGram === 'number' ? args.weightGram : ex.weightGram,
      date: typeof args.date === 'number' ? args.date : ex.date,
      protein: typeof args.protein === 'number' ? args.protein : ex.protein,
      carbs: typeof args.carbs === 'number' ? args.carbs : ex.carbs,
      fat: typeof args.fat === 'number' ? args.fat : ex.fat,
    });
    payload.baseCalories = ex.baseCalories !== undefined ? ex.baseCalories : null;
    payload.baseProtein = ex.baseProtein !== undefined ? ex.baseProtein : null;
    payload.baseCarbs = ex.baseCarbs !== undefined ? ex.baseCarbs : null;
    payload.baseFat = ex.baseFat !== undefined ? ex.baseFat : null;
    await coll.where({ id, userId: args.userId, type: 'food' }).update({ payload, updatedAt: nowSec });
    return { code: 0, id, action: 'updated', message: `已更新饮食：${payload.name}` };
  }

  // —— 新建模式 ——
  if (!name) return { code: -1, message: '饮食缺少食物名称' };
  const id = crypto.randomUUID();
  const payload = {
    name,
    calories: Math.round((Number(args.calories) || 0) * 10) / 10,
    protein: Number(args.protein) || 0,
    carbs: Number(args.carbs) || 0,
    fat: Number(args.fat) || 0,
    portion: (args.portion || '').toString(),
    meal: (args.meal || '').toString().trim() || '加餐',
    date: typeof args.date === 'number' ? args.date : nowSec,
    weightGram: typeof args.weightGram === 'number' ? args.weightGram : null,
    baseCalories: null,
    baseProtein: null,
    baseCarbs: null,
    baseFat: null,
  };
  await coll.add({
    id, userId: args.userId, type: 'food', updatedAt: nowSec, deleted: false, payload,
  });
  return { code: 0, created: id, action: 'created', message: `已记录饮食：${name}` };
}

async function create_todo(args = {}) {
  const title = normalizeCommandVerb((args.title || '').toString().trim());
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);

  // —— 修改模式：传 id 合并更新（未传的 due/remindAt/done 保持不变，避免清掉已有时间）——
  if (args.id && String(args.id).trim()) {
    const id = String(args.id).trim();
    const res = await coll.where({ id, userId: args.userId, type: 'reminder', deleted: false }).limit(1).get();
    const docs = res && res.data ? res.data : [];
    if (!docs.length) return { code: -1, message: '未找到要修改的待办' };
    const ex = docs[0].payload || {};
    const payload = Object.assign({}, ex, {
      title: title || ex.title,
      repeatRule: (args.repeatRule || '').toString().trim() || ex.repeatRule || 'none',
      priority: (args.priority || '').toString().trim() || ex.priority || 'medium',
    });
    if (typeof args.due === 'number') { payload.due = args.due; delete payload.dueNil; }
    else if (args.clearDue) { payload.dueNil = true; delete payload.due; }
    if (typeof args.remindAt === 'number') { payload.remindAt = args.remindAt; delete payload.remindAtNil; }
    else if (args.clearRemindAt) { payload.remindAtNil = true; delete payload.remindAt; }
    if (typeof args.done === 'boolean') payload.done = args.done;
    await coll.where({ id, userId: args.userId, type: 'reminder' }).update({ payload, updatedAt: nowSec });
    return { code: 0, id, action: 'updated', message: `已更新待办：${payload.title}` };
  }

  // —— 新建模式 ——
  if (!title) return { code: -1, message: '待办缺少标题' };
  const id = crypto.randomUUID();
  const payload = {
    title,
    repeatRule: (args.repeatRule || 'none').toString().trim() || 'none',
    priority: (args.priority || 'medium').toString().trim() || 'medium',
    done: !!args.done,
  };
  if (typeof args.due === 'number') payload.due = args.due; else payload.dueNil = true;
  if (typeof args.remindAt === 'number') payload.remindAt = args.remindAt; else payload.remindAtNil = true;
  await coll.add({
    id, userId: args.userId, type: 'reminder', updatedAt: nowSec, deleted: false, payload,
  });
  return { code: 0, created: id, action: 'created', message: `已创建待办：${title}` };
}

// —— 写入工具：记录健康指标（体重/身高/心率/血压/睡眠等）——
async function create_health(args = {}) {
  const metric = (args.metric || '').toString().trim();
  const value = (args.value || '').toString().trim();
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);

  // —— 修改模式：传 id 合并更新 ——
  const id = (args.id || '').toString().trim();
  const existing = (id && await coll.where({ id, userId: args.userId, type: 'health', deleted: false }).limit(1).get()) || null;
  if (id) {
    const docs = existing && existing.data ? existing.data : [];
    if (!docs.length) return { code: -1, message: '未找到要修改的健康指标' };
    const ex = docs[0].payload || {};
    const payload = Object.assign({}, ex, {
      metric: metric || ex.metric,
      value: value || ex.value,
      unit: typeof args.unit === 'string' ? args.unit.trim() : ex.unit,
      date: typeof args.date === 'number' ? args.date : ex.date,
    });
    await coll.where({ id, userId: args.userId, type: 'health' }).update({ payload, updatedAt: nowSec });
    return { code: 0, id, action: 'updated', message: `已更新健康指标：${payload.metric} ${payload.value}${payload.unit}` };
  }

  // —— 新建模式 ——
  if (!metric || !value) {
    return { code: -1, message: '健康指标缺少 metric 或 value' };
  }
  const newId = crypto.randomUUID();
  const payload = { metric, value, unit: (args.unit || '').toString().trim(), date: typeof args.date === 'number' ? args.date : nowSec };
  await coll.add({
    id: newId, userId: args.userId, type: 'health', updatedAt: nowSec, deleted: false, payload,
  });
  return { code: 0, created: newId, action: 'created', message: `已记录健康指标：${metric} ${value}${payload.unit}` };
}

// 通用软删除：优先用 id 精确命中，否则用关键词模糊匹配该类型最近一条。
// 软删除 = 置 deleted:true（与 App 端 syncDeleted 一致，pull 时会剔除本地记录）。
async function softDelete({ userId, type, id, searchField, searchKey }) {
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const tnow = Math.floor(Date.now() / 1000);
  let target = null;
  if (id && String(id).trim()) {
    const res = await coll.where({ id: String(id).trim(), userId, type, deleted: false }).limit(1).get();
    const docs = res && res.data ? res.data : [];
    if (docs.length) target = docs[0];
  } else if (searchKey && String(searchKey).trim()) {
    const key = String(searchKey).trim().toLowerCase();
    const res = await coll.where({ userId, type, deleted: false }).limit(50).get();
    const docs = res && res.data ? res.data : [];
    const matches = docs
      .filter((d) => {
        const v = (d && d.payload && d.payload[searchField]) || '';
        return String(v).toLowerCase().includes(key);
      })
      .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
    if (matches.length) target = matches[0];
  }
  if (!target) return { code: 0, deleted: false, found: false, type, message: '未找到匹配的记录' };
  await coll.where({ id: target.id, userId, type }).update({ deleted: true, updatedAt: tnow });
  const p = target.payload || {};
  return {
    code: 0, deleted: true, found: true, type, id: target.id,
    label: p.merchant || p.name || p.title || p.metric || type,
    payload: p,
    message: `已删除：${p.merchant || p.name || p.title || p.metric || type}`,
  };
}

async function delete_bill(args = {}) {
  return softDelete({ userId: args.userId, type: 'bill', id: args.id, searchField: 'merchant', searchKey: args.merchant });
}

async function delete_food(args = {}) {
  return softDelete({ userId: args.userId, type: 'food', id: args.id, searchField: 'name', searchKey: args.name });
}

async function delete_todo(args = {}) {
  return softDelete({ userId: args.userId, type: 'reminder', id: args.id, searchField: 'title', searchKey: args.title });
}

async function delete_health(args = {}) {
  return softDelete({ userId: args.userId, type: 'health', id: args.id, searchField: 'metric', searchKey: args.metric });
}

// 把某个待办标记为已完成（id 或 title 关键词命中，取最近一条）。
async function complete_todo(args = {}) {
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const tnow = Math.floor(Date.now() / 1000);
  let target = null;
  if (args.id && String(args.id).trim()) {
    const res = await coll.where({ id: String(args.id).trim(), userId: args.userId, type: 'reminder', deleted: false }).limit(1).get();
    const docs = res && res.data ? res.data : [];
    if (docs.length) target = docs[0];
  } else if (args.title && String(args.title).trim()) {
    const key = String(args.title).trim().toLowerCase();
    const res = await coll.where({ userId: args.userId, type: 'reminder', deleted: false }).limit(50).get();
    const docs = res && res.data ? res.data : [];
    const matches = docs
      .filter((d) => String((d.payload && d.payload.title) || '').toLowerCase().includes(key))
      .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
    if (matches.length) target = matches[0];
  }
  if (!target) return { code: 0, found: false, message: '未找到匹配的待办' };
  const p = Object.assign({}, target.payload, { done: true });
  await coll.where({ id: target.id, userId: args.userId, type: 'reminder' }).update({ payload: p, updatedAt: tnow });
  return { code: 0, found: true, id: target.id, title: p.title, done: true, message: `已完成待办：${p.title}` };
}

// 撤销：删除用户最近一条记录（账单/饮食/待办/健康中 updatedAt 最新的一条）。
async function undo_last(args = {}) {
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const types = ['bill', 'food', 'reminder', 'health'];
  let best = null;
  for (const t of types) {
    const res = await coll.where({ userId: args.userId, type: t, deleted: false }).orderBy('updatedAt', 'desc').limit(1).get();
    const docs = res && res.data ? res.data : [];
    if (docs.length) {
      const d = docs[0];
      if (!best || (d.updatedAt || 0) > (best.updatedAt || 0)) best = d;
    }
  }
  if (!best) return { code: 0, deleted: false, found: false, message: '没有可撤销的记录' };
  const tnow = Math.floor(Date.now() / 1000);
  await coll.where({ id: best.id, userId: args.userId, type: best.type }).update({ deleted: true, updatedAt: tnow });
  const p = best.payload || {};
  return {
    code: 0, deleted: true, found: true, type: best.type, id: best.id,
    label: p.merchant || p.name || p.title || p.metric || best.type,
    payload: p,
    message: `已撤销最近一条：${p.merchant || p.name || p.title || p.metric || best.type}`,
  };
}

// —— 商户分类规则（merchant_meta）——
// 新增或更新一条「商户 → 分类/收支类型」规则。按商户名复用已有记录 id，避免重复。
async function set_merchant(args = {}) {
  const merchant = (args.merchant || '').toString().trim();
  if (!merchant) return { code: -1, message: '商户名为空' };
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);
  const res = await coll.where({ userId: args.userId, type: 'merchant_meta', deleted: false }).limit(100).get();
  const docs = res && res.data ? res.data : [];
  const existing = docs.find((d) => (d.payload && d.payload.merchant || '') === merchant);
  const id = (args.id && String(args.id).trim()) || (existing && existing.id) || crypto.randomUUID();
  const base = existing ? existing.payload : {};
  const payload = Object.assign({}, base, {
    merchant,
    category: (args.category || '').toString().trim() || base.category || '其他',
    isIncome: typeof args.isIncome === 'boolean' ? !!args.isIncome : (base.isIncome || false),
    hitCount: base.hitCount || 0,
    lastSeen: nowSec,
  });
  if (existing) {
    await coll.where({ id, userId: args.userId, type: 'merchant_meta' }).update({ payload, updatedAt: nowSec });
    return { code: 0, id, action: 'updated', message: `已更新商户规则：${merchant} → ${payload.category}` };
  }
  await coll.add({ id, userId: args.userId, type: 'merchant_meta', updatedAt: nowSec, deleted: false, payload });
  return { code: 0, id, action: 'created', message: `已新增商户规则：${merchant} → ${payload.category}` };
}

async function list_merchants(args = {}) {
  const { data } = await queryRecords(args.userId, 'merchant_meta', { limit: args.limit || 100 });
  let list = data.map((d) => ({
    id: d.id,
    merchant: d.payload && d.payload.merchant,
    category: d.payload && d.payload.category,
    isIncome: !!(d.payload && d.payload.isIncome),
    hitCount: (d.payload && d.payload.hitCount) || 0,
  }));
  if (typeof args.category === 'string' && args.category.trim()) {
    const c = args.category.trim();
    list = list.filter((x) => x.category === c);
  }
  return { code: 0, count: list.length, data: list, message: `共 ${list.length} 条商户规则` };
}

async function delete_merchant(args = {}) {
  return softDelete({ userId: args.userId, type: 'merchant_meta', id: args.id, searchField: 'merchant', searchKey: args.merchant });
}

// —— 识别历史（recognition）——
async function list_recognitions(args = {}) {
  const { data } = await queryRecords(args.userId, 'recognition', { limit: args.limit || 20 });
  let list = data.map((d) => ({
    id: d.id,
    rawText: (d.payload && (d.payload.rawText || '')).toString().slice(0, 200),
    types: (d.payload && d.payload.types) || [],
    recognizedAt: d.payload && d.payload.recognizedAt,
  }));
  if (typeof args.type === 'string' && args.type.trim()) {
    const t = args.type.trim();
    list = list.filter((x) => (x.types || []).includes(t));
  }
  return { code: 0, count: list.length, data: list, message: `共 ${list.length} 条识别记录` };
}

async function delete_recognition(args = {}) {
  return softDelete({ userId: args.userId, type: 'recognition', id: args.id, searchField: 'rawText', searchKey: args.keyword });
}

// —— 跨类搜索 ——
async function search_all(args = {}) {
  const key = (args.query || '').toString().trim().toLowerCase();
  if (!key) return { code: -1, message: '搜索关键词为空' };
  const from = typeof args.from === 'number' ? args.from : undefined;
  const to = typeof args.to === 'number' ? args.to : undefined;
  let types = ['bill', 'food', 'reminder', 'health'];
  if (Array.isArray(args.types) && args.types.length) types = args.types;
  else if (typeof args.type === 'string' && args.type.trim()) types = [args.type.trim()];
  const results = [];
  for (const t of types) {
    const { data } = await queryRecords(args.userId, t, { from, to, limit: 50 });
    for (const d of data) {
      const p = d.payload || {};
      let hay = '';
      if (t === 'bill') hay = `${p.merchant || ''}${p.category || ''}${p.note || ''}`;
      else if (t === 'food') hay = `${p.name || ''}${p.portion || ''}`;
      else if (t === 'reminder') hay = `${p.title || ''}${p.note || ''}`;
      else if (t === 'health') hay = `${p.metric || ''}${p.value || ''}`;
      if (hay.toLowerCase().includes(key)) {
        results.push({ id: d.id, type: t, label: p.merchant || p.name || p.title || p.metric || t, payload: p });
      }
    }
  }
  return { code: 0, count: results.length, data: results, message: `在 ${types.join('/')} 中搜到 ${results.length} 条含「${key}」的记录` };
}

// —— 区间报告 ——
async function get_report(args = {}) {
  const range = typeof args.range === 'string' ? args.range : 'last7Days';
  const nowSec = Math.floor(Date.now() / 1000);
  let from;
  let to = nowSec;
  if (range === 'today') from = startOfDayShanghai(new Date());
  else if (range === 'yesterday') { from = startOfDayShanghai(new Date(Date.now() - 86400000)); to = startOfDayShanghai(new Date()) - 1; }
  else if (range === 'thisMonth') { const d = new Date(); from = startOfDayShanghai(new Date(d.getFullYear(), d.getMonth(), 1)); }
  else if (range === 'lastMonth') { const d = new Date(); const lm = new Date(d.getFullYear(), d.getMonth() - 1, 1); from = startOfDayShanghai(lm); to = startOfDayShanghai(new Date(d.getFullYear(), d.getMonth(), 1)) - 1; }
  else if (range === 'last30Days') from = nowSec - 30 * 86400;
  else if (range === 'last7Days') from = nowSec - 7 * 86400;
  else if (typeof args.from === 'number') { from = args.from; to = typeof args.to === 'number' ? args.to : nowSec; }
  else from = nowSec - 7 * 86400;

  const [bills, foods, todos, health] = await Promise.all([
    queryRecords(args.userId, 'bill', { from, to, limit: 500 }),
    queryRecords(args.userId, 'food', { from, to, limit: 500 }),
    queryRecords(args.userId, 'reminder', { from, to, limit: 500 }),
    queryRecords(args.userId, 'health', { from, to, limit: 500 }),
  ]);

  let income = 0;
  let expense = 0;
  const byCat = {};
  const merchants = {};
  for (const r of bills.data) {
    const amt = Number(r.amount) || 0;
    if (r.isIncome) income += amt;
    else {
      expense += amt;
      const c = r.category || '其他';
      byCat[c] = (byCat[c] || 0) + amt;
      const m = r.merchant || '其他';
      merchants[m] = (merchants[m] || 0) + amt;
    }
  }
  const topMerchants = Object.entries(merchants).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([m, v]) => ({ merchant: m, amount: round2(v) }));
  let cal = 0;
  let pro = 0;
  let carb = 0;
  let fat = 0;
  for (const r of foods.data) {
    cal += Number(r.calories) || 0;
    pro += Number(r.protein) || 0;
    carb += Number(r.carbs) || 0;
    fat += Number(r.fat) || 0;
  }
  const totalTodos = todos.data.length;
  const doneTodos = todos.data.filter((t) => t.payload && t.payload.done).length;
  const hg = {};
  for (const r of health.data) {
    const m = (r.payload && r.payload.metric) || '未知';
    const rec = { value: r.payload && r.payload.value, unit: (r.payload && r.payload.unit) || '', updatedAt: r.updatedAt };
    if (!hg[m] || (r.updatedAt || 0) > (hg[m].updatedAt || 0)) hg[m] = rec;
  }
  return {
    code: 0,
    range,
    message: `已生成「${range}」报告`,
    bills: {
      count: bills.count,
      income: round2(income),
      expense: round2(expense),
      net: round2(income - expense),
      byCategory: Object.fromEntries(Object.entries(byCat).map(([k, v]) => [k, round2(v)])),
      topMerchants,
    },
    foods: { count: foods.count, calories: Math.round(cal), protein: round2(pro), carbs: round2(carb), fat: round2(fat) },
    todos: { total: totalTodos, done: doneTodos, pending: totalTodos - doneTodos },
    health: hg,
  };
}

// —— 批量：把所有（或关键词匹配）待办标完成 ——
async function complete_all_todos(args = {}) {
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const tnow = Math.floor(Date.now() / 1000);
  const { data } = await queryRecords(args.userId, 'reminder', { limit: 200 });
  let matched = data.filter((d) => !(d.payload && d.payload.done));
  if (typeof args.keyword === 'string' && args.keyword.trim()) {
    const k = args.keyword.trim().toLowerCase();
    matched = matched.filter((d) => String((d.payload && d.payload.title) || '').toLowerCase().includes(k));
  }
  let n = 0;
  for (const d of matched) {
    const p = Object.assign({}, d.payload, { done: true });
    await coll.where({ id: d.id, userId: args.userId, type: 'reminder' }).update({ payload: p, updatedAt: tnow });
    n += 1;
  }
  return { code: 0, done: n, message: `已标记完成 ${n} 条待办` };
}

// —— 批量：删除某商户相关的所有记录（默认仅账单，可扩展到 food/reminder）——
async function delete_by_merchant(args = {}) {
  const merchant = (args.merchant || '').toString().trim();
  if (!merchant) return { code: -1, message: '商户名为空' };
  const types = Array.isArray(args.types) && args.types.length ? args.types
    : (typeof args.type === 'string' && args.type.trim() ? [args.type.trim()] : ['bill']);
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const tnow = Math.floor(Date.now() / 1000);
  const details = [];
  let total = 0;
  for (const t of types) {
    const searchField = t === 'bill' ? 'merchant' : (t === 'food' ? 'name' : (t === 'reminder' ? 'title' : 'metric'));
    const { data } = await queryRecords(args.userId, t, { limit: 200 });
    const matched = data.filter((d) => String((d.payload && d.payload[searchField]) || '').toLowerCase().includes(merchant.toLowerCase()));
    for (const d of matched) {
      await coll.where({ id: d.id, userId: args.userId, type: t }).update({ deleted: true, updatedAt: tnow });
      total += 1;
      details.push({ type: t, label: (d.payload && (d.payload.merchant || d.payload.name || d.payload.title)) || t });
    }
  }
  return { code: 0, deleted: total, details, message: `已删除「${merchant}」相关的 ${total} 条记录` };
}

// —— 阿宝的成长 / 学习：用户教给阿宝的习惯与规则（abao_learning）——
// 当用户教阿宝"以后 XXX 就 YYY" / "记住我的习惯" / "教你怎么处理" 时，保存为一条可复用规则。
// 存储于 aia_records（type=abao_learning），随用户云同步；handler 在每轮对话自动注入提示词，阿宝下次照做。

// 保存/更新一条"用户教给阿宝的规则"。按 topic 去重（同主题更新已有，不堆积）。
async function teach_abao(args = {}) {
  const topic = (args.topic || '').toString().trim();
  const rule = (args.rule || '').toString().trim();
  if (!rule) return { code: -1, message: '规则内容(rule)为空，没法学会' };
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);

  // 按 topic 去重：topic 相同则更新已有规则。
  const res = await coll.where({ userId: args.userId, type: 'abao_learning', deleted: false }).limit(200).get();
  const docs = res && res.data ? res.data : [];
  const existing = topic ? docs.find((d) => ((d.payload && d.payload.topic) || '') === topic) : null;
  const id = (args.id && String(args.id).trim()) || (existing && existing.id) || crypto.randomUUID();

  const base = existing ? existing.payload : {};
  const payload = Object.assign({}, base, {
    topic: topic || base.topic || rule.slice(0, 12),
    rule,
    example: (args.example || '').toString().trim() || base.example || '',
    learnedAt: nowSec,
  });
  if (existing) {
    await coll.where({ id, userId: args.userId, type: 'abao_learning' }).update({ payload, updatedAt: nowSec });
    return { code: 0, id, action: 'updated', message: `已更新你教我的规则「${payload.topic}」：${rule}` };
  }
  await coll.add({ id, userId: args.userId, type: 'abao_learning', updatedAt: nowSec, deleted: false, payload });
  return { code: 0, id, action: 'created', message: `学会啦！已记住「${payload.topic}」：${rule}` };
}

// 列出用户教过的全部规则（可关键词过滤）。
async function list_teachings(args = {}) {
  const { data } = await queryRecords(args.userId, 'abao_learning', { limit: args.limit || 100 });
  let list = data.map((d) => ({
    id: d.id,
    topic: (d.payload && d.payload.topic) || '',
    rule: (d.payload && d.payload.rule) || '',
    example: (d.payload && d.payload.example) || '',
  }));
  if (typeof args.keyword === 'string' && args.keyword.trim()) {
    const k = args.keyword.trim().toLowerCase();
    list = list.filter((x) => `${x.topic} ${x.rule}`.toLowerCase().includes(k));
  }
  return { code: 0, count: list.length, data: list, message: `共 ${list.length} 条你教过我的规则` };
}

// 按查询词检索相关规则（供阿宝动手前确认是否有对应的"用户习惯"可遵循）。
async function recall_teachings(args = {}) {
  const q = (args.query || '').toString().trim().toLowerCase();
  if (!q) return { code: -1, message: '查询词为空' };
  const { data } = await queryRecords(args.userId, 'abao_learning', { limit: 100 });
  const matched = data
    .map((d) => ({
      id: d.id,
      topic: (d.payload && d.payload.topic) || '',
      rule: (d.payload && d.payload.rule) || '',
      example: (d.payload && d.payload.example) || '',
    }))
    .filter((x) => `${x.topic} ${x.rule} ${x.example}`.toLowerCase().includes(q));
  return { code: 0, count: matched.length, data: matched, message: matched.length ? `找到 ${matched.length} 条相关规则` : '没有找到相关规则' };
}

// 供 handler 注入提示词：取最近 N 条规则（按 updatedAt 倒序）。非对外工具，仅供提示词拼装。
async function getLearnedRulesForPrompt(userId, limit = 30) {
  const { data } = await queryRecords(userId, 'abao_learning', { limit: Math.max(limit * 3, 50) });
  return (data || [])
    .map((d) => ({
      topic: (d.payload && d.payload.topic) || '',
      rule: (d.payload && d.payload.rule) || '',
      updatedAt: d.updatedAt || 0,
    }))
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .slice(0, limit);
}

// —— 饮水（water，对应 App 端 WaterLog）——
// amount 单位毫升(ml)。记录时间存 payload.date（上海秒），便于按天统计。
function waterRangeBounds(range) {
  const start = startOfDayShanghai(new Date());
  const day = 86400;
  switch (range) {
    case 'today': return { from: start, to: start + day };
    case 'yesterday': return { from: start - day, to: start };
    case 'last7Days': return { from: start - 6 * day, to: start + day };
    case 'last30Days': return { from: start - 29 * day, to: start + day };
    case 'thisMonth': { const d = new Date(start * 1000); d.setDate(1); return { from: Math.floor(d.getTime() / 1000), to: start + day }; }
    default: return { from: 0, to: 0 }; // from=0 表示不限
  }
}

// 云端记水与 App 端 ChatView.createWaterIntake 对齐：统一写入饮食记录（food 类型）
// 的 waterIntake 字段（营养全 0，name="饮用水"），不再使用独立的 water 类型。
// 这样无论本地还是云端记的水，回到 App 后都落在同一本 FoodEntry，饮水统计一致。
async function create_water(args = {}) {
  const amount = Number(args.amount);
  if (!amount || amount <= 0) return { code: -1, message: '饮水量(amount)需为正数(毫升)' };
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);
  const id = (args.id && String(args.id).trim()) || crypto.randomUUID();
  const dateSec = args.date ? Math.floor(new Date(args.date).getTime() / 1000) : nowSec;
  const note = (args.note || '').toString().trim();
  const payload = {
    name: '饮用水',
    calories: 0, protein: 0, carbs: 0, fat: 0,
    fiber: 0, sugar: 0, sodium: 0,
    waterIntake: amount,
    portion: note || `${amount}毫升`,
    meal: (args.meal && String(args.meal).trim()) || '加餐',
    date: dateSec,
    weightGram: 0,
    note,
  };
  await coll.add({ id, userId: args.userId, type: 'food', updatedAt: nowSec, deleted: false, payload });
  return { code: 0, id, message: `已记录饮水 ${amount} 毫升` };
}

async function delete_water(args = {}) {
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);
  // 按 id 删除：新建的饮水为 food(waterIntake>0)，历史的为 water，均软删
  if (args.id && String(args.id).trim()) {
    const rid = String(args.id).trim();
    await coll.where({ id: rid, userId: args.userId, type: 'food' }).update({ deleted: true, updatedAt: nowSec });
    await coll.where({ id: rid, userId: args.userId, type: 'water' }).update({ deleted: true, updatedAt: nowSec });
    return { code: 0, message: '已删除该条饮水记录' };
  }
  // 无 id：取最新的饮水记录（food 中 waterIntake>0 或老 water）
  const { data: waterData } = await queryRecords(args.userId, 'water', { limit: 100 });
  const { data: foodData } = await queryRecords(args.userId, 'food', { limit: 100 });
  let list = waterData.map((d) => ({ id: d.id, amount: Number(d.payload.amount) || 0, date: d.payload.date || 0, type: 'water', note: (d.payload.note || '') }));
  for (const d of foodData) {
    const w = Number(d.payload.waterIntake) || 0;
    if (w > 0) list.push({ id: d.id, amount: w, date: d.payload.date || 0, type: 'food', note: (d.payload.note || '') });
  }
  if (typeof args.keyword === 'string' && args.keyword.trim()) {
    const k = args.keyword.trim().toLowerCase();
    list = list.filter((x) => `${x.note} ${x.amount}`.toLowerCase().includes(k));
  }
  if (!list.length) return { code: 0, deleted: 0, message: '未找到可删除的饮水记录' };
  list.sort((a, b) => b.date - a.date);
  const rec = list[0];
  await coll.where({ id: rec.id, userId: args.userId, type: rec.type }).update({ deleted: true, updatedAt: nowSec });
  return { code: 0, deleted: 1, id: rec.id, message: `已删除一条饮水记录（${rec.amount} 毫升）` };
}

async function list_waters(args = {}) {
  const { data: waterData } = await queryRecords(args.userId, 'water', { limit: args.limit || 500 });
  const { data: foodData } = await queryRecords(args.userId, 'food', { limit: args.limit || 500 });
  // 合并老 water 记录与新的 food 中 waterIntake>0 的记录
  let list = waterData.map((d) => ({ id: d.id, amount: Number(d.payload.amount) || 0, date: d.payload.date || 0, note: (d.payload.note || '') }));
  for (const d of foodData) {
    const w = Number(d.payload.waterIntake) || 0;
    if (w > 0) list.push({ id: d.id, amount: w, date: d.payload.date || 0, note: (d.payload.note || '') });
  }
  const { from, to } = waterRangeBounds(args.range);
  if (from > 0) list = list.filter((x) => x.date >= from && x.date < to);
  const total = list.reduce((s, x) => s + x.amount, 0);
  const rangeLabel = { today: '今天', yesterday: '昨天', last7Days: '近7天', last30Days: '近30天', thisMonth: '本月' }[args.range] || '全部';
  return { code: 0, count: list.length, totalMl: total, data: list, message: `${rangeLabel}共 ${list.length} 条饮水记录，合计 ${total} 毫升` };
}

// —— 周期排程（recurring_rule，对应 App 端 RecurringRule）——
// 阿宝 可建/查/删周期账单规则；设备拉取后由 RecurringBillManager 自动生成账单。
async function create_recurring(args = {}) {
  const merchant = (args.merchant || '').toString().trim();
  const amount = Number(args.amount);
  if (!merchant || !amount) return { code: -1, message: '周期规则需要 merchant 与正数 amount' };
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);
  const id = (args.id && String(args.id).trim()) || crypto.randomUUID();
  const cycleRaw = (args.cycle || 'monthly').toString();
  const payload = {
    merchant,
    amount,
    category: (args.category || '').toString().trim() || '其他',
    note: (args.note || '').toString().trim(),
    isIncome: !!args.isIncome,
    dayOfMonth: Math.min(Math.max(parseInt(args.dayOfMonth, 10) || 1, 1), 28),
    startDate: args.startDate ? Math.floor(new Date(args.startDate).getTime() / 1000) : nowSec,
    lastGeneratedAt: args.lastGeneratedAt ? Math.floor(new Date(args.lastGeneratedAt).getTime() / 1000) : 0,
    cycleRaw,
    customValue: Math.max(parseInt(args.customValue, 10) || 1, 1),
    customUnitRaw: (args.customUnit || 'month').toString(),
  };
  // 同 merchant 去重更新
  const res = await coll.where({ userId: args.userId, type: 'recurring_rule', deleted: false }).limit(200).get();
  const docs = res && res.data ? res.data : [];
  const existing = docs.find((d) => ((d.payload && d.payload.merchant) || '') === merchant);
  if (existing) {
    await coll.where({ id: existing.id, userId: args.userId, type: 'recurring_rule' }).update({ payload, updatedAt: nowSec });
    return { code: 0, id: existing.id, action: 'updated', message: `已更新周期规则「${merchant}」` };
  }
  await coll.add({ id, userId: args.userId, type: 'recurring_rule', updatedAt: nowSec, deleted: false, payload });
  const cycleLabel = { daily: '天', weekly: '周', monthly: '月', quarterly: '季', yearly: '年', custom: '自定义周期' }[cycleRaw] || '月';
  return { code: 0, id, action: 'created', message: `已新建周期规则「${merchant}」每${cycleLabel} ${amount} 元` };
}

async function list_recurring(args = {}) {
  const { data } = await queryRecords(args.userId, 'recurring_rule', { limit: args.limit || 100 });
  const list = data.map((d) => ({
    id: d.id,
    merchant: (d.payload && d.payload.merchant) || '',
    amount: (d.payload && d.payload.amount) || 0,
    category: (d.payload && d.payload.category) || '',
    cycle: (d.payload && d.payload.cycleRaw) || 'monthly',
    dayOfMonth: (d.payload && d.payload.dayOfMonth) || 1,
    isIncome: !!(d.payload && d.payload.isIncome),
  }));
  return { code: 0, count: list.length, data: list, message: `共 ${list.length} 条周期规则` };
}

async function delete_recurring(args = {}) {
  const db = getDB();
  const coll = db.collection(COLLECTION);
  const nowSec = Math.floor(Date.now() / 1000);
  let id = (args.id && String(args.id).trim()) || '';
  if (!id && args.merchant) {
    const res = await coll.where({ userId: args.userId, type: 'recurring_rule', deleted: false }).limit(200).get();
    const docs = res && res.data ? res.data : [];
    const hit = docs.find((d) => ((d.payload && d.payload.merchant) || '') === args.merchant);
    id = hit ? hit.id : '';
  }
  if (!id) return { code: -1, message: '需提供 id 或 merchant' };
  await coll.where({ id, userId: args.userId, type: 'recurring_rule' }).update({ deleted: true, updatedAt: nowSec });
  return { code: 0, message: '已删除该周期规则' };
}

module.exports = {
  query_bills, query_foods, query_health, query_reminders, get_summary,
  create_bill, create_food, create_todo, create_health,
  delete_bill, delete_food, delete_todo, delete_health,
  complete_todo, undo_last,
  set_merchant, list_merchants, delete_merchant,
  list_recognitions, delete_recognition,
  search_all, get_report, complete_all_todos, delete_by_merchant,
  teach_abao, list_teachings, recall_teachings, getLearnedRulesForPrompt,
  create_water, delete_water, list_waters,
  create_recurring, list_recurring, delete_recurring,
};
