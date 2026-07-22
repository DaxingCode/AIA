'use strict';
// ============================================================================
// agentLoop.test.js
// 测试目标：AI 助理 Agent 主循环 + 降级闭环 + 向后兼容（经 exports.main 端到端）
//   C. Agent 循环：tool_calls 解析→回填→最终回复；多 tool_calls 一次回填
//   D. 降级闭环：无 userId / LLM 抛错 / 工具( DB )抛错 / 连续 5 轮 tool_calls → 均走 handleChat 兜底
//   E. 向后兼容：mode:"chat" 仍返回 {ok, reply}；agent 与 chat 共存无冲突
//
// 运行环境：Node 22（托管版）。离线 mock：
//   - @cloudbase/node-sdk → 假模块（可模拟 DB 不可用）
//   - https.request → 拦截 token.sensenova.cn，按可控策略返回 tool_calls / content / error
// 运行方式：node test/agentLoop.test.js
// ============================================================================

const fs = require('fs');
const path = require('path');
const Module = require('module');
const assert = require('assert');

// 环境变量兜底（exports.main 需要 SENSENOVA_API_KEY）
process.env.SENSENOVA_API_KEY = process.env.SENSENOVA_API_KEY || 'dummy-test-key';

// ---------------------------------------------------------------------------
// 假 CloudBase DB（只读）
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
    return false;
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
    // database() 每次返回稳定 DB 对象；抛错/数据集切换放到查询时动态判定
    return {
      init: () => ({
        database: () => makeMockDB(),
      }),
    };
  }
  return _origLoad.apply(this, arguments);
};

// ---------------------------------------------------------------------------
// 假记录
// ---------------------------------------------------------------------------
function buildSampleRecords() {
  const now = Math.floor(Date.now() / 1000);
  return {
    aia_records: [
      { _id: 'b1', userId: 'u1', type: 'bill', updatedAt: now - 100, deleted: false,
        payload: { merchant: '瑞幸', amount: 19.9, currency: 'CNY', category: '餐饮', time: '2026-07-22T10:00:00+08:00', note: '', isIncome: false } },
      { _id: 'b4', userId: 'u1', type: 'bill', updatedAt: now - 400, deleted: false,
        payload: { merchant: '工资', amount: 5000, currency: 'CNY', category: '其他', time: '2026-07-01T09:00:00+08:00', note: '', isIncome: true } },
      { _id: 'f1', userId: 'u1', type: 'food', updatedAt: now - 600, deleted: false,
        payload: { name: '鸡蛋', calories: 140, protein: 12, carbs: 1, fat: 9, portion: '100克', meal: '早餐', date: '2026-07-22' } },
    ],
  };
}

// ---------------------------------------------------------------------------
// mock https.request：拦截 LLM 调用，按 MOCK 策略返回
// ---------------------------------------------------------------------------
const https = require('https');

const MOCK = {
  mode: 'normal',      // normal | multi | always_tool
  httpsErrorOnce: false,
  agentCallCount: 0,
  httpsCallCount: 0,
};

function toolCallsResp(calls) {
  const tool_calls = calls.map((c, idx) => ({
    id: 'call_' + idx,
    type: 'function',
    function: { name: c[0], arguments: JSON.stringify(c[1]) },
  }));
  return JSON.stringify({ choices: [{ message: { tool_calls } }] });
}
function contentResp(text) {
  return JSON.stringify({ choices: [{ message: { content: text } }] });
}

function getResponse(bodyObj) {
  // agent 调用（callWithTools）带 tools；handleChat 的 callChatRaw 不带 tools
  if (bodyObj.tools && Array.isArray(bodyObj.tools)) {
    const i = MOCK.agentCallCount++;
    if (MOCK.mode === 'normal') {
      if (i === 0) return toolCallsResp([['query_bills', { userId: 'u1', from: 0, to: 0 }]]);
      return contentResp('阿宝的最终回复');
    }
    if (MOCK.mode === 'multi') {
      if (i === 0) return toolCallsResp([
        ['query_bills', { userId: 'u1', from: 0, to: 0 }],
        ['get_summary', { userId: 'u1', range: 'last7Days' }],
      ]);
      return contentResp('阿宝的多工具回复');
    }
    if (MOCK.mode === 'always_tool') {
      return toolCallsResp([['query_bills', { userId: 'u1', from: 0, to: 0 }]]);
    }
  }
  // handleChat（降级兜底）路径：返回标志性内容，用于断言确实走了 handleChat
  return contentResp('【兜底】handleChat回复');
}

function makeRes(bodyStr) {
  const listeners = {};
  return {
    statusCode: 200,
    on(ev, cb) { (listeners[ev] = listeners[ev] || []).push(cb); return this; },
    _emit(ev, arg) { (listeners[ev] || []).forEach((cb) => cb(arg)); },
    _body: bodyStr,
    _fire() { this._emit('data', this._body); this._emit('end'); },
  };
}

const mockRequest = function (options, callback) {
  const req = {
    _buf: '',
    _errCb: null,
    on(ev, cb) { if (ev === 'error') req._errCb = cb; return req; },
    write(chunk) { req._buf += chunk; return true; },
    end() {
      const callIndex = MOCK.httpsCallCount++;
      // 模拟 LLM 网络错误：仅首次请求触发一次，避免 handleChat 兜底时再次报错
      if (MOCK.httpsErrorOnce && callIndex === 0) {
        process.nextTick(() => { if (req._errCb) req._errCb(new Error('mock https request error')); });
        return;
      }
      let bodyObj = {};
      try { bodyObj = JSON.parse(req._buf || '{}'); } catch (e) { bodyObj = {}; }
      const respStr = getResponse(bodyObj);
      const res = makeRes(respStr);
      process.nextTick(() => { callback(res); res._fire(); });
    },
  };
  return req;
};

