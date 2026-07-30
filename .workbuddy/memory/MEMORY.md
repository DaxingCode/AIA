# AI 助理原生 App · 长期记忆

## 技术栈/环境
纯 Swift+SwiftUI+SwiftData(iOS17+)。Xcode `/Volumes/MacBook/Applications/Xcode.app`（非默认）。build：`/Volumes/MacBook/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project AIA/AIA.xcodeproj -scheme AIA -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build CODE_SIGNING_ALLOWED=NO`。部署目标 iOS 26.5 / Xcode 26.6；`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`，新代码默认 MainActor。Toolbar 用 `.topBarLeading`/`.topBarTrailing`（`cancellation`/`confirmation` 已移除）。工程用 `PBXFileSystemSynchronizedRootGroup` → `AIA/AIA/` 下新建 .swift 自动进编译，无需改 pbxproj。

## 关键约定
- Schema 闸门：@Model 变更 `AIAApp.schemaVersion`+1，集中管，禁多对话各自+1。
- 绝不静默入库：图片→识别→JSON→确认页→用户改后入库；原图仅本地不上传。
- 并行协作：动手前读 `多团队协作分工表.md` §3/§4；§3 高危=Models/AppPersistence/AIAMigrationPlan/AIATheme/UIComponents/RecognizeService。空闲先占 §4，commit 后清除。
- 用户：微信小程序开发者，无 Swift 经验，无 Apple 付费账号。

## SwiftData 铁律
不主动 save（autosave）；不用 withAnimation 包模型变更；副作用延后 main.async/Task@MainActor；详情页删/完成先 dismiss 再 .onDisappear 延迟 600ms；延迟闭包只存 persistentModelID 现场取活对象；非 NavigationLink cell 直接 withAnimation{delete}。

## SwiftUI 铁律
- 单 NavigationStack(path:)+.navigationDestination(for:HomeRoute.self)；进详情用 value-based `ValueSelectableCard(value:)`；闭包 destination 仅限 .sheet。被 push 的 view 自身绝不包 NavigationStack（双调用点拆 XxxSheet）。
- 禁 `ForEach(0..<n)+数组[i]` 及**含重复元素数组用 `id:\.self`**（日历 `[Date?]` 月首月尾 nil 重复 id→diff 错乱、月末选中不重绘）→ 一律 `ForEach(Array(enumerated()),id:\.offset)`。
- SegmentedPicker/Picker/Stepper/Toggle 写 Binding 做副作用**别用 `.onChange`**（首次渲染误触发）→ 用自定义 `Binding(get:set:)`，setter 里写状态+副作用。
- 跨日期共享 UI 写入用 `selectedDate` 禁 `Date()`；视觉/可点性跟统计对齐，勿加「只今天」门控。
- 大段删除前先 Grep 父级 ScrollViewReader/ScrollView/LazyVStack 起点、数 `}` 边界，删完先 build 再 commit；出错 `git checkout -- <file>` 精准还原（勿 `git checkout .`）。
- toolbar+多 sheet+多层 ZStack 或 ScrollViewReader 包大 body 报 type-check timeout → 条件分支抽 `@ViewBuilder private var xxx: some View`，body 只调 helper。
- ScrollView 动态列表用 LazyVStack（VStack 结构变化会复位滚动到顶）；`scrollTo` 贴顶不足时 content 末尾加 `Color.clear.frame(minHeight:1000)` 撑高。
- PhotosPicker 必须配 `.onChange(of: picker)` 消费选中项并保存；`UIImage` 非 Transferable，用 `loadTransferable(type: Data.self)` 再 `UIImage(data:)`。
- `ScrollView` 上的 `.onTapGesture` 会与子视图按钮点击手势竞争、吞掉按钮点击——收起键盘用 `.scrollDismissesKeyboard` 即可，勿再叠 `.onTapGesture { hideKeyboard() }`（2026-07-29 踩坑：设置页『恢复默认』按钮因此始终点不动）。
- **iOS 26.5 / Xcode 26.6 + `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` 环境下，自定义 `Button(action:) { }` 闭包可能不被派发**（控制台 action 内 print 不出现、UI 无响应），而 PhotosPicker/NavigationLink 等系统控件正常。兜底方案：改用 `Text/View + .onTapGesture { }`、`Menu` 或 `.contextMenu` 触发（2026-07-29 设置页『恢复默认』验证）。
- **同环境下 `.task` 修饰符闭包同样可能不派发**（即便挂在永远存在的 Group 上，body 被求值却 task 闭包不跑，2026-07-29 广告位 `AdBannerView` 验证：只有 `[AdBannerView] body 被调用`、无 `[AdBannerView] task 触发`）。兜底：① 首拉/首屏副作用放 `ContentView.onAppear` 内用裸 `Task { }` 异步派发；② 周期任务用 `@State Timer.publish(...).autoconnect()` + `.onReceive(timer)`（`.onReceive` 已验证可靠）；③ 切页/出现定位用 `.onAppear`。勿把关键 fetch 挂 `.task`。
- **进度条/进度环/占比条必走 `safeFraction`（2026-07-29 两次"Invalid frame dimension"坑）**：`RingView`(trim)/`MacroCard`(frame width)/`MiniBar`(frame width) 的占比一律用 `UIComponents.swift` 的**模块级** `func safeFraction(_:)`（非有限值/负数回退 0，即 `guard v.isFinite else {return 0}; return CGFloat(min(max(v,0),1))`）。**禁止**直接 `CGFloat(min(max(drawn,0),1))`——Swift 的 min/max 遇 NaN 原样返回 NaN、`geo.size.width * 负数` 得负宽度，二者进 `.frame()` 都会抛 `Invalid frame dimension (negative or non-finite)`。`safeFraction` 已改 `internal` 跨文件复用。两类根因：① 除零 `0/0=NaN`/`x/0=±inf`（`goal/monthlyBudget/calorieGoal/stepGoal/budget` 等分母为 0 时先判 `> 0` 守卫）；② **退款/负金额**使占比为负（`item.sum<0` → `geo.size.width * 负占比` 负宽度，如 `BillDashboardView.swift:380` 分类条）。任何 `geo.size.width * 占比` 的 width 一律走 `safeFraction`，负数退款钳 0（进度条不显示，合理），文本可保留负号如实展示。
- **NavigationStack 的 `path` 改写必须走单帧合并（2026-07-29 导航观察者报错坑）**：全 App 程控跳转统一经 `NavigationRouter.navigate(_:)`（追加）/ `replaceWith(_:)`（替换，冷启动/通知），二者共用 `scheduleFlush()`——同帧多次调用只留最后一次、`DispatchQueue.main.async` 下一帧提交**一次** path 变更，从机制上杜绝 `Update NavigationRequestObserver tried to update multiple times per frame`。**禁止**在 `Button`/`.onTapGesture`/各页入口直接 `router.path.append(...)`/`path = [...]`（手势导航与同帧其它 push 并发会触发断言）。入口清单：`ContentView.swift`(格子/气泡/设置/我的账号/`jump`)、`UIComponents.swift`(底部栏)、`RecordsViews.swift`(autoSetup×3/billTools/todoTools)、`RecurringRuleViews/BillToolsView/TodoToolsView`(autoSetup)、`QuickActionRouter.navigateToChat`。

