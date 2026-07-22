'use strict';
// ============================================================================
// agentTools.test.js
// 测试目标：AI 助理 Agent 的只读数据工具（agentTools.js）
//   A. 只读铁律：静态扫描无写操作 + module.exports 只含 4 个只读函数 + userId+deleted:false 过滤生效
//   B. 工具正确性：分类过滤/收支汇总、营养汇总、健康最新值、聚合摘要、limit(50) 超量截断
//
// 运行环境：Node 22（托管版）。不依赖真实 CloudBase —— 通过 Module._load 注入假
//           @cloudbase/node-sdk，假 DB 支持 collection().where().limit().get() 只读查询。
// 运行方式：node test/agentTools.test.js
// ============================================================================

const fs = require('fs');
const path = require('path');
const Module = require('module');
const assert = require('assert');

// ---------------------------------------------------------------------------
// 假 CloudBase DB（只读）：支持 .where(filter).limit(n).get() 与 db.command 操作符
// ---------------------------------------------------------------------------
function getByPath(obj, p) {
  return p.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

function matchesField(record, field, expected) {
  const actual = getByPath(record, field);
  if (expected && typeof expected === 'object' && !Array.isArray(expected)) {
    if ('$gte' in expected) return actual >= expected.$gte;
    if ('$lte' in expected) return actual <= expected.$lte;
    if ('$and' in expected) return expected.$and.every((op) => matchesField(record, field, op));
    return false; // 未知操作符对象 → 不匹配
  }
  return actual === expected;
}

function matchesWhere(record, where) {
  return Object.keys(where).every((k) => matchesField(record, k, where[k]));
}

// 动态数据/异常持有器：agentTools.js 内部会缓存 DB 句柄（getDB 只 init 一次），
// 因此 mock 必须在「查询时」动态读取 records / 抛错，而非在 init 时固化，
// 否则切换数据集或 DB_THROW 开关对后续用例无效。
const DB_HOLDER = { records: {} };
let DB_THROW = false;

// 返回稳定形状的 DB 对象；其 collection().get() 在调用时动态读取 DB_HOLDER / DB_THROW
function makeMockDB() {
  const command = {
    and: (arr) => ({ $and: arr }),
    gte: (v) => ({ $gte: v }),
    lte: (v) => ({ $lte: v }),
  };
  return {
    command,
    collection: (name) => ({
      where: (filter) => ({
        limit: () => ({
          get: async () => {
            if (DB_THROW) throw new Error('mock CloudBase DB unavailable');
            const all = DB_HOLDER.records[name] || [];
            return { data: all.filter((r) => matchesWhere(r, filter)) };
          },
        }),
      }),
    }),
  };
}

function setMockDB(recordsByName) {
  DB_HOLDER.records = recordsByName;
}

const _origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === '@cloudbase/node-sdk') {
    // 对应 agentTools.js 的 cloudbase.init({env}).database()
    // database() 每次返回稳定 DB 对象；抛错/数据集切换放到查询时动态判定
    return {
      init: () => ({
        database: () => makeMockDB(),
      }),
    };
  }
  return _origLoad.apply(this, arguments);
};

const agentTools = require(path.join(__dirname, '..', 'agentTools.js'));

