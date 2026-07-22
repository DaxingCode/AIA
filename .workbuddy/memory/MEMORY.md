# 项目长期记忆：AI 助理原生 App

## 项目定位
原生 iOS App，定位「AI 助理」：饮食记录 / 健康管理 / 账单管理 / 待办提醒。核心差异化 = 截屏自动识别（无感）。三大能力：截图识别、食物卡路里、HealthKit 健康数据。

## 技术栈
- 纯 Swift + SwiftUI（2026-07-16 选定），原生 iOS，不用 RN/Flutter。
- 本地存储 **SwiftData**（iOS 17+）。
- 截图无感自动化 = 快捷指令「截屏」个人自动化 + **App Intents**（`ProcessScreenshotIntent`，`openAppWhenRun=false`）；兜底用**分享扩展**手动导入。
- 多模态模型主力 **通义千问视觉 Qwen-VL**（阿里 DashScope），API Key 走 **CloudBase 云函数**代理，不硬编码在前端。

## 关键工程约定
- **SwiftData schema 版本闸门**：任何 @Model 字段变更/新增模型，必须把 `AIAApp.schemaVersion` +1，否则旧 store 白屏。
- **App Intents 短语**：AppShortcut utterance 必须包含 `\(.applicationName)` token，否则 `appintentsmetadataprocessor` 拒绝导出。
- **聊天意图本地优先分流**：文本含「吃/喝/奶茶/咖啡/饭/面/餐」等饮食词且不含明确账单词（如「花了」「付了」「消费」）时，必须先走 `food` 识别。`ChatView.processNext` 顺序：疑问句 → food → bill → todo → 兜底云端；`createBillLocally` 也要防御 `isFoodLike` 输入。
- **聊天上下文过滤**：`buildRecentMessages` 需过滤 role=ai 且以「记好啦」开头的确认消息，以及 role=user 且含「记一下/帮我记/添加/删除/改到/完成」等操作动词的消息，避免确认消息触发重复入库。
- **兜底记录需明确创建意图**：`processNext` 兜底分支只有用户文本含「记一下/记一笔/帮我记/添加/创建/新建」等明确创建动词时才允许保存记录。
- 识别链路：图片 → 识别 → 结构化 JSON → 结果确认页 → 用户改字段后入库，**绝不静默入库**。
- 识别原图仅本地存储，模型只存 `imageName`；`CloudSyncManager` 上传 payload 永不包含 `imageName`。
- 改完云函数必须立即跑 `bash cloudfunctions/package-recognize.sh` 重新打包 zip，zip 名跟随 `index.js` 的 `FN_VERSION`。

## SwiftData 操作铁律（2026-07-20 踩坑）
- **不主动 `try? context.save()`**：SwiftData `autosaveEnabled=true` 自动持久化；显式 save 同步等写盘，叠加系统状态机会卡死主线程。
- **不用 `withAnimation` 包模型属性变更**：`@Query` 会把模型变更动画化，最后一条记录删除/完成时空态与切 tab 动画叠加会卡死。
- **副作用延后**：通知调度/网络/文件 IO 推到 `DispatchQueue.main.async` 或 `Task { @MainActor }` 下一帧执行。
- **详情页删除/标记完成**：先 `dismiss()` 回到列表，在 `.onDisappear` 中再延迟 600ms 执行 `SafeDelete` 或改 `done`。300ms 不够——父页面 pop 动画完全结束后可能仍在收尾渲染。
- **延迟闭包禁止直接捕获 SwiftData 对象**：详情页 pop 后若没有任何视图再引用该对象，SwiftData 会将其标记为 fault；延迟访问属性会触发 fault 异常并闪退。**正解**：只保存 `persistentModelID`，延迟执行时通过 `context.model(for: id)` 重新取活对象。`SafeDelete.swift` 已提供 `reminderByID` / `billByID` / `foodByID` / `healthByID` 四个 ID 版本方法。
- **SafeDelete 软删不 save，scheduleHardDelete 不 save**：软删只设 `syncDeleted=true`；1s 后硬删只 `context.delete(live)`，都靠 autosave 自动持久化。
- **列表页删除**：cell 非 `NavigationLink` 目标时直接 `withAnimation { context.delete(obj) }` 硬删，无需 SafeDelete，不显式 save。

