// CloudBase 云函数：截图/照片识别（多模态大模型代理）
// ----------------------------------------------------------------------------
// 作用：App 把图片(base64)发过来，本函数调用「通义千问视觉 Qwen-VL」，
//       返回结构化 JSON（含 type 路由：food / bill / todo / health / none）。
// 好处：API Key 只存在云端（环境变量），App 不直接接触，避免被逆向泄露。
// 部署：在 CloudBase 控制台新建「云函数」-> 上传本目录 -> 开启 HTTP 触发。
// ----------------------------------------------------------------------------

const https = require('https');

// 不同服务商的调用配置；默认 qwen（通义千问视觉）。
// 其他三家是预留：将来想对比/回落，只改 event.provider 即可，App 不用动。
// 注意：API Key 请配置成 CloudBase 的「环境变量」，不要硬编码在这里！
const PROVIDERS = {
  qwen: {
    endpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    model: 'qwen-vl-plus', // 默认性价比款；要更高精度改 'qwen-vl-max-latest'（自动跟随最新版）
    apiKeyEnv: 'DASHSCOPE_API_KEY',
  },
  // 纯文字识别专用：App 文字输入/ OCR 文字走这里（见 RecognizeService 的 qwenText）。
  // 之前漏掉这个 key，导致 PROVIDERS["qwenText"] 为 undefined，回退到视觉模型 qwen-vl-plus 去解析纯文本，
  // 视觉模型吃没有图片的纯文字时极不稳定，会把「炸春卷吃了100克」这类正常饮食识别成 types:["none"]，
  // 结果食物被静默丢弃。补上后文字走 qwen-plus，稳定且更省钱。
  qwenText: {
    endpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    model: 'qwen-plus',
    apiKeyEnv: 'DASHSCOPE_API_KEY',
  },
  // 商汤科技「日日新」SenseNova 系列
  // 视觉识别用 SenseChat-Vision（支持图文混合输入），替代 Qwen-VL
  // 注册：https://platform.sensenova.cn/ → 控制台 → 访问密钥
  // 公测期：¥0/月，每5小时1500次免费
  // 付费后：输入0.01元/千tokens，输出0.06元/千tokens
  sensenova: {
    endpoint: 'https://token.sensenova.cn/v1/chat/completions',
    model: 'sensechat-vision',
    apiKeyEnv: 'SENSENOVA_API_KEY',
  },
  // 文字识别用 SenseChat-Turbo（轻量文本模型），替代 Qwen-Plus
  // 付费后：输入0.0003元/千tokens，输出0.0006元/千tokens（当前最优性价比）
  sensenovaText: {
    endpoint: 'https://token.sensenova.cn/v1/chat/completions',
    model: 'sensechat-turbo',
    apiKeyEnv: 'SENSENOVA_API_KEY',
  },
  doubao: {
    endpoint: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    model: 'doubao-vision',
    apiKeyEnv: 'DOUBAO_API_KEY',
  },
  // 智谱 GLM 视觉（已有：GLM-4V 视觉模型）
  glm: {
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4v',
    apiKeyEnv: 'GLM_API_KEY',
  },
  // 智谱 GLM 纯文字（GLM-4-Flash，轻量便宜）
  glmText: {
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4-flash',
    apiKeyEnv: 'GLM_API_KEY',
  },
  // 百度千帆 ERNIE（OpenAI 兼容，base_url: https://qianfan.baidubce.com/v2）
  // 视觉用 ERNIE-4.0-Turbo（多模态）；文字用 ERNIE-Speed（最便宜）
  // 注册：https://cloud.baidu.com/ → 千帆控制台 → API Key
  qianfan: {
    endpoint: 'https://qianfan.baidubce.com/v2/chat/completions',
    model: 'ernie-4.0-turbo-8k',
    apiKeyEnv: 'QIANFAN_API_KEY',
  },
  qianfanText: {
    endpoint: 'https://qianfan.baidubce.com/v2/chat/completions',
    model: 'ernie-speed-8k',
    apiKeyEnv: 'QIANFAN_API_KEY',
  },
};