// ---------------------------------------------------------------------------
// 假记录（参考 aia_records payload 形状）
// ---------------------------------------------------------------------------
function buildSampleRecords() {
  const now = Math.floor(Date.now() / 1000);
  return {
    aia_records: [
      // —— u1 合法账单 ——
      { _id: 'b1', userId: 'u1', type: 'bill', updatedAt: now - 100, deleted: false,
        payload: { merchant: '瑞幸', amount: 19.9, currency: 'CNY', category: '餐饮', time: '2026-07-22T10:00:00+08:00', note: '', isIncome: false } },
      { _id: 'b4', userId: 'u1', type: 'bill', updatedAt: now - 400, deleted: false,
        payload: { merchant: '工资', amount: 5000, currency: 'CNY', category: '其他', time: '2026-07-01T09:00:00+08:00', note: '', isIncome: true } },
      { _id: 'b5', userId: 'u1', type: 'bill', updatedAt: now - 500, deleted: false,
        payload: { merchant: '永辉', amount: 58.5, currency: 'CNY', category: '超市', time: '2026-07-22T19:00:00+08:00', note: '果蔬', isIncome: false } },
      // —— 他人账单（必须被过滤）——
      { _id: 'b2', userId: 'other', type: 'bill', updatedAt: now - 200, deleted: false,
        payload: { merchant: '星巴克', amount: 30, currency: 'CNY', category: '餐饮', time: '2026-07-22T11:00:00+08:00', note: '', isIncome: false } },
      // —— 已删除（墓碑，必须被过滤）——
      { _id: 'b3', userId: 'u1', type: 'bill', updatedAt: now - 300, deleted: true,
        payload: { merchant: '麦当劳', amount: 25, currency: 'CNY', category: '餐饮', time: '2026-07-22T12:00:00+08:00', note: '', isIncome: false } },
      // —— 饮食 ——
      { _id: 'f1', userId: 'u1', type: 'food', updatedAt: now - 600, deleted: false,
        payload: { name: '鸡蛋', calories: 140, protein: 12, carbs: 1, fat: 9, portion: '100克', meal: '早餐', date: '2026-07-22' } },
      { _id: 'f2', userId: 'u1', type: 'food', updatedAt: now - 700, deleted: false,
        payload: { name: '奶茶', calories: 300, protein: 5, carbs: 40, fat: 10, portion: '1杯', meal: '加餐', date: '2026-07-22' } },
      // —— 健康 ——
      { _id: 'h1', userId: 'u1', type: 'health', updatedAt: now - 800, deleted: false,
        payload: { metric: '体重', value: '65.5', unit: 'kg', date: '2026-07-20' } },
      { _id: 'h2', userId: 'u1', type: 'health', updatedAt: now - 900, deleted: false,
        payload: { metric: '体重', value: '66.0', unit: 'kg', date: '2026-07-10' } },
      { _id: 'h3', userId: 'u1', type: 'health', updatedAt: now - 1000, deleted: false,
        payload: { metric: '步数', value: '8000', unit: '步', date: '2026-07-22' } },
      // —— 待办 ——
      { _id: 'r1', userId: 'u1', type: 'reminder', updatedAt: now - 1100, deleted: false,
        payload: { title: '体检', due: '2026-08-30', done: false } },
    ],
  };
}

// 生成 51 条 u1 账单，用于验证 limit(50) 截断
function buildManyBills() {
  const now = Math.floor(Date.now() / 1000);
  const arr = [];
  for (let i = 0; i < 51; i++) {
    arr.push({
      _id: 'mb' + i, userId: 'u1', type: 'bill', updatedAt: now - i, deleted: false,
      payload: { merchant: '商户' + i, amount: 10 + i, currency: 'CNY', category: '餐饮', time: '2026-07-22T10:00:00+08:00', note: '', isIncome: false },
    });
  }
  return { aia_records: arr };
}

// ---------------------------------------------------------------------------
// 简易测试运行器
// ---------------------------------------------------------------------------
let passed = 0;
let failed = 0;
const failures = [];

const pending = [];
function test(name, fn) {
  // 仅注册，不立即执行；由 run() 顺序 await，避免并发共享 mock 状态互相污染
  pending.push({ name, fn });
}

// ===========================================================================
// A. 只读铁律
// ===========================================================================
console.log('\n[A] 只读铁律（read-only 强制）');

