// CloudBase 云函数：截图/照片识别（多模态大模型代理）
// ----------------------------------------------------------------------------
// 作用：App 把图片(base64)发过来，本函数调用「通义千问视觉 Qwen-VL」，
//       返回结构化 JSON（含 type 路由：food / bill / todo / health / none）。
// 好处：API Key 只存在云端（环境变量），App 不直接接触，避免被逆向泄露。
// 部署：在 CloudBase 控制台新建「云函数」-> 上传本目录 -> 开启 HTTP 触发。
// ----------------------------------------------------------------------------

const https = require('https');

// 数据库（纠错样本回流）：优先 CloudBase Node SDK，其次微信云开发 wx-server-sdk。
// 若运行环境未提供任一 SDK，db 置 null，识别与报错降级为「无学习」，绝不影响主流程。
let db = null;
try {
  let cloud;
  try { cloud = require('@cloudbase/node-sdk'); }
  catch (_) { try { cloud = require('wx-server-sdk'); } catch (_) { cloud = null; } }
  if (cloud) {
    const env = cloud.DYNAMIC_CURRENT_ENV || process.env.CLOUDBASE_ENV_ID;
    const app = cloud.init({ env });
    db = (app && app.database) ? app.database() : (cloud.database ? cloud.database() : null);
  }
} catch (_) { db = null; }
const CORRECTIONS_COL = 'aia_corrections';

// 不同服务商的调用配置；默认 qwen（通义千问视觉）。
// 其他三家是预留：将来想对比/回落，只改 event.provider 即可，App 不用动。
// 注意：API Key 请配置成 CloudBase 的「环境变量」，不要硬编码在这里！
const PROVIDERS = {
  qwen: {
    endpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    model: 'qwen-vl-plus', // 视觉模型：复杂图片/食物照片兜底
    apiKeyEnv: 'DASHSCOPE_API_KEY',
  },
  qwenText: {
    endpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    model: 'qwen-plus', // 文本模型：OCR 后的文字识别，比视觉便宜一档
    apiKeyEnv: 'DASHSCOPE_API_KEY',
  },
  doubao: {
    endpoint: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    model: 'doubao-vision',
    apiKeyEnv: 'DOUBAO_API_KEY',
  },
  glm: {
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4v',
    apiKeyEnv: 'GLM_API_KEY',
  },
};

