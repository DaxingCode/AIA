# AI 助理原生 App · 长期记忆

## 定位/技术栈
原生 iOS App（饮食/健康/账单/待办），核心差异化=截屏无感识别。纯 Swift+SwiftUI+SwiftData(iOS17+)。截图无感=快捷指令+App Intents(`ProcessScreenshotIntent`)，兜底分享扩展。视觉模型主力商汤sensenova，API Key 走 CloudBase 云函数代理，不硬编码前端。

## 环境/工具链
- Xcode：`/Volumes/MacBook/Applications/Xcode.app`（非默认）。`xcodebuild` 用绝对路径：`/Volumes/MacBook/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project AIA/AIA.xcodeproj -scheme AIA -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build CODE_SIGNING_ALLOWED=NO`。
- 沙箱内可正常构建验证（含 @Model/@Query 宏，2026-07-25 实测 SUCCEEDED），无需真机/解除沙箱。

## 关键工程约定
- Schema 闸门：@Model 变更必须 `AIAApp.schemaVersion`+1，集中责任人管，禁多对话各自+1（否则旧 store 白屏）。
- App Intents 短语须含 `\(.applicationName)` token。
- 聊天分流：含饮食词不含账单词→先 food；兜底仅当用户含「记一下/添加」等创建动词才入库。
- 绝不静默入库：图片→识别→JSON→确认页→用户改后入库；原图仅本地，`imageName` 不上传。

## SwiftData 铁律
- 不主动 `context.save()`（autosave）；不用 `withAnimation` 包模型变更。
- 副作用延后 `DispatchQueue.main.async`/`Task{@MainActor}`。
- 详情页删/完成：先 `dismiss()`，`.onDisappear` 延迟 600ms 再执行。
- 延迟闭包禁直接捕获 SwiftData 对象→只存 `persistentModelID`，执行时 `context.model(for:)` 取活对象（`SafeDelete` 已提供）。
- 非 NavigationLink 的列表 cell 直接 `withAnimation{context.delete(obj)}` 硬删。

## SwiftUI 铁律（崩溃/编译坑）
- 单 `NavigationStack(path: $router.path)+.navigationDestination(for:HomeRoute.self)` 全 App 通用。从首页列表进详情必须 value-based（`ValueSelectableCard(value: HomeRoute.xxx(记录))` + HomeRoute 加 case）；严禁 `SelectableCard(destination:)` 闭包式嵌根层（AnyNavigationPath try! comparisonTypeMismatch 死锁白屏）。闭包 destination 仅限 .sheet 内。
- view 若会被 navigationDestination 推入父级 NavigationStack，自身**绝不能**包 NavigationStack；双调用点（push+sheet）必须拆 `XxxSheet` wrapper。历史崩过的 view（EditTodoView）即使只剩 sheet 调用也永留 wrapper。
- Swift struct 带默认属性（如 `let isAdding: Bool = false`）必须显式写 init，否则调用方报 extra argument。
- 加 toolbar+多 sheet+多层 ZStack 报 type-check timeout → 拆 `@ViewBuilder private func` helper，body 只调 helper。
- push 一致性：全编程式 `path.append` 或全闭包 `NavigationLink`，混用会绕过中间页。
- Button 不能嵌 NavigationLink.label；行内多交互用 ZStack 分层。禁 `ForEach(0..<n)+数组[i]` 遍历 @Query 派生数组→`ForEach(Array(x.enumerated()),id:\.offset)`。

## 图片识别链路（2026-07-22 单一入口）
`recognizeWithLocalPriority`：①本地 OCR 仅判营养成分表+视觉失败兜底；②营养成分表→本地版面解析；③其它图片统一走视觉模型；④失败本地兜底，无则抛错绝不返 0 空账单。营养库匹配：精确→别名→子串(头名词靠后优先)→调料前缀护栏。

