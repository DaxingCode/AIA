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
  query_reminders: TOOLS.query_reminders,
  get_summary: TOOLS.get_summary,
  create_bill: TOOLS.create_bill,
  create_food: TOOLS.create_food,
  create_todo: TOOLS.create_todo,
  create_health: TOOLS.create_health,
  delete_bill: TOOLS.delete_bill,
  delete_food: TOOLS.delete_food,
  delete_todo: TOOLS.delete_todo,
  delete_health: TOOLS.delete_health,
  complete_todo: TOOLS.complete_todo,
  undo_last: TOOLS.undo_last,
  set_merchant: TOOLS.set_merchant,
  list_merchants: TOOLS.list_merchants,
  delete_merchant: TOOLS.delete_merchant,
  list_recognitions: TOOLS.list_recognitions,
  delete_recognition: TOOLS.delete_recognition,
  search_all: TOOLS.search_all,
  get_report: TOOLS.get_report,
  complete_all_todos: TOOLS.complete_all_todos,
  delete_by_merchant: TOOLS.delete_by_merchant,
  teach_abao: TOOLS.teach_abao,
  list_teachings: TOOLS.list_teachings,
  recall_teachings: TOOLS.recall_teachings,
  create_water: TOOLS.create_water,
  delete_water: TOOLS.delete_water,
  list_waters: TOOLS.list_waters,
  create_recurring: TOOLS.create_recurring,
  list_recurring: TOOLS.list_recurring,
  delete_recurring: TOOLS.delete_recurring,
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
            const tcs = Array.isArray(message.tool_calls) ? message.tool_calls : [];
            console.log('[agent] <- content="' + (message.content || '').slice(0, 80) + '" tool_calls=' + tcs.length);
            resolve({
              content: message.content || '',
              tool_calls: tcs,
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

  // 拉取"用户教过阿记的规则"，注入提示词（让阿记每轮都"记得"并按其行事）。
  let learnedText = '（暂无，用户还没教过我什么）';
  try {
    const rules = await TOOLS.getLearnedRulesForPrompt(userId, 30);
    if (rules && rules.length) {
      learnedText = rules.map((r, i) => `${i + 1}. 【${r.topic}】${r.rule}`).join('\n');
    }
  } catch (e) {
    learnedText = '（读取已学规则失败）';
  }

  const messages = [
    { role: 'system', content: AGENT_SYSTEM_PROMPT.replace('{CURRENT_TIME}', now).replace('{LEARNED_RULES}', learnedText) },
  ];
  // context 透传：把本地数据摘要带进去，帮助模型理解上下文（降级时也透传给 handleChat）。
  if (body.context) {
    messages.push({ role: 'user', content: '本地数据摘要：' + JSON.stringify(body.context) });
  }
  messages.push({ role: 'user', content: body.text });
  // 【多步推理】注入思维步骤引导：让模型在每轮工具选前先想一想用户意图，避免跳过工具直接回文字。
  messages.push({
    role: 'system',
    content: '【思维步骤】接下来如果需要工具：先想想用户是「查」还是「记」，选对工具类别。如果工具返回空数据（如"未找到"），试试换一个工具或关键词再查。如果用户是在提问而不是下指令，不要创建新记录。'
  });

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
          // 防御纵深：若模型在参数里自带了 userId（且与会话不符），先记 warning 并剥离，
          // 任何情况下都只用请求体的 userId，杜绝跨账号操作。
          if (args.userId && args.userId !== userId) {
            console.warn('[agent] tool=' + name + ' 自带 userId 与会话不符，已强制覆盖: ' + args.userId + ' -> ' + userId);
            delete args.userId;
          }
          args.userId = userId;
          const known = TOOL_FUNCS[name];
          let result;
          if (!known) {
            // 未知工具：报错但不降级，让模型知道并自行纠正。
            result = { code: -1, message: '未知工具: ' + name };
          } else {
            result = await known(args);
          }
          console.log('[agent] tool=' + name + ' result=' + JSON.stringify(result));
          messages.push({ role: 'tool', tool_call_id: tc.id, content: JSON.stringify(result) });
          // 空结果兜底：工具返回了空数据（如 count=0 / data 为空 / "未找到"/deleted:false），
          // 追加提示让模型**如实告知用户操作未真正完成**，
          // 不要使用「已删除/已撤销/已成功」等措辞。覆盖 query + 删除类工具。
          const isQueryTool = name.startsWith('query_') || name.startsWith('list_') || name === 'search_all';
          const isDeleteTool = name.startsWith('delete_') || name === 'undo_last' || name === 'complete_all_todos' || name === 'delete_by_merchant';
          const resultStr = JSON.stringify(result);
          // 删除类工具的"失败"信号：deleted:false / found:false / count=0 / 含「未找到/没有找到」
          const deleteFailed = isDeleteTool && result && (
            (typeof result.deleted === 'boolean' && !result.deleted) ||
            (typeof result.found === 'boolean' && !result.found) ||
            (typeof result.deleted === 'number' && result.deleted === 0) ||
            (typeof result.done === 'number' && result.done === 0) ||
            resultStr.includes('未找到') ||
            resultStr.includes('没有找到')
          );
          const queryEmpty = isQueryTool && result && (
            (result.code === 0 && result.count === 0) ||
            (Array.isArray(result.data) && result.data.length === 0) ||
            resultStr.includes('未找到') ||
            resultStr.includes('没有找到')
          );
          if ((deleteFailed || queryEmpty) && round < 3) {
            const hint = deleteFailed
              ? '【关键】上面的删除/撤销/批量工具调用没有真正成功（返回了 deleted:false 或 "未找到"）。请**明确告诉用户**：相关记录没有被删掉，可能是用户本地刚建还没同步、或记录本来就不存在。**严禁使用「已删除/已撤销/帮您删掉了」等措辞**，否则就是误导。'
              : '【提示】上面查到的结果为空。如果可能的话，换个关键词、换一种查询方式（如用 search_all 跨类型搜索）、或者调整时间范围再试一次。如果确实没有数据，再如实告诉用户。';
            messages.push({
              role: 'user',
              content: hint
            });
          }
        }
        // 继续下一轮，让模型综合工具结果。
        continue;
      }

      // 无 tool_calls：先判是否是「写/改/删/查全部/生成报告意图但模型忘了调工具」的幻觉场景。
      const writeIntent = /(记(?:一?下|一笔|个|上|录)?|花了|付了|买了|记下|记上|记账|记一笔|记录|加上?|加个|加一|加个待办|提醒我|待办|提醒|删(?:除|掉|了)|去掉|撤销|撤回|改一下|修改|标记完成|完成|勾掉|商户|规则|分类|识别记录|报告|汇总|统计|搜索|查找|查一下|找一下|所有|全部|生成.*报告|分类规则|设.*规则|教|记住|记着|习惯|下次照做|怎么处理|喝水|饮水|水|周期|排程|订阅|自动扣费|自动记账|吃(?:了|掉|过)?|喝(?:了|掉|过|杯|了点)?|早餐|午餐|晚餐|加餐|宵夜|夜宵|体重|身高|心率|血压|睡眠|体脂|血糖|配置)/.test(body.text || '');
      // 加强幻觉检测：覆盖「已经帮你X了/啦」「已经X了」「已经帮我把X删掉啦」等变体
      // 其中 X 可以是各种动作的完成时（记好/上了/下/删除/删掉/去掉/撤销/撤回/标记完...）
      const hallucinatedWrite = writeIntent && (
        // 「已X」「已经X」「已经帮我X」「帮我X」（X 是动作完成时）的宽匹配
        /(?:已(?:经)?(?:帮我?|帮你|给我)?(?:把|把那|把那个)?(?:.{0,10})?(?:记(?:好|上|下)?了?|加上了?|创建了?|删(?:除|掉|了|掉啦|掉呗)?|去掉(?:了|啦)?|撤(?:销|回)了?|取消了?|更新了?|新增了?|生成了?|搜索了?|找到了?|标记完成了?|完成了?|记住了?|记着了?|学到了?|教过了?))/.test(content || '')
        // 短促确认短语
        || /(记(?:好|上|下)了|添加成功|创建成功|删除成功|去(?:掉)?了|撤回成功|已?完成|已删除|已?撤销|已更新|已新增|已生成|已搜索|已找到|已标记完成|教过你了|学到了)/.test(content || '')
      );
      if (hallucinatedWrite) {
        console.log('[agent] 检测到幻觉：用户写意图 + 模型声称成功但无 tool_calls，强制重试');
        // 追加一条强约束的系统提示，让模型必须真正调用工具
        messages.push({
          role: 'user',
          content: '【重要纠正】你刚才没有调用任何工具，只生成了一段声称"已经记下"的文字。这是幻觉，用户的请求并没有真正保存。请立即调用 create_bill / create_food / create_todo 中对应的工具，把记录真正写进去；调用后再用一句话告诉用户。',
        });
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
