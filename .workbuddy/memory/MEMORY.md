# AI 助理原生 App · 长期记忆

## 技术栈/环境
纯 Swift+SwiftUI+SwiftData(iOS17+)。Xcode `/Volumes/MacBook/Applications/Xcode.app`。build：`xcodebuild -project AIA/AIA.xcodeproj -scheme AIA -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build CODE_SIGNING_ALLOWED=NO`。iOS 26.5 / Xcode 26.6，`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`，新代码默认 MainActor。Toolbar 用 `.topBarLeading`/`.topBarTrailing`。`PBXFileSystemSynchronizedRootGroup` → `AIA/AIA/` 下新 .swift 自动进编译。用户：微信小程序开发者，无 Swift 经验，**已购 Apple Developer Program 付费账号（$99/年，个人）**，可真机/TestFlight/上架；签名开 `CODE_SIGNING_ALLOWED=YES`（模拟器仍可 NO）。

## 关键约定
Schema 闸门：@Model 变更 `AIAApp.schemaVersion`+1 集中管。绝不静默入库（图片→识别→确认页→改后入库；原图仅本地）。并行协作先读 `多团队协作分工表.md` §3/§4，§3 高危=Models/AppPersistence/AIAMigrationPlan/AIATheme/UIComponents/RecognizeService。

## SwiftData 铁律
不主动 save（autosave）；不用 withAnimation 包模型变更；副作用延后 main.async/Task@MainActor；详情页删/完成先 dismiss 再 .onDisappear 延迟 600ms；延迟闭包只存 persistentModelID 现场取活对象；非 NavigationLink cell 直接 withAnimation{delete}。

## SwiftUI 铁律
- 单 NavigationStack(path:)+.navigationDestination(for:HomeRoute.self)；进详情用 `ValueSelectableCard(value:)`；闭包 destination 仅限 .sheet；被 push 的 view 自身绝不包 NavigationStack。
- 禁 `ForEach(0..<n)+数组[i]` 及含重复元素数组用 `id:\.self` → `ForEach(Array(enumerated()),id:\.offset)`。
- 控件做副作用用自定义 `Binding(get:set:)`，别用 `.onChange`（首次误触发）。
- 跨日期共享 UI 用 `selectedDate` 禁 `Date()`。大段删除先 Grep 父级起点数 `}` 边界，删完先 build 再 commit；出错 `git checkout -- <file>`。toolbar/大 body 报 type-check timeout → 抽 `@ViewBuilder`/`private func`，body 只调 helper。ScrollView 动态列表用 LazyVStack；`scrollTo` 贴顶不足末尾加 `Color.clear.frame(minHeight:1000)`。PhotosPicker 配 `.onChange(of:)`；`UIImage` 用 `loadTransferable(type: Data.self)`。`ScrollView` 上勿叠 `.onTapGesture` 收键盘，用 `.scrollDismissesKeyboard`。

## iOS26.5/Xcode26.6 + MainActor 坑
- 自定义 `Button(action:){}` 闭包可能不派发 → 改用 `View+.onTapGesture`/`Menu`/`.contextMenu`。
- `.task` 闭包可能不派发 → 首屏副作用放 `ContentView.onAppear` 内裸 `Task{}`；周期用 `Timer.publish().autoconnect()+.onReceive`；切页用 `.onAppear`。
- 进度条/环/占比条必走 `safeFraction`（防 NaN/负宽度 `Invalid frame dimension`）。
- NavigationStack `path` 改写必须走 `NavigationRouter.navigate/replaceWith`（单帧合并），禁止各处直接 append/`=`。
- `PreferenceKey` value 与 `.animation(value:)` 值绝不能用元组，用显式 `Equatable` struct。

## 识别/云同步
`recognizeWithLocalPriority`：本地OCR(营养成分表+兜底)→版面解析→其它图走视觉模型(商汤sensenova，Key 走 CloudBase 云函数代理)。云同步环境 `cloud1-d1ga55pizf294dbe9`；pull 把 `_id` 映射 `id`；启动 60s 同步；改后 3s 防抖。recognize 主目录 `云函数/recognize/`。

