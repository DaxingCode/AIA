// CloudBase 云函数：截图/照片识别（多模态大模型代理）
// ----------------------------------------------------------------------------
// 作用：App 把图片(base64)发过来，本函数调用「通义千问视觉 Qwen-VL」，
//       返回结构化 JSON（含 type 路由：food / bill / todo / health / none）。
// 好处：API Key 只存在云端（环境变量），App 不直接接触，避免被逆向泄露。
// 部署：在 CloudBase 控制台新建「云函数」-> 上传本目录 -> 开启 HTTP 触发。
// ----------------------------------------------------------------------------

const https = require('https');

// 付费墙：recognize 不直连数据库，统一向 aia-sync 的 entitlement 动作做权威校验（白名单/免费额度/全局熔断都在 aia-sync 一侧）。
const SYNC_URL = process.env.SYNC_URL || 'https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/sync';

function httpsPostJSON(url, payload) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(payload);
    let u;
    try { u = new URL(url); } catch (e) { return reject(e); }
    const opt = {
      method: 'POST',
      hostname: u.hostname,
      path: u.pathname,
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }
    };
    const req = https.request(opt, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => {
        try { resolve(JSON.parse(buf || '{}')); } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// 由请求体推断「被管控的云功能」
function deriveFeature(body) {
  // >>> CHANGE-[2026-08-19 23:14:15]-打招呼不扣费 开始
  // 原因: 打招呼(greeting)是本地数据生成的轻量开场白, 非用户主动 AI 提问, 不应消耗免费额度
  // 回退: 恢复 if (body.mode === 'greeting') return 'cloudChat';
  if (body.mode === 'greeting') return null;
  // <<< CHANGE-[2026-08-19 23:14:15]-打招呼不扣费 结束
  if (body.mode === 'queryFood') return 'cloudFoodQuery';
  if (body.mode === 'agent') return 'cloudAgent';
  if (body.mode === 'chat') return 'cloudChat';
  if (body.imageBase64) return 'cloudVision';
  if (body.text) return 'cloudTextParse';
  return null;
}

// Agent 模式（可单独开关的云端智能问答）：避免循环依赖，仅引入 handleAgent；
// TOOL_SCHEMAS / AGENT_SYSTEM_PROMPT 由 agentHandler 内部 require，index.js 不重复依赖。
const { handleAgent } = require('./agentHandler');

// 云端权威营养表（AUTO-GENERATED，由 gen-food-table.mjs 从 App 端 NutritionLibrary.swift 同步生成）。
// queryFood 查表优先：常见食物命中即返确定值，仅长尾回落 LLM，杜绝数值漂移、省云调用。
const { lookupFood } = require('./foodTable');

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
  // 智谱 GLM-4V-Flash —— 永久免费的视觉模型（16K 上下文）
  // 注册：https://open.bigmodel.cn/ → API Key（与 glm/glmText 共用的 GLM_API_KEY）
  // 说明：https://aisharenet.com/zhipukaifangpingtai/
  glm4vFlash: {
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4v-flash',
    apiKeyEnv: 'GLM_API_KEY',
  },
  // 智谱 GLM 视觉（已有：GLM-4V 视觉模型，较贵 ¥50/M，救急用）
  glm: {
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4v',
    apiKeyEnv: 'GLM_API_KEY',
  },
  // 智谱 GLM 纯文字（GLM-4.7-Flash，2025 新模型，永久免费，200K 上下文，增强 function calling）
  // 旧版 glm-4-flash 已停更好，2026-07-25 升级至 glm-4.7-flash。
  glmText: {
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4.7-flash',
    apiKeyEnv: 'GLM_API_KEY',
  },
  // 智谱 GLM-4-Flash-250414（基础版，非推理、永久免费、无 <think> 思考链）
  // 专为 queryFood 营养查表设计：比 glm-4.7-flash 快很多。共用 GLM_API_KEY，无需新增环境变量。
  // 注：旧名 glm-4-flash 已更名为 glm-4-flash-250414（智谱有自动路由，但用现名最稳）。
  glmFlash: {
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4-flash-250414',
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
  // DeepSeek（深度求索）—— 文字处理 + function-calling 最强，性价比极高
  // 注册：https://platform.deepseek.com/ → API Keys → 创建 Key
  // 定价：deepseek-chat 输入 ¥2/百万 tokens，输出 ¥8/百万 tokens
  // 说明：完全兼容 OpenAI 格式，支持工具调用（function calling）、多轮对话。
  //       注意：DeepSeek 暂时不支持图片视觉识别（无多模态模型），仅文字场景。
  //       强烈推荐将 Agent 模式的 provider 改成 deepseek——function-calling 准确度远超 sensenovaText。
  deepseek: {
    endpoint: 'https://api.deepseek.com/v1/chat/completions',
    model: 'deepseek-chat',  // V3 模型，文字+工具调用首选
    apiKeyEnv: 'DEEPSEEK_API_KEY',
  },
  deepseekText: {
    endpoint: 'https://api.deepseek.com/v1/chat/completions',
    model: 'deepseek-chat',  // 文字专用，与 deepseek 同模型可共用
    apiKeyEnv: 'DEEPSEEK_API_KEY',
  },
};

// 版本标记：发布后 curl 可通过返回值里的 ver 字段确认是否部署了最新代码
// 注意：保持全小写+连字符，package-recognize.sh 的正则 [a-z]+ 兼容（小写 + 数字后缀 + 可选 -xxx 后缀，不支持大写）
const FN_VERSION = '20260815b-billname';

// 服务端兜底：纯通用回应（不论上下文）强制 types:["none"]，不依赖模型是否听话。
// 与云端提示词规则 10 双保险，杜绝「好的/可以」被当成记录指令重复建待办。
// 注意：仅当整条消息几乎只剩一个通用回应词时才拦截；含具体指令的（如"好的帮我改"）不拦，交给模型。
const GENERIC_ACK = ['好的','好','可以','嗯','行','谢谢','再见','哦','知道了','收到','没问题','好滴','行吧','好嘞','嗯嗯','哦哦',
  '测试','测试一下','试试','试一下','随便','你好','在吗','hi','hello'];
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

// 账单分类预设枚举：与 App 端 billCategoryOptions（EditSheets.swift）及
// BillCategoryHelpers.normalizedCategory 对齐。方案1 用于约束视觉/文本模型只从本枚举选分类（App 端另有归一化兜底）。
const BILL_CATEGORY_ENUM = "餐饮、交通、购物、住房、娱乐、医疗、教育、通讯、保险、运动、宠物、旅行、家居、服饰、美妆、数码、云服务、礼品、人情、投资、工资、办公、快递、母婴、慈善、其他";
const BILL_CATEGORY_RULE = `账单分类必须严格从下列预设分类中选择最贴切的一个，不要自造更细的子类（如"咖啡""快餐""超市""奶茶"请归入"餐饮/购物"）：${BILL_CATEGORY_ENUM}。例：星巴克/瑞幸/奶茶/火锅→餐饮；滴滴/地铁/加油/停车→交通；永辉/便利店/网购→购物；手机/电脑/相机→数码；若无法确定填"其他"。`;

// 系统提示词：告诉模型「如何判断类型并抽取字段」。这是识别质量的核心。
const SYSTEM_PROMPT_IMAGE = `你是一个手机截图/照片理解引擎。用户会发来一张图片（截图或照片）。
请判断图片内容属于以下哪类（可多选）：
- food：食物/餐食照片、食品包装上的营养成分表（用于饮食记录，估算热量与营养成分）
- bill：账单/小票/支付/转账/消费记录（用于账单管理，提取金额、商户、分类、时间）
- todo：包含待办/提醒/日程/任务的信息，如「周五交报表」「提醒复诊」（用于待办提醒，提取事项、截止时间、重复规则）
- health：体检报告、检查报告、检验单、运动记录、睡眠数据、身体指标（用于健康管理，指个人健康数据，不是食品营养成分；**体检预约因含明确时间，归 todo 不归 health**）
- none：以上都不是（如聊天闲聊、新闻等无关内容）

请只输出一个 JSON 对象，不要任何解释文字，格式如下：
{
  "types": ["bill"],
  "confidence": 0.92,
  "bill":   { "merchant":"滴滴出行", "amount":24.0, "currency":"CNY", "category":"交通", "time":"2026-07-16T09:10:00+08:00", "note":"" },
  "bills":  [
    { "merchant":"永辉超市", "amount":58.5,  "currency":"CNY", "category":"购物", "time":"2026-07-16T19:32:00+08:00", "note":"果蔬" },
    { "merchant":"滴滴出行", "amount":24.0,  "currency":"CNY", "category":"交通", "time":"2026-07-16T09:10:00+08:00", "note":"" },
    { "merchant":"瑞幸咖啡", "amount":19.9,  "currency":"CNY", "category":"餐饮", "time":"2026-07-15T14:05:00+08:00", "note":"" }
  ],
  "food":   { "name":"伊利畅轻风味发酵乳", "calories":100, "energyRaw":417, "energyUnit":"kJ", "protein":2.7, "carbs":14.0, "fat":3.6, "fiber":0, "sugar":12.0, "sodium":60, "portion":"100克" },
  "foods":  [
    { "name":"招牌白切隔山肉", "calories":350, "protein":22, "carbs":3, "fat":28, "fiber":0, "sugar":0, "sodium":85, "portion":"150克" },
    { "name":"青菜", "calories":50, "protein":4, "carbs":8, "fat":0.5, "fiber":3, "sugar":2, "sodium":120, "portion":"200克" },
    { "name":"米饭", "calories":200, "protein":4, "carbs":42, "fat":0.5, "fiber":0.3, "sugar":0.1, "sodium":1, "portion":"1碗" },
    { "name":"例汤", "calories":40, "protein":2, "carbs":4, "fat":1, "fiber":0.5, "sugar":0.5, "sodium":400, "portion":"1碗" }
  ],
  "todo":   { "title":"交月度报表", "due":"2026-07-16T18:00:00+08:00", "repeat":"none", "priority":"high" },
  "health": { "metric":"体检预约", "value":"2026-08-30", "unit":"", "note":"南宁江南分院，含空腹血糖" }
}
规则：
1. 只输出图片中真实出现的信息，不要编造、推断或臆测。如果看不清，就降低 confidence 或返回 ["none"]。
2. 只填写与 types 对应的字段；未命中的类型字段省略或设为 null。
3. 金额用数字（如 24.0）；货币默认 "CNY"。
4. 当前时间：{CURRENT_TIME}。所有相对时间（如"明天""周五""下周三""昨天""前天""星期二"）必须基于当前时间推算为绝对时间；返回的时间必须是 ISO8601 格式（含时区 +08:00）。
   - **支付宝/微信账单常见相对日期必须转换**："昨天 12:58" → "2026-07-22T12:58:00+08:00"，"星期二 19:09" → 取最近一个周二的绝对日期，"前天 15:30" → 前天对应时刻。**绝不能原样返回中文相对日期**。
5. 支持一图多意图：例如"付完款记得交报表"应返回 ["bill","todo"] 两条。
6. 食物热量是估算值，允许误差；如有包装/外卖图标请尽量准确。营养成分表优先读取每100克数据，portion 写"100克"或整包净含量。calories 字段必须是千卡（kcal）。同时返回 energyRaw（标签原始能量数值）和 energyUnit（kJ 或 kcal）。如果 energyUnit 是 kJ 或 千焦，calories = energyRaw / 4.184；如果 energyUnit 是 kcal 或 千卡，calories = energyRaw。换算结果允许四舍五入到整数。**除 calories/protein/carbs/fat 外，还必须返回 fiber（膳食纤维 g/100g）、sugar（糖 g/100g）、sodium（钠 mg/100g）三项**——这三项是用户每日摄入追踪的关键指标，缺一即视为识别不完整。**单条 food 与多食物 foods[] 数组里的每一个元素都强制要求这三项**，缺一不可。如果图片/包装上没标注，可按常见食物的典型值估算（如白米饭 fiber≈0.3、sugar≈0.1、sodium≈1），绝不能默认 0 或省略字段。
7. **一图多食物必须拆条输出「foods」数组**：如果图片包含**多种独立食物**（如「招牌白切隔山肉+青菜+米饭+例汤」「三菜一汤」等套餐/多品餐食），必须识别每一种食物并输出一个「foods」数组，数组的每个元素是一条独立的食物对象（字段同单条 food：name/calories/protein/carbs/fat/fiber/sugar/sodium/portion，**micro 三项同样必填，绝不可省略或填 0**）。即使其中某种食物营养价值低或份量小，也照常输出，**不要**为了省事合并成一条。单种食物（/纯米饭/单一菜品）仍用单条「food」对象即可，只有一图多种食物才用「foods」数组。「types」写 ["food"]。
7. 如果是聊天截图，请提取其中截图或文字里的关键信息；如果聊天内容本身没有明确可记录的 bill/food/todo/health，则返回 types: ["none"]。**重要：聊天截图讨论体检/挂号/医疗预约时（如"我也去江南的""空腹血糖""7月30"），应优先识别为 todo（提取 title 与 due，体检注意事项写进 note），不要识别为 bill，也不要识别为 health。** 严禁在没有真实交易证据时凭空编造账单：只有当截图能明确读出商户名或可识别的支付动作（转账/付款/消费）时，才能返回 bill；绝不得返回 merchant 为"账单"、category 为"餐饮"这类占位默认值来凑数，这种情况应返回 ["none"] 或对应的 todo/health。
   **反例（必须遵守）**：截图是微信聊天，聊天内容包含"我是在江南那个美年大""那我也去江南的""它有一项是空腹血糖，是不是不能吃早餐""对的""好的""7月30""哈哈哈"，即使聊天中嵌入了一张体检套餐/预约页面图，也**必须**返回 types: ["todo"]，todo.title: "去江南美年大健康体检"，todo.due: "2026-07-30T00:00:00+08:00"，todo.note: "空腹血糖，不能吃早餐"。**严禁**因为嵌入页面里可能有价格/金额数字就返回 bill，也**严禁**输出 bills 数组。
8. **待办(todo)的优先级高于健康(health)。** 体检预约、检查报告、医疗相关内容中：只要内容包含明确的执行/预约时间（如"8月30日""周五""周二15:30"），**一律优先识别为 todo**（title 写具体事项如"去江南分院体检"，due 填对应的 ISO8601 时间，repeat 默认 "none"，priority 默认 "high"），**不要**识别为 health；仅当截图是纯体检报告、检查报告、检验单、个人身体指标/运动/睡眠数据（无明确执行时间）时才归为 health。
9. 食品包装上的营养成分表属于 food，不属于 health。
10. **强制识别为账单的截图类型**：如果截图是支付宝/微信「账单详情」「支付成功」「账单列表」「付款记录」「消费明细」「转账记录」等，或线下「超市小票」「便利店小票」「收银小票」「购物小票」「餐饮小票」「外卖订单」等，**都必须识别为 bill**。即使金额显示为负数（如支付宝/微信支出 -18.00）、商户名被脱敏为「**娟(个人)」、或商品说明是「经营码交易」「转账」「生活缴费」等，也绝不要返回 none。**本规则仅适用于真正的账单/支付/转账/小票截图，不适用于聊天截图，也不适用于体检套餐/体检预约/挂号/医院预约类页面截图。** 如果一张截图整体是聊天界面（即使里面嵌入了其他页面图），应优先按规则 7 判断聊天意图；嵌入的体检套餐/预约页面不得触发本规则的强制账单识别，而应按规则 8 归为 todo（含预约时间）或 health。
11. **支付成功页金额提取**：支付成功页/账单详情页的中心大数字（如 -0.81、-18.00）就是交易金额；负数表示支出，应取绝对值作为 amount。优惠/立减行（如「广发随机立减优惠¥0.19」）不是主交易金额，不要误把优惠金额当主金额。若截图同时出现「原价」「实付」「共支付」等，优先取实际支付金额。
12. 商户名 cleaning：去掉首尾星号*，去掉「(个人)」「(商户)」等后缀，如「**娟(个人)」→ merchant 填「娟」；小票顶部的店名如「永辉(95HC 南宁盛隆世界店)欢迎您」→ merchant 填「永辉」或「永辉超市」；若收款方只有星号或无法读取，可取「商品说明」「账单」或「超市/便利店」作为 merchant。若无法确定分类，category 可填"其他"，但绝不要返回 none。
13. **一图多账单（列表）必须拆条输出「bills」数组**：如果截图是「账单列表 / 支付记录列表 / 账单详情列表 / 转账记录」等包含**多笔独立交易**的页面，请识别每一笔交易，并输出一个「bills」数组，数组的每个元素都是一条完整的账单对象（字段同单条 bill：merchant / amount / currency / category / time / note）。
   - 每一笔都要读取它**自己那一行/那一条**的支付时间作为 time，必须是 ISO8601（含时区 +08:00）；**不要**把截图的拍摄时间或列表顶部状态栏时间当成某笔交易的支付时间。
   - 支出金额为负数时取绝对值作为 amount（如 -18.00 → 18.0）。
   - 即使其中某笔金额/商户看不清，也照常输出能识别的条目，看不清的字段可留空或降低 confidence，但**不要**为了某一条不清就整体返回 none 或只返回一条。
   - 单笔账单（非列表）仍用单条「bill」对象即可；只有「一图多笔」才用「bills」数组。
   - 聊天截图里嵌入的页面（如体检套餐、医院预约、培训报名、活动介绍）即使包含多个价格项，也**不得**输出「bills」数组；整体按聊天意图处理。
   - 「types」写 ["bill"]。
14. **通知/会议/培训/活动类截图归为待办(todo)**：如果截图是「培训通知」「会议邀请」「活动预告」「课程表」「日程安排」「打卡提醒」「系统通知」等，包含明确的**时间+地点**但**没有任何金额/支付/转账/价格/收款**信息，应识别为 todo（提取 title 与 due，有地点可写进 note），**不要识别为 bill**。即使截图里出现"群""群聊""微信通知""公众号"等字样，只要没有钱款交易行为，就不是账单。仅当截图确实含缴费/支付动作（如"请于X日前缴纳XXX元""扫码付款"）时，才识别为 bill。**本规则优先级高于第 8 条：涉及医疗主题的体检预约/培训/会议/活动通知，一律归 todo，不归 health。**
   - 培训/会议/活动邀请函：**title 必须取活动/课程/会议的名称**（如「走进明亚广西分公司」或「广西分公司2026年8月新人班」），**绝不要取主办方/页头品牌名**（如「明亚保险经纪 MINGYA INSURA…」）。优先从「授课内容/培训主题/会议主题/活动主题：」后的文字取，没有则取含「新人班/培训班/课程/讲座/会议/活动」的活动名行。
   - **due 取「授课时间/培训时间/活动时间/会议时间：」后的开始时间**（如「8月7日 9:15-10:30」→ 用 8月7日 09:15，转 ISO8601 含 +08:00 时区；无年份按当前年份补全）。不要用截图拍摄时间或状态栏时间。
   - **地点写进 note**：把「授课地点/培训地点/活动地点/会议地点：」后的地址（如「南宁市华润大厦A座47楼会议室」）写入 note，同时可把原始「授课时间」行一并放入 note 便于核对。
   - 示例：邀请卡页头是「明亚保险经纪」、正文「广西分公司2026年8月新人班 / 授课时间：8月7日 9:15-10:30 / 授课地点：南宁市华润大厦A座47楼会议室 / 形式：培训教室面授课程」→ title=「广西分公司2026年8月新人班」或「走进明亚广西分公司」，due=2026-08-07T09:15+08:00，note 填地点与原始授课时间。

15. **电影票/演出票/机票/火车票等票据类截图一律归为待办(todo)，不要归为 bill**：这类截图有影片/演出/航班名、影院/剧院/车站、座位号、取票/扫码入场二维码，但**通常没有本单实付金额**（票价在购票订单里而非这张票根上）。即使页面出现"¥"或数字（座位号、序列号、验证码、底部卖品广告"XX元起"），只要不是本单实付金额，就必须判为 todo 而非 bill。title 用影片/演出/航班主题（如"蜘蛛侠：崭新之日"），due 取截图中的具体时间（如 14:40，无则当天 8:00），note 可填影院/地点/座位。**本规则优先级高于第 10 条：票据不算账单。**
16. **截图顶部的地图/导航悬浮窗/状态栏是噪声，必须忽略**：截图常混入「预计 14:37 到达」「↑ 67米」「剩 197米」「导航中」等地图导航悬浮信息，以及系统状态栏时间。这些**不是票面内容**：
   - title **必须取片名/演出名/事项名**（如"蜘蛛侠：崭新之日"），**绝不能取导航文案、距离"XX米"、或状态栏/导航时间**。
   - due **必须取票面/正文的放映或开始时间**（如票根上的"今天 08-02 14:40"→ 2026-08-02T14:40:00+08:00，注意 08-02 是日期、14:40 才是时刻，两者都要取，不要用系统当前日期替代票面日期），**绝不能用导航预计到达时间或截图状态栏时间**。
   - note 保留影院名、厅、座位、场次等票面详情。
   - 反例：顶部有"14:37 个 67米 剩197米 all"，正文是"永恒·中华大戏院（三街两巷4K巨幕店）蜘蛛侠：崭新之日 原版2D 2张 / 今天 08-02 14:40~17:05 / 1号 4K巨幕厅"→ title="蜘蛛侠：崭新之日"，due=2026-08-02T14:40:00+08:00，note="永恒·中华大戏院（三街两巷4K巨幕店）；1号 4K巨幕厅；黄金 11排14座|11排15座；14:40~17:05"。
17. **还款/缴费单既记账又提醒（双卡）**：如果截图是「信用卡账单」「还款单」「缴费通知」「账单日/还款日」等，**同时含有截止日期或账单日/还款日（如"7月25日还款""账单日每月8日""最晚8月30日前缴费"）和金额**，应**同时**返回 bill 和 todo 两类：
   - bill：正常记账（merchant 取商户/还款机构，amount 取金额）。
   - todo：title 写「X月X日还款/缴费」类（如"7月25日还信用卡""8月30日前交水电费"），due 取截止/还款日，repeat 若为固定周期（"每月X号"）填 "monthly" 否则 "none"。
   - **本规则优先级高于第 10 条：带截止日期的还款/缴费单不能只当账单漏掉还款提醒。**
   - 仅当截图只有金额没有明确日期/账单日/还款日时，才只返回 bill，不建 todo。
18. **服务型票券（交通/酒店/预约/景点）归为待办(todo)**：除了电影/演出/赛事票，这类**无本单实付金额**的票券/预约也归 todo，不要归 bill。按服务类型取 title 与 due：
   - 火车/高铁票：title 用车次号（如"G1234次车票"），due 取发车时间，note 填出发/到达站、座位、检票口、车次。
   - 机票：title 用航班号（如"MU5331航班"），due 取起飞时间，note 填起降时间、登机口、行李。
   - 酒店/民宿入住单：title 用酒店名（如"XX酒店"），due 取入住日，note 填离店日、房型、地址。
   - 景点/乐园门票：title 用园区名（如"XX欢乐谷"），due 取入园日，note 填园区、场次、入园时间。
   - 医院挂号/体检预约/复诊单：title 用就诊项目/科室（如"XX科复诊"），due 取预约时间，note 填科室、地址、预约号。**此类含明确预约时间的按规则 8 归 todo，不归 health。**
   - **本规则优先级高于第 10 条：服务型票券/预约单不算账单。**
19. **待办的周期识别（repeat 字段）**：提取待办时，若文本含周期词，把 repeat 填成对应枚举，**不要一律写 "none"**：
   - "每天/每日/天天" → "daily"
   - "每周X/每星期X"（如"每周一"）→ "weekly"
   - "每两周/隔周" → "biweekly"
   - "每月X号/每X号"（如"每月15号还房贷"）→ "monthly"
   - "每两月/隔月" → "bimonthly"
   - "每季度" → "quarterly"
   - "每半年" → "semiannual"
   - "每年X月X号/每年X月X日/年年/每年"（如"每年9月1号提醒我狗证续签"）→ "yearly"，due 填**下一个**该月日的日期时间（已过去的顺延次年，如今天是8月3日，"每年9月1号"→ 2026-09-01T08:00:00+08:00）。
   - 其余一次性待办才写 "none"。周期待办的 due 填**下一个**该周期的日期时间（如今天是8月3日周二，"每周一19点开会"→ 下一个周一，即 2026-08-09T19:00:00+08:00）。若周期待办文本**无任何具体日期/周几**（如"每天喝水""每周开会"），due 填**今天此刻**（而非1小时后）。
${BILL_CATEGORY_RULE}`;

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
  "food": { "name":"伊利畅轻风味发酵乳", "calories":100, "protein":2.7, "carbs":14.0, "fat":3.6, "fiber":0, "sugar":12.0, "sodium":60, "portion":"100克", "meal":"早餐", "action":"create", "targetTitle":"" },
  "todo": { "title":"交月度报表", "due":"2026-07-16T18:00:00+08:00", "repeat":"none", "priority":"high", "action":"create", "targetTitle":"" }
}
规则：
1. 只从用户消息中提取真实信息，不要编造。
2. 只填写与 types 对应的字段；未命中的类型字段省略或设为 null。
3. 金额用数字；货币默认 "CNY"。收入类关键词（工资、报销、退款、奖金、转账收入、投资收益）金额记为正数。
4. 当前时间：{CURRENT_TIME}。所有相对时间（如"明天""下午3点""周五""下周三""7月30日"）必须基于当前时间推算为绝对时间；如未说明日期，默认是最近的一个未来时间点。返回的时间必须是 ISO8601 格式（含时区 +08:00）。
   4b. 账单类 time 字段纪律：仅当用户原话明确包含日期或时刻（如"昨天""下午3点""8月7日""刚才""刚刚"）才填 time；若用户只说了金额/商户/餐次（如"早餐花了15""午饭35元"）而没有任何时间表述，不要返回 time 字段（省略或设为 null），由客户端按当前时间/餐次默认时刻记录。严禁凭空编造时间。
5. 支持一消息多意图：例如"付完款记得交报表"应返回 ["bill","todo"]。
6. 食物返回的是用户所描述分量的总热量与总营养（不是每100克），calories 字段必须是千卡（kcal），protein/carbs/fat/fiber/sugar 是总克数，sodium 是总毫克数。portion 写用户描述的分量，如"1个""1杯""100克"。**meal 字段根据用户消息里的餐次关键词推断：早餐/早饭→早餐、午餐/午饭→午餐、晚餐/晚饭/夜宵→晚餐、加餐/点心/零食→加餐；如用户未提及则省略该字段。**
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
11. **重要：不要对同一用户消息进行重复响应或自我确认。如果上一条已经是 AI 回复，用户的消息只是简单回应，不要把它理解为"继续执行上一次操作"。**
12. **待办的周期识别（repeat 字段）**：若待办含周期词，把 repeat 填成对应枚举，不要一律写 "none"："每天/每日/天天"→"daily"；"每周X/每星期X"→"weekly"；"每两周/隔周"→"biweekly"；"每月X号/每X号"→"monthly"；"每两月/隔月"→"bimonthly"；"每季度"→"quarterly"；"每半年"→"semiannual"；"每年X月X号/每年/年年"→"yearly"（如"每年9月1号提醒我狗证续签"→ yearly，due 填下一个9月1日，已过去的顺延次年）；其余一次性待办才写 "none"。周期待办的 due 填**下一个**该周期的时间（如今天8月3日周二，说"每周一19点开会"→ 2026-08-09T19:00:00+08:00）。若周期待办文本**无任何具体日期/周几**（如"每天喝水""每周开会"），due 填**今天此刻**（而非1小时后），让重复从今天开始。
${BILL_CATEGORY_RULE}`;

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
        .map(m => `${m.role === 'user' ? '用户' : '阿记'}：${m.text}`)
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
function callChatRaw(provider, messages, apiKey, opts = {}) {
  return new Promise((resolve, reject) => {
    const reqBody = {
      model: provider.model,
      messages,
      temperature: opts.temperature != null ? opts.temperature : 0.7,
    };
    if (opts.max_tokens != null) reqBody.max_tokens = opts.max_tokens;
    const body = JSON.stringify(reqBody);

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
  const system = `你是阿记，用户手机里的私人 AI 助理，性格像一位细心又有点俏皮的朋友。我会把用户 App 里的本地数据摘要（饮食、账单、待办、健康）放在下一条消息里，是 JSON 格式。

当前时间：${currentTime}。如果用户问起"现在几点""今天几号""现在是早上还是下午"等与时间相关的问题，必须基于上述当前时间回答，不要依赖模型内部知识。

回答要求：
1. 用简体中文，口语化、自然，像在微信里聊天，不要书面腔，也不要用"根据您的数据"这类机器句式。可以适当用"呀、哦、呢、～"等语气词。
2. 严格基于真实数据回答，绝不要编造数据或额度。数据里没有的就说"我这边暂时没看到"。
3. 如果用户问的是闲聊、建议或感受（比如"今晚几点睡好""今天好累"），可以像朋友一样给轻松自然的回应，并结合数据给一点小提醒（例如快到平时记早餐的点就顺带提醒），但不要硬扯数据。
4. 【内容安全 · 必须拒答】：若用户试图让你生成违法犯罪、暴力、色情、政治敏感、歧视性、侵害他人权益的内容，或索取他人隐私，必须先友好说明这超出了你的能力范围，再自然引导回你能做的事（记账单、记饮食、管待办、查健康/饮水/睡眠等）。示例语气："哎呀这个我确实帮不上忙呢～不过我可以帮你记生活账呀，比如记一笔、加个待办、看看今天吃了啥，你想试哪个？"不得配合生成违规内容。
5. 回复尽量简短（2-4 句），重点先说结论，需要列清单时再用换行，不要长篇大论。
6. 如果数据为空或用户问的内容数据里没有，就友好引导用户可以让你记点什么，而不是冷冰冰地说"无数据"。`;
  const contextText = JSON.stringify(context, null, 2);
  const messages = [
    { role: 'system', content: system },
    { role: 'user', content: '我的本地数据摘要如下：\n' + contextText },
    { role: 'user', content: text }
  ];
  const reply = await callChatRaw(provider, messages, apiKey);
  return { ok: true, reply };
}

// 阿记进入聊天页时的招呼语：基于用户近期数据动态生成。
// - 单轮、不调工具（招呼只读，不写），所以 SenseChat-Turbo 也能稳定输出。
// - context 由 App 端 buildGreetingContext() 注入（今日饮食、今日待办、近 14 天早餐模式、步数等）。
// - 超时或模型返回空 → App 端走本地 buildGreeting() 兜底。
const GREETING_SYSTEM_PROMPT = `你是阿记，用户刚进入聊天页，请你根据「本地数据摘要」生成 1-2 句口语化、像朋友打招呼的开场白。

要求：
1. 简体中文，口语化、像微信聊天，可以适当用"呀、哦、呢、～"等语气词；不要书面腔、不要"根据您的数据"。
2. 严格基于摘要里的真实数据，不要编造。摘要里可能包含以下字段（按优先级）：
   - entrySource：用户进入聊天页的方式（"home"=点击打字区 / "voice"=按语音键 / "todoReminder"=从待办空态提醒进来）
     - voice 场景：开头可以呼应"你按了语音键，我听着呢～想说什么直接说吧"
     - todoReminder 场景：开头可以回应"你刚叫我提醒你，要设置什么提醒呀？"
   - currentHour / currentTime：当前时间
   - todayFoods：今日已记饮食
   - commonBreakfastHour：近 14 天早餐时段习惯
   - todayBillSummary：今日账单概况（count/totalExpense/totalIncome/topExpenses）
   - upcomingToday / upcomingTodayCount：今日待办
   - latestHealthMetric：最近一次健康指标
   - stepsToday：今日步数
   - totalFoods / totalReminders：总记录数
3. 摘要里没数据时，就简单打个招呼（如「晚上好，我是阿记～今天想记点什么？」），不要硬凑。
4. 输出必须是 1-2 句（30-80 字），不要再加任何寒暄前缀如"以下是招呼："。
5. 不要在招呼里调用任何工具、不要假装给用户记了什么、不要重复发"我是阿记"。
6. **注意多样性**：避免每天说一模一样的话。即使数据相同，也尽量换不同的切入角度和表达方式。`;

async function handleGreeting(provider, body, apiKey) {
  const context = body.context || {};
  const messages = [
    { role: 'system', content: GREETING_SYSTEM_PROMPT },
    { role: 'user', content: '本地数据摘要：' + JSON.stringify(context, null, 2) },
  ];
  const reply = await callChatRaw(provider, messages, apiKey);
  const trimmed = (reply || '').trim();
  if (!trimmed) return { ok: false, error: '模型返回为空' };
  return { ok: true, reply: trimmed };
}

// queryFood 模式处理：手动添加食物页搜不到时，问云端该食物每 100g 的营养。
// - 入参 body.foodName（必填，trim 后非空）
// - 客户端 FoodPayload 期望：{name, calories, protein, carbs, fat, fiber?, sugar?, sodium?}
// - 关键：要求模型只输出 JSON。sensechat-turbo / qwen-plus 等小模型可能包 ```json``` 围栏
//   或前后多空行，extractJSON 做了防御性清洗。
// - 关键：模型说"不知道"或不是食物时，必须返回 {ok:false, error}，禁止把 caloriess=0 的伪结果返给前端。
//   客户端 queryFood() 用 calories > 0 判定"有效"，但 0 容易混在「空数据」里出错，前端显示更不友好。
// queryFood 专用的宽松 JSON 提取：extractJSON() 是图片识别专用（强制要求 types 数组，
// 缺失时丢弃解析结果返回 {types:['none']}），营养 JSON {name,calories,...} 没有 types，
// 用 extractJSON 永远解析失败。此函数只做通用清洗：剥 Markdown 围栏 / 截取首尾大括号。
function extractPlainJSON(text) {
  // 剥掉推理模型（如 glm-4.7-flash）可能夹带的 <think>...</think> 段，其中的大括号会干扰截取
  const t = (text || '').replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
  if (!t) return null;
  const fenced = t.match(/```(?:json)?\s*([\s\S]*?)```/i);
  let candidate = (fenced ? fenced[1] : t).trim();
  try {
    return JSON.parse(candidate);
  } catch (e) {
    // 模型可能在 JSON 前后加了说明文字：截取第一个 { 到最后一个 } 再试
    const first = candidate.indexOf('{');
    const last = candidate.lastIndexOf('}');
    if (first >= 0 && last > first) {
      try { return JSON.parse(candidate.slice(first, last + 1)); } catch (_) { /* fallthrough */ }
    }
    console.log(`[extractPlainJSON] 解析失败: ${e.message}, 原文: ${t.slice(0, 200)}`);
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// queryFood 性能优化（A+B+C 三合一）
// A：营养查表是确定性任务，优先用「非推理快模型」（无 <think> 思考链、首字延迟低）。
//    按候选顺序选第一个 Key 已配置的 provider；都不满足则回落前端传入的 provider（保证不退化）。
// B：callChatRaw 已支持 opts.temperature/max_tokens，queryFood 用 temperature:0 + max_tokens:300 限长。
// C：同实例内存 LRU 缓存，挡热词与跨用户重复查询（事件函数冷启会清空，属可接受）。
// ─────────────────────────────────────────────────────────────
// queryFood 结果缓存：key=归一化食物名（去空格小写），10 分钟 TTL，最多 300 条。
// 仅缓存成功结果（失败不缓存，避免缓存"无数据"）。
const _qfCache = new Map();
const QF_CACHE_TTL = 10 * 60 * 1000;
const QF_CACHE_MAX = 300;
const _qfNormKey = (n) => (n || '').trim().toLowerCase();
function _qfCacheGet(k) {
  const h = _qfCache.get(k);
  if (!h) return null;
  if (Date.now() - h.ts > QF_CACHE_TTL) { _qfCache.delete(k); return null; }
  return h.payload;
}
function _qfCacheSet(k, payload) {
  _qfCache.set(k, { ts: Date.now(), payload });
  if (_qfCache.size > QF_CACHE_MAX) {
    const fk = _qfCache.keys().next().value;
    if (fk !== undefined) _qfCache.delete(fk);
  }
}
// 选非推理快模型：候选顺序优先便宜/快模型，最后回落推理模型兜底。
const NUTRITION_PROVIDER_PRIORITY = ['glmFlash', 'qianfanText', 'deepseek', 'sensenovaText'];
function pickNutritionProvider(fallbackProvider, fallbackKey) {
  for (const name of NUTRITION_PROVIDER_PRIORITY) {
    const p = PROVIDERS[name];
    if (p && process.env[p.apiKeyEnv]) return { provider: p, key: process.env[p.apiKeyEnv], used: name };
  }
  return { provider: fallbackProvider, key: fallbackKey, used: 'fallback' };
}

async function handleQueryFood(provider, body, apiKey) {
  const rawName = (body.foodName || '').trim();
  if (!rawName) {
    return { ok: false, error: '缺少 foodName' };
  }

  // ① 缓存命中 → 直接返回，不调模型
  const cacheKey = _qfNormKey(rawName);
  const cached = _qfCacheGet(cacheKey);
  if (cached) {
    console.log(`[queryFood] 缓存命中: ${rawName}`);
    return { ...cached, cached: true };
  }

  // ①.5) 云端权威表优先（C3）：与 App 本地 NutritionLibrary 同源。命中即返确定值，
  // 不再走 LLM（避免常见食物反复估算导致数值漂移，并省一次云调用）。仅长尾回落 LLM。
  const hit = lookupFood(rawName);
  if (hit) {
    const cacheKeyT = _qfNormKey(rawName);
    const result = {
      ok: true,
      result: {
        types: ['food'],
        food: {
          name: hit.name,
          calories: hit.kcal,
          protein: hit.protein,
          carbs: hit.carbs,
          fat: hit.fat,
          fiber: hit.fiber,
          sugar: hit.sugar,
          sodium: hit.sodium,
        },
      },
      source: 'table',
      matched_name: hit.name,
    };
    _qfCacheSet(cacheKeyT, result);
    console.log(`[queryFood] 权威表命中: ${rawName} → ${hit.name}`);
    return result;
  }

  // ② 选非推理快模型（无 <think> 思考链、首字延迟低）
  const { provider: np, key: nkey, used } = pickNutritionProvider(provider, apiKey);

  const system = `你是食物营养助手。严格基于公开营养数据库（中国食物成分表 / USDA FoodData Central）输出食物每 100 克的可食部分营养。
回答规则：
1. 必须是 JSON 对象，不要解释、不要 Markdown 围栏、不要前后缀文字。
2. 字段：name（标准中文名）、calories（千卡/100g，number）、protein（克/100g）、carbs（克/100g）、fat（克/100g）、fiber（膳食纤维，克/100g，必填）、sugar（糖，克/100g，必填）、sodium（钠，毫克/100g，必填）。fiber/sugar/sodium 是用户每日摄入追踪的关键指标，必须返回；数据库未直接标注时按典型配方估算（如白米饭 fiber≈0.3、sugar≈0.1、sodium≈1），不要省略字段。
3. 绝大多数常见单一食物与复合菜品（如饺子、披萨、红烧肉、奶茶）都有可参考的典型营养值，请直接给出合理估算（基于典型配方或通用数据库），不要因为"不确定精确值"就返回 0。复合菜品可在 name 中标注口径，例如"玉米猪肉饺子（熟，约值）"。
4. 仅当满足以下之一才返回失败（calories 设为 0、name 设为 null）：a) 完全不是食物（如品牌名、虚构/臆造物、人名）；b) 你确实没有任何可参考的数据。绝不要瞎编数字。
5. 数字字段必须是 number 类型（不要带"g""kcal"等单位字符串）。`;
  const messages = [
    { role: 'system', content: system },
    { role: 'user', content: `请告诉我"${rawName}"每 100 克可食部分的营养。` },
  ];
  let reply;
  try {
    // ③ 确定性任务：低温度 + 限长，砍掉推理/啰嗦尾巴
    reply = await callChatRaw(np, messages, nkey, { temperature: 0, max_tokens: 300 });
  } catch (e) {
    return { ok: false, error: `模型调用失败: ${e.message}` };
  }
  const parsed = extractPlainJSON(reply);
  // 强制约束：必须是 {name, calories, ...} 的对象
  if (!parsed || typeof parsed !== 'object' || !('calories' in parsed)) {
    console.log(`[queryFood] 解析无 calories 字段: ${String(reply).slice(0, 200)}`);
    return { ok: false, error: '未能解析营养数据' };
  }
  const name = typeof parsed.name === 'string' && parsed.name.trim() ? parsed.name.trim() : null;
  const calories = Number(parsed.calories);
  // 关键防线：name==null 或 calories<=0 或 NaN → 整体失败，不返伪数据
  if (!name || !Number.isFinite(calories) || calories <= 0) {
    console.log(`[queryFood] 营养无效（name=${name}, calories=${calories}），原文: ${String(reply).slice(0, 200)}`);
    return { ok: false, error: '该食物不在数据库或无可靠数据' };
  }
  const toNum = (v) => {
    const n = Number(v);
    return Number.isFinite(n) && n >= 0 ? n : 0;
  };
  const result = {
    ok: true,
    result: {
      types: ['food'],
      food: {
        name,
        calories,
        protein: toNum(parsed.protein),
        carbs:   toNum(parsed.carbs),
        fat:     toNum(parsed.fat),
        fiber:   toNum(parsed.fiber),
        sugar:   toNum(parsed.sugar),
        sodium:  toNum(parsed.sodium),
      },
    },
    provider: used,
  };
  _qfCacheSet(cacheKey, result);   // ④ 仅缓存成功结果
  return result;
}

// 有些模型会在 JSON 外面包 ```json 代码块，这里做防御性清洗。
// 同时兜底解析失败（空 result / 非法 JSON / 缺 types 字段）为 {types:["none"]}，
// 避免 App 端拿到空 result 后直接崩溃。
function extractJSON(text) {
  const t = (text || '').trim();
  if (!t || t === '{}') {
    console.log(`[extractJSON] 模型返回空对象`);
    return { types: ['none'] };
  }
  try {
    const fenced = t.match(/```(?:json)?\s*([\s\S]*?)```/i);
    const candidate = fenced ? fenced[1] : t;
    const parsed = JSON.parse(candidate);
    if (!parsed || typeof parsed !== 'object' || !parsed.types || !Array.isArray(parsed.types)) {
      console.log(`[extractJSON] 缺 types 字段: ${t.slice(0, 200)}`);
      return { types: ['none'] };
    }
    return parsed;
  } catch (e) {
    console.log(`[extractJSON] 解析失败: ${e.message}, 原文: ${t.slice(0, 200)}`);
    return { types: ['none'] };
  }
}

