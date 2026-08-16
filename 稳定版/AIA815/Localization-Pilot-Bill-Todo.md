# AIA 本地化试点：账单 / 待办模块 中英文词条对照表

> 第一轮试点「账单管理」「待办提醒」，已铺开「饮食」「健康」模块；后续向首页、对话页、设置页铺开。

## 文件位置

| 语言 | 文件 |
|------|------|
| 英文（基础语言） | `AIA/AIA/en.lproj/Localizable.strings` |
| 简体中文 | `AIA/AIA/zh-Hans.lproj/Localizable.strings` |
| 繁体中文（台湾） | `AIA/AIA/zh-Hant.lproj/Localizable.strings` |
| 繁体中文（香港） | `AIA/AIA/zh-HK.lproj/Localizable.strings` |

## 代码接入方式

- 静态文本：`Text(LocalizedStringKey("key"))` 或直接 `Text(NSLocalizedString("key", comment: ""))`。
- 需要 `String(format:)` 格式化的文本：`String(format: NSLocalizedString("key", comment: ""), ...)`。
- 导航标题：`.navigationTitle(LocalizedStringKey("key"))`。
- 自定义组件如 `SectionTitle(text:)` 目前只接受 `String`，传 `NSLocalizedString`。

---

## 一、通用词条

| Key | 简体中文 | English | 使用场景 |
|-----|---------|---------|---------|
| `common.delete` | 删除 | Delete | 左滑删除按钮 |
| `common.other` | 其他 | Other | 账单分类为空时的默认显示 |
| `common.none` | — | — | 暂无数据占位 |
| `common.save` | 保存 | Save | 编辑页保存（预留） |
| `common.cancel` | 取消 | Cancel | 弹窗取消（预留） |
| `common.ok` | 好 | OK | 弹窗确认（预留） |

## 二、导航标题

| Key | 简体中文 | English | 使用场景 |
|-----|---------|---------|---------|
| `tab.bill` | 账单管理 | Bills | 账单列表页导航标题 |
| `tab.todo` | 待办提醒 | Todos | 待办列表页导航标题 |

## 三、账单模块（BillListView）

| Key | 简体中文 | English | 使用场景 |
|-----|---------|---------|---------|
| `bill.today` | 今日账单 | Today | 顶部左侧圆环标题 |
| `bill.thisMonth` | 本月账单 | This Month | 顶部右侧圆环标题 |
| `bill.noRecords` | 暂无记录 | No records | 圆环下方无数据提示 |
| `bill.budget` | 预算 | Budget | 预算区域标题 |
| `bill.monthlyBudget` | 本月预算 ¥%d | Monthly budget ¥%d | 预算左侧文字，带金额参数 |
| `bill.budgetUsed` | 已用 %d%% | Used %d%% | 预算右侧文字，带百分比参数 |
| `bill.filter.all` | 全部 | All | 账单筛选：全部 |
| `bill.filter.pending` | 待确认 | Pending | 账单筛选：待确认 |
| `bill.filter.done` | 已确认 | Done | 账单筛选：已确认 |
| `bill.empty.title` | 没有%@账单记录 | No %@ bill records | 空状态标题，带当前筛选名称参数 |
| `bill.empty.desc` | 截一张付款 / 消费截图 | Take a screenshot of a payment or receipt | 空状态描述 |
| `bill.status.confirmed` | 已确认 | Confirmed | 账单行状态标签 |
| `bill.status.pending` | 待确认 | Pending | 账单行状态标签 |
| `bill.category.food` | 餐饮 | Dining | 分类配色（预留，云端返回分类目前不翻译） |
| `bill.category.transport` | 交通 | Transport | 分类配色（预留） |
| `bill.category.shopping` | 购物 | Shopping | 分类配色（预留） |

## 四、待办模块（ReminderListView）

| Key | 简体中文 | English | 使用场景 |
|-----|---------|---------|---------|
| `todo.title` | 待办提醒 | Todos | 页面标题（预留） |
| `todo.suggestion.title` | 智能建议 | Smart Suggestion | 顶部智能建议卡片标题 |
| `todo.suggestion.desc` | 截图已识别，建议创建待办 | Screenshot recognized, create a todo? | 智能建议卡片描述 |
| `todo.suggestion.add` | 添加 | Add | 智能建议卡片按钮 |
| `todo.filter.active` | 待办提醒 %d | Todo %d | 筛选：待办，带数量参数 |
| `todo.filter.finished` | 已完成 %d | Done %d | 筛选：已完成，带数量参数 |
| `todo.filter.calendar` | 日历展示 | Calendar | 筛选：日历展示 |
| `todo.empty.title` | 没有%@待办 | No %@ todos | 空状态标题，带当前筛选名称参数 |
| `todo.empty.desc` | 截一张待办 / 日程截图 | Take a screenshot of a task or schedule | 空状态描述 |
| `todo.calendar.weekday.sun` | 日 | Sun | 日历星期头 |
| `todo.calendar.weekday.mon` | 一 | Mon | 日历星期头 |
| `todo.calendar.weekday.tue` | 二 | Tue | 日历星期头 |
| `todo.calendar.weekday.wed` | 三 | Wed | 日历星期头 |
| `todo.calendar.weekday.thu` | 四 | Thu | 日历星期头 |
| `todo.calendar.weekday.fri` | 五 | Fri | 日历星期头 |
| `todo.calendar.weekday.sat` | 六 | Sat | 日历星期头 |
| `todo.calendar.noTasks` | 当天没有待办 | No tasks for this day | 选中日无待办提示 |
| `todo.calendar.selectedDateTitle` | %@ 待办 | %@ Todos | 选中日待办区域标题，带日期参数 |
| `todo.priority.high` | 高 | High | 优先级标签 |
| `todo.priority.medium` | 中 | Medium | 优先级标签 |
| `todo.priority.low` | 低 | Low | 优先级标签 |