// 版本标记：发布后 curl 可通过返回值里的 ver 字段确认是否部署了最新代码
const FN_VERSION = '20260721l';

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
  "bills":  [ { "merchant":"滴滴出行", "amount":24.0, "currency":"CNY", "category":"交通", "time":"2026-07-16T09:10:00+08:00", "note":"" } ],
  "food":   { "name":"洋葱炒肉", "calories":280, "protein":18, "carbs":12, "fat":18, "portion":"1份" },
  "todo":   { "title":"交月度报表", "due":"2026-07-16T18:00:00+08:00", "repeat":"none", "priority":"high" },
  "health": { "metric":"体检预约", "value":"2026-08-30", "unit":"", "note":"南宁江南分院，含空腹血糖" }
}
规则：
1. 只输出图片中真实出现的信息，不要编造、推断或臆测。如果看不清，就降低 confidence 或返回 ["none"]。
2. 只填写与 types 对应的字段；未命中的类型字段省略或设为 null。
3. 金额用数字（如 24.0）；货币默认 "CNY"。
4. 当前时间：{CURRENT_TIME}。所有相对时间（如"明天""周五""下周三"）必须基于当前时间推算为绝对时间；返回的时间必须是 ISO8601 格式（含时区 +08:00）。**如果截图/账单里完全没有显示任何时间信息，账单 time 必须填写当前时间 {CURRENT_TIME}（含时分秒），绝不要写 00:00:00；只有当截图明确显示 0 点（如"00:15""凌晨0点"）时才允许 time 为 00:xx。**
5. 支持一图多意图：例如"付完款记得交报表"应返回 ["bill","todo"] 两条。
6. 食物热量是估算值，允许误差；如有包装/外卖图标请尽量准确。营养成分表优先读取每100克数据，portion 写"100克"或整包净含量。calories 字段必须是千卡（kcal）。同时返回 energyRaw（标签原始能量数值）和 energyUnit（kJ 或 kcal）。如果 energyUnit 是 kJ 或 千焦，calories = energyRaw / 4.184；如果 energyUnit 是 kcal 或 千卡，calories = energyRaw。换算结果允许四舍五入到整数。
7. 如果是聊天截图，请提取其中截图或文字里的关键信息；如果聊天内容本身没有明确可记录的 bill/food/todo/health，则返回 types: ["none"]。**如果聊天内容涉及体检、就医、检查预约、疫苗、复诊等健康事项，即使只有文字描述（如"空腹血糖""去江南分院"），也必须同时返回 "health" 和 "todo" 两类。**
8. 体检预约、检查报告、医疗相关内容优先归为 health；**同时必须额外生成一条 todo**：title 写具体事项（如"去江南分院体检""空腹血糖检查"），有明确执行/预约时间（如"8月30日""周五"）就填 due，没有明确时间则省略 due 字段或填 null，repeat 默认 "none"，priority 默认 "high"，让 types 同时包含 "health" 和 "todo"。
9. 食品包装上的营养成分表属于 food，不属于 health。
10. 如果截图/聊天内容涉及「犹豫期」「N天(内/后)」「截止日」「还款日」「N天内确认/办理」等「相对 N 天后的截止或办理类」事项，必须生成一条 todo：title 写具体事项（犹豫期场景写"犹豫期结束前确认是否退保"，其他场景写"XX截止"或"XX办理"，如"信用卡还款截止"）；due = 当前时间 + N 天（基于 {CURRENT_TIME} 推算成绝对时间，ISO8601 含 +08:00；出现"左右""约""大概"时按字面天数计算，如"15天左右"算 15 天）；priority 默认 "high"；让 types 包含 "todo"。若同图还存在体检/就医/账单等内容，types 要一并包含对应类型，并按各自规则补充字段。
11. 如果截图是支付宝/微信「账单详情」「支付成功」「账单列表」「付款记录」「消费明细」「转账记录」等，或线下「超市小票」「便利店小票」「收银小票」「购物小票」「餐饮小票」「外卖订单」等，**都必须识别为 bill**。即使金额显示为负数（如支付宝支出 -18.00）、商户名被脱敏为「**娟(个人)」、或商品说明是「经营码交易」「转账」等，也绝不要返回 none。
**金额读取优先级**：① 带 ¥/￥/元 的数字；② 支付宝/微信详情里常见的「-18.00」「−18.00」「-¥18.00」等带负号金额，表示支出，amount 取绝对值 18.0；③ 小票/订单上的「应收」「实收」「合计」「总计」「成交价」「实付金额」「微信支付」「支付宝支付」「现金」后面的数字；④ 收入取正数。**绝对不要把银行卡号/信用卡号后四位、手机号、订单号、会员卡号、流水号、开票号、税号、客服电话、时间、群人数、楼层、教室/会议室号当金额**，如「中国银行信用卡(6590)」「尾号 1234」「手机号 138****8888」「订单号 8268900990031390」「流水号 4200003112202607153880404554」「客服电话：0771-5622691」「18:34」「9:00-18:00」「(36)」「47楼」「A座47楼」里的数字都不是金额。如果金额和这些长串数字同时出现，优先选带 ¥、负号、或紧跟「应收/实收/合计/微信支付」的金额。
商户名 cleaning：去掉首尾星号*，去掉「(个人)」「(商户)」等后缀，如「**娟(个人)」→ merchant 填「娟」；小票顶部的店名如「永辉(95HC 南宁盛隆世界店)欢迎您」→ merchant 填「永辉」或「永辉超市」；若收款方只有星号或无法读取，可取「商品说明」「账单」或「超市/便利店」作为 merchant。若无法确定分类，category 可填"其他"，但绝不要返回 none。
12. **一图多账单：如果图片里有多条账单记录（如账单列表、消费明细、多笔转账/支付），请返回 "bills" 数组，每一笔账单都是数组里的一个完整对象（含 merchant/amount/currency/category/time/note 等字段），App 会逐条分别记录。数组中每条账单都要有独立的标题(merchant)、日期、时间和金额，不要合并或只取一条。如果只有一条账单，也请用 "bills" 数组（只含一个元素），不要用单个 "bill" 对象，统一格式便于 App 处理。**
13. **食物照片必须识别为 food**：只要图片主体是食物（家常菜、炒菜、外卖餐、餐厅菜品、汤、粥、面、饭、点心、水果、饮品、营养成分表等），必须返回 types 包含 "food"。给出合理的食物名称（如"洋葱炒肉""青椒肉丝"），calories 给估算千卡值，portion 写"1份"或"100克"；即使看不清具体菜名，也应描述为可见主要食材（如"炒肉丝与洋葱"）。**绝不要对明显是食物的照片返回 ["none"]**。仅当图片明显不是食物（如风景、文字文档、人物、桌面杂物）时才允许返回 ["none"]。
14. **微信群聊通知/活动海报/培训会议/招募报名截图优先识别为 todo**：如果截图内容是微信群聊里的通知、活动海报、培训/训练营/课程/讲座/会议/招募报名信息（含「培训时间」「上课时间」「地点」「课程安排」「报名」「招募」「建议参训对象」等），**必须识别为 todo**，标题用活动/培训主题（如"招募训练营报名""三年建百人团队技巧培训"），due 取活动开始时间（如"2026年7月28日9:00"），repeat "none"，priority 默认 "medium"；**绝不要识别为 bill**。这类截图里的数字（时间、群人数、楼层、教室号）都不是金额。
15. **云服务商消费必须归类 "云服务"**：若商户是阿里云/腾讯云/华为云/天翼云/百度云/京东云等云厂商，或截图/文字涉及「云计算」「云服务器」「ECS」「云数据库」「OSS」「对象存储」「CDN」「域名」「SSL证书」「云监控」「云函数」等云资源购买，bill 的 category 必须填 "云服务"，**不要**归到 "数码""购物""其他"。merchant 保留品牌名（如 "阿里云""腾讯云"）。;\n16. **支付宝/微信账单详情页字段提取铁律（极易错，务必遵守）**：\n- 金额：只从「商品金额/付款金额/实付金额/订单金额/应付金额」标签后，或页面顶部大字号金额（如 -10.00、¥10.00、−10.00）读取。这是唯一正确金额，绝不要从「订单号」「流水号」「交易号」里的数字、或状态栏时间里的数字取金额。\n- 时间：只从「支付时间/交易时间/付款时间/创建时间」这一行读取（如 2026-07-21 19:09:35）。**页面顶部状态栏显示的时间（如 19:34）是「你截图的时间」，不是账单交易时间，绝对禁止把它当作账单 time。** 只有在截图里完全没有「支付时间」这类行时，才允许用当前时间 {CURRENT_TIME}。\n- 商户：只从「收款方全称/商户名称/付款方/商家」标签后读取（如「阿里云计算有限公司」→ merchant 填「阿里云」或「阿里云计算有限公司」）。**「19:09」「19:34」这类 HH:mm 时间串是时间，绝不是商户名，禁止当作 merchant。** 没有商户标签但能看到平台/店铺名时，才取平台/店铺名。\n- 分类：若商户或商品含「阿里云/腾讯云/华为云/云计算/云服务器/ECS/OSS/CDN/域名」等云相关词，category 必须填「云服务」。`;

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
  "bills": [ { "merchant":"滴滴出行", "amount":24.0, "currency":"CNY", "category":"交通", "time":"2026-07-16T09:10:00+08:00", "note":"", "action":"create", "targetTitle":"" } ],
  "food": { "name":"伊利畅轻风味发酵乳", "calories":100, "protein":2.7, "carbs":14.0, "fat":3.6, "portion":"100克", "meal":"早餐", "action":"create", "targetTitle":"" },
  "todo": { "title":"交月度报表", "due":"2026-07-16T18:00:00+08:00", "repeat":"none", "priority":"high", "action":"create", "targetTitle":"" }
}
规则：
1. 只从用户消息中提取真实信息，不要编造。
2. 只填写与 types 对应的字段；未命中的类型字段省略或设为 null。
3. 金额用数字；货币默认 "CNY"。收入类关键词（工资、报销、退款、奖金、转账收入、投资收益）金额记为正数。如果 OCR 文字里金额带负号（如支付宝详情 "-18.00"），表示支出，amount 取绝对值。**不要把银行卡号/信用卡号后四位、手机号、订单号当金额**，如「信用卡(6590)」「尾号1234」里的数字不是金额。
4. 当前时间：{CURRENT_TIME}。所有相对时间（如"明天""下午3点""周五""下周三""7月30日"）必须基于当前时间推算为绝对时间；如未说明日期，默认是最近的一个未来时间点。返回的时间必须是 ISO8601 格式（含时区 +08:00）。
5. 支持一消息多意图：例如"付完款记得交报表"应返回 ["bill","todo"]。
6. 食物字段返回的是**每100克**的热量和营养：calories 为千卡（kcal）、protein/carbs/fat 为克，均为每100g含量。portion 写用户描述的分量，如"1个""1杯""100克"；App 会根据 portion 解析重量并按每100g自动换算总量。**meal 字段根据用户消息里的餐次关键词推断：早餐/早饭→早餐、午餐/午饭→午餐、晚餐/晚饭/夜宵→晚餐、加餐/点心/零食→加餐；如用户未提及则省略该字段。**
7. 明确饮食意图（消息含"吃""喝"或具体食物名，如"晚餐吃了越南炸春卷100克"）时，**必须**返回 types 包含 "food"，并给出 name、calories、protein、carbs、fat、portion 的合理估算值，**绝不要返回 ["none"]**。即使是不常见的食物，也根据其主要食材与做法估算；不要以"查不到"为由拒绝返回 food。只有消息明显与饮食无关（如风景、纯闲聊、明确疑问且无记录意图）时才允许返回 ["none"]。
8. **重要：区分「提问」与「记录指令」。如果用户只是在提问（消息包含"？"、"几点"、"多少"、"吗"、"呢"、"怎么"、"为什么"、"什么"、"如何"、"谁"、"哪里"、"哪位"、"请问"等疑问词，或以问号结尾），不要把它当作待办/饮食/账单。请返回 types: ["none"]，不要生成任何 payload。**
   例如："今晚几点睡？"是提问，应返回 types: ["none"]；"帮我设置一个22:00的睡觉提醒"才是记录指令，应返回 types: ["todo"]。
9. **重要：上下文理解。我会把最近几条聊天记录放在请求里。请根据上下文判断用户是在新建、修改还是删除已有记录。所有类型（food/bill/todo）都适用同样的 action 约定。**
   - action 取值："create"（默认，新建）、"update"（修改前文提到的记录）、"delete"（删除前文提到的记录）。待办额外支持 "complete"（标记完成）。
   - targetTitle：修改/删除时，尽量填前文那条记录的关键词片段（如食物名、商户名、待办标题），帮助用户端精准定位目标；新建时可省略或填空串。
   - **默认是 create**：用户说"周五提醒我交报表""午饭35""买咖啡30"这类表达，无论是否已有同名记录，都视为**再次创建**，不要因为有同名记录就推断为 update/delete/complete。
   - **必须明确看到操作词才能返回 update/delete/complete**：
     - update：出现"改""改成""改到""改一下""改为""修改""更新""调整""提前""延后"等词。
     - delete：出现"删除""删掉""删了""取消""去掉""不要了""移除"等词。
     - complete（仅待办）：出现"完成""完成了""搞定""搞定了""做完了""标记完成""已完成"等词。
   例如：
   - 前文记了饮食「螺蛳粉」，用户说"把螺蛳粉热量改成 500" → 返回 food: { name:"螺蛳粉", calories:500, action:"update", targetTitle:"螺蛳粉" }。
   - 前文记了账单「滴滴出行 ¥24」，用户说"那笔滴滴删掉" → 返回 bill: { merchant:"滴滴出行", amount:24.0, action:"delete", targetTitle:"滴滴" }。
   - 前文创建了待办「带上身份证，空腹去体检」，用户说"这个提醒帮我改成7月30日" → 返回 todo: { title:"带上身份证，空腹去体检", due:"2026-07-30T09:00:00+08:00", action:"update", targetTitle:"带上身份证" }。
   - 用户说"帮我增加一个7月30日去体检的提醒" → 直接新建，返回 todo: { title:"去体检", due:"2026-07-30T09:00:00+08:00", action:"create" }。
   - **关键**：前文刚创建待办「交报表」，用户接着说"周五提醒我交报表" → 这是重复创建，仍返回 todo: { title:"交报表", due:"...", action:"create" }。
10. **重要：不要重复执行。如果用户消息是简短通用回应（如"好的"、"可以"、"嗯"、"行"、"谢谢"、"再见"、"嗯嗯"、"哦"、"知道了"），或者与记录无关（如"你是谁"、"你叫什么"、"随便聊聊"），无论上下文如何，都返回 types: ["none"]，不要再次创建、修改或删除任何记录。**
   例如：用户已创建待办「写代码」，随后说"好的" → 返回 types: ["none"]，而不是再建一条"写代码"。
11. **重要：不要对同一用户消息进行重复响应或自我确认。如果上一条已经是 AI 回复，用户的消息只是简单回应，不要把它理解为"继续执行上一次操作"。**
12. **一消息多账单：如果一条消息里包含多笔账单（如"买了A花了10，买了B花了20"），请返回 "bills" 数组，每笔一个完整对象（含 merchant/amount/currency/category/time/note/action）；不要用单个 "bill" 对象，统一格式便于 App 逐条处理。**
14. **微信群聊通知/活动海报/培训会议/招募报名类文字，优先识别为 todo，绝不为 bill**：如果用户消息（或 OCR 文字）是培训/训练营/课程/讲座/会议/招募报名/活动通知（含「培训时间」「上课时间」「地点」「课程安排」「报名」「招募」「建议参训对象」「参训」等），**必须识别为 todo**，title 用活动/培训主题（如"招募训练营报名""三年建百人团队技巧培训"），due 取活动开始时间（如"2026年7月28日9:00"），repeat "none"，priority 默认 "medium"；**绝不要当账单**。这类文字里的数字（时间、群人数、楼层、教室/会议室号）都不是金额，不要提取成账单金额。
15. **饮食 + 消费金额 = 同时记账单和热量**：当用户消息同时包含饮食描述（如"喝了奶茶""吃了火锅""来杯星巴克"）和消费金额（如"花了35""¥30""30元"）时，应**同时**生成一条 bill（记录花费）和一条 food（记录该食物的热量/营养），让 types 同时包含 "bill" 和 "food"。例如"喝了一杯星巴克奶茶花了¥35" → types: ["bill","food"]；bills 里记 merchant:"星巴克"、amount:35.0、category 按饮品推断（如"餐饮"）；food 里记 name:"星巴克奶茶"、calories 估算该杯总热量（如约 350 kcal）、portion:"1杯"。这样用户既能记账又能追踪卡路里摄入。仅含饮食描述无金额（如"喝了一杯奶茶"）→ 只返回 food；仅含金额无饮食描述（如"花了35"）→ 只返回 bill。
16. **云服务商消费必须归类 "云服务"**：若商户是阿里云/腾讯云/华为云/天翼云/百度云/京东云等云厂商，或消息含「云计算」「云服务器」「ECS」「云数据库」「OSS」「对象存储」「CDN」「域名」「SSL证书」等云资源购买，bill 的 category 必须填 "云服务"，**不要**归到 "数码""购物""其他"。merchant 保留品牌名（如 "阿里云""腾讯云"）。`;