## SwiftUI 交互铁律（2026-07-20 踩坑）
- **NavigationLink 与 Button 嵌套会吞点击**：`Button` 不能嵌在 `NavigationLink.label` 内部。
- **行内多交互正确结构**：用 **ZStack 分层**。底层是 `NavigationLink`（撑满整行）；顶层是 `Color.clear.frame(36,36).contentShape(Rectangle()).overlay(Image).onTapGesture` 等独立 hit area。顶层 z-order 高，点击优先响应；content 必须加对应 leading padding，避免文字与圆圈重叠。
- **图标与多行文字垂直对齐**：用 `HStack(alignment: .firstTextBaseline)`，不用默认 `.center`。
- **禁止 NavigationStack 嵌套**：被外层 push 的 view 不要再包 `NavigationStack`。
- **禁用会导致中间态的动画**：`SegmentedPicker` 选中背景切换、列表项出现/消失/空态切换，都加 `.animation(nil, value: ...)`，避免两个 segment 同时白色或空态切换动画叠加卡死。
- **禁止 `ForEach(0..<计算数组.count)` + `数组[i]` 下标遍历 `@Query` 派生数组**：`groupedByDate`/`monthlyGroups`/`categoryBreakdown` 等在导航 `onAppear` 等时机会被多次求值、长度不一致，导致 `Index out of range` 闪退。**正解**：直接遍历元素，用 `ForEach(Array(数组.enumerated()), id: \.offset)` 物化一次并取 offset 作 id；tuple 不要用 `id: \.date`（Reminder 的 date 是 Optional，推断可能失败），更不要用 `id: { ... }` 闭包。

## 用户背景
- 微信小程序开发者，无 Swift 经验；开发环境 Mac，暂无 Apple Developer 付费账号。
- 免费账号可用：App 内识别、待办时间、摄入/宏量、无感截图识别、CloudBase 云同步。
- 付费账号才能用：App Group/ShareExtension、HealthKit、CloudKit 整库同步。

## MVP 落地顺序
M1 分享扩展导入 → M2 快捷指令无感对接 → M3 食物卡路里(+营养库校正) → M4 HealthKit → M5 净热量联动+云同步。

## CloudBase 部署
- 环境 ID：`cloud1-d1ga55pizf294dbe9-1445590522`（上海）。
- `recognize` 与 `aia-sync` 同环境；App 端 endpoint 在 `RecognizeService.swift`。
- 打包：`bash cloudfunctions/package-recognize.sh` 生成 zip，命名跟随 `index.js` 的 `FN_VERSION`；所有 `recognize-*.zip` 放在 `原生代码脚手架/cloudfunctions/recognize/`。

## 识别能力
- **省 token 架构（2026-07-20，2026-07-22 更新）**：截图压缩到最大边 1024px、JPEG 0.8、目标 <120KB；本地 `MerchantMeta` 缓存「商户→分类」，**已支持 CloudSync 同步**；云端 `aia_img_cache` 按图片 base64 哈希缓存 30 天。
- **成本优先识别架构决策（2026-07-22，用户明确约束）**：诉求=成本最低前提下准确率最高，**不发的图**（视觉模型 image token 太贵）。方向=本地 OCR 文本 → 云端**文本模型**（非视觉）做结构化；账单/待办走文本路径，只有食物照片这类无文本场景才用视觉模型。为弥补「不发的图」的准确率损失，必须叠加：①本地 OCR 预处理（放大/对比度/透视校正，免费）提升文本质量；②把 OCR 版面坐标一并上送，让文本 LLM 理解栏位；③本地高置信快路径（已知商户+干净金额）零成本秒回；④云返回后本地再做校验+商户模糊纠错（免费）。纯文本上云 = qwen-plus 文本档，远比视觉档便宜。
- **一图多账单（2026-07-21）**：`RecognizeService` 支持一张截图含多条账单同时识别、分别记录。`ResultConfirmView` 逐条卡片可改/删，`RecognitionSaver.autoSave` 逐条关联同一 `imageName`。
- **营养成分表本地 OCR（2026-07-22）**：`RecognizeService.localParseNutritionTable(observations:)` 用 Vision boundingBox 版面分析，提取能量/蛋白质/脂肪/碳水化合物；kJ→kcal 换算；未识别能量但三大宏量齐全时按 4/9/4 估算。
- **营养库匹配铁律（2026-07-22）**：`NutritionLibrary.match` 顺序 = **精确 → 别名归一(`aliases`) → 子串(头名词/靠后优先，同位取更长) → 调料前缀护栏(`seasoningPrefixes`)**。中文复合食物是「修饰语+头名词」，头名词在后且是营养主体（猕猴桃酸奶→酸奶）。新增食物**异名走 `aliases` 表**（凤梨→菠萝、奇异果→猕猴桃、圣女果→番茄、提子→葡萄、车厘子→樱桃、方便面→面条、卡布奇诺→拿铁、里脊→瘦肉），**不要往 `rows` 塞异名**；别名优先级高于子串，可修掉「凤梨含梨」这类子串错配。调料/做法词若与独立食物键重名（如「可乐」），必须进 `seasoningPrefixes`——唯一命中该词且它在名称最前端时返回 nil 交云端，避免「可乐鸡翅→可乐」。
- **营养库校正开关（2026-07-22）**：`ResultConfirmView` 仅当 `source != .local` 才用营养库覆盖宏量；本地营养成分表 OCR(`.local`) 保留包装标签值，展示「按包装标签识别」。

