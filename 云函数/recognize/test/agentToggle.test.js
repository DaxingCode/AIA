// agentToggle.test.js
// ---------------------------------------------------------------------------
// 验证点 3（降级铁律 4 场景 + 未知工具不降级，走 handleAgent 直接验证）
// 与 验证点 4/5/6/7（开关双保险 / ack 豁免 / 视觉链路 / 向后兼容，走 index.main）。
//
// 重要：index.js 在当前源码存在致命 bug（见测试末「源码缺陷」标记），require 即抛错，
// 因此验证点 4/5/6/7 的用例会在加载 index.js 时失败 —— 这本身就是 blocker 的证据。
// 验证点 3 走 handleAgent（不依赖 index.js），可独立运行。
// ---------------------------------------------------------------------------
'use strict';

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

const {
  installMocks, resetDbState, resetHttpState, dbState, httpState,
  toolCallsBody, contentBody, visionBody,
  pushResponse, setDefaultResponse, setDbGetError,
} = require('./qaMockHarness');

installMocks();
resetDbState();
resetHttpState();

// 提供所有可能的 API Key 环境变量，避免 main 因缺 key 提前返回
process.env.SENSENOVA_API_KEY = 'sk-sensenova';
process.env.DASHSCOPE_API_KEY = 'sk-dashscope';
process.env.SENSENOVA_TEXT_API_KEY = 'sk';
process.env.GLM_API_KEY = 'sk';
process.env.DOUBAO_API_KEY = 'sk';
process.env.QIANFAN_API_KEY = 'sk';

const agentTools = require('../agentTools');
const { handleAgent } = require('../agentHandler');

// index.js 懒加载：源码有 bug 时此处会抛错（这是 blocker 的证据）
let mainCache = null;
let mainLoadError = null;
function getMain() {
  if (mainCache === null && mainLoadError === null) {
    try {
      mainCache = require('../index').main;
    } catch (e) {
      mainLoadError = e;
    }
  }
  if (mainLoadError) throw mainLoadError;
  return mainCache;
}

beforeEach(() => {
  resetDbState();
  resetHttpState();
  delete process.env.AGENT_ENABLED;
});

// ====================== 验证点 3：降级铁律（handleAgent 直接验证） ======================
function makeChatSpy() {
  const state = { called: 0 };
  const fn = async () => { state.called++; return { ok: true, reply: 'CHAT_FALLBACK' }; };
  fn.state = state;
  return fn;
}

test('降级(a)：body.userId 为空 → 回落 handleChat，且不调模型', async () => {
  const chat = makeChatSpy();
  const out = await handleAgent(
    { model: 'm', endpoint: 'https://x' },
    { mode: 'agent', text: '你好' }, // 无 userId
    'sk', chat
  );
  assert.equal(chat.state.called, 1, 'handleChat 应被调用一次');
  assert.equal(out.reply, 'CHAT_FALLBACK');
  assert.equal(httpState.requestLog.length, 0, '无 userId 时不应调模型');
});

test('降级(b)：工具执行抛异常(mock DB.get 抛错) → 回落 handleChat', async () => {
  setDbGetError(new Error('DB 连接失败'));
  pushResponse(toolCallsBody([{ name: 'query_bills', args: {} }]));
  const chat = makeChatSpy();
  const out = await handleAgent(
    { model: 'm', endpoint: 'https://x' },
    { mode: 'agent', text: '查账单', userId: 'u1' },
    'sk', chat
  );
  assert.equal(chat.state.called, 1, '异常应回落 handleChat');
  assert.equal(out.reply, 'CHAT_FALLBACK');
});

test('降级(c)：连续 5 轮都返回 tool_calls 不收敛 → 超轮回落 handleChat', async () => {
  for (let i = 0; i < 5; i++) {
    pushResponse(toolCallsBody([{ name: 'query_bills', args: {} }]));
  }
  const chat = makeChatSpy();
  const out = await handleAgent(
    { model: 'm', endpoint: 'https://x' },
    { mode: 'agent', text: '查账单', userId: 'u1' },
    'sk', chat
  );
  assert.equal(chat.state.called, 1, '超过 5 轮应回落 handleChat');
  assert.equal(out.reply, 'CHAT_FALLBACK');
  assert.equal(httpState.requestLog.length, 5, '应恰好发生 5 轮工具调用');
});

test('非降级(d)：首轮即返回 content 无 tool_calls → 直接返回该 content（不降级）', async () => {
  pushResponse(contentBody('直接给的回复'));
  const chat = makeChatSpy();
  const out = await handleAgent(
    { model: 'm', endpoint: 'https://x' },
    { mode: 'agent', text: '你好', userId: 'u1' },
    'sk', chat
  );
  assert.equal(chat.state.called, 0, '有 content 不应降级');
  assert.equal(out.reply, '直接给的回复');
});