// 食物营养专用查询提示词：本地食物库未命中时，App 直接问营养，不走通用意图识别。
const SYSTEM_PROMPT_QUERY_FOOD = `你是一个食物营养估算助手。用户会提供一个食物名称，请估算该食物**每100克**的热量与三大营养素。
只输出一个 JSON 对象，不要任何解释文字，格式如下：
{
  "name": "越南炸春卷",
  "calories": 180,
  "protein": 4.0,
  "carbs": 30.0,
  "fat": 6.0
}
规则：
1. name 尽量用用户提供的名称；如果是中餐菜品、地方小吃、街头食物，根据常见食材与做法估算。
2. calories 是千卡（kcal），protein/carbs/fat 是克，**全部按每100克可食部**计算。
3. 即使是不常见食物，也基于其主要食材（肉/菜/主食/油炸/清蒸等）给出合理估算，**绝不能返回空或拒绝**。
4. 只返回 JSON，不要 markdown 代码块，不要附加说明。`;

// 调用 OpenAI 兼容接口（Qwen / Doubao / GLM 都支持这种格式）
// 传入 customSystem 时优先使用（如 queryFood 模式），否则按 image/text 自动选择默认提示词。
function callChatCompletions(provider, { imageBase64, text, recentMessages, fewShotText, customSystem }, apiKey) {
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
    const systemPrompt = (customSystem
      ? customSystem.replace(/{CURRENT_TIME}/g, currentTime)
      : (isImage ? SYSTEM_PROMPT_IMAGE : SYSTEM_PROMPT_TEXT)
          .replace(/{CURRENT_TIME}/g, currentTime));

    // 用户历史纠错偏好（few-shot）：让模型越用越懂用户习惯，db 不可用时为空
    if (fewShotText && fewShotText.length) {
      systemPrompt += '\n\n' + fewShotText;
    }

    const body = JSON.stringify({
      model: provider.model,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userContent },
      ],
      response_format: { type: 'json_object' },
      temperature: 0.2,
      max_tokens: 4000,
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

数据结构说明（供你回答时参考）：
- today.foods：今日饮食记录，每项包含 calories（千卡）、protein（克）、carbs（克）、fat（克）、meal（餐次）、portion（份量）、date（时间）
- today.totalProtein / totalCarbs / totalFat：今日蛋白质/碳水/脂肪总量
- today.bills：今日账单，含 merchant（商户/标题）、amount（金额）、category（分类）、isIncome（是否收入）、time（时间）、note（备注）
- today.totalExpense / totalIncome：今日支出/收入合计
- today.todos：今日待办，含 title、due（截止时间）、priority（优先级）
- yesterday.foods / yesterday.bills / yesterday.todos：昨日数据，结构与 today 相同。用户问"昨天花了多少/昨天吃什么/昨天有什么事"时必须优先看这里。
- last7Days：最近 7 天汇总（totalCalories / totalProtein / totalCarbs / totalFat / totalExpense / totalIncome），以及 dailyFoods 每日明细、dailyBills 每日逐条账单明细。用户问"最近花了什么"可逐条列出。
- health：stepsToday（今日步数）、activeEnergyToday（今日活动消耗千卡）、latestMetrics（最新健康记录，如体重/身高/心率/体检等）
- upcomingTodos：近期待办；activeTodos：全部未完成待办，含 repeatRule（重复规则）

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

// 食物营养专用查询：本地食物库未命中时，App 直接问营养，不走通用意图识别。
async function handleQueryFood(provider, body, apiKey) {
  const foodName = String(body.foodName || '').trim();
  if (!foodName) {
    return { ok: false, error: '缺少 foodName' };
  }
  const result = await callChatCompletions(provider, {
    text: foodName,
    customSystem: SYSTEM_PROMPT_QUERY_FOOD
  }, apiKey);
  // 模型可能返回数组或对象；统一取第一个对象或对象本身
  let food = null;
  if (Array.isArray(result) && result.length > 0) food = result[0];
  else if (result && typeof result === 'object' && !Array.isArray(result)) food = result;
  if (!food || typeof food !== 'object') {
    return { ok: false, error: '模型未返回有效食物营养数据' };
  }
  // 校验关键字段
  const calories = parseFloat(food.calories);
  const protein = parseFloat(food.protein);
  const carbs = parseFloat(food.carbs);
  const fat = parseFloat(food.fat);
  if ([calories, protein, carbs, fat].some(v => isNaN(v))) {
    return { ok: false, error: '模型返回营养字段不完整' };
  }
  return {
    ok: true,
    result: {
      types: ['food'],
      confidence: 0.9,
      food: {
        name: foodName,
        calories: calories,
        protein: protein,
        carbs: carbs,
        fat: fat,
        portion: '100克',
        action: 'create',
        targetTitle: ''
      }
    }
  };
}

// 有些模型会在 JSON 外面包 ```json 代码块 / 返回不合法 JSON（OCR 文本混入引号、换行、
// 缺逗号、末尾多逗号、被截断等）。这里做多级防御性清洗与修复，最终兜底返回 none，
// 避免偶发坏 JSON 直接中断整条识别链路（用户会看到「解析模型返回失败」报错弹窗）。
function extractJSON(text) {
  const raw = String(text == null ? '' : text);

  // 0. 去掉 ```json ``` 代码块围栏
  const fenced = raw.trim().match(/```(?:json)?\s*([\s\S]*?)```/i);
  let candidate = (fenced ? fenced[1] : raw).trim();

  // 1. 直接解析
  const direct = tryParse(candidate);
  if (direct !== undefined) return direct;

  // 2. 只取第一个 { 到最后一个 } 之间的内容（去掉前后多余解释文字）
  const start = candidate.indexOf('{');
  const end = candidate.lastIndexOf('}');
  if (start >= 0 && end > start) {
    candidate = candidate.slice(start, end + 1);
    const sliced = tryParse(candidate);
    if (sliced !== undefined) return sliced;
  }

  // 3. 常见修复：去掉末尾多余逗号；去掉控制字符；补属性间缺失的逗号
  let repaired = candidate
    .replace(/,\s*([}\]])/g, '$1')                          // 末尾多逗号 {"a":1,} → {"a":1}
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '') // 去掉不可见控制字符
    // 属性/元素间缺逗号：值(引号/]/}/数字/布尔/null) 后直接跟 "key" → 补一个逗号
    .replace(/(["\]}]|\d|true|false|null)\s+(")/g, '$1,$2');
  const rep1 = tryParse(repaired);
  if (rep1 !== undefined) return rep1;

  // 4. 处理被截断的 JSON：从末尾逐字符回退，尝试补齐括号后解析
  const salvaged = salvageTruncatedJSON(repaired);
  if (salvaged !== undefined) return salvaged;

  // 5. 全部失败 → 兜底返回 none（不抛错），让主 App 至少能弹确认页而非报错
  console.error('[extractJSON] 无法解析模型返回，已兜底 none。原始内容前 400 字：', raw.slice(0, 400));
  return { types: ['none'], _parseError: true };
}