## UI/深色模式（最高优先级）
颜色走 `AIATheme` 自适应令牌，禁写死 hex；禁 `AIATheme.ink` 当前景色→用 `Color.primary`/`AIATheme.sub`；淡底用 `dietBG/billBG/todoBG/healthBG`。hairline(深色`0x636366`)全行分隔；容器描边 `iconInactive`(light`0xc9ced3`/dark`0x5a5a5e`)。列表图标用经典 SF Symbol。

## 三件套
- 背景图 `AppBackground.swift`：存 Documents/app_background.jpg+`aia.customBackground`+`aia.backgroundMask`(默认0.35)；仅首页/聊天页根 `.background`。
- 广告位 `AdBanner.swift`：云端 `aia_ads`，`AdStore` 拉取+容错+缓存；轮播 `ScrollView(.horizontal)+scrollTargetBehavior(.paging)`+4s `Timer+.onReceive`；首拉 `ContentView.onAppear` 内 `Task{ AdStore.shared.fetchIfNeeded() }`。
- 开发者入口 `DeveloperTools.swift`：`DeveloperGate` 口令 `Daxing@0329`；写操作 `云函数/ads/index.js` 校验 `DEV_PASSCODE`。
- 全局配置 `GlobalConfigStore.swift`：智能问答/AI 模型云端 `aia_config` 文档 `global` 全局权威；`ContentView.onAppear` 首拉+30s `Timer+.onReceive`。

## 品牌命名
- App 实际定名 **好记AI**（设备上显示名 `好记`，见 pbxproj `INFOPLIST_KEY_CFBundleDisplayName`）。曾用「识记AI」「阿宝AI管家」并已全工程批量改；历史图标文件名 `AppIcon_识记AI.png`/`Logo_识记AI.svg` 等仍残留未统一（属历史遗留，非紧急）。
- 对话页 AI 助手昵称 **小记**（"记"字与品牌呼应；2026-08-03 由「阿记」改）。
- App 图标：**苹果绿渐变**（顶部 `#34C759` → 底部 `#1AAE54`，像电话/信息 App）+ 白「記」字标（繁体，方方正正华文黑体）+ 右上 AI 火花/字标。现用 `AppIcons/build_icon_final.py` 生成的 `AppIcon_识记AI.png`(1024) 写入 `AppIcon.appiconset/AppIcon.png` 与 `AppLogo.imageset/AppLogo.png`（图标文件名保留历史命名 `AppIcon_识记AI.png`）。2026-08-11 由蓝→青渐变改为苹果绿。渲染脚本 `AppIcons/build_icon_final.py`（程序化绘制，绕过 AI 生图中文乱码）。
- 商标待办：查第9/42/38类近似；文字标+图形标分开注册；logo 著作权登记。候选表 `候选名总表.md`、IP 风险 `商标检索清单_备用改名方案.md`。
- **2026-08-10 改名决策**：曾评估改「全能记」，但 App Store 已有同名在架「全能记」(id 1587301632，4.6分) 且多「全能记事本」占用 → 名称冲突/商标近似驳回风险高。**用户最终决定保留好记AI，不改全能记。**

## 上架/发布
- 已购 Apple Developer Program 个人付费账号（$99/年，2026-08-10），上架首道门槛打通。
- Bundle ID 前缀 `com.daxing.aia`（主 App `com.daxing.aia.AIA`；Widget/ShareExtension/LiveActivity 同前缀子域）。App Store Connect 建 App 须用同一 Bundle ID。
- 模拟器构建仍 `CODE_SIGNING_ALLOWED=NO`；真机/Archive 分发需开签名并选 Team。
- 应用内账户删除已实现（云函数 `aia-sync` 的 `deleteAccount` + 客户端 `CloudSyncManager.deleteAccount` + `MyAccountView` UI，满足苹果 Guideline 5.1.1(v) 有账号体系必做项）；用户协议页 `好记用户协议.html` 已建（因做订阅自定义 EULA，¥88/年·¥8.8/月）。**构建验证注意**：命令行 `xcodebuild` 在沙箱/CLI 环境会因 SwiftData 宏插件 `swift-plugin-server` 加载被拒（Operation not permitted）无法编译 AIAKit，非代码错误，须在真实 Xcode GUI ⌘B 验证。
