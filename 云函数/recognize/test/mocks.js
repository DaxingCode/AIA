'use strict';
// 共享 mock 基础设施（零额度、零真实网络）：
// 1) 拦截 require('@cloudbase/node-sdk')，返回只读数据库 mock，统计所有写操作。
// 2) 拦截 https.request，按场景队列返回模型响应（tool_calls / content / vision JSON）。
const Module = require('module');
const https = require('https');
const { EventEmitter } = require('events');

// ---------------------------------------------------------------------------
// CloudBase 数据库 mock：链式 where().limit().get()，并统计写入调用
// ---------------------------------------------------------------------------
const dbState = {
  whereArgs: [],          // 每次 .where(cond) 的 cond 快照（用于断言 userId+deleted:false）
  add: 0,
  update: 0,
  set: 0,
  remove: 0,
  docUpdate: 0,
  getData: () => [],      // 可配置：返回给 .get() 的数据
  getError: null,         // 可配置：若设置，.get() 抛错（模拟 DB/工具异常 → 降级）
};

const dbChain = {
  where(cond) {
    dbState.whereArgs.push(cond);
    return dbChain;
  },
  limit() {
    return dbChain;
  },
  get() {
    if (dbState.getError) return Promise.reject(new Error(dbState.getError));
    return Promise.resolve({ data: dbState.getData() });
  },
  // 以下均为「写入」操作；一旦被调用会被计数（只读铁律校验）
  add() { dbState.add++; return Promise.resolve({ id: 'x' }); },
  update() { dbState.update++; return Promise.resolve({}); },
  set() { dbState.set++; return Promise.resolve({}); },
  remove() { dbState.remove++; return Promise.resolve({}); },
  doc() {
    return {
      update() { dbState.docUpdate++; return Promise.resolve({}); },
      set() { dbState.set++; return Promise.resolve({}); },
      remove() { dbState.remove++; return Promise.resolve({}); },
    };
  },
};

const dbMock = {
  command: {
    gte: (v) => ({ $gte: v }),
    lte: (v) => ({ $lte: v }),
    and: (...a) => ({ $and: a }),
  },
  collection() { return dbChain; },
};

const fakeCloudbase = { init: () => ({ database: () => dbMock }) };

let _origLoad = null;
function installCloudbaseMock() {
  if (_origLoad) return;
  _origLoad = Module._load;
  Module._load = function (request, parent, isMain) {
    if (request === '@cloudbase/node-sdk') return fakeCloudbase;
    return _origLoad.apply(this, arguments);
  };
}
function uninstallCloudbaseMock() {
  if (_origLoad) { Module._load = _origLoad; _origLoad = null; }
}
function resetDbState(opts = {}) {
  dbState.whereArgs = [];
  dbState.add = 0;
  dbState.update = 0;
  dbState.set = 0;
  dbState.remove = 0;
  dbState.docUpdate = 0;
  dbState.getData = opts.getData || (() => []);
  dbState.getError = opts.getError || null;
}

// ---------------------------------------------------------------------------
// https.request mock：按队列返回模型响应
// ---------------------------------------------------------------------------
const httpsState = {
  responses: [],        // 数组：(parsedBody) => string
  defaultResponder: null,
  reqBodies: [],        // 捕获的（已解析）请求体，用于断言 tools 是否存在
  callCount: 0,
};

let _origHttpsRequest = null;
function installHttpsMock() {
  if (_origHttpsRequest) return;
  _origHttpsRequest = https.request;
  https.request = function (options, callback) {
    const chunks = [];
    const req = {
      on() {},
      write(c) { chunks.push(typeof c === 'string' ? c : c.toString()); },
      end() {
        const raw = chunks.join('');
        let parsed = null;
        try { parsed = JSON.parse(raw); } catch (e) { parsed = raw; }
        httpsState.reqBodies.push(parsed);
        const responder = httpsState.responses[httpsState.callCount] || httpsState.defaultResponder;
        httpsState.callCount++;
        const bodyStr = responder ? responder(parsed) : '{}';
        const res = new EventEmitter();
        res.statusCode = 200;
        process.nextTick(() => {
          callback(res);
          res.emit('data', bodyStr);
          res.emit('end');
        });
      },
    };
    return req;
  };
}
function uninstallHttpsMock() {
  if (_origHttpsRequest) { https.request = _origHttpsRequest; _origHttpsRequest = null; }
}
function resetHttpsState(opts = {}) {
  httpsState.responses = opts.responses || [];
  httpsState.defaultResponder = opts.defaultResponder || null;
  httpsState.reqBodies = [];
  httpsState.callCount = 0;
}

// ---------------------------------------------------------------------------
// 响应构造器
// ---------------------------------------------------------------------------
function respContent(content) {
  return () => JSON.stringify({ choices: [{ message: { role: 'assistant', content, tool_calls: [] } }] });
}
function respToolCalls(toolCalls) {
  return () => JSON.stringify({ choices: [{ message: { role: 'assistant', content: '', tool_calls: toolCalls } }] });
}
function respVision(jsonObj) {
  return () => JSON.stringify({ choices: [{ message: { role: 'assistant', content: JSON.stringify(jsonObj) } }] });
}

module.exports = {
  dbState, dbMock,
  installCloudbaseMock, uninstallCloudbaseMock, resetDbState,
  httpsState, installHttpsMock, uninstallHttpsMock, resetHttpsState,
  respContent, respToolCalls, respVision,
};