function tryParse(s) {
  try { return JSON.parse(s); } catch (_) { return undefined; }
}

// 补齐被截断的 JSON：统计未闭合的 { [ ，在末尾补上对应的 ] }，并去掉末尾残缺片段
function salvageTruncatedJSON(s) {
  let str = s;
  // 去掉末尾可能残缺的 "key": 或半个字符串
  str = str.replace(/,\s*"[^"]*"\s*:\s*$/,'').replace(/,\s*$/,'');
  const stack = [];
  let inStr = false, esc = false;
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
    if (inStr) {
      if (esc) { esc = false; }
      else if (c === '\\') { esc = true; }
      else if (c === '"') { inStr = false; }
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === '{') stack.push('}');
    else if (c === '[') stack.push(']');
    else if (c === '}' || c === ']') stack.pop();
  }
  if (inStr) str += '"';
  while (stack.length) str += stack.pop();
  return tryParse(str);
}

// 读取用户近 N 条纠错样本，格式化为「偏好参考」段落，作为 few-shot 注入识别提示词。
// 这样模型能学到用户的习惯（如「淘宝闪购→购物类」「中国电信→通讯类」），越用越准。
async function loadFewShot(limit = 8) {
  if (!db) return '';
  const res = await db.collection(CORRECTIONS_COL).orderBy('createdAt', 'desc').limit(limit).get();
  const list = (res && res.data) || [];
  if (!list.length) return '';
  const lines = list.map((c, i) => {
    const o = c.original || {};
    const k = c.corrected || {};
    const t = c.type || '?';
    if (t === 'bill') {
      return `${i + 1}. 账单：识别为商户「${o.merchant ?? '?'}」、分类「${o.category ?? '?'}」→ 用户修正为分类「${k.category ?? '?'}」（商户保持「${k.merchant ?? o.merchant ?? '?'}」）`;
    }
    if (t === 'food') {
      return `${i + 1}. 食物：识别为「${o.name ?? '?'}」→ 用户修正为「${k.name ?? o.name ?? '?'}」`;
    }
    if (t === 'todo') {
      return `${i + 1}. 待办：识别为「${o.title ?? '?'}」→ 用户修正为「${k.title ?? o.title ?? '?'}」`;
    }
    if (t === 'health') {
      return `${i + 1}. 健康：识别为「${o.metric ?? '?'}」→ 用户修正为「${k.metric ?? o.metric ?? '?'}」`;
    }
    return `${i + 1}. ${t}：原=${JSON.stringify(o)} → 改=${JSON.stringify(k)}`;
  });
  return '以下是用户以往的识别修正偏好（仅供参考，遇到相似情况请优先遵循用户的习惯）：\n' + lines.join('\n');
}