## 云同步铁律（2026-07-22）
- **CloudBase pull 字段名陷阱**：CloudBase 数据库存储主键字段是 `_id`，但 App 端 `CloudSyncManager.pull` 按约定读 `rec["id"]`。`aia-sync` 云函数 `pull` 返回前必须显式把 `_id` 映射到 `id`；App 端已做兼容防御：`(rec["id"] as? String) ?? (rec["_id"] as? String)`。
- **登录/重装必须先拉后推**：`CloudSyncManager.syncAfterLogin` 重置 `lastSyncAt` 后，先全量 `pull` 写回本地，再执行 `sync()` 推本地，防止本地空数据覆盖云端。
- **高频同步兜底**：首页启动 60 秒定时同步器；识别结果入库、聊天创建/修改记录后调用 3 秒防抖同步 `syncAfterLocalChange`；前后台切换仍保留 `autoSyncIfEnabled`。

## UI 约定
- 设计系统 v2：跟随系统浅/深自适应 + 科技蓝 #378ADD；所有颜色用 `AIATheme` 令牌，禁止散写 `Color(hex: 0x...)`。
- 类型语义色板（2026-07-20）：`food`(饮食·暖琥珀)、`health`(健康·紫)、`bill`(账单·森绿)、`todo`(待办·科技蓝)、`income`(收入绿)、`expense`(支出红)、`warning`(预算预警琥珀)、`over`(超支深红)。蓝色仅留作品牌主操作色。
- 宫格底色须与类型语义色同 hue：`dietBG/healthBG/billBG/todoBG` 分别为 `food/health/bill/todo` 同 hue 的淡 tint。
- **空状态垂直居中约定（2026-07-22）**：各模块空态的插画+文案+「点击」提示必须落在模块可视区域中央，用 `EmptyStateView` 自带 `Spacer()` + 调用点 `.frame(maxWidth:.infinity, maxHeight:.infinity)` 实现。
- **底部栏提示箭头自动跟随图标位置（2026-07-22，已代码固化）**：`AIBottomBar` 的提示文案改为结构化 `AIPrompt(text:pointsTo:)`（`pointsTo: .mic/.camera/.album/nil`），箭头方向由 `AIBottomBar.iconOrder`（图标从左到右顺序，含输入框胶囊 `nil`）单一真源推导——目标在输入框左侧→`←`在前、在右侧→`→`在后。**改图标左右顺序只改 `iconOrder` 一处**，箭头自动翻转，切勿在 `text` 里手写 `←`/`→`，也勿在调用点硬编码箭头字符串。HStack 内 Button 顺序必须与 `iconOrder` 保持一致。
- **底部栏悬浮胶囊形态（2026-07-22 落地，AIBottomBar 重构）**：`AIBottomBar` 现在是单体 Glass Capsule（`.ultraThinMaterial` + 柔阴影 + 12pt 水平边距），4 个控件（mic·输入·相机·相册）布局在胶囊内部，不再贴满屏幕宽。图标无独立圆背景，直接浮在玻璃上。中间输入区保持 `fillSoft` 小胶囊双层视觉。顶部 Divider 已移除。**构造仍为 ScrollView 的 VStack 兄弟**（非 overlay，遵守 iOS 26 白屏铁律）。`iconOrder`/`arrowPrefix` 依然生效。
- **动效令牌 + 按压反馈约定（2026-07-22 落地）**：新动效一律走 `AIATheme.Motion`（press=spring(0.32/0.6)、draw=easeOut(0.8)、progress=easeOut(0.6)）+ `AIATheme.motionReduce`（= `UIAccessibility.isReduceMotionEnabled`），禁止散写 `Animation.xxx`。**可点卡片/按钮的按压反馈统一用 `PressableCardStyle`**（已写入 `UIComponents.swift`），把 `.buttonStyle(.plain)` 换成 `.buttonStyle(PressableCardStyle())` 即得「缩放下沉 + 阴影抬升 + spring 回弹」；切勿在 `.card()` 里另加 `Gesture`/`onTapGesture` 做按压（会违反项目铁律吞点击）。图表类（`RingView`/`DonutView`/`MacroCard`/`MiniBar`）用 `@State` 插值 + `onAppear`/`onChange(of:)` 做描边/生长动画；Swift Charts 曲线在 iOS 26 下路径动画不可靠，用「透明度+缩放淡入」替代真·描边生长。
- **账单支付时间铁律（2026-07-22，用户明确）**：`RecognizeService.extractISODateTime` **只匹配「支付时间/付款时间/交易时间/创建时间」标签下的时间戳**；命中不到则返回 nil，上层 `localParseBill` fallback 到 `.now`（系统当前时间）。**绝不**把状态栏（左上角）的 HH:MM 当成支付时间——那是截图拍摄时间，不是交易时间。禁止再加任何「纯 HH:MM / 今天/昨天/M月D日/星期X」的相对时间兜底。
  - **2026-07-22 补充**：列表项时间（如「7月21日15:39」「昨天 19:09」）例外——用户明确这是支付时间（每笔交易的显示时间）。在多账单路径中，`extractBillEntries` 提取的 `timeLine` 通过 `preferredTimeLine` 参数传入 `localParseBill`，作为 `extractISODateTime` 之后、`.now` 之前的第二 fallback。单账单路径不涉及此参数。
