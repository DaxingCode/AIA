# AI 助理原生 App · 长期记忆

## AI 协作铁律（贯穿所有对话）
- **本环境 AI 没有自动执行终端命令的能力**：git / xcodebuild / 任何 shell 命令都**不会自动跑**，全由用户手动在终端敲。AI 给命令时必须主动问"要不要我帮你执行 / 还是你自己跑？"，尤其 commit/push/reset/revert/stash/checkout 先问。
- AI 只负责：开分支建议、插 CHANGE- 标记、写带格式 commit 信息、给现成命令文字。

## 环境/构建
- 纯 Swift+SwiftUI+SwiftData；**部署目标 iOS 17.0**；视觉模型走 CloudBase 云函数代理。
- 构建：`xcodebuild -project AIA/AIA.xcodeproj -scheme AIA -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build CODE_SIGNING_ALLOWED=NO`（命令行须指定 simulator name，否则解析成 mac 构建失败）。
- CloudBase `cloud1-d1ga55pizf294dbe9-1445590522`（上海）；`云函数/recognize/` 唯一规范目录，改完须 `./package-<fn>.sh` 重打包部署。
- 账号 `sanhaoai@163.com`，Team `XRJH9U2Y5F`；Bundle `com.daxing.aia.AIA`/`.ShareExtension`/`.AIALiveActivityWidget`；AppGroup `group.com.daxing.aia`；iCloud `iCloud.com.daxing.aia.AIA`。
- entitlements/签名/pbxproj 走 Xcode GUI；三个 appex 已在 `Embed App Extensions`。**`AIAKit.framework` 必须 Embed**（`PBXCopyFilesBuildPhase` 排在 Embed App Extensions 前，appex 靠 `@executable_path/../../Frameworks` 找主 App 那份；真机先删旧 App 再装）。
- `GENERATE_INFOPLIST_FILE=YES`：隐私键写 `INFOPLIST_KEY_NSxxx`；相册写入须配 `NSPhotoLibraryAddUsageDescription`。
- 调试 Widget 选 `AIA` scheme；误选 extension scheme 报 `_XCWidgetKind` 错（非 bug）。新增 .swift 放 `AIA/AIA/` 自动编译。
- 本机调试：`Dxiphone` 真机 + `iPhone 17 Pro` 模拟器；`iPhone XS Max`(iOS 18.7.7, A12 老芯片) 模拟真实客户环境验收性能。
- Info.plist 双路径坑：extension target 的 `INFOPLIST_FILE` 指向某 plist 且 `GENERATE_INFOPLIST_FILE=NO` 时，该 plist 的 Target Membership 须 "No Targets"；源文件须勾 Membership。
- 模型在 AIAKit 后 `@Model` 必须 `public`；跨模块类型一律 public。
- **入口架构（2026-08-15 定稿）**：纯 SwiftUI `@main App` + `WindowGroup` 托管（AIAApp.swift 仍是 `@main`，无 main.swift）。AppDelegate 仅作纯 `UIApplicationDelegate`（不当 UISceneDelegate）。冷启动快捷项走 `didFinishLaunching` + `configurationForConnecting` 双入口写 `pending`，`guard pending==nil` 防二次覆盖；`performActionFor` 已删。
- **`AIAKit` 真实路径 = `AIA/AIAKit/`**（独立 framework target，含 8 文件），**不是** `AIA/AIA/AIAKit/`。两套 synchronized group 别混。
- pbxproj 悬空引用坑：磁盘无文件却留 pbxproj 引用→`Build input file cannot be found`，须删引用别误删其他有效引用。
- **Manage Schemes 重复同名（2026-08-15 根治）**：`project.xcworkspace/xcshareddata/xcschemes/` 残缺那套已删，仅留 `AIA.xcodeproj/xcshareddata/xcschemes/` 正确套 + swiftpm/，重启 Xcode 即正常。