// 接收 App 上报的纠错样本：{ type, original, corrected }，写入 aia_corrections 集合。
// 失败不影响主流程（db 不可用或写失败都返回 ok:false 但不抛错）。
async function handleFeedback(body) {
  const { type, original, corrected } = body;
  if (!db) return { ok: false, error: '数据库不可用（学习功能未启用）', ver: FN_VERSION };
  if (!type || !original || !corrected) return { ok: false, error: '缺少参数', ver: FN_VERSION };
  try {
    await db.collection(CORRECTIONS_COL).add({ type, original, corrected, createdAt: new Date() });
    return { ok: true, ver: FN_VERSION };
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e), ver: FN_VERSION };
  }
}

// 图片识别结果缓存（云端路由兜底）：相同图片（base64 完全一致，如重复发送、快捷指令双触发）
// 直接返回历史识别结果，跳过 Qwen-VL 视觉调用，省 token。仅在 db 可用时启用，缓存 30 天失效。
// 关键：cachedAt 必须存真实 Date 类型，否则 MongoDB TTL 索引（见 ensureImageCacheTTLIndex）不会自动清理。
const REC_IMG_CACHE = 'aia_img_cache';
const IMG_CACHE_TTL = 30 * 24 * 60 * 60 * 1000;

function hashImage(base64) {
  try { return require('crypto').createHash('sha256').update(String(base64)).digest('hex'); }
  catch (_) { return null; }
}

