// agentSchema.js
// Agent 模式的 function-calling 工具定义（OpenAI 兼容格式）。
// 注意：userId 由服务端在调用工具时强制注入（防越权），schema 中故意不暴露，避免模型传参。
const TOOL_SCHEMAS = [
  {
    type: 'function',
    function: {
      name: 'query_bills',
      description: '查询用户的账单记录（只读）。可按分类、时间范围过滤，并返回收入/支出汇总。',
      parameters: {
        type: 'object',
        properties: {
          category: {
            type: 'string',
            description: '账单分类过滤，如 餐饮、交通、购物、工资、退款 等，可选。',
          },
          from: {
            type: 'integer',
            description: '起始时间，Unix 秒级时间戳（Asia/Shanghai 时区），可选。',
          },
          to: {
            type: 'integer',
            description: '结束时间，Unix 秒级时间戳（Asia/Shanghai 时区），可选。',
          },
          limit: {
            type: 'integer',
            description: '返回最大条数，默认 50。',
          },
        },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'query_foods',
      description: '查询用户的饮食记录（只读）。可按餐次（早餐/午餐/晚餐/加餐）过滤，并返回营养汇总。',
      parameters: {
        type: 'object',
        properties: {
          meal: {
            type: 'string',
            description: '餐次过滤，取值：早餐、午餐、晚餐、加餐，可选。',
          },
          from: {
            type: 'integer',
            description: '起始时间，Unix 秒级时间戳（Asia/Shanghai 时区），可选。',
          },
          to: {
            type: 'integer',
            description: '结束时间，Unix 秒级时间戳（Asia/Shanghai 时区），可选。',
          },
          limit: {
            type: 'integer',
            description: '返回最大条数，默认 50。',
          },
        },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'query_health',
      description: '查询用户的健康记录（只读）。可按指标（如 体重、身高、心率、血压、睡眠、体检预约）过滤，按指标分组返回最新值。',
      parameters: {
        type: 'object',
        properties: {
          metric: {
            type: 'string',
            description: '健康指标过滤，如 体重、身高、心率、血压、睡眠、体检预约 等，可选。',
          },
          from: {
            type: 'integer',
            description: '起始时间，Unix 秒级时间戳（Asia/Shanghai 时区），可选。',
          },
          to: {
            type: 'integer',
            description: '结束时间，Unix 秒级时间戳（Asia/Shanghai 时区），可选。',
          },
          limit: {
            type: 'integer',
            description: '返回最大条数，默认 50。',
          },
        },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'get_summary',
      description: '对指定时间范围做只读聚合汇总：账单收支（收入/支出合计）与饮食餐次计数。',
      parameters: {
        type: 'object',
        properties: {
          range: {
            type: 'string',
            description: '汇总范围，取值：today（今天）、yesterday（昨天）、last7Days（近 7 天）。',
            enum: ['today', 'yesterday', 'last7Days'],
          },
        },
        required: ['range'],
      },
    },
  },
];

module.exports = { TOOL_SCHEMAS };
