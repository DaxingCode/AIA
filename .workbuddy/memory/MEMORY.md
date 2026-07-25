# AI 助理原生 App · 长期记忆

## 定位/技术栈
原生 iOS App（饮食/健康/账单/待办），核心差异化=截屏无感识别。纯 Swift+SwiftUI+SwiftData（iOS17+）。截图无感=快捷指令+App Intents(`ProcessScreenshotIntent`)；兜底分享扩展。视觉模型主力 Qwen-VL/商汤 sensenova（公测免费），API Key 走 CloudBase 云函数代理，不硬编码前端。

## 环境/工具链
- **Xcode 路径**：`/Volumes/MacBook/Applications/Xcode.app`（非系统默认 `/Applications`）。调用 `xcodebuild` 时如从 PATH 找不到，用绝对路径：`/Volumes/MacBook/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild`。
- `xcodebuild` 目标：项目 `AIA/AIA.xcodeproj`，scheme `AIA`。模拟器构建示例：`xcodebuild -project AIA/AIA.xcodeproj -scheme AIA -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build CODE_SIGNING_ALLOWED=NO`。
- `xcodebuild` 在本机沙箱内**可正常构建验证**（含 `@Model`/`@Query` 宏的项目 2026-07-25 实测 BUILD SUCCEEDED）。无需解除沙箱或真机即可跑模拟器构建。

## 关键工程约定
- **Schema 版本闸门**：@Model 变更必须 `AIAApp.schemaVersion`+1，否则旧 store 白屏；集中由指定责任人管，禁止多对话各自+1。
- **App Intents 短语**必须含 `\(.applicationName)` token。
- **聊天意图分流**：文本含饮食词且不含账单词→先 food；`processNext` 顺序 疑问句→food→bill→todo→兜底；兜底仅当用户含「记一下/添加」等创建动词才入库。
- **绝不静默入库**：图片→识别→JSON→确认页→用户改字段后入库。原图仅本地，`imageName` 永不上传。

## SwiftData 铁律（2026-07-20 踩坑）
- 不主动 `context.save()`（autosave 自动持久化）；不用 `withAnimation` 包模型变更。
- 副作用延后到 `DispatchQueue.main.async`/`Task{@MainActor}`。
- 详情页删除/完成：先 `dismiss()`，`.onDisappear` 延迟 600ms 再执行（300ms 不够）。
- 延迟闭包禁止直接捕获 SwiftData 对象→只存 `persistentModelID`，执行时 `context.model(for:)` 取活对象（`SafeDelete` 已提供 ID 版本）。
- 列表 cell 非 NavigationLink 目标时直接 `withAnimation{context.delete(obj)}` 硬删。