test('未知工具：返回错误结果但不降级（保持只读安全，不触发任何写操作）', async () => {
  pushResponse(toolCallsBody([{ name: 'delete_everything', args: { userId: 'x' } }]));
  pushResponse(contentBody('这个工具我暂时用不了，但其他查询可以帮你'));
  const chat = makeChatSpy();
  const out = await handleAgent(
    { model: 'm', endpoint: 'https://x' },
    { mode: 'agent', text: '删掉所有', userId: 'u1' },
    'sk', chat
  );
  assert.equal(chat.state.called, 0, '未知工具不应降级到 handleChat');
  assert.ok(out.reply.includes('其他查询可以帮你'));
  assert.deepEqual(
    dbState.writes, { add: 0, update: 0, set: 0, remove: 0 },
    '未知工具也不应触发任何写操作'
  );
});

// ====================== 验证点 4/5/6/7：index.main 层（被源码 bug 阻塞） ======================
async function expectIndexLoads() {
  // index.js 当前无法加载；调用 getMain() 会抛错。这里显式暴露 blocker。
  getMain();
}

test('【源码缺陷阻塞】开关(关)：mode=agent 且 AGENT_ENABLED!=true → 走 handleChat', async () => {
  await expectIndexLoads();
  delete process.env.AGENT_ENABLED;
  pushResponse(contentBody('普通聊天回复'));
  const res = await getMain()({ body: JSON.stringify({ mode: 'agent', text: '你好', userId: 'u1', context: {} }) });
  assert.equal(res.ok, true);
  assert.equal(res.reply, '普通聊天回复');
  assert.equal(httpState.requestLog.length, 1);
  const body = JSON.parse(httpState.requestLog[0].bodyStr);
  assert.equal(body.tools, undefined);
  assert.equal(body.tool_choice, undefined);
});

test('【源码缺陷阻塞】开关(开)：mode=agent 且 AGENT_ENABLED=true → 进入 handleAgent', async () => {
  await expectIndexLoads();
  process.env.AGENT_ENABLED = 'true';
  pushResponse(contentBody('agent 回复'));
  const res = await getMain()({ body: JSON.stringify({ mode: 'agent', text: '你好', userId: 'u1' }) });
  assert.equal(res.ok, true);
  assert.equal(res.reply, 'agent 回复');
  const body = JSON.parse(httpState.requestLog[0].bodyStr);
  assert.ok(Array.isArray(body.tools));
  assert.equal(body.tool_choice, 'auto');
});

test('【源码缺陷阻塞】ack 豁免：mode=agent + 通用应答"好的" → 进入 agent 分支', async () => {
  await expectIndexLoads();
  process.env.AGENT_ENABLED = 'true';
  pushResponse(contentBody('agent 处理了的回复'));
  const res = await getMain()({ body: JSON.stringify({ mode: 'agent', text: '好的', userId: 'u1' }) });
  assert.equal(res.ok, true);
  assert.equal(res.reply, 'agent 处理了的回复');
  assert.equal(httpState.requestLog.length, 1);
  const body = JSON.parse(httpState.requestLog[0].bodyStr);
  assert.ok(Array.isArray(body.tools));
});

test('【源码缺陷阻塞】视觉链路：imageBase64 存在(无 mode) → 走 callWithFallback', async () => {
  await expectIndexLoads();
  delete process.env.AGENT_ENABLED;
  pushResponse(visionBody({ types: ['bill'], confidence: 0.9 }));
  const res = await getMain()({ body: JSON.stringify({ imageBase64: 'base64data', userId: 'u1' }) });
  assert.equal(res.ok, true);
  assert.ok(res.result.types.includes('bill'));
  const body = JSON.parse(httpState.requestLog[0].bodyStr);
  assert.equal(body.tools, undefined);
  assert.ok(body.response_format);
});

test('【源码缺陷阻塞】向后兼容：mode=chat → 走 handleChat', async () => {
  await expectIndexLoads();
  delete process.env.AGENT_ENABLED;
  pushResponse(contentBody('chat 回复'));
  const res = await getMain()({ body: JSON.stringify({ mode: 'chat', text: '你好', userId: 'u1', context: {} }) });
  assert.equal(res.ok, true);
  assert.equal(res.reply, 'chat 回复');
  const body = JSON.parse(httpState.requestLog[0].bodyStr);
  assert.equal(body.tools, undefined);
});
