'use strict';
// 验证清单 3（降级铁律4种 + 未知工具）、4（开关双保险）、5（ack 拦截豁免）、
// 6（视觉链路不动）、7（向后兼容）。全部通过 mock exports.main 驱动，零额度。
const test = require('node:test');
const assert = require('node:assert/strict');
const mocks = require('./mocks');

const PROVIDER = 'qwen'; // 固定走 qwen，避免触发 fallback，保证单次模型调用

function makeMain() {
  return require('../index.js').main;
}

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

// ---------------------- 验证清单 4：开关双保险（index.js 层）----------------------
test('[开关] AGENT_ENABLED!=true 时 mode=agent 回落 handleChat', async () => {
  mocks.resetHttpsState({ responses: [mocks.respContent('普通聊天回复')] });
  delete process.env.AGENT_ENABLED;
  const res = await makeMain()({ provider: PROVIDER, mode: 'agent', text: '你好', userId: 'u1' });
  assert.equal(mocks.httpsState.callCount, 1, '应有且仅 1 次模型调用');
  assert.ok(!mocks.httpsState.reqBodies[0].tools, '未开启时请求体不应含 tools（走 handleChat）');
  assert.equal(res.ok, true);
  assert.equal(res.reply, '普通聊天回复');
});

test('[开关] AGENT_ENABLED=true 时 mode=agent 进入 handleAgent', async () => {
  mocks.resetHttpsState({ responses: [mocks.respContent('agent 回复')] });
  process.env.AGENT_ENABLED = 'true';
  const res = await makeMain()({ provider: PROVIDER, mode: 'agent', text: '查账单', userId: 'u1' });
  assert.equal(mocks.httpsState.callCount, 1, '应有且仅 1 次模型调用');
  assert.ok(Array.isArray(mocks.httpsState.reqBodies[0].tools), '开启时应进入 handleAgent，请求体应含 tools');
  assert.equal(res.reply, 'agent 回复');
});

// ---------------------- 验证清单 5：ack 拦截豁免 ----------------------
test('[ack豁免] mode=agent + 通用应答「好的」不被拦截，进入 agent 分支', async () => {
  mocks.resetHttpsState({ responses: [mocks.respContent('好的，已为你查询')] });
  process.env.AGENT_ENABLED = 'true';
  const res = await makeMain()({ provider: PROVIDER, mode: 'agent', text: '好的', userId: 'u1' });
  assert.ok(mocks.httpsState.callCount >= 1, '应发生模型调用（未被 ack 拦截）');
  assert.ok(Array.isArray(mocks.httpsState.reqBodies[0].tools), '应进入 agent 分支（请求体含 tools）');
  assert.equal(res.reply, '好的，已为你查询');
});

test('[ack对照] 非 agent/chat 模式 + 通用应答「好的」被拦截返回 none（证明豁免仅限 agent）', async () => {
  // 无 mode、无 imageBase64 → 命中 L374 通用 ack 拦截，直接返回 none，不调模型
  const res = await makeMain()({ provider: PROVIDER, text: '好的' });
  assert.equal(mocks.httpsState.callCount, 0, '应被 ack 拦截，无任何模型调用');
  assert.deepEqual(res.result, { types: ['none'] });
  assert.equal(res.ok, true);
});

// ---------------------- 验证清单 6：视觉链路不动 ----------------------
test('[视觉链路] imageBase64 存在（无 mode）走 callWithFallback，不进 agent', async () => {
  mocks.resetHttpsState({ responses: [mocks.respVision({ types: ['bill'], confidence: 0.9, bill: { merchant: 'x', amount: 10 } })] });
  const res = await makeMain()({ provider: PROVIDER, imageBase64: 'AAAA', userId: 'u1' });
  assert.equal(mocks.httpsState.callCount, 1, '视觉识别应有 1 次模型调用');
  assert.ok(!mocks.httpsState.reqBodies[0].tools, '视觉识别请求体不应含 tools（不进 agent）');
  assert.deepEqual(res.result.types, ['bill']);
});

// ---------------------- 验证清单 7：向后兼容 ----------------------
test('[兼容] mode=chat 走 handleChat，与 agent 无关', async () => {
  mocks.resetHttpsState({ responses: [mocks.respContent('聊天回复')] });
  const res = await makeMain()({ provider: PROVIDER, mode: 'chat', text: '今天天气', userId: 'u1' });
  assert.equal(mocks.httpsState.callCount, 1, '应有且仅 1 次模型调用');
  assert.ok(!mocks.httpsState.reqBodies[0].tools, 'chat 模式请求体不应含 tools');
  assert.equal(res.reply, '聊天回复');
});