## 云同步/CloudBase
- pull 把 `_id` 映射 `id`；登录/重装先全量 pull 再 push。启动 60s 定时同步；改后 3s 防抖 `syncAfterLocalChange`。
- 环境 `cloud1-d1ga55pizf294dbe9`；recognize 主目录 `云函数/recognize/`，脚本 `package-recognize.sh`，zip 随 FN_VERSION，gitignored，需手动部署。

## UI/视觉约定
- **深色模式强制适配（最高优先级）**：新建/修改任何 UI 必须同时验证浅色与深色两套配色，禁止只按浅色设计。具体：① 颜色一律走 `AIATheme` 自适应令牌（`food`/`dietBG`/`billBG`/`todoBG`/`healthBG`/`surface`/`hairline`/`sub` 等均已深浅双值），不要写死 hex；② 文字/图标**禁止用 `AIATheme.ink` 当前景色**——`ink` 深色值 `0x2c2c2e` 近黑，深色下会直接隐形，深色可读文字用 `Color.primary` 或 `AIATheme.sub`；③ 有色淡底在深色下要用 `dietBG`/`billBG`/`todoBG`/`healthBG` 这类自适应淡底，不要用 `food.opacity(0.08)` 等低透明度叠深色（深色下近乎不可见）；④ 改完在模拟器切深色模式肉眼核对一次再 commit。
- 颜色走 `AIATheme` 令牌：food(琥珀)/health(紫)/bill(绿)/todo(蓝)/expense(红)/warning(琥珀)。动效走 `AIATheme.Motion`+`PressableCardStyle`，禁散写 `Animation.xxx`。
- 空态垂直居中；底部栏 `AIBottomBar` 箭头由 `iconOrder` 推导。
- 账单行间 hairline 3 处（groupedByDate/billCalendarView/MonthlyBillListView）必一起改：`ForEach(enumerated)`+`Rectangle().fill(AIATheme.hairline).frame(height:0.7).padding(.leading,62)`。
- 深色 hairline 标准 dark `0x636366` + 宽度≥0.7pt（light `0xe6e9ec` 不动）。按字段分组列表相邻组间插 hairline 0.7pt。
- **hairline vs iconInactive 分工（2026-07-26 踩坑）**：`AIATheme.hairline` light `0xe6e9ec` vs `fillSoft` light `0xeef1f4` 色差仅 ~6 级，**作"容器边框/控件分隔"在浅色下几乎不可见**。「**全行/全段分隔细线**」用 hairline（克制、深色对）；「**需可见但克制的容器描边/控件分隔**」（如 SegmentedPicker 外层描边 + 页签间分隔）改用 `AIATheme.iconInactive`（light `0xc9ced3`、dark `0x5a5a5e`，双模式色差都 ~38-46 级清晰）。
- **HStack/VStack 内 Rectangle/Divider 控高/控宽必须用显式 `frame(width:height:)`**（2026-07-26 踩坑）：`Rectangle` 在父容器默认被拉满到「最高子项」尺寸，`.padding(.vertical/horizontal, ...)` 只缩**内部**内容、**不影响外部撑满**。要控高必须 `frame(width: 0.7, height: 18)` 这种显式指定。SegmentedPicker 竖线高度 ≈ 60% 容器高 = 18pt 是 iOS 标准克制比例。
- 列表图标用语义色 SF Symbol 直显，避开 iOS 新版复杂 symbol（如 `sparkles.rectangle.portrait.fill` 渲染退化）。经典：`wand.and.stars`/`bell.badge.fill`/`viewfinder.circle`。

## 协作/用户/营养库
- 多对话并行改同仓，协调中枢=`多团队协作分工表.md`：动手前读 §3/§4，占则停下，空闲先写 §4 再动手，commit 后清除。§3 高危：Models/AppPersistence/AIAMigrationPlan/AIATheme/UIComponents/RecognizeService。
- 用户：微信小程序开发者，无 Swift 经验，无 Apple 付费账号。
- 营养三级校正：① NutritionLibrary → ② FoodMetaStore → ③ 联网查落库；新增别名走 `aliases` 不塞 `rows`；`source==.local` 绝不被覆盖。