// 云函数入口
exports.main = async (event, context) => {
  try {
    // 定时保活触发器：快速返回，不进入业务逻辑，避免消耗 token / 资源点。
    // 控制台加定时触发器 cron = "0 */5 * * * * *"（每 5 分钟）后，每次触发仅走这段就 return。
    if (event.Type === 'timer' || (event.trigger && event.trigger.Name)) {
      return { ok: true, ping: true, ts: Date.now(), ver: FN_VERSION };
    }

    // CloudBase HTTP 触发会把请求体放在 event.body；微信小程序端调用则直接是 event 对象。
    // 这里做兼容：先尝试 event.body，再回退到 event 本身。
    const body = parseEventBody(event);
    const providerName = body.provider || 'sensenova';
    const provider = PROVIDERS[providerName] || PROVIDERS.qwen;
    const apiKey = process.env[provider.apiKeyEnv];
    if (!apiKey) return { ok: false, error: `缺少环境变量 ${provider.apiKeyEnv}（请在 CloudBase 配置）`, ver: FN_VERSION };

    // ===== 付费墙：云功能须经服务端强校验（白名单→订阅→试用→免费额度→全局熔断→过期）=====
    // 付费/试用由客户端断言（App Store/Keychain 负责真实验证），直接放行省一次远程往返；
    // 免费额度/白名单/过期用户必须远程查询 aia-sync 权威状态并计费。校验失败一律拒绝（保护成本）。
    const entFeature = deriveFeature(body);
    // >>> CHANGE-[2026-08-19 22:54:43]-付费墙日志+remaining回传 开始
    // 原因: 排查免费额度不扣费——日志明确走没走付费墙/entRes 返回; 修 BugB(return 丢 _entitlement)
    // 回退: 删除 console.log 段 + return 合并 _entitlement 那行
    console.log('[entcheck] entFeature=', entFeature, 'mode=', body.mode, 'hasImg=', !!body.imageBase64, 'hasText=', !!body.text,
      'isPaid=', body.isPaid, 'trialActive=', body.trialActive, 'userId=', (body.userId || '').slice(0, 12));
    if (entFeature) {
      if (body.isPaid || body.trialActive) {
        // 付费/试用：本地放行，不查远程
        console.log('[entcheck] 客户端 isPaid/trialActive 放行，不查远程');
      } else {
        try {
          const entRes = await httpsPostJSON(SYNC_URL, {
            action: 'entitlement',
            feature: entFeature,
            userId: body.userId || '',
            deviceId: body.deviceId || '',
            userPhone: body.userPhone || '',
            isPaid: false,
            trialActive: false
          });
          console.log('[entcheck] 远程校验结果:', JSON.stringify(entRes));
          if (!entRes || entRes.allowed === false) {
            return { ok: false, error: 'entitlement_denied', code: (entRes && entRes.reason) || 'denied', plan: (entRes && entRes.plan), feature: entFeature, ver: FN_VERSION };
          }
          body._entitlement = { plan: entRes.plan, remaining: entRes.remaining };
        } catch (e) {
          console.error('entitlement remote check error, deny to protect cost:', e);
          return { ok: false, error: 'entitlement_error', code: 'check_failed', ver: FN_VERSION };
        }
      }
    }
    // <<< CHANGE-[2026-08-19 22:54:43]-付费墙日志+remaining回传 结束
    // 图片识别（默认/聊天分支）必须有 imageBase64 或 text；但 queryFood（食物营养查询，只带 foodName）
    // 与 greeting（招呼，只带 context/userId）是纯文本/上下文模式，不需要图片或 text，须在此门禁前放行，
    // 否则会先于各自 handler 被"缺少 imageBase64 或 text"拦截（此前联网搜索/云端招呼一直静默失效的根因）。
    const needsImageOrText = body.mode !== 'queryFood' && body.mode !== 'greeting';
    if (needsImageOrText && !body.imageBase64 && !body.text) return { ok: false, error: '缺少 imageBase64 或 text', ver: FN_VERSION };

    // 服务端兜底：纯通用回应（非聊天、非图片）强制 none，省一次模型调用且确定性生效，
    // 不依赖模型是否听话（提示词规则 10 的双保险）。含具体指令的（如"好的帮我改"）不拦。
    if (body.mode !== 'chat' && body.mode !== 'agent' && !body.imageBase64 && body.text && isGenericAcknowledgement(body.text)) {
      return { ok: true, result: { types: ['none'] }, ver: FN_VERSION };
    }

    // Agent 模式：可单独开关的云端智能问答（只读）。未开启或异常均回落 handleChat。
    // Agent 文字对话默认走 DeepSeek（function-calling 彻底最好）；但当用户在 App 明确
    // 选了非默认模型（如智谱 GLM）时，尊重用户选择，不走 DeepSeek 兜底。
    if (body.mode === 'agent') {
      if (process.env.AGENT_ENABLED !== 'true') {
        const chatRes = await handleChat(provider, body, apiKey);
        return { ...chatRes, ver: FN_VERSION };
      }
      // 仅当用户仍在使用默认模型（sensenova/sensenovaText）且 DEEPSEEK_API_KEY 存在时，
      // 自动升级到 DeepSeek。用户如在 App 设置里切换了（glmText/qianfanText/deepseek 等）
      // 或之前已处理过的 fallback（qwenText 等），一律尊重用户选择。
      const isDefault = providerName === 'sensenova' || providerName === 'sensenovaText';
      const useDeepSeek = process.env.DEEPSEEK_API_KEY && isDefault;
      const agentProvider = useDeepSeek ? PROVIDERS.deepseek : provider;
      const agentKey = useDeepSeek ? process.env.DEEPSEEK_API_KEY : apiKey;
      const agentRes = await handleAgent(agentProvider, body, agentKey, handleChat);
      return { ...agentRes, ver: FN_VERSION };
    }

    // queryFood 模式：纯文本食物营养查询（手动添加食物页搜不到时联网兜底）。
    // 客户端 RecognizeService.queryFood() 期望返回 { ok, result:{ food:{name, calories, protein, carbs, fat, ...} } }
    // 与 FoodPayload 编码一致；失败/找不到 → { ok:false, error } 让前端走「联网未找到」分支。
    if (body.mode === 'queryFood') {
      const qfRes = await handleQueryFood(provider, body, apiKey);
      return { ...qfRes, ver: FN_VERSION };
    }

    // 聊天模式：不返回结构化 JSON，而是基于本地数据摘要直接回答
    if (body.mode === 'chat') {
      const chatRes = await handleChat(provider, body, apiKey);
      return { ...chatRes, ver: FN_VERSION };
    }

    // 招呼模式：进入聊天页时的开场白，单轮、不调工具；返回空时 App 端走本地兜底。
    if (body.mode === 'greeting') {
      const gRes = await handleGreeting(provider, body, apiKey);
      return { ...gRes, ver: FN_VERSION };
    }

    const result = await callWithFallback(body, apiKey);
    if (result) {
      if (result.food) normalizeFoodResult(result.food);
      if (Array.isArray(result.foods)) result.foods.forEach(normalizeFoodResult);
      enrichFoodMicro(result);   // 补全 LLM 漏填的 fiber/sugar/sodium
    }
    // >>> CHANGE-[2026-08-19 22:54:43]-付费墙日志+remaining回传 开始
    // 原因: BugB——body._entitlement 赋值后从未带进返回, App 端读不到 remaining
    // 回退: 删除下面 4 行, 恢复 return { ok: true, result, ver: FN_VERSION }
    const ret = { ok: true, result, ver: FN_VERSION };
    if (body._entitlement) ret._entitlement = body._entitlement;
    return ret;
    // <<< CHANGE-[2026-08-19 22:54:43]-付费墙日志+remaining回传 结束
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
    glm4vFlash: 'qwen',           // 免费视觉→qwen（通义人人有 Key，比 sensenova 更稳定）
    sensenova: 'qwen',            // 免费视觉→付费视觉（兜底）
    sensenovaText: 'qwenText',
    glm: 'qwen',
    glmText: 'qwenText',
    qianfan: 'qwen',
    qianfanText: 'qwenText',
    deepseek: 'qwenText',
    deepseekText: 'qwenText',
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

// 补全微营养素：对 LLM 漏填 fiber/sugar/sodium 的食物项，回查权威 foodTable 命中后补值。
// 仅在 macro 已填（>0）但 micro 全 0/缺失时补全；macro=0 视为无效记录，交给客户端 Saver 跳过逻辑。
// 仅补全 micro 三项，绝不覆盖 LLM 已填的 macro，避免「静默编造」。
function enrichFoodMicro(result) {
  if (!result || typeof result !== 'object') return;
  const items = [];
  if (result.food) items.push(result.food);
  if (Array.isArray(result.foods)) items.push(...result.foods);
  if (items.length === 0) return;

  for (const f of items) {
    if (!f || typeof f !== 'object') continue;
    const name = (f.name || '').trim();
    if (!name) continue;

    const hasMacro = (f.calories || 0) > 0 || (f.protein || 0) > 0 || (f.carbs || 0) > 0 || (f.fat || 0) > 0;
    const microMissing = [f.fiber, f.sugar, f.sodium].every(v => v == null || v === 0);
    if (hasMacro && microMissing) {
      const hit = lookupFood(name);   // 复用 queryFood 同一张权威表
      if (hit) {
        f.fiber  = hit.fiber;
        f.sugar  = hit.sugar;
        f.sodium = hit.sodium;
      }
    }
  }
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