## SwiftUI 铁律
- `Button` 不能嵌 `NavigationLink.label`；行内多交互用 ZStack 分层（底层 NavigationLink 撑满，顶层独立 hit area）。
- 图标与多行文字用 `HStack(alignment:.firstTextBaseline)`；禁止 NavigationStack 嵌套；SegmentedPicker/列表空态切换加 `.animation(nil,...)`。
- 禁 `ForEach(0..<数组.count)`+`数组[i]` 遍历 `@Query` 派生数组→用 `ForEach(Array(数组.enumerated()),id:\.offset)`。
- **导航铁律（2026-07-24 踩坑·崩）**：全 App 用单 `NavigationStack(path: $router.path) + .navigationDestination(for: HomeRoute.self)`（ContentView.swift 77/103）。**所有从首页列表点行进入详情/编辑页必须走 value-based**：`ValueSelectableCard(value: HomeRoute.xxx(记录), content: ...)` + HomeRoute 加 associated value case + navigationDestination switch 加分支。**严禁** `SelectableCard(destination: SomeView)` 闭包式嵌入首页 NavigationStack 根层——AnyNavigationPath 内部 `try!` 比较 path entry 会触发 `comparisonTypeMismatch` 崩溃，整页 NavigationStack 死锁（白屏 + 首页任何按钮点不动）。闭包式 destination 仅允许用于 `.sheet` 自带 NavigationStack 内部（如 EditBillView）。新增列表行跳详情前**先**确认 HomeRoute 有对应 case，否则用 `enum HomeRoute { case xxx(记录) }` 加好再写 UI。
- **NavigationStack 嵌套铁律（2026-07-24 二次踩坑·崩）**：view 的 body **绝对不能**自己包 `NavigationStack` 如果它会被 `navigationDestination(for: HomeRoute.self)` 推到父级 `NavigationStack` 内（父级 path 是 `[HomeRoute]`，子级 `NavigationStack` 默认是 `NavigationPath` untyped，两者并存 AnyNavigationPath try! 比较会 `comparisonTypeMismatch` 直接崩）。**view 有双调用点（既有 navigationDestination 又有 .sheet）必须拆 wrapper**：view 自身无 NavigationStack 包装（父级 push 用），sheet 路径另加 `XxxSheet` wrapper 包 NavigationStack（sheet 弹起自带 NavigationContext 可以包）。修法见 EditTodoView → EditTodoSheet（commit `b2ce263`）。**新增 view 前先扫调用点**：如果只在 `.sheet` 内被调（EditFoodView/EditBillView/EditHealthView），自身保留 NavigationStack OK；如果在 `navigationDestination` + `.sheet` 双调，必须拆 wrapper。
- **「拆 wrapper 即使单调用点也保留」铁律（2026-07-24 三次踩坑）**：即使一个 view 当前的**所有**调用入口都是 `.sheet`（如 2026-07-24 把 HomeRoute.editTodo 删后 EditTodoView 只剩 sheet 调用），**EditTodoView 自身仍不带 NavigationStack**，所有 sheet 入口必须走 `EditTodoSheet` wrapper。**理由**：① 预防未来再加 push 入口时崩（单调用点变双调用点会引历史 bug 复活）；② EditTodoSheet 注释明确「所有 sheet 入口必须用本 wrapper」+ 列出全部调用点，新人一眼能看到约束；③ wrapper 本身零运行时开销（仅多一层 NavigationStack），纯防御性。**判断标准**：如果一个 view 历史上曾因 NavigationStack 嵌套崩过（EditTodoView b2ce263 案例），即使现在只剩 sheet 入口，wrapper 拆法**永远保留**，不合并回主 view。
- **Swift struct 默认参数铁律（2026-07-24 踩坑·编译失败）**：**Swift struct 用 `let isAdding: Bool = false` 默认值时，编译器生成的自动 init 是 `init(reminder:isAdding:)`（全部属性按顺序），不会让 `isAdding` 变成可选参数**。调用 `EditTodoSheet(reminder: r, isAdding: true)` 会报 `extra argument 'isAdding' in call`。**修法**：必须**显式写 init**：```swift
struct EditTodoSheet: View {
    let reminder: Reminder
    let isAdding: Bool
    init(reminder: Reminder, isAdding: Bool = false) {
        self.reminder = reminder
        self.isAdding = isAdding
    }
}
```**适用范围**：所有 wrapper 结构体（EditXxxSheet / AddXxxView）只要加了带默认值的属性，**必须**显式 init，否则编译失败且错误位置误导到调用方。
- **SwiftUI type-check timeout 铁律（2026-07-24 踩坑·编译失败）**：加 toolbar + 多 sheet + 多层 ZStack 后 body modifier 链总深度让 Swift 编译器类型推断**超时**，报 `the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions`，错误位置通常**指在嵌套最深处**（误导）。**修法**：把嵌套 ZStack / VStack 抽成 `@ViewBuilder private func xxx(_ r: ...) -> some View` helper，body 里只调 helper，编译器压力大幅减小。**适用范围**：所有 view body 内联多层嵌套 view builder + 多 modifier。**预防**：新增 toolbar / sheet / 多级 ZStack 时如果报 type-check timeout，优先拆 helper（拆 ViewBuilder 树）。RemindersView 拆 todoRow(r) helper 后 BUILD SUCCEEDED（commit `356dd10`）。