## SwiftData
- @Model 变更须 `AppPersistence.currentSchemaVersion`+1 加 `AIAMigrationPlan` Stage；仅新增模型安全。
- 新模型必带 `syncId/syncUpdatedAt/syncDeleted`；展示 Bill/Todo/Reminder/FoodEntry/SleepSession 的 `@Query` 必加 `#Predicate{!$0.syncDeleted}`。
- `AppPersistence` 所有 `ModelConfiguration` 加 `cloudKitDatabase:.none`。
- 不主动 `context.save()`；不用 `withAnimation` 包模型变更；副作用延后 main async。
- 详情页删/完成：先 `dismiss()`，`.onDisappear` 延 600ms；闭包只存 `persistentModelID`，执行时 `context.model(for:)` 取活对象。左滑删一律 `SafeDelete.xxxByID` 避免滚动后 fault 闪退。

## SwiftUI · 首页架构铁律（以 ContentView.swift / QuickActionRouter.swift 为准）
- **根视图首帧死循环（仍在排查，未根治）**：`ContentView.body` 首帧在 iOS 18/26 多轮重算 + NavigationStack 触发内部 `_NavigationRequestObserver` 断言 → 主线程卡死 → 启动页 asyncAfter 排不上队。`ContentView` 头部注释声称把 `quickAction/router/layout` 改 `private let` 切断订阅，但代码**暂未落实**（仍是 `@ObservedObject`），`Self._printChanges()` 探针（530 行）仍在定位首帧哪个 @Published 反复重算。下一步：若探针确认是某单例触发，改为 let 或把 NavigationStack 抽到独立子视图解耦；勿再猜。
- **NavigationRouter 帧合并（已落地，根治"同帧多次改 path"崩溃）**：所有 `router.navigate(...)` 先 `enqueue` 入队，`flushScheduled` 在下一帧只 flush 一次。全 App 统一单 `NavigationStack(path:) + 单 .navigationDestination(for: HomeRoute.self)`；四宫格/齿轮/快捷操作全走 `router.navigate(...)`，**禁用** `NavigationLink(value:)`（iOS 26 首屏白屏 bug）和多个 `.navigationDestination(isPresented:)`。
- 首页死循环一大半已靠上面规避：`homeEnterToken` 已改根 `performOnAppear`（homeEnterFired 幂等守卫）+ `didBecomeActive`。
- 健康派生值抽到 `HomeHealthData.shared`；healthTile 用 `.onReceive(HealthManager.shared.debouncedChange)`（300ms 去抖）。
- Button 不嵌 NavigationLink；行内多交互用 ZStack 分层。`.swipeActions` 仅 List 生效；列表全 ScrollView → 左滑删/多选用 `SelectableRow`+`MultiSelectBottomBar`；长按用 `UIKitLongPressView`（cancelsTouchesInView=false, delegate.shouldRecognizeSimultaneouslyWith=true, overlay 挂最上层）。
- 根 NavigationStack 用 `NavigationRouter.shared.navigate(.x)`；首页模块布局由 `HomeLayoutStore`(@AppStorage) 驱动。
- **`AIATheme.ink` 雷区**：dark 值 0x2c2c2e 与深色卡片底同色，绝不做正文文字色，正文用 `.primary`/`AIATheme.reading`。
- 语义色：food(琥珀)/health(紫)/bill(绿)/todo(蓝)/income(绿)/expense(红)/warning(amber)/over(深红)。
- 宫格右上角图标统一 `.overlay(alignment:.topTrailing)` 浮层：固定 `frame(width:54,height:54)`+`contentShape(Rectangle())`+12pt inset；禁止 `frame(maxWidth/maxHeight:.infinity)` 撑满——老芯片(A12/XS Max) UIKit 把点击判给父卡片致"点不动"。
- 全屏 UIKit UI 不走 SwiftUI：相机等用全局 Presenter 建绑定 `UIWindowScene` 的临时 `UIWindow`（windowLevel=.statusBar+1、黑底、.dark），回调前先拆窗。
- 提示型弹窗用自定义 `CenteredAlert`（iOS 26 系统 alert 文字强制左对齐）。「标题+说明+单确认」一律 `.centeredAlert`；带 destructive 双按钮或 SecureField 仍用系统 `.alert`。
- 动画进度条丝滑（2026-08-13）：`MiniBar`/`MacroCard` 进度改「固定全宽 + `.mask(alignment:.leading){ Rectangle().scale(x:fraction, anchor:.leading) }`」走 GPU 合成层，别每帧改 `.frame(width:)`（老芯片掉帧）。