// 版本标记：发布后 curl 可通过返回值里的 ver 字段确认是否部署了最新代码
const FN_VERSION = '20260722b-sensenova';

// 服务端兜底：纯通用回应（不论上下文）强制 types:["none"]，不依赖模型是否听话。
// 与云端提示词规则 10 双保险，杜绝「好的/可以」被当成记录指令重复建待办。
// 注意：仅当整条消息几乎只剩一个通用回应词时才拦截；含具体指令的（如"好的帮我改"）不拦，交给模型。
const GENERIC_ACK = ['好的','好','可以','嗯','行','谢谢','再见','哦','知道了','收到','没问题','好滴','行吧','好嘞','嗯嗯','哦哦'];
function isGenericAcknowledgement(text) {
  if (!text || typeof text !== 'string') return false;
  const t = text.trim().replace(/[\s。！？，、；：.!?,;:~\-—…]/g, '');
  if (GENERIC_ACK.includes(t)) return true;
  // 允许尾部语气词：好的呢 / 可以呀 / 谢谢啦 / 行吧哈
  for (const w of GENERIC_ACK) {
    if (t === w + '呢' || t === w + '呀' || t === w + '啦' || t === w + '哈' || t === w + '哦') return true;
  }
  return false;
}

// 系统提示词：告诉模型「如何判断类型并抽取字段」。这是识别质量的核心。
const SYSTEM_PROMPT_IMAGE = `你是一个手机截图/照片理解引擎。用户会发来一张图片（截图或照片）。
请判断图片内容属于以下哪类（可多选）：
- food：食物/餐食照片、食品包装上的营养成分表（用于饮食记录，估算热量与营养成分）
- bill：账单/小票/支付/转账/消费记录（用于账单管理，提取金额、商户、分类、时间）
- todo：包含待办/提醒/日程/任务的信息，如「周五交报表」「提醒复诊」（用于待办提醒，提取事项、截止时间、重复规则）
- health：体检报告、体检预约、运动记录、睡眠数据、身体指标（用于健康管理，指个人健康数据，不是食品营养成分）
- none：以上都不是（如聊天闲聊、新闻等无关内容）

请只输出一个 JSON 对象，不要任何解释文字，格式如下：
{
  "types": ["bill"],
  "confidence": 0.92,
  "bill":   { "merchant":"滴滴出行", "amount":24.0, "currency":"CNY", "category":"交通", "time":"2026-07-16T09:10:00+08:00", "note":"" },
  "food":   { "name":"伊利畅轻风味发酵乳", "calories":100, "energyRaw":417, "energyUnit":"kJ", "protein":2.7, "carbs":14.0, "fat":3.6, "portion":"100克" },
  "todo":   { "title":"交月度报表", "due":"2026-07-16T18:00:00+08:00", "repeat":"none", "priority":"high" },
  "health": { "metric":"体检预约", "value":"2026-08-30", "unit":"", "note":"南宁江南分院，含空腹血糖" }
}
规则：
1. 只输出图片中真实出现的信息，不要编造、推断或臆测。如果看不清，就降低 confidence 或返回 ["none"]。
2. 只填写与 types 对应的字段；未命中的类型字段省略或设为 null。
3. 金额用数字（如 24.0）；货币默认 "CNY"。
4. 当前时间：{CURRENT_TIME}。所有相对时间（如"明天""周五""下周三"）必须基于当前时间推算为绝对时间；返回的时间必须是 ISO8601 格式（含时区 +08:00）。
5. 支持一图多意图：例如"付完款记得交报表"应返回 ["bill","todo"] 两条。
6. 食物热量是估算值，允许误差；如有包装/外卖图标请尽量准确。营养成分表优先读取每100克数据，portion 写"100克"或整包净含量。calories 字段必须是千卡（kcal）。同时返回 energyRaw（标签原始能量数值）和 energyUnit（kJ 或 kcal）。如果 energyUnit 是 kJ 或 千焦，calories = energyRaw / 4.184；如果 energyUnit 是 kcal 或 千卡，calories = energyRaw。换算结果允许四舍五入到整数。
7. 如果是聊天截图，请提取其中截图或文字里的关键信息；如果聊天内容本身没有明确可记录的 bill/food/todo/health，则返回 types: ["none"]。
8. 体检预约、检查报告、医疗相关内容优先归为 health；如果内容中包含明确的执行/预约时间（如"8月30日""周五"），必须额外生成一条 todo：title 写具体事项（如"去江南分院体检"），due 填对应的 ISO8601 时间，repeat 默认 "none"，priority 默认 "high"，并让 types 同时包含 "health" 和 "todo"。
9. 食品包装上的营养成分表属于 food，不属于 health。`;

