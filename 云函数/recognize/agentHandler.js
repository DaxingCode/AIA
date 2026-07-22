// agentHandler.js
// Agent 模式处理：多轮 function-calling，只读查询用户记录后综合作答。
// 关键：本文件不 require('./index')，避免循环依赖；handleChat 由 index.js 作为第 4 参数传入。
const https = require('https');
const { TOOL_SCHEMAS } = require('./agentSchema');
const { AGENT_SYSTEM_PROMPT } = require('./agentPrompt');
const TOOLS = require('./agentTools');

const TOOL_FUNCS = {
  query_bills: TOOLS.query_bills,
  query_foods: TOOLS.query_foods,
  query_health: TOOLS.query_health,
  get_summary: TOOLS.get_summary,
};

// 调用支持 function-calling 的文本模型（OpenAI 兼容格式）。
// 返回 { content, tool_calls }；tool_calls 为数组，每项 { id, function:{ name, arguments(JSON 字符串) } }。
function callWithTools(provider, messages, apiKey) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model: provider.model,
      messages,
      tools: TOOL_SCHEMAS,
      tool_choice: 'auto',
      temperature: 0.7,
    });

    const u = new URL(provider.endpoint);
    const req = https.request(
      {
        method: 'POST',
        hostname: u.hostname,
        path: u.pathname + u.search,
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${apiKey}`,
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            const message = json.choices && json.choices[0] ? json.choices[0].message : {};
            resolve({
              content: message.content || '',
              tool_calls: Array.isArray(message.tool_calls) ? message.tool_calls : [],
            });
          } catch (e) {
            reject(new Error('解析模型返回失败: ' + e.message));
          }
        });
      }
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// Agent 主流程：最多 5 轮。无 userId / 无 tool_calls / 异常 均降级到 handleChat。
async function handleAgent(provider, body, apiKey, handleChat) {
  const userId = body.userId;
  if (!userId) {
    // 未登录（无 userId）：按「userId 缺失」规则回落 handleChat（只读无数据）。
    return await handleChat(provider, body, apiKey);
  }

  const now = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
  const messages = [
    { role: 'system', content: AGENT_SYSTEM_PROMPT.replace('{CURRENT_TIME}', now) },
  ];
  // context 透传：把本地数据摘要带进去，帮助模型理解上下文（降级时也透传给 handleChat）。
  if (body.context) {
    messages.push({ role: 'user', content: '本地数据摘要：' + JSON.stringify(body.context) });
  }
  messages.push({ role: 'user', content: body.text });

  try {
    for (let round = 0; round < 5; round++) {
      const { content, tool_calls } = await callWithTools(provider, messages, apiKey);

      if (tool_calls && tool_calls.length > 0) {
        // 把助手的工具调用原样回写，供下一轮模型综合工具结果。
        messages.push({ role: 'assistant', content: content || '', tool_calls });
        for (const tc of tool_calls) {
          const name = tc.function && tc.function.name;
          let args = {};
          try {
            args = JSON.parse((tc.function && tc.function.arguments) || '{}');
          } catch (e) {
            args = {};
          }
          // 服务端强制覆盖 userId，防止模型越权查询他人数据。
          args.userId = userId;
          const known = TOOL_FUNCS[name];
          let result;
          if (!known) {
            // 未知工具：报错但不降级，让模型知道并自行纠正。
            result = { code: -1, message: '未知工具: ' + name };
          } else {
            result = await known(args);
          }
          messages.push({ role: 'tool', tool_call_id: tc.id, content: JSON.stringify(result) });
        }
        // 继续下一轮，让模型综合工具结果。
        continue;
      }

      // 无 tool_calls：有 content 则作为最终回复。
      if (content) {
        return { ok: true, reply: content };
      }
      break;
    }
    // 超过 5 轮或无最终 content：降级到普通 chat。
    return await handleChat(provider, body, apiKey);
  } catch (e) {
    // 工具/DB/网络异常：降级到普通 chat。
    console.error('[handleAgent] 异常，降级 handleChat:', e && e.message);
    return await handleChat(provider, body, apiKey);
  }
}

module.exports = { handleAgent, callWithTools };