// ---------------------- 验证清单 3：降级铁律（4 种）----------------------
test('[降级-a] userId 缺失 → handleChat', async () => {
  mocks.resetHttpsState({ responses: [mocks.respContent('未登录兜底回复')] });
  process.env.AGENT_ENABLED = 'true';
  const res = await makeMain()({ provider: PROVIDER, mode: 'agent', text: '查账单' }); // 无 userId
  assert.equal(mocks.httpsState.callCount, 1, '应有且仅 1 次调用');
  assert.ok(!mocks.httpsState.reqBodies[0].tools, 'userId 缺失应降级 handleChat（无 tools）');
  assert.equal(res.reply, '未登录兜底回复');
});

test('[降级-b] 工具/DB 抛异常 → handleChat', async () => {
  mocks.resetDbState({ getError: 'DB boom' }); // .get() 抛错模拟工具/DB 异常
  mocks.resetHttpsState({
    responses: [
      mocks.respToolCalls([{ id: 'c1', type: 'function', function: { name: 'query_bills', arguments: '{}' } }]),
      mocks.respContent('异常已降级到聊天'),
    ],
  });
  process.env.AGENT_ENABLED = 'true';
  const res = await makeMain()({ provider: PROVIDER, mode: 'agent', text: '查账单', userId: 'u1' });
  assert.equal(mocks.httpsState.callCount, 2, '应：1 次 agent + 1 次降级 handleChat');
  assert.ok(Array.isArray(mocks.httpsState.reqBodies[0].tools), '第 1 次应为 agent（含 tools）');
  assert.ok(!mocks.httpsState.reqBodies[1].tools, '第 2 次应为降级 handleChat（无 tools）');
  assert.equal(res.reply, '异常已降级到聊天');
});

test('[降级-c] 连续 5 轮均返回 tool_calls → 超轮降级 handleChat', async () => {
  mocks.resetDbState();
  const tc = mocks.respToolCalls([{ id: 'c', type: 'function', function: { name: 'query_bills', arguments: '{}' } }]);
  mocks.resetHttpsState({
    responses: [tc, tc, tc, tc, tc, mocks.respContent('超轮降级回复')], // 5 轮 agent + 1 次降级
  });
  process.env.AGENT_ENABLED = 'true';
  const res = await makeMain()({ provider: PROVIDER, mode: 'agent', text: '查很多', userId: 'u1' });
  assert.equal(mocks.httpsState.callCount, 6, '应：5 轮 agent + 1 次降级');
  for (let i = 0; i < 5; i++) {
    assert.ok(Array.isArray(mocks.httpsState.reqBodies[i].tools), `第 ${i + 1} 轮应为 agent`);
  }
  assert.ok(!mocks.httpsState.reqBodies[5].tools, '第 6 次应为降级 handleChat（无 tools）');
  assert.equal(res.reply, '超轮降级回复');
});

test('[降级-d] 首轮返回 content 无 tool_calls → 直接返回，不降级', async () => {
  mocks.resetHttpsState({ responses: [mocks.respContent('直接回复')] });
  process.env.AGENT_ENABLED = 'true';
  const res = await makeMain()({ provider: PROVIDER, mode: 'agent', text: '你好', userId: 'u1' });
  assert.equal(mocks.httpsState.callCount, 1, '应仅 1 次调用，无降级');
  assert.equal(res.reply, '直接回复');
});

// ---------------------- 验证清单 3：未知工具名 → 报错但不降级 ----------------------
test('[未知工具] 返回错误但不降级，最终由模型综合作答', async () => {
  mocks.resetHttpsState({
    responses: [
      mocks.respToolCalls([{ id: 'cx', type: 'function', function: { name: 'delete_everything', arguments: '{}' } }]),
      mocks.respContent('我知道了，没有可用工具，口头回答'),
    ],
  });
  process.env.AGENT_ENABLED = 'true';
  const res = await makeMain()({ provider: PROVIDER, mode: 'agent', text: '删掉所有', userId: 'u1' });
  // 两次调用都应是 agent（含 tools），绝不降级到 handleChat
  assert.equal(mocks.httpsState.callCount, 2, '应 2 次 agent 调用，无降级');
  assert.ok(Array.isArray(mocks.httpsState.reqBodies[0].tools), '第 1 次应为 agent');
  assert.ok(Array.isArray(mocks.httpsState.reqBodies[1].tools), '未知工具后应继续 agent，不应降级');
  // 第 2 次请求的 messages 中应包含「未知工具」错误信息（证明报错但不降级）
  const msgs = mocks.httpsState.reqBodies[1].messages || [];
  const toolMsg = msgs.find((m) => m.role === 'tool' && /未知工具/.test(m.content));
  assert.ok(toolMsg, '应将「未知工具」错误回传给模型');
  assert.equal(res.reply, '我知道了，没有可用工具，口头回答');
});
