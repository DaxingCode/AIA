// agentSchema.js
// ============================================================================
// Agent 工具的 function-calling JSON Schema（OpenAI 兼容格式）。
// 直接作为请求体的 tools 参数下发给商汤 SenseNova（sensechat-turbo）。
// 四个工具全部只读，入参 userId 由客户端透传，不得编造。
// 定义严格对应 system_design.md §3.2。
// ============================================================================

const AGENT_TOOLS = [
  // ① query_bills —— 查询账单（支出/收入），按时间范围 + 可选分类过滤
  {
    type: 'function',
    function: {
      name: 'query_bills',
      description: '查询用户的账单记录（支出/收入），可按时间范围和分类过滤。仅读取已同步数据，不创建或修改任何记录。',
      parameters: {
        type: 'object',
        properties: {
          userId: { type: 'string', description: '用户唯一ID，必须原样传入' },
          from: { type: 'number', description: '起始时间，秒级Unix时间戳；0=不限制' },
          to: { type: 'number', description: '结束时间，秒级Unix时间戳；0=不限制' },
          category: { type: 'string', description: "分类过滤，如 '餐饮'/'交通'/'超市'；可省略" },
        },
        required: ['userId', 'from', 'to'],
      },
    },
  },

  // ② query_foods —— 查询饮食记录，按时间范围 + 可选餐次过滤，附营养汇总
  {
    type: 'function',
    function: {
      name: 'query_foods',
      description: '查询用户的饮食记录，可按时间范围和餐次过滤，返回明细与营养汇总（热量/蛋白/碳水/脂肪）。只读。',
      parameters: {
        type: 'object',
        properties: {
          userId: { type: 'string', description: '用户唯一ID' },
          from: { type: 'number', description: '起始时间，秒级Unix时间戳；0=不限制' },
          to: { type: 'number', description: '结束时间，秒级Unix时间戳；0=不限制' },
          meal: { type: 'string', description: '餐次过滤：早餐/午餐/晚餐/加餐；可省略' },
        },
        required: ['userId', 'from', 'to'],
      },
    },
  },

  // ③ query_health —— 查询健康指标最新值，可选指标名
  {
    type: 'function',
    function: {
      name: 'query_health',
      description: '查询用户的健康指标最新值（如体重、血压、步数），可按指标名过滤。只读。',
      parameters: {
        type: 'object',
        properties: {
          userId: { type: 'string', description: '用户唯一ID' },
          metric: { type: 'string', description: "指标名过滤，如 '体重'/'血压'；省略则返回全部最新指标" },
        },
        required: ['userId'],
      },
    },
  },

  // ④ get_summary —— 生成 today/yesterday/last7Days 聚合摘要（云端重算 buildContext）
  {
    type: 'function',
    function: {
      name: 'get_summary',
      description: '生成指定时间范围的聚合摘要（账单收支、饮食营养、待办、健康），等价于客户端 buildContext 的云端重算。只读。',
      parameters: {
        type: 'object',
        properties: {
          userId: { type: 'string', description: '用户唯一ID' },
          range: { type: 'string', enum: ['today', 'yesterday', 'last7Days'], description: '聚合范围' },
        },
        required: ['userId', 'range'],
      },
    },
  },
];

module.exports = { AGENT_TOOLS };