## 业务口径
- 识别唯一入口 `recognizeWithLocalPriority`：本地 OCR→营养表→本地待办/健康→视觉模型→本地兜底；`todoExcludeSignals` 强排除真账单。绝不静默入库（识别→待确认→确认才入库）。
- 待办过滤统一 `!done`（含 due=nil→「未安排」置底）。
- 饮食时间语义：记食物「没说餐次/时刻」→ 记录时间=发消息那一刻；餐次标签按当前小时猜。`RelativeDateParser.dateTimeOrToday` 无日期词返回 `(Date(), true)` 走 isoLocal 带完整时刻；带「昨天/M月D日/周X」回溯走餐次整点。ChatView 与 Siri 共用。
- **对话页识别卡片**：协议串 `__RECOGNITION_RESULT__{json}`/`__USER_IMAGE__{文件名}`/`__UPGRADE_PRO__{文案}`。三态：待确认(syncId=nil)→已保存(@Query 取活实例)→真实记录被删整张卡消失。自动保存/待确认/丢弃由 `ImageAutoRecogSettings` 按 (source×type) 二维配置；任一 pending 时截屏走 `ResultConfirmView`。会员误报付费墙坑：任何"升级 Pro"引导前须确认非 `plan==.unknown` 误判。

## 营养库
- `NutritionLibrary.match` 只读 `FoodMetaStore`（精确→别名→子串）。内置表灌库 `AppDelegate` 版本化 seed，补齐后 +1 `SEED_VERSION`。`createFoodLocally` 0 缓存→云端重查 upsert，同名只试一次。
- **铁律·营养值必须按重量缩放**：库存每 100 克营养，凡组装 `FoodPayload` 入口都须 `×(重量÷100)`；云端视觉返回的已是"这份总热量"不要乘。

## 云同步 / 云函数
- 已上云 type：`bill/reminder/food/health/manualHealth/recognition/merchant_meta/chat/water/recurring_rule/setting/profile/sleep`；时间字段秒；待办无截止 `due=0`+`dueNil=true`。
- 增量 pull `updatedAt>since`，push `syncUpdatedAt>lastSyncAt`；软删刷新 `syncUpdatedAt`。
- **云同步放行铁律（2026-08-13 定稿）**：统一走 `CloudSyncManager.canPerformCloudSync`（`autoSync && EntitlementManager.shared.can(.cloudSyncPush)`）。会员到期（plan=.expired）按彻底关闭。三处调用点 `syncAfterLocalChange`/`syncAfterLogin`/`backupIdentityProfile` 及 `sync(context:)` 均已加守卫。
- **两个默认关闭的开关（隐私优先）**：①`autoSync` 默认 false；②`icloudEnabled` 默认 false。各自 `AppDelegate.register(defaults:)` 兜底 + 老用户一次性迁移强制 false。`deleteAccount`/注销清云端是主动操作，不受开关影响。
- `aia_config.global` 是免费版总开关：`freeQuotaEnabled:true`/`freeQuotaPerMonth:30` 需手动补。
- broadcast 推送链路：token→`aia_devices`→`handleBroadcast` 接单 `{ok,accepted:N}`（passcode `Daxing@0329` 须与 `DeveloperGate.passcode` 一致）→续批自调→提交者收「✅ 推送完成」回执，`aia_broadcast_jobs` 记录。APNs PEM 控制台不支持换行→`makeAPNsJWT` 按 RFC7468 每 64 字符重拆。