## 图片识别链路（2026-07-22 重构·单一清晰路径）
- `recognizeWithLocalPriority(imageData:in:)` 是唯一入口，链路自上而下、命中即返回：
  ① 本地 OCR（离线零成本）——**仅**用于判断营养成分表 + 视觉失败兜底，不再用于业务分流。
  ② **营养成分表** → 本地版面解析（`localParseNutritionTable`，成分表密集数字视觉模型易错，本地更准）。这是唯一的本地强规则例外。
  ③ **其它所有图片**（单账单/多账单/食物/体检/待办/普通照片）→ **统一走视觉模型**（sensenova）。
  ④ 视觉失败 → 本地规则尽力兜底（`localParseMultiBillsIfNeeded`→`localParseBill`）；都没有则**抛错**让上层提示，**绝不返回 0.00 空账单**。
- **已删除**：免费/付费档位对视觉的硬拦截（`AppUserTier` 不再拦视觉）、`degrade()` 空账单降级、`localWins()`、多账单 `detectMultiBillList` 提前分支、OCR 空/非空分支。这些是「食物被当空账单」「7月被当商户」的根因。
- `UserTier`/`AppUserTier` 仅 SettingsView 展示剩余额度用，识别链路不再消费额度。`recognizeOCRText`（文本模型）保留但主链路不再调用，供未来成本优先回退用。
- 时间规则：只取「支付/付款/交易/创建时间」标签下时间戳；绝不把状态栏 HH:MM 当支付时间（列表项显示时间例外，用户明确是支付时间）。
- 营养库匹配：精确→别名(`aliases`)→子串(头名词靠后优先)→调料前缀护栏(`seasoningPrefixes`)；异名走 `aliases` 不塞 `rows`。

## 云同步铁律
- CloudBase pull 须把 `_id` 映射到 `id`；登录/重装先全量 pull 再 push（防本地空覆盖云端）。
- 首页启动 60s 定时同步；入库/改记录后 3s 防抖 `syncAfterLocalChange`。

## CloudBase 部署
- 环境 `cloud1-d1ga55pizf294dbe9-1445590522`（上海）；recognize 与 aia-sync 同环境，App endpoint 在 `RecognizeService.swift`。
- **打包产物位置（2026-07-22 起）**：`云函数/recognize/` 为 recognize 云函数**唯一规范主目录**（含 index.js/package.json/打包脚本/zip）。规范脚本=`云函数/recognize/package-recognize.sh`（自相对，zip 落自身目录）；`原生代码脚手架/cloudfunctions/package-recognize.sh` 仅作重定向包装。zip 名跟随 `index.js` 的 `FN_VERSION`（如 `20260722e-sensenova`），gitignored，**需手动上传 CloudBase 控制台重新部署**。

## 用户背景
微信小程序开发者，无 Swift 经验；Mac 开发，暂无 Apple 付费账号（付费才能用 App Group/ShareExtension/HealthKit/CloudKit 整库同步）。

## UI 约定
- 颜色全用 `AIATheme` 令牌；类型语义色 food(琥珀)/health(紫)/bill(绿)/todo(蓝)/income(绿)/expense(红)/warning(琥珀)/over(深红)。
- 空态垂直居中（`EmptyStateView`+`frame(maxWidth:.infinity,maxHeight:.infinity)`）。
- 底部栏 `AIBottomBar` 单体玻璃胶囊；箭头由 `iconOrder` 单一真源推导，勿手写 `←/→`。
- 动效走 `AIATheme.Motion`+`PressableCardStyle`，禁散写 `Animation.xxx`。
- **账单行间 hairline 铁律（2026-07-24 多次踩坑）**：账单管理页有 3 个独立账单列表渲染入口，凡是「账单行间加 hairline」必须**全 3 处一起检查 + 一起改**：
  1. **「全部」tab**：`groupedByDate`（`RecordsViews.swift:1393+`）
  2. **「在日历查看」tab**：`billCalendarView`（`RecordsViews.swift:1784+`，易漏——独立 ForEach 不是 groupedByDate）
  3. **「按月查看」tab**：`MonthlyBillListView`（独立文件）
  统一模式：`ForEach(Array(xxx.enumerated()), id: ...)` + `Rectangle().fill(AIATheme.hairline).frame(height: 0.7).padding(.leading, 62)`。下次再有反馈先用 `grep -n "ForEach.*[Bb]ills"` 一键扫全 3 处，避免「改一处忘两处」。