// 文字输入专用系统提示词
const SYSTEM_PROMPT_TEXT = `你是一个智能生活记录助手。用户会发来一条自然语言消息，请判断它属于饮食/账单/待办中的哪几类（可多选），并提取结构化字段。
- food：饮食记录，如"早餐吃了鸡蛋""下午喝了杯奶茶""夜宵一份烧烤"
- bill：账单/消费/收入，如"买咖啡花了30元""收到工资5000""打车支出24"
- todo：待办/提醒/日程，如"明天下午3点开会""记得交水电费""周五前交报表"
- none：以上都不是

请只输出一个 JSON 对象，不要任何解释文字，格式如下：
{
  "types": ["bill"],
  "confidence": 0.92,
  "bill": { "merchant":"滴滴出行", "amount":24.0, "currency":"CNY", "category":"交通", "time":"2026-07-16T09:10:00+08:00", "note":"", "action":"create", "targetTitle":"" },
  "food": { "name":"伊利畅轻风味发酵乳", "calories":100, "protein":2.7, "carbs":14.0, "fat":3.6, "portion":"100克", "meal":"早餐", "action":"create", "targetTitle":"" },
  "todo": { "title":"交月度报表", "due":"2026-07-16T18:00:00+08:00", "repeat":"none", "priority":"high", "action":"create", "targetTitle":"" }
}
规则：
1. 只从用户消息中提取真实信息，不要编造。
2. 只填写与 types 对应的字段；未命中的类型字段省略或设为 null。
3. 金额用数字；货币默认 "CNY"。收入类关键词（工资、报销、退款、奖金、转账收入、投资收益）金额记为正数。
4. 当前时间：{CURRENT_TIME}。所有相对时间（如"明天""下午3点""周五""下周三""7月30日"）必须基于当前时间推算为绝对时间；如未说明日期，默认是最近的一个未来时间点。返回的时间必须是 ISO8601 格式（含时区 +08:00）。
5. 支持一消息多意图：例如"付完款记得交报表"应返回 ["bill","todo"]。
6. 食物返回的是用户所描述分量的总热量与总营养（不是每100克），calories 字段必须是千卡（kcal），protein/carbs/fat 是总克数。portion 写用户描述的分量，如"1个""1杯""100克"。**meal 字段根据用户消息里的餐次关键词推断：早餐/早饭→早餐、午餐/午饭→午餐、晚餐/晚饭/夜宵→晚餐、加餐/点心/零食→加餐；如用户未提及则省略该字段。**
7. 如果无法判断，返回 types: ["none"]。
8. **重要：区分「提问」与「记录指令」。如果用户只是在提问（消息包含"？"、"几点"、"多少"、"吗"、"呢"、"怎么"、"为什么"、"什么"、"如何"、"谁"、"哪里"、"哪位"、"请问"等疑问词，或以问号结尾），不要把它当作待办/饮食/账单。请返回 types: ["none"]，不要生成任何 payload。**
   例如："今晚几点睡？"是提问，应返回 types: ["none"]；"帮我设置一个22:00的睡觉提醒"才是记录指令，应返回 types: ["todo"]。
9. **重要：上下文理解。我会把最近几条聊天记录放在请求里。请根据上下文判断用户是在新建、修改还是删除已有记录。所有类型（food/bill/todo）都适用同样的 action 约定。**
   - action 取值："create"（默认，新建）、"update"（修改前文提到的记录）、"delete"（删除前文提到的记录）。待办额外支持 "complete"（标记完成）。
   - targetTitle：修改/删除时，尽量填前文那条记录的关键词片段（如食物名、商户名、待办标题），帮助用户端精准定位目标；新建时可省略或填空串。
   - 判断依据：
     - "这个...改成...""把那个...改成...""改一下...""把...换成..." → update。
     - "删除这个...""取消这个...""不要这个了""删掉那条..." → delete。
     - "这个提醒完成了""搞定了" → 待办 complete。
     - "帮我增加一个...""帮我添加一个...""帮我设置一个...提醒/待办/任务" 等明确新建指令 → create。
   例如：
   - 前文记了饮食「螺蛳粉」，用户说"把螺蛳粉热量改成 500" → 返回 food: { name:"螺蛳粉", calories:500, action:"update", targetTitle:"螺蛳粉" }。
   - 前文记了账单「滴滴出行 ¥24」，用户说"那笔滴滴删掉" → 返回 bill: { merchant:"滴滴出行", amount:24.0, action:"delete", targetTitle:"滴滴" }。
   - 前文创建了待办「带上身份证，空腹去体检」，用户说"这个提醒帮我改成7月30日" → 返回 todo: { title:"带上身份证，空腹去体检", due:"2026-07-30T09:00:00+08:00", action:"update", targetTitle:"带上身份证" }。
   - 用户说"帮我增加一个7月30日去体检的提醒" → 直接新建，返回 todo: { title:"去体检", due:"2026-07-30T09:00:00+08:00", action:"create" }。
10. **重要：不要重复执行。如果用户消息是简短通用回应（如"好的"、"可以"、"嗯"、"行"、"谢谢"、"再见"、"嗯嗯"、"哦"、"知道了"），或者与记录无关（如"你是谁"、"你叫什么"、"随便聊聊"），无论上下文如何，都返回 types: ["none"]，不要再次创建、修改或删除任何记录。**
   例如：用户已创建待办「写代码」，随后说"好的" → 返回 types: ["none"]，而不是再建一条"写代码"。
11. **重要：不要对同一用户消息进行重复响应或自我确认。如果上一条已经是 AI 回复，用户的消息只是简单回应，不要把它理解为"继续执行上一次操作"。**`;