// A1. 静态扫描：agentTools.js + index.js 的 agent 路径不得出现写操作
test('A1 静态扫描：全文件无 .add/.update/.set/.remove/.doc 写操作', () => {
  const files = [
    path.join(__dirname, '..', 'agentTools.js'),
    path.join(__dirname, '..', 'index.js'),
  ];
  const WRITE_RE = /\.(add|update|set|remove|doc)\s*\(/g;
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8');
    let m;
    const bad = [];
    while ((m = WRITE_RE.exec(src))) {
      const method = m[1];
      const dotIdx = m.index;
      if (method === 'set') {
        // 排除 JS 容器方法 Map.set / hmap.set（非 CloudBase 写）
        const pre = src.slice(Math.max(0, dotIdx - 8), dotIdx).toLowerCase();
        if (/(^|[^.\w])(map|hmap)$/.test(pre)) continue;
      }
      bad.push('.' + method + '(');
    }
    assert.strictEqual(bad.length, 0,
      `${path.basename(f)} 发现疑似 DB 写操作: ${bad.join(', ')}`);
  }
});

// A2. module.exports 只含 4 个只读函数
test('A2 导出只含 query_bills/query_foods/query_health/get_summary 共 4 个函数', () => {
  const keys = Object.keys(agentTools);
  assert.deepStrictEqual(
    keys.sort(),
    ['get_summary', 'query_bills', 'query_foods', 'query_health'].sort(),
    '导出键应为 4 个只读工具'
  );
  for (const k of keys) {
    assert.strictEqual(typeof agentTools[k], 'function', `${k} 必须是函数`);
  }
});

// A3. userId + deleted:false 过滤生效（已删/他人记录不得出现）
test('A3 查询结果排除 deleted:true 与他人 userId 记录', async () => {
  setMockDB(buildSampleRecords());
  DB_THROW = false;
  const res = await agentTools.query_bills({ userId: 'u1', from: 0, to: 0 });
  assert.strictEqual(res.code, 0);
  const merchants = res.data.list.map((x) => x.merchant);
  // 合法 u1 账单应出现
  assert.ok(merchants.includes('瑞幸'), '应包含 u1 的瑞幸账单');
  assert.ok(merchants.includes('工资'), '应包含 u1 的工资（收入）');
  assert.ok(merchants.includes('永辉'), '应包含 u1 的永辉账单');
  // 已删除 / 他人记录不得出现
  assert.ok(!merchants.includes('麦当劳'), '不应包含已删除的麦当劳');
  assert.ok(!merchants.includes('星巴克'), '不应包含他人(other)的星巴克');
});

// ===========================================================================
// B. 工具正确性
// ===========================================================================
console.log('\n[B] 工具正确性');

// B1. query_bills：分类过滤 + 收支汇总
test('B1 query_bills 分类(餐饮)过滤与 income/expense 汇总', async () => {
  setMockDB(buildSampleRecords());
  DB_THROW = false;
  // 全量
  const all = await agentTools.query_bills({ userId: 'u1', from: 0, to: 0 });
  assert.strictEqual(all.data.summary.count, 3, 'u1 共 3 条账单');
  assert.strictEqual(all.data.summary.income, 5000, '收入=5000');
  assert.ok(Math.abs(all.data.summary.expense - (19.9 + 58.5)) < 1e-9, '支出=19.9+58.5=78.4');
  // 分类过滤：仅餐饮
  const eat = await agentTools.query_bills({ userId: 'u1', from: 0, to: 0, category: '餐饮' });
  assert.strictEqual(eat.data.summary.count, 1, '餐饮分类仅 1 条');
  assert.strictEqual(eat.data.list[0].merchant, '瑞幸');
  assert.strictEqual(eat.data.summary.expense, 19.9);
});