- **深色模式细线设计铁律（2026-07-24 多次踩坑）**：`AIATheme.hairline` 深色值标准 = `0x636366`（系统深色 fill 3，已取代旧值 `0x545458`）；light 值保持 `0xe6e9ec` 不动；**细线宽度硬性下限 = 0.7pt**（0.5pt 物理权重太弱，单独提亮颜色救不了「细到几乎看不见」的视觉问题）。**双管齐下**：颜色对比（dark `0x636366` vs 表面 `0x1c1c1e`）+ 物理宽度（≥0.7pt）任一缺失都判不合格。所有行间分隔/列表 hairline 必须用此标准；卡片描边（1pt）用 `0x636366` 同样协调不突兀。
- **「按字段分组的列表」必须显式加分隔铁律（2026-07-24 踩坑）**：`dateHeader` 纯文字（无 chip/无背景/无 hairline）时，相邻分组在深色模式 + 小字号 + 高密度布局下完全看不出分组。**改法**：相邻 daySection 之间的 VStack 之前插 `Rectangle hairline 0.7pt + padding(.top, 14).padding(.bottom, 2)`（第一个不加避免与上方标题冲突）；颜色宽度自动继承 `AIATheme.hairline` 标准。**适用范围**：所有按日期/类型/状态分组的列表（饮食/待办/健康/账单）。
- **NavigationStack 推入方式一致性铁律（2026-07-24 踩坑）**：要么全用编程式 `path.append(...)` 推入（与根栈 `.navigationDestination(for: HomeRoute.self)` 配对，能被 `path.removeLast()` 正确回退），要么全用闭包 `NavigationLink`（在同一子栈内可正确管理）。**混用（闭包推 + 编程式推）** 会导致中间页从根栈消失，绕过特定层级——典型表现：从深层 page 返回时**绕过中间页**直接落到更早页。**判别法**：把每个工具页（聚合入口页、子工具页）都提升为 `HomeRoute` case，走编程式 push，让所有 page 都在根 path 上才能保证 `path.removeLast()` 步进正确。`TodoToolsView`/`billTools` 是合格范式。
- 列表 cell 图标：用语义色 SF Symbol **直显**（不包 Circle 背景，与 `.card()` 同级）。**避坑：避开 `sparkles.rectangle.portrait.fill` 等 iOS 新版复杂 symbol**，2026-07-24 实测 iOS 26.5 模拟器 + title3 字号下渲染退化、视觉等同空白。优先 iOS 13-14+ 经典稳定符号：`wand.and.stars`（自动/AI）/ `bell.badge.fill`（提醒）/ `sparkles`（AI）/ `viewfinder.circle`（截屏）/ `rectangle.dashed`（选区）。

## 多对话并行协作协议（强制）
- 多 WorkBuddy 对话并行改同仓，协调中枢=`多团队协作分工表.md`。
- 动手前读 §3(高危)/§4(占用看板)；目标文件被占→停下告知用户；空闲→先写 §4 占用再动手；commit 后清除。
- §3 高危：`Models`/`AppPersistence`/`AIAMigrationPlan`/`AIATheme`/`UIComponents`/`RecognizeService`，动前必标锁定。

## 营养库三级校正策略（2026-07-22 起）
- 图片/文字识别到食物 → 校正优先级：**① `NutritionLibrary` 硬编码库 → ② `FoodMetaStore` 本地联网缓存(SwiftData,FoodMeta) → ③ 联网查并落库**。
- ③ 联网：前端 `ResultConfirmView.resolveFoodNutrition` 调 `RecognizeService.queryFood(name:)` → 云函数 `mode:"queryFood"`（sensenovaText，fallback qwenText）→ `FoodMetaStore.upsert` 沉淀。命中即写 `FoodMeta`，下次同类食物本地直中，省模型调用与费用。
- 硬性护栏：`source == .local`（营养成分表 OCR 标签值）绝不被通用营养库覆盖；`NutritionLibrary` 仅静态匹配，不耦合 SwiftData context；`FoodMeta` 的 `name` 为归一化唯一键。
- 新增食物别名/特殊菜：优先在 `NutritionLibrary.aliases` 加映射（如牛肉汤面→牛肉面），不要塞进 `rows`。