// 调用 OpenAI 兼容接口（Qwen / Doubao / GLM 都支持这种格式）
function callChatCompletions(provider, { imageBase64, text, recentMessages }, apiKey) {
  return new Promise((resolve, reject) => {
    const isImage = !!imageBase64;
    const userContent = [];
    if (isImage) {
      userContent.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${imageBase64}` } });
    }

    // 如果有最近聊天记录，先作为上下文拼在前面，帮助模型理解"这个/那个"指代
    if (Array.isArray(recentMessages) && recentMessages.length > 0) {
      const contextText = recentMessages
        .map(m => `${m.role === 'user' ? '用户' : '阿宝'}：${m.text}`)
        .join('\n');
      userContent.push({ type: 'text', text: '以下是最近几条聊天记录，供你判断上下文：\n' + contextText });
    }

    userContent.push({ type: 'text', text: text || '请分析这张图片，只输出要求的 JSON。' });

    // 把当前真实时间注入提示词，避免模型把"明天"解析到错误日期
    const now = new Date();
    const currentTime = now.toLocaleString('zh-CN', {
      timeZone: 'Asia/Shanghai', hour12: false,
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', weekday: 'long'
    }) + ' +08:00';
    const systemPrompt = (isImage ? SYSTEM_PROMPT_IMAGE : SYSTEM_PROMPT_TEXT)
      .replace(/{CURRENT_TIME}/g, currentTime);

    const body = JSON.stringify({
      model: provider.model,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userContent },
      ],
      response_format: { type: 'json_object' },
      temperature: 0.2,
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
            const content = json.choices?.[0]?.message?.content ?? '{}';
            resolve(extractJSON(content));
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

// 通用对话：不强制 JSON，返回模型原始文本（用于基于本地数据的聊天）
function callChatRaw(provider, messages, apiKey) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model: provider.model,
      messages,
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
            const content = json.choices?.[0]?.message?.content ?? '';
            resolve(content);
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

// 基于本地数据摘要的 AI 聊天
async function handleChat(provider, body, apiKey) {
  const text = body.text || '';
  const context = body.context || {};
  const now = new Date();
  const currentTime = now.toLocaleString('zh-CN', {
    timeZone: 'Asia/Shanghai', hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', weekday: 'long'
  }) + ' +08:00';
  const system = `你是阿宝，用户手机里的私人 AI 助理，性格像一位细心又有点俏皮的朋友。我会把用户 App 里的本地数据摘要（饮食、账单、待办、健康）放在下一条消息里，是 JSON 格式。

当前时间：${currentTime}。如果用户问起"现在几点""今天几号""现在是早上还是下午"等与时间相关的问题，必须基于上述当前时间回答，不要依赖模型内部知识。

回答要求：
1. 用简体中文，口语化、自然，像在微信里聊天，不要书面腔，也不要用"根据您的数据"这类机器句式。可以适当用"呀、哦、呢、～"等语气词。
2. 严格基于真实数据回答，绝不要编造数据或额度。数据里没有的就说"我这边暂时没看到"。
3. 如果用户问的是闲聊、建议或感受（比如"今晚几点睡好""今天好累"），可以像朋友一样给轻松自然的回应，并结合数据给一点小提醒（例如快到平时记早餐的点就顺带提醒），但不要硬扯数据。
4. 回复尽量简短（2-4 句），重点先说结论，需要列清单时再用换行，不要长篇大论。
5. 如果数据为空或用户问的内容数据里没有，就友好引导用户可以让你记点什么，而不是冷冰冰地说"无数据"。`;
  const contextText = JSON.stringify(context, null, 2);
  const messages = [
    { role: 'system', content: system },
    { role: 'user', content: '我的本地数据摘要如下：\n' + contextText },
    { role: 'user', content: text }
  ];
  const reply = await callChatRaw(provider, messages, apiKey);
  return { ok: true, reply };
}

// 有些模型会在 JSON 外面包 ```json 代码块，这里做防御性清洗
function extractJSON(text) {
  const t = text.trim();
  const fenced = t.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidate = fenced ? fenced[1] : t;
  return JSON.parse(candidate);
}

// 云函数入口
exports.main = async (event, context) => {
  try {
    // CloudBase HTTP 触发会把请求体放在 event.body；微信小程序端调用则直接是 event 对象。
    // 这里做兼容：先尝试 event.body，再回退到 event 本身。
    const body = parseEventBody(event);
    const providerName = body.provider || 'sensenova';
    const provider = PROVIDERS[providerName] || PROVIDERS.qwen;
    const apiKey = process.env[provider.apiKeyEnv];
    if (!apiKey) return { ok: false, error: `缺少环境变量 ${provider.apiKeyEnv}（请在 CloudBase 配置）`, ver: FN_VERSION };
    if (!body.imageBase64 && !body.text) return { ok: false, error: '缺少 imageBase64 或 text', ver: FN_VERSION };

    // 服务端兜底：纯通用回应（非聊天、非图片）强制 none，省一次模型调用且确定性生效，
    // 不依赖模型是否听话（提示词规则 10 的双保险）。含具体指令的（如"好的帮我改"）不拦。
    if (body.mode !== 'chat' && !body.imageBase64 && body.text && isGenericAcknowledgement(body.text)) {
      return { ok: true, result: { types: ['none'] }, ver: FN_VERSION };
    }

    // 聊天模式：不返回结构化 JSON，而是基于本地数据摘要直接回答
    if (body.mode === 'chat') {
      const chatRes = await handleChat(provider, body, apiKey);
      return { ...chatRes, ver: FN_VERSION };
    }

    const result = await callWithFallback(body, apiKey);
    if (result && result.food) {
      normalizeFoodResult(result.food);
    }
    return { ok: true, result, ver: FN_VERSION };
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e), ver: FN_VERSION };
  }
};

// 优先调用主 provider（sensenova/sensenovaText）→ 失败或结果不合格时回退到 qwen/qwenText。
// 回退规则：主调用抛异常 OR 返回 types:["none"] 但输入明显有内容（有图或非通用回应文字）。
async function callWithFallback(body, apiKey) {
  const providerName = body.provider || 'sensenova';
  const primary = PROVIDERS[providerName] || PROVIDERS.qwen;
  const primaryKey = apiKey;

  // 定义 fallback 映射：所有非 qwen 的厂商 → 回到 qwen/qwenText 兜底
  const fallbackMap = {
    sensenova: 'qwen',
    sensenovaText: 'qwenText',
    glm: 'qwen',
    glmText: 'qwenText',
    qianfan: 'qwen',
    qianfanText: 'qwenText',
  };
  const fallbackName = fallbackMap[providerName];
  const fallback = fallbackName ? (PROVIDERS[fallbackName] || null) : null;
  const fallbackKey = fallback ? process.env[fallback.apiKeyEnv] || primaryKey : null;
  // fallback 是否可用（有 provider 配置且对应 API Key 存在）
  const canFallback = !!(fallback && fallbackKey);

  // 判断输入是否明显「有内容可分析」—— 有图或者文字非通用回应
  function inputIsMeaningful() {
    if (body.imageBase64) return true;
    if (body.text && !isGenericAcknowledgement(body.text)) return true;
    return false;
  }

  // 尝试主 provider
  try {
    const result = await callChatCompletions(primary, {
      imageBase64: body.imageBase64, text: body.text, recentMessages: body.recentMessages
    }, primaryKey);

    // 主调用成功返回了，但若是 none 而且输入明显有内容 → 说明主模型可能没认出，降级试 fallback
    if (canFallback && result && (!result.types || result.types.includes('none')) && inputIsMeaningful()) {
      console.log(`[Fallback] ${providerName} 返回 none，尝试回退到 ${fallbackName}`);
      const fbResult = await callChatCompletions(fallback, {
        imageBase64: body.imageBase64, text: body.text, recentMessages: body.recentMessages
      }, fallbackKey);
      // 如果 fallback 返回了非 none 的结果，采用 fallback 的结果；否则保留主结果
      if (fbResult && fbResult.types && !fbResult.types.includes('none')) {
        return fbResult;
      }
    }
    return result;
  } catch (e) {
    // 主调用失败（网络超时、HTTP 错误、JSON 解析错误等）
    if (canFallback) {
      console.log(`[Fallback] ${providerName} 调用失败（${e.message}），回退到 ${fallbackName}`);
      const fbResult = await callChatCompletions(fallback, {
        imageBase64: body.imageBase64, text: body.text, recentMessages: body.recentMessages
      }, fallbackKey);
      return fbResult;
    }
    throw e;  // 无 fallback 可选，继续抛
  }
}

// 后处理：营养成分表上的能量常以 kJ 标注，而 calories 要求 kcal，统一换算
function normalizeFoodResult(food) {
  if (!food || typeof food !== 'object') return food;

  const raw = parseFloat(food.energyRaw);
  const unit = String(food.energyUnit || '').toLowerCase();

  if (!isNaN(raw) && unit) {
    if (unit.includes('kj') || unit.includes('千焦')) {
      // 1 kcal = 4.184 kJ
      food.calories = Math.round(raw / 4.184);
    } else if (unit.includes('kcal') || unit.includes('千卡') || unit.includes('大卡')) {
      food.calories = Math.round(raw);
    }
  }

  // 云端已经把 calories 修正为 kcal，删除中间字段让返回更干净
  delete food.energyRaw;
  delete food.energyUnit;

  return food;
}

// 兼容 CloudBase HTTP 触发 / 微信小程序云函数调用 两种 event 结构
function parseEventBody(event) {
  if (event.imageBase64 || event.text) return event;
  let body = event.body;
  if (!body) return {};

  if (typeof body === 'string') {
    // 1) 先尝试当作普通 JSON 字符串解析（CloudBase 测试/某些网关场景）
    try {
      return JSON.parse(body);
    } catch (e) {
      // 2) 再尝试 base64 解码后解析（标准 HTTP 触发常见）
      try {
        const decoded = Buffer.from(body, 'base64').toString('utf8');
        return JSON.parse(decoded);
      } catch (e2) {
        return {};
      }
    }
  }
  return body || {};
}