## 图片识别链路
`recognizeWithLocalPriority`：本地OCR(仅营养成分表+视觉失败兜底)→营养成分表本地版面解析→其它图走视觉模型(商汤sensenova，API Key 走 CloudBase 云函数代理不硬编码前端)→失败本地兜底，无则抛错绝不返 0 空账单。营养匹配：精确→别名→子串(头名词靠后优先)→调料前缀护栏。

## 云同步/CloudBase
环境 `cloud1-d1ga55pizf294dbe9`。pull 把 `_id` 映射 `id`；启动 60s 定时同步；改后 3s 防抖。recognize 主目录 `云函数/recognize/`（需手动部署）。

## UI/深色模式（最高优先级）
颜色走 `AIATheme` 自适应令牌（深色模式必须双套验证）。禁写死 hex；禁 `AIATheme.ink` 当前景色(深近黑隐形)→用 `Color.primary`/`AIATheme.sub`；有色淡底用 `dietBG/billBG/todoBG/healthBG` 自适应淡底，勿低透明度叠深色。hairline(深色 `0x636366`)用于全行分隔；容器描边/控件分隔用 `iconInactive`(light `0xc9ced3`/dark `0x5a5a5e`)。Rectangle/Divider 控高宽须显式 `frame`。列表图标用 `wand.and.stars`/`bell.badge.fill`/`viewfinder.circle` 等经典 SF Symbol。

## 三件套（2026-07-29）
- 背景图 `AppBackground.swift`：`AppBackgroundStore` 单例存 Documents/app_background.jpg(压缩)+`aia.customBackground`+`aia.backgroundMask`(默认0.35)；`AppBackgroundView` 有图缩放填充+自适应遮罩，无图 systemGroupedBackground。仅首页/聊天页根 `.background`。图片只存本机。选择后由 `.onChange(of: bgPicker)` 调 `save` 并广播 `aiaBackgroundChanged` 刷新。
- 广告位 `AdBanner.swift`：云端 `aia_ads`（逻辑并入 `aia-sync` /sync 路由，action: list/listAll/upsert/delete/reorder），`AdStore` 拉取+容错解码(`AdItemRaw`)+缓存+时间窗过滤，`AdBannerView` 放 syncHeaderIndicator 后/homeModules 前。轮播：`ScrollView(.horizontal)+scrollTargetBehavior(.paging)+scrollPosition(id:)` 单向从右往左循环(尾部克隆页无动画瞬移)，多广告 4s `@State Timer+.onReceive` 推进，空→EmptyView。首拉触发点：`ContentView.onAppear` 内 `Task{ AdStore.shared.fetchIfNeeded() }`（本环境 .task 不派发，勿挂 .task）。
- 开发者入口 `DeveloperTools.swift`：`DeveloperGate` 口令 `Daxing@0329`+`aia.devModeUnlocked`；设置「版本」行长按1.2s解锁→开发者中心→`AdManagerView`(PhotosPicker 选图转 base64)。写操作 `云函数/ads/index.js` 校验 `DEV_PASSCODE`(环境变量优先)。云函数需手动部署(`package-ads.sh`)。
- 全局配置 `GlobalConfigStore.swift`（2026-07-29）：智能问答开关/AI 模型**云端全局权威**——`aia_config` 集合固定文档 `global`，开发者中心切换后 `saveConfig`(带 `DeveloperGate.passcode`) 写云端，所有用户 `fetchConfig`(公开 getConfig) 自动跟随；本地 UserDefaults 仅缓存(键 `aia.agentEnabled`/`aia.modelProvider`/`aia.visionModelProvider`)。`ContentView.onAppear` 首拉 + 30s `Timer+.onReceive` 周期拉；`DeveloperCenterView`/`ChatView` 经 `@ObservedObject GlobalConfigStore.shared` 观察。`RecognizeService.textCurrent/visionCurrent` 读 UserDefaults 缓存即自动跟随。普通用户看不到开发者中心、无法改（入口受口令保护）。
