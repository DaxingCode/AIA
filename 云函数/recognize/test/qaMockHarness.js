// qaMockHarness.js
// ---------------------------------------------------------------------------
// 独立回归测试用的 mock 工具：
//   1) 拦截 require('@cloudbase/node-sdk')，返回一个「可变 holder」驱动的假数据库，
//      使得 agentTools.getDB() 缓存的 DB 句柄在查询时仍读取最新数据（v1 坑：用 holder 而非固定引用）。
//   2) 拦截 https.request，按测试场景返回不同的模型响应（tool_calls / content / 视觉 JSON），
//      零额度消耗，并完整记录请求体与调用链。
// ---------------------------------------------------------------------------
'use strict';

const Module = require('module');
const https = require('https');

// ============================== 数据库 mock ==============================
const dbState = {
  data: [],                                   // 当前集合数据（可变）
  calls: [],                                  // 记录 where / limit / get 调用
  getResults: [],                             // 每次 get() 返回后的过滤结果（用于越权校验）
  writes: { add: 0, update: 0, set: 0, remove: 0 },
  getError: null,                             // 若设置，fake .get() 抛错（模拟 DB 异常）
};

function resetDbState(data = []) {
  dbState.data = data;
  dbState.calls = [];
  dbState.getResults = [];
  dbState.writes = { add: 0, update: 0, set: 0, remove: 0 };
  dbState.getError = null;
}

// 按 where 子句过滤记录（支持 userId/type/deleted 等值与 updatedAt 的 gte/lte/and 命令）
function matchWhere(rec, where) {
  if (!where || typeof where !== 'object') return true;
  for (const key of Object.keys(where)) {
    const val = where[key];
    if (key === 'updatedAt') {
      if (val && typeof val === 'object') {
        if (val.__op === 'gte' && !(rec.updatedAt >= val.v)) return false;
        if (val.__op === 'lte' && !(rec.updatedAt <= val.v)) return false;
        if (val.__op === 'and' && Array.isArray(val.a)) {
          for (const part of val.a) {
            if (part.__op === 'gte' && !(rec.updatedAt >= part.v)) return false;
            if (part.__op === 'lte' && !(rec.updatedAt <= part.v)) return false;
          }
        }
      }
      continue;
    }
    if (rec[key] !== val) return false;
  }
  return true;
}

function makeFakeDB() {
  const collectionApi = (collectionName) => ({
    where(whereClause) {
      dbState.calls.push({ op: 'where', collection: collectionName, where: whereClause });
      const query = {
        limit(limitVal) {
          dbState.calls.push({ op: 'limit', limit: limitVal });
          return {
            async get() {
              dbState.calls.push({ op: 'get' });
              if (dbState.getError) {
                const e = typeof dbState.getError === 'string'
                  ? new Error(dbState.getError)
                  : dbState.getError;
                throw e;
              }
              const filtered = dbState.data.filter((rec) => matchWhere(rec, whereClause));
              dbState.getResults.push(filtered);
              return { data: filtered };
            },
          };
        },
      };
      // 写操作：只读代码绝不应到达；一旦到达则累加计数（测试据此断言为 0）。
      query.add = () => { dbState.writes.add++; return Promise.resolve({ id: 'x' }); };
      query.update = () => { dbState.writes.update++; return Promise.resolve({}); };
      query.set = () => { dbState.writes.set++; return Promise.resolve({}); };
      query.remove = () => { dbState.writes.remove++; return Promise.resolve({}); };
      query.doc = () => ({
        update: () => { dbState.writes.update++; return Promise.resolve({}); },
        set: () => { dbState.writes.set++; return Promise.resolve({}); },
        remove: () => { dbState.writes.remove++; return Promise.resolve({}); },
      });
      return query;
    },
  });
  return {
    command: {
      gte: (v) => ({ __op: 'gte', v }),
      lte: (v) => ({ __op: 'lte', v }),
      and: (...args) => ({ __op: 'and', a: args }),
    },
    collection: collectionApi,
  };
}

let cloudbaseInstalled = false;
function installMocks() {
  if (!cloudbaseInstalled) {
    const fakeCloudbase = { init: () => ({ database: () => makeFakeDB() }) };
    const originalLoad = Module._load;
    Module._load = function (request, parent, isMain) {
      if (request === '@cloudbase/node-sdk') return fakeCloudbase;
      // eslint-disable-next-line prefer-rest-params
      return originalLoad.apply(this, arguments);
    };
    cloudbaseInstalled = true;
  }
  installHttpsMock();
}

// ============================== https mock ==============================
const httpState = {
  requestLog: [],        // 每次模型请求的 { opts, bodyStr }
  responseQueue: [],     // 依次出队的响应（字符串或 fn(bodyStr)=>string）
  defaultResponse: null, // 队空时使用的默认响应
};

function resetHttpState() {
  httpState.requestLog = [];
  httpState.responseQueue = [];
  httpState.defaultResponse = null;
}

// 构造 OpenAI 兼容的模型响应体
function makeModelResponse({ content = '', toolCalls = [] }) {
  return JSON.stringify({
    choices: [{ message: { content, tool_calls: toolCalls } }],
  });
}

// toolCalls: [{ name, args }]  -> 带 function-calling 的响应
function toolCallsBody(toolCalls) {
  return makeModelResponse({
    content: '',
    toolCalls: toolCalls.map((tc, i) => ({
      id: 'call_' + i,
      type: 'function',
      function: { name: tc.name, arguments: JSON.stringify(tc.args || {}) },
    })),
  });
}

// 纯文本回复（chat / agent 无 tool_calls 路径）
function contentBody(text) {
  return makeModelResponse({ content: text, toolCalls: [] });
}

// 视觉识别：content 内嵌 JSON（被 extractJSON 解析）
function visionBody(obj) {
  return makeModelResponse({ content: JSON.stringify(obj), toolCalls: [] });
}

let httpsInstalled = false;
function installHttpsMock() {
  if (httpsInstalled) return;
  https.request = function (opts, cb) {
    let captured = '';
    const req = {
      write: (chunk) => { captured += chunk; },
      end: () => {
        const entry = { opts, bodyStr: captured };
        httpState.requestLog.push(entry);
        const provider = httpState.responseQueue.shift() || httpState.defaultResponse;
        let body;
        if (provider) {
          body = typeof provider === 'function' ? provider(captured) : provider;
        } else {
          body = contentBody('默认兜底回复');
        }
        const res = {
          statusCode: 200,
          on: (event, handler) => {
            if (event === 'data') process.nextTick(() => handler(Buffer.from(body)));
            else if (event === 'end') process.nextTick(() => handler());
          },
        };
        process.nextTick(() => { if (cb) cb(res); });
      },
      // 仅记录 error 处理器，绝不触发
      on: (event, handler) => { if (event === 'error') req._err = handler; },
    };
    return req;
  };
  httpsInstalled = true;
}

module.exports = {
  installMocks,
  resetDbState,
  resetHttpState,
  dbState,
  httpState,
  toolCallsBody,
  contentBody,
  visionBody,
  pushResponse: (bodyOrFn) => httpState.responseQueue.push(bodyOrFn),
  setDefaultResponse: (bodyOrFn) => { httpState.defaultResponse = bodyOrFn; },
  setDbGetError: (e) => { dbState.getError = e; },
};
