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
      name: 'query_reminders',
      description: '查询用户的待办/提醒记录（只读）。可按完成状态过滤，也可按时间范围过滤。',
      parameters: {
        type: 'object',
        properties: {
          done: {
            type: 'boolean',
            description: '是否已完成。传 true 查已完成的，传 false 查未完成的，不传则查全部。',
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
  // —— 写入工具：由 agent 直接帮用户记账/记饮食/加待办 ——
  {
    type: 'function',
    function: {
      name: 'create_bill',
      description: '记录一笔账单（支出或收入）。当用户说"花了/付了/买了/记一笔/工资/退款/收款"等想记账时调用；如果上下文里的 recentBills 有匹配项且用户表达了修改/纠错意图，传 id 表示更新已有记录。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要更新的已有记录 id（来自上下文 recentBills[i].id），仅修改/纠错意图时传；省略则新建。' },
          merchant: { type: 'string', description: '商户或消费对象名称，如 星巴克、美团、超市。' },
          amount: { type: 'number', description: '金额，正数，单位元。' },
          category: { type: 'string', description: '分类，如 餐饮、交通、购物、咖啡、工资、退款。不确定就省略，由系统按商户常识默认。' },
          isIncome: { type: 'boolean', description: '是否为收入，默认 false（支出）。工资、退款、收款时填 true。' },
          time: { type: 'integer', description: '发生时间，Unix 秒级时间戳（Asia/Shanghai）。省略则用当前时间。' },
          note: { type: 'string', description: '备注，可选。' }
        },
        required: ['merchant', 'amount']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'create_food',
      description: '记录一餐饮食。当用户说"吃了/喝了/早餐/午餐/晚餐/加餐 + 食物"想记录饮食时调用；如果上下文里的 recentFoods 有匹配项且用户表达了修改/纠错意图（如"搞错了、只吃了50克、改一下、刚记的"），传 id 表示更新已有记录。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要更新的已有记录 id（来自上下文 recentFoods[i].id），仅修改/纠错意图时传；省略则新建。' },
          name: { type: 'string', description: '食物名称，如 苹果、米饭、拿铁。必须是真实食物名，不要把用户的疑问句或请求当食物名（如"你能帮我修改一下吗"不是食物）。' },
          calories: { type: 'number', description: '估算热量（千卡 kcal）。不确定时基于常识估算，如一个苹果约 95、一碗米饭约 230。' },
          meal: { type: 'string', enum: ['早餐', '午餐', '晚餐', '加餐'], description: '餐次，可由名称或当前时间推断，省略则默认加餐。' },
          portion: { type: 'string', description: '份量描述，如 1个、一碗、200克。' },
          weightGram: { type: 'number', description: '重量（克），可选。' },
          date: { type: 'integer', description: '用餐日期，Unix 秒级时间戳（Asia/Shanghai）。省略则今天。' },
          protein: { type: 'number', description: '蛋白质克数，可选。' },
          carbs: { type: 'number', description: '碳水克数，可选。' },
          fat: { type: 'number', description: '脂肪克数，可选。' }
        },
        required: ['name']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'create_todo',
      description: '创建一条待办/提醒事项。当用户说"提醒我/记得/待办/记一下要做"等想记录任务时调用。',
      parameters: {
        type: 'object',
        properties: {
          title: { type: 'string', description: '待办标题/内容。' },
          id: { type: 'string', description: '要更新的已有记录 id（来自上下文 recentReminders[i].id），仅修改/纠错/完成意图时传；省略则新建。' },
          due: { type: 'integer', description: '截止时间，Unix 秒级时间戳（Asia/Shanghai）。可选。' },
          remindAt: { type: 'integer', description: '提醒时间，Unix 秒级时间戳（Asia/Shanghai）。可选。' },
          repeatRule: { type: 'string', enum: ['none', 'day', 'week', 'month'], description: '重复规则，默认 none。' },
          priority: { type: 'string', enum: ['low', 'medium', 'high'], description: '优先级，默认 medium。' },
          done: { type: 'boolean', description: '是否已完成，用户说"完成了/做完了"时设为 true。' }
        },
        required: ['title']
      }
    }
  },
  // —— 记录健康指标 ——
  {
    type: 'function',
    function: {
      name: 'create_health',
      description: '记录一条健康指标（体重/身高/心率/血压/睡眠/体脂率/血糖等）。当用户说"体重68/身高175/心率72/血压120 80/昨晚睡了7小时"等想记录健康数据时调用；若 recentHealth 有匹配且用户要修改，传 id（upsert）。',
      parameters: {
        type: 'object',
        properties: {
          metric: { type: 'string', description: '指标中文名，如 体重/身高/心率/收缩压/舒张压/睡眠/体脂率/血糖。' },
          value: { type: 'string', description: '指标值，如 "68"/"175"/"72"；体检预约类可传日期字符串。' },
          unit: { type: 'string', description: '单位，如 kg/cm/bpm；无单位留空字符串。' },
          date: { type: 'integer', description: '该指标日期，Unix 秒级时间戳（Asia/Shanghai）。省略则今天。' },
          id: { type: 'string', description: '要更新的已有健康记录 id（来自 recentHealth[i].id），仅修改意图时传；省略则新建。' }
        },
        required: ['metric', 'value']
      }
    }
  },
  // —— 删除/撤销（软删除）——
  {
    type: 'function',
    function: {
      name: 'delete_bill',
      description: '删除一条账单记录（软删除）。用户说"把那条滴滴删了/删除/去掉/不要这笔账单/撤掉那笔"时调用。优先用 id（recentBills[i].id）；无 id 时用 merchant 关键词模糊匹配最近一条。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要删除的账单 id，来自 recentBills[i].id。' },
          merchant: { type: 'string', description: '商户名关键词，无 id 时模糊匹配最近一条账单。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_food',
      description: '删除一条饮食记录（软删除）。用户说"把苹果那顿删了/刚才吃的记错了删掉/去掉那条饮食"时调用。优先用 id（recentFoods[i].id）；无 id 时用 name 关键词模糊匹配最近一条。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要删除的饮食 id，来自 recentFoods[i].id。' },
          name: { type: 'string', description: '食物名关键词，无 id 时模糊匹配最近一条饮食。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_todo',
      description: '删除一条待办事项（软删除）。用户说"把买菜那个待办删了/删除那条提醒"时调用。优先用 id（recentReminders[i].id）；无 id 时用关键词模糊匹配最近一条。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要删除的待办 id，来自 recentReminders[i].id。' },
          title: { type: 'string', description: '待办标题关键词，无 id 时模糊匹配最近一条。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_health',
      description: '删除一条健康指标记录（软删除）。用户说"把体重那条删了/删掉心率记录"时调用。优先用 id（recentHealth[i].id）；无 id 时用 metric 关键词模糊匹配最近一条。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要删除的健康记录 id，来自 recentHealth[i].id。' },
          metric: { type: 'string', description: '指标名关键词，无 id 时模糊匹配最近一条。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'complete_todo',
      description: '把某个待办标记为已完成（done=true）。用户说"把买菜那个待办标记完成/勾掉/做好了/那条待办完成了"时调用。优先用 id（recentReminders[i].id），也可用 title 关键词模糊匹配最近一条未完成待办。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要完成的待办 id，来自 recentReminders[i].id。' },
          title: { type: 'string', description: '待办标题关键词，无 id 时模糊匹配最近一条未完成待办。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'undo_last',
      description: '撤销用户刚刚记录的内容：删除最近一条账单/饮食/待办/健康记录（按 updatedAt 取最新一条软删除）。仅当用户明确说"撤销/撤回/取消刚才记的/刚才那个记错了删掉/不要刚才那条"时使用；普通删除请求请用 delete_*。',
      parameters: {
        type: 'object',
        properties: {},
        required: []
      }
    }
  },
  // —— 商户分类规则 ——
  {
    type: 'function',
    function: {
      name: 'set_merchant',
      description: '新增或更新一条「商户 → 分类/收支类型」规则。当用户说\"滴滴算餐饮/外卖都归餐饮/工资是收入/把星巴克设成餐饮\"时调用；按商户名复用已有规则（不会重复）。',
      parameters: {
        type: 'object',
        properties: {
          merchant: { type: 'string', description: '商户名，如 滴滴/星巴克/工资。' },
          category: { type: 'string', description: '分类名，如 餐饮/交通/收入/购物。' },
          isIncome: { type: 'boolean', description: 'true=收入，false=支出。' }
        },
        required: ['merchant']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_merchants',
      description: '列出全部或某个分类下的商户分类规则。当用户问\"现在有哪些商户规则/餐饮类归了哪些商户\"时调用。',
      parameters: {
        type: 'object',
        properties: {
          category: { type: 'string', description: '只返回该分类的规则；省略则返回全部。' },
          limit: { type: 'integer', description: '返回条数上限，默认 100。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_merchant',
      description: '删除一条商户分类规则（软删除）。当用户说\"把滴滴那条规则删了/不用再记星巴克分类了\"时调用。优先用 id（来自 list_merchants 的 id），也可用 merchant 关键词。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要删除的规则 id，来自 list_merchants 返回。' },
          merchant: { type: 'string', description: '商户名关键词，无 id 时模糊匹配。' }
        },
        required: []
      }
    }
  },
  // —— 识别历史 ——
  {
    type: 'function',
    function: {
      name: 'list_recognitions',
      description: '列出最近的截图/文字识别记录（含原始文本、识别出的数据类型）。当用户问\"我之前识别过什么/有哪些识别记录\"时调用。',
      parameters: {
        type: 'object',
        properties: {
          type: { type: 'string', description: '只返回该类型(bill/food/reminder)的识别记录；省略则返回全部。' },
          limit: { type: 'integer', description: '返回条数上限，默认 20。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_recognition',
      description: '删除一条识别历史记录（软删除）。当用户说\"把刚才那条识别记录删了/清理识别历史\"时调用。优先用 id（来自 list_recognitions），也可用 keyword 在原文中模糊匹配。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '要删除的识别记录 id，来自 list_recognitions 返回。' },
          keyword: { type: 'string', description: '在识别原文中模糊匹配的关键词，无 id 时使用。' }
        },
        required: []
      }
    }
  },
  // —— 跨类搜索 / 报告 / 批量 ——
  {
    type: 'function',
    function: {
      name: 'search_all',
      description: '跨类型（账单/饮食/待办/健康）按关键词搜索记录。当用户说\"找一下我所有跟咖啡有关的/哪些记录提到了打车/搜一下滴滴\"时调用。返回命中记录的 id 与类型，便于后续修改或删除。',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string', description: '搜索关键词，如 咖啡/打车/滴滴/体检。' },
          type: { type: 'string', description: '限定类型 bill/food/reminder/health；省略则全部。' },
          types: { type: 'array', items: { type: 'string' }, description: '多类型限定；与 type 二选一。' },
          from: { type: 'integer', description: '起始时间（Unix 秒），可选。' },
          to: { type: 'integer', description: '结束时间（Unix 秒），可选。' }
        },
        required: ['query']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'get_report',
      description: '生成一段时间内的数据报告（收支总额、分类占比、Top 商户、饮食营养、待办完成情况、最新健康指标）。当用户说\"给我做个本周总结/上个月花了多少/生成月度报告/这周的饮食怎么样\"时调用。range 支持 today/yesterday/last7Days/last30Days/thisMonth/lastMonth。',
      parameters: {
        type: 'object',
        properties: {
          range: { type: 'string', enum: ['today', 'yesterday', 'last7Days', 'last30Days', 'thisMonth', 'lastMonth'], description: "报告区间，默认 last7Days。" },
          from: { type: 'integer', description: '自定义起始时间（Unix 秒），与 to 配合使用。' },
          to: { type: 'integer', description: '自定义结束时间（Unix 秒）。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'complete_all_todos',
      description: '把全部（或关键词匹配的）待办一次性标为已完成。当用户说\"把所有待办都标记完成/把买菜相关的待办全勾掉\"时调用。',
      parameters: {
        type: 'object',
        properties: {
          keyword: { type: 'string', description: '只标记标题含该关键词的待办；省略则全部。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_by_merchant',
      description: '删除某商户相关的全部记录（默认仅账单，可扩展类型）。当用户说\"把滴滴的账单全删了/清空星巴克所有记录\"时调用。',
      parameters: {
        type: 'object',
        properties: {
          merchant: { type: 'string', description: '商户名关键词，如 滴滴/星巴克。' },
          type: { type: 'string', description: '限定类型 bill/food/reminder；省略默认 bill。' },
          types: { type: 'array', items: { type: 'string' }, description: '多类型限定；与 type 二选一。' }
        },
        required: ['merchant']
      }
    }
  },
  // —— 阿宝的成长 / 学习 ——
  {
    type: 'function',
    function: {
      name: 'teach_abao',
      description: '把用户教给阿宝的一条习惯/规则记住（持久化，下次自动照做）。当用户说"以后XXX就YYY/记住我的习惯/教你怎么处理/我的规则是"等，明确在教阿宝怎么办某事时调用。topic 是简短主题（如"打车分类""午睡提醒"），rule 是清晰可执行的做法，example 可放用户原话示例。',
      parameters: {
        type: 'object',
        properties: {
          topic: { type: 'string', description: '简短主题/分类，如 打车分类、午睡提醒、工资入账方式；便于去重与检索。' },
          rule: { type: 'string', description: '具体可执行的做法，如"打车都记成交通类，不记成餐饮"。' },
          example: { type: 'string', description: '用户的原话示例，可选，便于后续回忆。' }
        },
        required: ['rule']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_teachings',
      description: '列出用户教过阿宝的全部规则（可关键词过滤）。当用户问"你都学会了什么/教过你什么/你记住了哪些习惯"时调用。',
      parameters: {
        type: 'object',
        properties: {
          keyword: { type: 'string', description: '只返回主题或规则含该关键词的规则；省略则返回全部。' },
          limit: { type: 'integer', description: '返回条数上限，默认 100。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'recall_teachings',
      description: '检索与当前请求相关的"用户教过的规则"。当阿宝准备动手前想确认"用户有没有教过我这种情况怎么处理"时调用，按 query 关键词匹配 topic/rule/example，返回相关规则供遵循。',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string', description: '检索词，如 打车、午睡、工资、分类。' }
        },
        required: ['query']
      }
    }
  },
  // —— 饮水（water）——
  {
    type: 'function',
    function: {
      name: 'create_water',
      description: '记录一次饮水（毫升）。当用户说"记一杯水/我喝了300毫升/加水"时调用。amount 为毫升数。',
      parameters: {
        type: 'object',
        properties: {
          amount: { type: 'number', description: '饮水量，单位毫升(ml)，如 300。' },
          date: { type: 'string', description: '饮水时间 ISO 字符串，省略默认现在。' },
          note: { type: 'string', description: '备注，可选。' }
        },
        required: ['amount']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_water',
      description: '删除饮水记录。可指定 id 精确删除；否则按 keyword 或默认删最近一条。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '精确删除某条饮水记录的 id。' },
          keyword: { type: 'string', description: '关键词（匹配备注/毫升数），不指定 id 时用于定位要删的记录。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_waters',
      description: '查询饮水记录与总量。range 支持 today/yesterday/last7Days/last30Days/thisMonth/不填(全部)。当用户问"今天喝了多少水"时调用。',
      parameters: {
        type: 'object',
        properties: {
          range: { type: 'string', description: '时间范围：today/yesterday/last7Days/last30Days/thisMonth；省略为全部。' },
          limit: { type: 'integer', description: '返回条数上限，默认 500。' }
        },
        required: []
      }
    }
  },
  // —— 周期排程（recurring_rule）——
  {
    type: 'function',
    function: {
      name: 'create_recurring',
      description: '新建/更新一条周期账单规则（如"每月1号房租3000/每周健身费200"）。同商户名会自动更新已有规则。设备拉取后自动按期生成账单。',
      parameters: {
        type: 'object',
        properties: {
          merchant: { type: 'string', description: '规则名/商户，如 房租/工资/健身。' },
          amount: { type: 'number', description: '每次金额。' },
          category: { type: 'string', description: '分类，如 居住/收入/运动。' },
          note: { type: 'string', description: '备注。' },
          isIncome: { type: 'boolean', description: '是否收入（工资等），默认 false。' },
          dayOfMonth: { type: 'integer', description: '每月几号生成，1-28，默认 1。' },
          cycle: { type: 'string', description: '周期：daily/weekly/monthly/quarterly/yearly/custom，默认 monthly。' },
          customValue: { type: 'integer', description: '自定义周期数值（cycle=custom 时生效）。' },
          customUnit: { type: 'string', description: '自定义周期单位：day/week/month/year。' },
          startDate: { type: 'string', description: '起始日期 ISO，省略默认现在。' }
        },
        required: ['merchant', 'amount']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_recurring',
      description: '列出全部周期账单规则。当用户问"我有哪些自动扣费/周期账单"时调用。',
      parameters: {
        type: 'object',
        properties: {
          limit: { type: 'integer', description: '返回条数上限，默认 100。' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'delete_recurring',
      description: '删除一条周期账单规则。可指定 id，或按 merchant 名定位。当用户说"取消每月房租自动记账"时调用。',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '精确删除某条规则的 id。' },
          merchant: { type: 'string', description: '规则名/商户，用于定位要删的规则。' }
        },
        required: []
      }
    }
  },
];

module.exports = { TOOL_SCHEMAS };