https.request = mockRequest;

// 引入被测模块（其内部 require 的 agentTools 已用假 cloudbase 替换）
const index = require(path.join(__dirname, '..', 'index.js'));
const main = index.main;

// ---------------------------------------------------------------------------
// mock 重置
// ---------------------------------------------------------------------------
function setupMock(opts) {
  MOCK.mode = opts.mode || 'normal';
  MOCK.httpsErrorOnce = !!opts.httpsErrorOnce;
  MOCK.agentCallCount = 0;
  MOCK.httpsCallCount = 0;
  DB_THROW = !!opts.dbThrow;
  setMockDB(opts.records || buildSampleRecords());
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
// C. Agent 循环
// ===========================================================================
console.log('\n[C] Agent 循环（tool_calls 解析→回填→最终回复）');

test('C1 正常循环：第一轮 tool_calls → 第二轮 content，reply 非空且 toolsUsed 含 query_bills', async () => {
  setupMock({ mode: 'normal' });
  const res = await main({ body: { mode: 'agent', userId: 'u1', text: '上个月咖啡花了多少', provider: 'sensenovaText' } });
  assert.strictEqual(res.ok, true, 'ok 应为 true');
  assert.ok(res.reply && res.reply.length > 0, 'reply 不应为空');
  assert.strictEqual(res.reply, '阿宝的最终回复', '应返回最终回复内容');
  assert.ok(Array.isArray(res.toolsUsed) && res.toolsUsed.includes('query_bills'), 'toolsUsed 应含 query_bills');
  assert.ok(res.ver, '应带 ver 字段');
});

test('C2 多 tool_calls 一次回填：toolsUsed 含 query_bills 与 get_summary', async () => {
  setupMock({ mode: 'multi' });
  const res = await main({ body: { mode: 'agent', userId: 'u1', text: '帮我汇总一下', provider: 'sensenovaText' } });
  assert.strictEqual(res.ok, true);
  assert.strictEqual(res.reply, '阿宝的多工具回复');
  assert.ok(res.toolsUsed.includes('query_bills'), '应含 query_bills');
  assert.ok(res.toolsUsed.includes('get_summary'), '应含 get_summary');
});

// ===========================================================================
// D. 降级闭环
// ===========================================================================
console.log('\n[D] 降级闭环（始终有回复，且走 handleChat 兜底）');

test('D1 缺 userId → 降级 handleChat', async () => {
  setupMock({ mode: 'normal' });
  const res = await main({ body: { mode: 'agent', text: '你好', provider: 'sensenovaText' } }); // 无 userId
  assert.strictEqual(res.ok, true);
  assert.strictEqual(res.reply, '【兜底】handleChat回复', '缺少 userId 应走 handleChat 兜底');
});

test('D2 LLM 抛错（https error）→ 降级 handleChat', async () => {
  setupMock({ mode: 'normal', httpsErrorOnce: true });
  const res = await main({ body: { mode: 'agent', userId: 'u1', text: 'Q', provider: 'sensenovaText' } });
  assert.strictEqual(res.ok, true);
  assert.strictEqual(res.reply, '【兜底】handleChat回复', 'LLM 错误应降级 handleChat');
});

test('D3 工具/DB 抛错（getDB 抛）→ 5 轮后降级 handleChat', async () => {
  setupMock({ mode: 'always_tool', dbThrow: true });
  const res = await main({ body: { mode: 'agent', userId: 'u1', text: 'Q', provider: 'sensenovaText' } });
  assert.strictEqual(res.ok, true);
  assert.strictEqual(res.reply, '【兜底】handleChat回复', 'DB 不可用应最终降级 handleChat');
});

test('D4 连续 5 轮均返回 tool_calls（无最终 content）→ 超限降级 handleChat', async () => {
  setupMock({ mode: 'always_tool', dbThrow: false });
  const res = await main({ body: { mode: 'agent', userId: 'u1', text: 'Q', provider: 'sensenovaText' } });
  assert.strictEqual(res.ok, true);
  assert.strictEqual(res.reply, '【兜底】handleChat回复', '超过 5 轮应超限降级 handleChat');
});

// ===========================================================================
// E. 向后兼容
// ===========================================================================
console.log('\n[E] 向后兼容');

test('E1 mode:"chat" 仍返回 {ok, reply}', async () => {
  setupMock({ mode: 'normal' });
  const res = await main({ body: { mode: 'chat', text: '你好', userId: 'u1', provider: 'sensenovaText' } });
  assert.strictEqual(res.ok, true);
  assert.ok(typeof res.reply === 'string' && res.reply.length > 0, 'chat 应返回非空 reply');
  assert.strictEqual(res.reply, '【兜底】handleChat回复');
});

test('E2 mode:"agent" 与 mode:"chat" 共存无冲突（各分支独立）', async () => {
  setupMock({ mode: 'normal' });
  const a = await main({ body: { mode: 'agent', userId: 'u1', text: 'Q', provider: 'sensenovaText' } });
  setupMock({ mode: 'normal' });
  const c = await main({ body: { mode: 'chat', text: '你好', userId: 'u1', provider: 'sensenovaText' } });
  assert.strictEqual(a.ok, true);
  assert.strictEqual(a.reply, '阿宝的最终回复', 'agent 分支应返回工具链结果');
  assert.strictEqual(c.ok, true);
  assert.strictEqual(c.reply, '【兜底】handleChat回复', 'chat 分支应返回兜底回复');
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
  console.log(`\n========== agentLoop.test.js ==========`);
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