async function loadImageCache(hash) {
  if (!db || !hash) return null;
  try {
    // 缓存 key 带 FN_VERSION：prompt/规则升级后自动失效旧缓存，避免老 none 结果继续命中。
    const cacheId = hash + '_' + FN_VERSION;
    const res = await db.collection(REC_IMG_CACHE).doc(cacheId).get();
    const doc = res && res.data;
    if (!doc || !doc.result) return null;
    // cachedAt 存真实 Date 类型；过期后数据库 TTL 索引会自动删除，这里再读时检查一遍做兜底。
    if (doc.cachedAt) {
      const t = (doc.cachedAt instanceof Date) ? doc.cachedAt.getTime() : new Date(doc.cachedAt).getTime();
      if (!isNaN(t) && Date.now() - t > IMG_CACHE_TTL) return null;
    }
    return doc.result;
  } catch (_) { return null; }
}

async function saveImageCache(hash, result) {
  if (!db || !hash) return;
  try {
    const cacheId = hash + '_' + FN_VERSION;
    await db.collection(REC_IMG_CACHE).doc(cacheId).set({ result, cachedAt: new Date() });
  } catch (_) { /* 缓存写失败不影响主流程 */ }
}

// 确保 aia_img_cache.cachedAt 上有 TTL 索引：数据库后台定时任务会自动删除过期文档，
// 否则缓存集合只增不减、长期膨胀。MongoDB TTL 索引要求被索引字段为 Date 类型（已满足）。
// 幂等：同一函数实例只真正建一次（ttlIndexPromise 缓存），失败不影响主流程。
let ttlIndexPromise = null;
function ensureImageCacheTTLIndex() {
  if (!db) return Promise.resolve(false);
  if (ttlIndexPromise) return ttlIndexPromise;
  ttlIndexPromise = (async () => {
    try {
      await db.collection(REC_IMG_CACHE).createIndex(
        { cachedAt: 1 },
        { expireAfterSeconds: IMG_CACHE_TTL / 1000, name: 'ttl_cachedAt' }
      );
      console.log('[ensureImageCacheTTLIndex] TTL 索引已就绪（cachedAt，' + (IMG_CACHE_TTL / 1000) + 's）');
      return true;
    } catch (e) {
      console.warn('[ensureImageCacheTTLIndex] 创建 TTL 索引失败（可忽略，主流程不受影响）：', e && e.message);
      return false;
    }
  })();
  return ttlIndexPromise;
}