## iCloud / 模拟器坑
- 模拟器 `url(forUbiquityContainerIdentifier:)` 返回非 nil → `ICloudBackupManager.isAvailable()` 恒 true，须 `#if targetEnvironment(simulator) 短路 #endif`。模拟器 ubiquity 残留触发 RunLoop Timer 占主线程→卡死；探测入口带模拟器守卫、轮询有上限兜底。

## 端侧 LLM / 健康 / 会员
- 端侧 LLM：iOS26 纯文本可用，图像输入 iOS27；一律 `@available(iOS 26,*)`+`isAvailable` 守卫+云端回落。
- 健康数据源 `@AppStorage("aia.health.source.<metric>")`；`SleepSession` 归属按醒来那天。
- `EntitlementManager.simulateFree` 统一阀门；判定用 `isFullAccess`/`isPro`/`can(_:)`，不裸写 `plan==.paid`。Pro「宽松拦截」：允许看/拖/删，保存/落库时拦并弹 `PaywallView`。30天免费体验（`trialActive`）纯时间判断不带 Timer；10分钟 Pro 限时（`proTrialActive`）1Hz 心跳仅在活跃时每秒发。
- **试用到期弹窗（2026-08-15 方案 A）**：`trialEdgeTick()` 已改 internal，由 `AppDelegate.applicationDidBecomeActive`（冷启动+回前台）驱动。30 天体验：持久化 `aia.trialExpiredPromptShown` 终身只弹一次；10 分钟 Pro：标记 `aia.proTrial.promptShownMonth` 按月维度每月弹一次。两类提示独立互不误拦。

## 日期/时间解析铁律
- **中文 OCR 正则前必做全角→半角归一化**（`:`、空格、`\u{3000}`、冒号→点号），否则带时刻分支静默失配回落纯日期（时间恒 00:00）。
- **ISO8601 formatter 必须显式带时区**：`iso`（带 Z）、`isoLocal`（.current）、`isoDate`（纯日期）必须 `TimeZone(identifier:"Asia/Shanghai")`；禁裸 `ISO8601DateFormatter()`。
- **ISO8601 毫秒坑（2026-08-12 修）**：带 `.withFractionalSeconds` 只认带毫秒串，云端常不带毫秒→fallback 0:00。修法：先试带毫秒、再试无毫秒双兜底。涉及 `RecognitionTypes.date(from:)`/`RecognitionSaver.dueDate`/食物日期解析/`ResultRowCard`。
- 时区解析顺序：`RecognitionResult.date(from:)` 先走带时区 ISO，再 fallback 空格分隔本地。
- 中文日期解析：`RelativeDateParser.extractWeekday` 只匹配「周/星期/礼拜」前缀（防「一个苹果=周一」）。
- Live Activity UI 只在 Widget Extension，主 App 只启/更/停；模拟器不显灵动岛。

## App Store 隐私标签 + 协议链接（2026-08-14 定稿）
- 申报结论：选「是，我们会从此 App 中收集数据」。9 类：电子邮件地址、健康、健身（读 `HealthManager.appleExerciseTime` 运动时长）、照片或视频、音频数据、其他用户内容、用户 ID、设备 ID、其他使用数据（分析）、崩溃数据（匿名）。
- 不勾：付款/信用、位置、浏览/搜索历史、购买项目、广告数据、产品交互、性能数据（仅崩溃）、敏感信息、周围环境/身体、联系人。
- 用途铁律：追踪目的/第三方广告/开发者广告 3 问一律选「否」。换账号/改版重填直接照此表勾。
- **协议链接（`AppURLs.swift` 兜底默认值，云端可下发覆盖）**：隐私政策 `https://arvti3crmf.feishu.cn/wiki/H7yYwwC8NiWR0XkjObecyyvknOe`；用户协议 `https://arvti3crmf.feishu.cn/wiki/NeU0wzsOeigh77k0X8qcnhqZndg`（飞书 wiki，须对访客公开）。
- **云端优先级铁律**：`GlobalConfigStore`（aia_config 全局记录，需 DeveloperGate.passcode）下发链接优先于代码默认值，全局广播。后台清空两框才回退飞书默认；改动非即时生效须冷启/回前台重拉 fetchConfig。三入口（SettingsView/LoginView/PhoneAuthForm）均经 `AppURLs` 取值。
- 旧 CloudBase 静态站口径已废弃（协议早已不在静态站）；用户协议已完善 9 条（用户手动加入飞书 wiki，代码无需改）。

