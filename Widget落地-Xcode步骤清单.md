# AIAKit Framework + 桌面 Widget — Xcode GUI 落地步骤（可勾选）

> 开发者网站已配置完成：App Group `group.com.daxing.aia` 已注册，主 App 与 Widget(App ID `com.daxing.aia.AIA.AIAWidget`) 均已关联。
> 本文件所有操作都在 Xcode 里完成（pbxproj / target / entitlements 不可手改）。

## 一、新建 AIAKit Framework target
- [ ] Xcode 顶部菜单 File → New → Target
- [ ] 选 **Framework**（iOS 过滤下）→ Next
- [ ] Product Name: `AIAKit`；Framework Type: `Dynamic`（或 Static，推荐 Dynamic 避免符号重复）
- [ ] 部署目标 Minimum Deployments: iOS **17.0**（与 App 一致）
- [ ] Finish
- [ ] 在 Project → AIAKit target → **General → Identity**：
  - Bundle Identifier: `com.daxing.aia.AIA.AIAKit`
  - 勾选 **App Groups** capability，选 `group.com.daxing.aia`
- [ ] General → **Frameworks, Libraries, and Embedded Content** 不用动
- [ ] **Build Settings → Info.plist File**：指向 `AIAKit/Info.plist`（已创建）
- [ ] 把以下 7 个文件加入 AIAKit target（勾选文件 → 右侧 File Inspector → Target Membership 勾 AIAKit）：
  - `AIAKit/RecognitionTypes.swift`
  - `AIAKit/AIATheme.swift`
  - `AIAKit/RecurringRule.swift`
  - `AIAKit/AppFormat.swift`
  - `AIAKit/AppPersistence.swift`
  - `AIAKit/Models.swift`
  - `AIAKit/AIAMigrationPlan.swift`

## 二、主 App 关联 AIAKit
- [ ] 选中主 App target (AIA) → General → **Frameworks, Libraries, and Embedded Content**
- [ ] 点 + → 选 `AIAKit.framework` → Add
- [ ] Embed 设为 **Do Not Embed**（framework 由主 App 和 Widget 各自链接，不需要嵌入）
- [ ] 主 App 已 `import AIAKit`（多处）+ `AIAApp.swift` 顶部 `@_exported import AIAKit` ✓（无需改代码）
- [ ] 删除的文件（`AIA/Models.swift` `AppPersistence.swift` `AppFormat.swift` `AIAMigrationPlan.swift`）在 Xcode 里会显示红色 missing → 选中按 Delete 移除引用（文件已删，只清引用）
  - ⚠️ 确认 AIAKit target 里已包含对应的同名 4 文件（见上），不要误删 AIAKit 里的

## 三、新建 Widget Extension target
- [ ] File → New → Target → 选 **Widget Extension**（iOS）
- [ ] Product Name: `AIAWidget`
- [ ] 取消勾选 **Include Configuration Intent**（我们不需要可配置 widget）
- [ ] Finish → 弹窗选 **Activate**（激活 scheme）
- [ ] 删除 Xcode 自动生成的占位文件：`AIAWidget/AIAWidget.swift`（含默认 `Hello World` 那个 struct），只保留我们自己写的 5 个文件
- [ ] 把以下 5 个文件加入 AIAWidget target（File Inspector → Target Membership 勾 AIAWidget）：
  - `AIAWidget/AIAWidgetBundle.swift`（含 `@main`）
  - `AIAWidget/WidgetData.swift`
  - `AIAWidget/SummaryWidget.swift`
  - `AIAWidget/UpcomingWidget.swift`
  - `AIAWidget/OverviewWidget.swift`
- [ ] 设置 Widget target：
  - General → Identity → Bundle Identifier: `com.daxing.aia.AIA.AIAWidget`（与开发者网站一致）
  - Minimum Deployments: iOS **17.0**
  - **Signing & Capabilities → + Capability → App Groups** → 勾 `group.com.daxing.aia`
  - General → **Frameworks, Libraries, and Embedded Content** → 点 + → 选 `AIAKit.framework` → Add（Embed 选 Do Not Embed）
  - General → **Signing** → 关联 `AIAWidget.entitlements`（已创建，含 AppGroup）
    - 若找不到关联入口：Build Settings → `CODE_SIGN_ENTITLEMENTS` 填 `AIAWidget/AIAWidget.entitlements`

## 四、主 App URL Scheme (aia://)
- [ ] 选中主 App target (AIA) → Info → **URL Types** → +
- [ ] Identifier: `aia`；URL Schemes: `aia`；Role: `Viewer`
- [ ] `AppDelegate.scene(_:openURLContexts:)` 已含 `aia://` 分支 ✓

## 五、编译验证
- [ ] 选 AIA scheme，⌘B 编译主 App（应先编译 AIAKit 再主 App）
- [ ] 选 AIAWidget scheme，⌘B 编译 Widget
- [ ] 真机/模拟器跑主 App，回到桌面添加小组件验证数据（需 AppGroup 数据已写入）

## 已知风险
- 若报 `invalid redeclaration of 'hex'`：说明 Color 的 hex 扩展在别处也定义了。把重复定义合并到 AIAKit 一处，主 App 侧删除。
- 若 Widget 报 `cannot find 'AIATheme' in scope`：确认 AIAKit 的 AIATheme 字段都是 `public`，且 Widget target 已链接 AIAKit.framework。
- 清 App 重装一次（AppGroup 容器切换需重置）。