// 云函数入口
exports.main = async (event, context) => {
  try {
    // CloudBase HTTP 触发会把请求体放在 event.body；微信小程序端调用则直接是 event 对象。
    // 这里做兼容：先尝试 event.body，再回退到 event 本身。
    const body = parseEventBody(event);

    // 纠错样本回流：App 在确认页修改识别结果后上报，写入 aia_corrections，供下次 few-shot 学习。
    if (body.action === 'feedback') {
      return await handleFeedback(body);
    }

    const providerName = body.provider || (body.imageBase64 || body.mode === 'chat' ? 'qwen' : 'qwenText');
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

    // 食物营养专用查询：本地食物库未命中时，App 直接问营养，不走通用意图识别。
    if (body.mode === 'queryFood' && body.foodName) {
      const foodRes = await handleQueryFood(provider, body, apiKey);
      return { ...foodRes, ver: FN_VERSION };
    }

    // 识别前读取用户历史纠错偏好，作为 few-shot 注入（db 不可用时自动跳过）
    let fewShotText = '';
    if (db) {
      try { fewShotText = await loadFewShot(); } catch (e) { fewShotText = ''; }
    }

    // 云端路由兜底：相同图片（base64 完全一致）直接返回历史识别结果，跳过视觉模型调用，省 token。
    if (body.imageBase64) {
      const imgHash = hashImage(body.imageBase64);
      if (imgHash) {
        ensureImageCacheTTLIndex(); // 懒建 TTL 索引（幂等），让过期缓存自动清理
        const cached = await loadImageCache(imgHash);
        if (cached) {
          if (cached.food) normalizeFoodResult(cached.food);
          return { ok: true, result: cached, cached: true, ver: FN_VERSION };
        }
      }
    }

    const result = await callChatCompletions(provider, { imageBase64: body.imageBase64, text: body.text, recentMessages: body.recentMessages, fewShotText }, apiKey);
    if (result && result.food) {
      normalizeFoodResult(result.food);
    }
    // 写回图片缓存：下次同一张图直接命中，不再调 AI
    if (body.imageBase64) {
      const imgHash = hashImage(body.imageBase64);
      if (imgHash) { ensureImageCacheTTLIndex(); await saveImageCache(imgHash, result); }
    }
    return { ok: true, result, ver: FN_VERSION };
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e), ver: FN_VERSION };
  }
};

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