## 开发者调试开关（DeveloperCenterView）
- 两个按钮：「轻量复位」（仅 `aia.onboardingDone=false`）与「彻底重置」（+`aia.isLoggedIn=false`+`AuthManager.shared.logout()` 清 Keychain）。点完**必须双击上滑杀 App 冷启**才生效。
- 「清空全部业务数据」按钮尚未做；要真·清空走模拟器 `xcrun simctl erase <UDID>` 或真机删 App 重装。

## 新人引导弹出机制（2026-08-15 定稿，防回归）
- **首装与 re-view 统一走 `NavigationRouter.shared.navigate(.onboarding(writesDone:))` push 路径**，绝不用 `fullScreenCover` 在 `.onAppear` 同步弹出（模拟器/老机型会被系统吞掉）。
- `showOnboarding` 仅作「首装引导激活中」标记驱动 `runDeferredStartup` 的 onChange，不绑任何 cover。

## 代码改动可回退备注规范（2026-08-16 定稿）
### 铁律 1：小步多次 commit（整体回退根本手段）
- 每改完一处/一个功能，验收 OK 后**立即 commit**，绝不攒一大堆未提交改动堆在工作区。
- commit 格式：`类型(范围): 简述`，正文补 `原因 / 风险等级(低中高) / 关联记忆#xxx`。
- **commit 前必须先编译过**（至少 `xcodebuild` 不报 error），确保可运行快照。
- 巨无霸文件（ChatView/ContentView/RecordsViews/RecognizeService >100KB）颗粒度更细：一个函数一小提。

### 铁律 2：功能分支隔离（零成本回退沙盒）
- 改代码前开临时分支：`git checkout -b fix/主题_YYYYMMDD` → 改完 commit → 验收 OK 再 `git checkout main && git merge fix/主题_YYYYMMDD`。改崩直接 `git branch -D` 弃分支。

### 铁律 3：代码内 CHANGE- 标记（单处改动秒级定位）
- 成对插入：`// >>> CHANGE-[YYYY-MM-DD HH:MM:SS]-[主题] 开始` … `// <<< CHANGE-[同时间戳]-[主题] 结束`。开始/结束同时间戳成对出现；搜 `CHANGE-[2026-08-16 14:32` 秒级定位整段。

### 铁律 4：稳定版打里程碑 tag
- 验收通过的稳定版：`git tag -a v2026.08.16-stable -m "..."`。`git checkout v日期-stable` 一键回退。

### 回退速查
- 整体：`git revert <hash>`（安全留历史）/ `git reset --hard <hash>`（丢弃后续）。
- 单文件：`git checkout <hash> -- 路径`。
- 按标记：`grep -rn "CHANGE-\[2026-08-16" AIA/AIA/`。
- 未提交备份：`git stash push -u -m "备份_$(date +%Y%m%d_%H%M%S)"`；留后路：`git branch backup-xxx` 或 `git stash`。

## Git 大白话速查（开发小白版）
- Git=拍照存档的相册；commit=按存档键拍快照；branch=复印相册（原件安全）；stash=半成品塞抽屉；reset --hard=撕掉后面几张（危险）；revert=拍反悔照（安全留历史）；tag=贴红标签（好版本起名）。
- 流程：开分支→改→`git stash` 临时切走→回来 `git stash pop`→commit→merge 回 main→稳了打 tag。