- **图片识别链路铁律（2026-07-22，用户明确）**：所有图片识别（拍照/截图/相册）→ 本地规则（**仅一图多账单 + 营养成分表**）→ **直接发图给视觉模型**（sensenova，公测免费）。**单账单本地规则不提前返回**（localParseBill 只作 fallback）—— 曾因命中「本月」字符错把「生活缴费」认成「7月 ¥1.0 17:32」错账，2026-07-22 之后永久禁止。识别来源徽章要么是「本地AI识别」（一图多账单/营养成分表），要么是「云端AI识别」/「云端AI识别」（视觉），不可能再走「本地AI识别」+单账单路径。模型收费后改回成本优先链路：OCR 文字 + 文本模型。

## 多对话并行协作协议（2026-07-22 起，强制）
- 本仓库是**多 WorkBuddy 对话并行改同一份代码**，各对话互不知情，同文件会静默覆盖。协调中枢 = 根目录 `多团队协作分工表.md`。
- **动手前必做**：① 读 `多团队协作分工表.md` 的 §3（共享高危文件）和 §4（文件级占用看板）；② 若目标文件已在 §4 被其他对话占用 → 停下并告知用户「XX 文件正被[对话]占用，请换任务或等其释放」，不硬改；③ 空闲则先把占用写进 §4（文件|对话标识|进行中|预计释放）再动手；④ commit 后清除占用。
- **对话标识对照**：`对话B` = software-company 齐活林小队（负责 UI 优化、底部栏、识别链路 bug 修复）；`对话C` = 本对话（用户当前对话，负责导航/设置崩溃排查、并行协作协议执行）。占用 §4 时本对话统一用 `对话C`。
- **§3 高危文件**（`Models`/`AppPersistence`/`AIAMigrationPlan`/`AIATheme`/`UIComponents`/`RecognizeService`）：无论是否被占，动手前都在 §4 标注「锁定中」并提醒用户。
- SwiftData Schema 变更（`AIAApp.schemaVersion`+1）由 §6 指定责任人集中处理，禁止多对话各自 +1。
- 小步提交；冲突由后提交方 rebase/解决，不得静默覆盖。