## 五、饮食模块（FoodListView）

| Key | 简体中文 | English | 使用场景 |
|-----|---------|---------|---------|
| `food.navTitle` | 饮食记录 | Diet Log | 饮食列表页导航标题 |
| `food.today` | 今天 · %@ %@ | Today · %@ %@ | 顶部日期行（参数：日期、星期） |
| `food.netLabel` | 净热量 kcal | Net kcal | 净热量数字下方标签 |
| `food.intakeTdee` | 摄入 %d · TDEE %d | Intake %d · TDEE %d | 摄入/消耗对比，带两个整型参数 |
| `food.belowGoal` | 低于目标，可加餐 🍎 | Under goal, have a snack 🍎 | 净热量为负时提示 |
| `food.overGoal` | 已超目标，注意控制 | Over goal, watch your intake | 净热量为正时提示 |
| `food.burned` | 今日消耗 | Burned | 右侧能量消耗卡标题 |
| `food.nutrition` | 营养构成 | Nutrition | 营养区域标题 |
| `food.nutritionTarget` | 目标 蛋白%d / 碳水%d / 脂肪%d g | Goal Protein %d / Carb %d / Fat %d g | 营养区域副标题，带 3 个整型参数 |
| `food.macro.protein` | 蛋白质 | Protein | 营养卡：蛋白质 |
| `food.macro.carb` | 碳水 | Carb | 营养卡：碳水 |
| `food.macro.fat` | 脂肪 | Fat | 营养卡：脂肪 |
| `food.macro.fiber` | 膳食纤维 | Fiber | 营养卡：膳食纤维 |
| `food.last7days` | 近 7 日热量 | Last 7 Days Calories | 7 日热量图标题 |
| `food.empty.title` | 还没有%@记录 | No %@ records yet | 空状态标题，带当前餐次参数 |
| `food.empty.desc` | 点底部相机拍照识别 | Tap the camera at the bottom to scan | 空状态描述 |
| `food.recognized` | 识别 | Recognized | 食物行「识别」来源标记 |
| `food.meal.breakfast` | 早餐 | Breakfast | 餐次页签（展示用，数据仍存中文规范值） |
| `food.meal.lunch` | 午餐 | Lunch | 餐次页签 |
| `food.meal.dinner` | 晚餐 | Dinner | 餐次页签 |
| `food.meal.snack` | 加餐 | Snack | 餐次页签 |

## 六、健康模块（HealthListView）

| Key | 简体中文 | English | 使用场景 |
|-----|---------|---------|---------|
| `health.navTitle` | 健康管理 | Health | 健康列表页导航标题 |
| `health.ring.steps` | 步 / 10,000 | Steps / 10,000 | 步数圆环 caption |
| `health.ring.sleep` | 睡眠 / 8h | Sleep / 8h | 睡眠圆环 caption |
| `health.ring.energy` | 能量 / 500 | Energy / 500 | 能量圆环 caption |
| `health.ring.exercise` | 运动 / 30m | Exercise / 30m | 运动圆环 caption |
| `health.stat.weight` | 体重 | Weight | 统计卡：体重 |
| `health.stat.height` | 身高 | Height | 统计卡：身高 |
| `health.stat.restingHR` | 静息心率 | Resting HR | 统计卡：静息心率 |
| `health.stat.bmi` | BMI | BMI | 统计卡：BMI |
| `health.weightTrend` | 体重趋势 | Weight Trend | 体重趋势图标题 |
| `health.noWeight` | 暂无体重记录，去首页截一张体重截图 | No weight records yet. Capture a weight screenshot on Home | 无体重记录提示 |
| `health.sleepStages` | 睡眠分期 · 昨晚 | Sleep Stages · Last Night | 睡眠分期区标题 |
| `health.sleep.deep` | 深睡 %.1fh | Deep %.1fh | 深睡卡标题，带浮点参数 |
| `health.sleep.deepSub` | 占比 %d%%，良好 | %.0f%%, good | 深睡卡副标题，带整型参数 |
| `health.sleep.light` | 浅睡 %.1fh | Light %.1fh | 浅睡卡标题，带浮点参数 |
| `health.sleep.rem` | REM %.1fh | REM %.1fh | REM 卡标题，带浮点参数 |
| `health.sleep.remSub` | 快速眼动 | Rapid eye movement | REM 卡副标题 |
| `health.weekSteps` | 近 7 日步数 | Steps (7d) | 7 日步数图标题 |

## 七、图表坐标轴共享词条

| Key | 简体中文 | English | 使用场景 |
|-----|---------|---------|---------|
| `chart.day` | 日 | Day | 折线/柱状图 X 轴「日」 |
| `chart.kcal` | kcal | kcal | 热量图 Y 轴单位 |
| `chart.kg` | kg | kg | 体重图 Y 轴单位 |
| `chart.step` | 步 | Steps | 步数图 Y 轴单位 |

> 健康页星期头不再硬编码「日一二三…」，改为 `Calendar.current.shortWeekdaySymbols`，自动跟随系统语言。

---

## 后续铺开建议

1. **首页**：问候语（早上好/中午好等）、AI 摘要气泡、四宫格标题。
2. **对话页**：输入框占位、发送按钮、快捷指令、错误提示。
3. **设置页**：各设置项标题、默认提醒时间选项、同步开关、权限说明。

## 验证方法

1. 在 iPhone 设置 → 通用 → 语言与地区 中切换 **English**。
2. 重新打开 App，进入「账单管理」和「待办提醒」页面，确认上述文字显示为英文。
3. 切换回 **简体中文**，确认显示中文。
4. 编译时 Xcode 不应产生新的本地化相关警告。
