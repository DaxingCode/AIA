'use strict';
// 验证清单 1（只读铁律）与 2（userId 服务端覆盖 + 防越权）
// 通过静态扫描 + 动态 mock 数据库，证明 Agent 工具只做 where().get() 只读查询，
// 且 userId 由服务端强制覆盖，绝不允许越权查询他人数据。
const path = require('path');
const fs = require('fs');
const test = require('node:test');
const assert = require('node:assert/strict');
const mocks = require('./mocks');

const AGENT_TOOLS_PATH = path.join(__dirname, '..', 'agentTools.js');

test.before(() => {
  mocks.installCloudbaseMock();
  mocks.installHttpsMock();
});
test.after(() => {
  mocks.uninstallCloudbaseMock();
  mocks.uninstallHttpsMock();
});
test.beforeEach(() => {
  mocks.resetDbState();
  mocks.resetHttpsState();
  process.env.DASHSCOPE_API_KEY = 'test-key';
  delete process.env.AGENT_ENABLED;
});

// ---------------------- 验证清单 1：只读铁律（静态）----------------------
test('[只读-静态] agentTools.js 不含任何增删改调用', () => {
  const src = fs.readFileSync(AGENT_TOOLS_PATH, 'utf8');
  const writePatterns = [
    /\.\s*add\s*\(/,
    /\.\s*update\s*\(/,
    /\.\s*set\s*\(/,
    /\.\s*remove\s*\(/,
    /\.doc\s*\(/,
  ];
  for (const re of writePatterns) {
    assert.ok(!re.test(src), `发现疑似写入调用，命中正则 ${re}`);
  }
  // 反向确认只读查询路径确实存在
  assert.ok(/\.where\s*\(/.test(src), '应包含 .where(');
  assert.ok(/\.get\s*\(/.test(src), '应包含 .get(');
  // 4 个只读工具均已导出
  const exported = ['query_bills', 'query_foods', 'query_health', 'get_summary'];
  for (const name of exported) {
    assert.ok(new RegExp('module\\.exports\\s*=\\s*\\{\\s*' + name).test(src) ||
      new RegExp(name + '\\s*[,}]').test(src), `应导出工具 ${name}`);
  }
});

// ---------------------- 验证清单 1：只读铁律（动态，直接调 4 工具）----------------------
test('[只读-动态] 4 工具只调用 where().get()，绝不 add/update/set/remove/doc().update', async () => {
  mocks.resetDbState({ getData: () => ([{ userId: 'u1', type: 'bill', amount: 10, deleted: false }]) });
  const tools = require('../agentTools.js');
  await tools.query_bills({ userId: 'u1', category: '餐饮' });
  await tools.query_foods({ userId: 'u1', meal: '早餐' });
  await tools.query_health({ userId: 'u1', metric: '体重' });
  await tools.get_summary({ userId: 'u1', range: 'today' });

  assert.equal(mocks.dbState.add, 0, '不应调用 add');
  assert.equal(mocks.dbState.update, 0, '不应调用 update');
  assert.equal(mocks.dbState.set, 0, '不应调用 set');
  assert.equal(mocks.dbState.remove, 0, '不应调用 remove');
  assert.equal(mocks.dbState.docUpdate, 0, '不应调用 doc().update');
  // get_summary 内部查 2 次，故 where 调用 >= 4
  assert.ok(mocks.dbState.whereArgs.length >= 4, 'where 调用次数不足（应 >=4）');
  for (const w of mocks.dbState.whereArgs) {
    assert.equal(w.deleted, false, 'where 条件必须含 deleted:false');
    assert.ok(w.userId, 'where 条件必须含 userId');
    assert.ok(['bill', 'food', 'health'].includes(w.type), 'where 条件必须含合法 type');
  }
});

// ---------------------- 验证清单 2：userId 服务端覆盖 + 防越权 ----------------------
test('[防越权] 模型返回他人 userId，实际查询被强制覆盖为 body.userId，且 DB 返回跨用户数据不被越权', async () => {
  // DB 返回含 userA/userB 的混合记录，模拟「云端库未做任何过滤」，证明代码层只按 body.userId 查
  mocks.resetDbState({
    getData: () => ([
      { userId: 'attacker-999', type: 'bill', amount: 999, deleted: false },
      { userId: 'user-legit', type: 'bill', amount: 50, deleted: false },
    ]),
  });
  // 第1轮：模型返回带他人 userId 的 tool_calls；第2轮：返回综合 content
  mocks.resetHttpsState({
    responses: [
      mocks.respToolCalls([{
        id: 'c1', type: 'function',
        function: { name: 'query_bills', arguments: JSON.stringify({ userId: 'attacker-999', category: '餐饮' }) },
      }]),
      mocks.respContent('已查到你的餐饮账单。'),
    ],
  });

  process.env.AGENT_ENABLED = 'true';
  const { handleAgent } = require('../agentHandler.js');
  const provider = { endpoint: 'https://example.com/v1/chat/completions', model: 'test-model' };
  const body = { mode: 'agent', text: '查我的账单', userId: 'user-legit' };
  const chatFallback = async () => ({ ok: true, reply: 'CHAT_FALLBACK' });

  const res = await handleAgent(provider, body, 'test-key', chatFallback);

  // 未降级：返回的是 agent 直接给的 content，而不是 CHAT_FALLBACK
  assert.notEqual(res.reply, 'CHAT_FALLBACK', '不应降级到 handleChat');
  assert.equal(res.reply, '已查到你的餐饮账单。');

  // 关键：实际传给工具的 where 中 userId 被服务端强制覆盖为 body.userId
  const lastWhere = mocks.dbState.whereArgs[mocks.dbState.whereArgs.length - 1];
  assert.equal(lastWhere.userId, 'user-legit', 'userId 应被服务端覆盖为 body.userId');
  assert.notEqual(lastWhere.userId, 'attacker-999', '绝不允许越权查询他人 userId');
  for (const w of mocks.dbState.whereArgs) {
    assert.notEqual(w.userId, 'attacker-999', 'where 中出现越权 userId');
  }
  // 同时确认整条链路仍是只读
  assert.equal(mocks.dbState.add + mocks.dbState.update + mocks.dbState.set + mocks.dbState.remove + mocks.dbState.docUpdate, 0, '整条链路不得有写入');
});