// B2. query_foods：营养汇总
test('B2 query_foods 营养汇总（热量/蛋白/碳水/脂肪）', async () => {
  setMockDB(buildSampleRecords());
  DB_THROW = false;
  const res = await agentTools.query_foods({ userId: 'u1', from: 0, to: 0 });
  assert.strictEqual(res.data.summary.count, 2);
  assert.strictEqual(res.data.summary.totalCalories, 140 + 300);
  assert.strictEqual(res.data.summary.totalProtein, 12 + 5);
  assert.strictEqual(res.data.summary.totalCarbs, 1 + 40);
  assert.strictEqual(res.data.summary.totalFat, 9 + 10);
  // 餐次过滤
  const brk = await agentTools.query_foods({ userId: 'u1', from: 0, to: 0, meal: '早餐' });
  assert.strictEqual(brk.data.summary.count, 1);
  assert.strictEqual(brk.data.list[0].name, '鸡蛋');
});

// B3. query_health：按 metric 取最新值
test('B3 query_health 按 metric 取最新一条', async () => {
  setMockDB(buildSampleRecords());
  DB_THROW = false;
  const all = await agentTools.query_health({ userId: 'u1' });
  // 体重应取最新（updatedAt 大）的 h1=65.5，而非 h2=66.0
  const weight = all.data.list.find((x) => x.metric === '体重');
  assert.ok(weight, '应包含体重指标');
  assert.strictEqual(weight.value, '65.5', '体重应为最新值 65.5');
  const steps = all.data.list.find((x) => x.metric === '步数');
  assert.ok(steps, '应包含步数指标');
  assert.strictEqual(steps.value, '8000');
  // 指定 metric 过滤
  const onlyWeight = await agentTools.query_health({ userId: 'u1', metric: '体重' });
  assert.strictEqual(onlyWeight.data.list.length, 1);
  assert.strictEqual(onlyWeight.data.list[0].value, '65.5');
});

// B4. get_summary：聚合摘要
test('B4 get_summary 聚合（账单/饮食/待办/健康）', async () => {
  setMockDB(buildSampleRecords());
  DB_THROW = false;
  const res = await agentTools.get_summary({ userId: 'u1', range: 'last7Days' });
  assert.strictEqual(res.code, 0);
  assert.strictEqual(res.data.range, 'last7Days');
  assert.strictEqual(res.data.bills.count, 3);
  assert.strictEqual(res.data.bills.income, 5000);
  assert.ok(Math.abs(res.data.bills.expense - 78.4) < 1e-9);
  assert.strictEqual(res.data.foods.count, 2);
  assert.strictEqual(res.data.foods.totalCalories, 440);
  assert.strictEqual(res.data.reminders.length, 1);
  assert.strictEqual(res.data.reminders[0].title, '体检');
  assert.strictEqual(res.data.reminders[0].done, false);
  // 健康最新：体重65.5 + 步数8000
  const metrics = res.data.health.map((h) => h.metric).sort();
  assert.deepStrictEqual(metrics, ['体重', '步数']);
});

// B5. limit(50) 超量截断
test('B5 query_bills 超过 50 条时 truncated=true 且 list 截断到 50', async () => {
  setMockDB(buildManyBills());
  DB_THROW = false;
  const res = await agentTools.query_bills({ userId: 'u1', from: 0, to: 0 });
  assert.strictEqual(res.data.truncated, true, '应标记 truncated');
  assert.strictEqual(res.data.list.length, 50, '明细应截断到 50');
  assert.strictEqual(res.data.count, 50);
});

// ===========================================================================
// 汇总
// ===========================================================================
(async () => {
  for (const t of pending) {
    try {
      await t.fn();
      passed++;
      console.log('  \u2713 ' + t.name);
    } catch (e) {
      failed++;
      failures.push({ name: t.name, error: e });
      console.log('  \u2717 ' + t.name + '  ::  ' + (e && e.message ? e.message : e));
    }
  }
  console.log(`\n========== agentTools.test.js ==========`);
  console.log(`通过 ${passed} / 失败 ${failed}`);
  if (failed > 0) {
    console.log('\n失败用例：');
    failures.forEach((f) => console.log(' - ' + f.name + ' :: ' + (f.error && f.error.message)));
    process.exit(1);
  } else {
    console.log('全部通过 \u2705');
    process.exit(0);
  }
})();
