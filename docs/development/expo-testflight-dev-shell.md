# Expo TestFlight 开发壳

本流程把现有 ETOS Chat 的 Xcode Cloud 归档入口换成 Expo 开发壳，并从同一 TestFlight 记录安装。它不新建 App、App Store Connect 记录或 TestFlight 产品，也不把开发壳当作 App Store 正式版本。

## 身份与版本

- App：现有 **ETOS Chat**，Bundle ID `io.guion.etos.cfl4960`，团队 `RL5WAW5828`；`expo-client/app.json` 的 `ios.appleTeamId` 是该团队的生成源，生成工程的两个 target 配置只写入 `DEVELOPMENT_TEAM`。生成工程没有 `CODE_SIGN_STYLE` 或 `ProvisioningStyle`，本机 `xcodebuild -showBuildSettings` 也只给出 `CODE_SIGN_IDENTITY = iPhone Developer`，因此**不能**把签名方式当作 Automatic 的既定事实（旧 Swift target 才显式写了 `CODE_SIGN_STYLE = Automatic`）。Apple 的 Xcode Cloud 设置说明要求在 Signing & Capabilities 里“允许 Xcode 管理签名 / 勾选 Automatically manage signing”，这一步属于 Cloud 入口必须实测的待验项。
- 版本：`2.0.0`（`expo-client/app.json` 的 `version`、`expo-client/ios/ETOSExpo/Info.plist` 的 `CFBundleShortVersionString` 一致）。发布编号（`CFBundleVersion`）在构建时由 Cloud 注入，见下文。
- 这是同一 App 的新 build：设备上同一 Bundle ID 的旧原生 ETOS Chat 会被替换。安装前由用户自行卸载旧原生版本；仓库没有卸载脚本、不清理沙盒或 Keychain、不迁移旧原生本地数据。登录状态与聊天历史以后端为准，不承诺旧原生本地数据自动恢复。
- 不接受把本流程改成第二个 App、第二个 ASC 记录或双 Bundle ID 兼容路径。

## 仓库接线

- `expo-client/ios` 现在被跟踪：`ETOSExpo.xcodeproj`（含共享 scheme）、`ETOSExpo/` 应用源码与资源、`Podfile`、`Podfile.lock`、`Podfile.properties.json`、`.xcode.env`、`ios/.gitignore`。`Pods/`、`build/`、`xcuserdata/`、`.xcode.env.local` 继续被忽略。
- 根级 `ETOSExpo.xcworkspace` 是 Cloud 使用的真实 workspace，只引用 `expo-client/ios/ETOSExpo.xcodeproj` 和 `expo-client/ios/Pods/Pods.xcodeproj`（后者由 `pod install` 生成，不纳入版本控制）。新 clone 先在 `expo-client` 执行 `npm run ios:prepare`，生成 Pods 和本地 `ios/ETOSExpo.xcworkspace`。
- 命名来源：`expo-client/app.json` 的 `name`（`ETOS Chat`）决定显示名，同时被 prebuild 派生成 Xcode 产物名 `ETOSChat`，因此构建产物是 `ETOSChat.app`（`FULL_PRODUCT_NAME`）；而工程目录与 target 名仍是 `ETOSExpo`（`--no-clean` 的 prepare 不重命名工程）。本地 `ios:build`/`ios:install` 与归档都按 `ETOSChat.app` 交付，workspace/scheme 仍按 `ETOSExpo.xcodeproj` 引用。`expo-client/ios/Podfile.properties.json` 的 `expo.inlineModules.xcodeProjectTargets.mainTarget` 跟随该产物名（`ETOSChat`），当前没有 inline module targets，本地 `ETOSInputArea` 仍通过自己的 podspec 自动链接。
- 共享 scheme **`ETOSExpo Dev Archive`** 位于 `expo-client/ios/ETOSExpo.xcodeproj/xcshareddata/xcschemes/`，Archive 使用现有 `Debug` 配置。不新增编译配置，也不把 dev-launcher/dev-menu 强塞进 Release：它们只在 Debug 条件下注册，Release 归档里仍会被 Strip 阶段去掉开发用的 Bonjour 与本地网络描述。
- 本地显式 `npm run ios:prepare` 仍以 `--no-clean` 刷新生成物；生成工程的变化需人工核查后提交。云端不执行 prebuild。

### CI 脚本（唯一根 `ci_scripts`）

两个脚本都按 scheme 名显式分派。`ci_post_clone.sh` 只服务 Expo 开发壳，非 Expo scheme 直接零动作；`ci_pre_xcodebuild.sh` 的 Expo 分支提前退出，其他 scheme 继续走原有 Swift 路径（扩展本地化检查与 `ETCommitHash` 写入）。

- `ci_scripts/ci_post_clone.sh`：仅当 `CI_XCODE_SCHEME` 为 `ETOSExpo Dev Archive` 时执行。按 `uname -m` 选择官方 Node 24.18.1 tarball（`arm64` → `darwin-arm64`，`x86_64` → `darwin-x64`，各自独立 SHA256；其他架构直接失败），校验摘要并解压，先把下载的 Node 加入 `PATH` 再自装 npm 12.0.2（官方 npm 的 shebang 是 `env node`，冷启动镜像可能没有 system Node）。随后导出 `NODE_USE_ENV_PROXY=1`，让 npm 与安装脚本（含 enriched-markdown 的原生资产下载）遵循镜像提供的 `HTTP(S)_PROXY`，不放宽 TLS 校验；写入 `expo-client/ios/.xcode.env.local` 的 `NODE_BINARY`（Xcode 构建阶段不继承脚本 PATH），在 `expo-client` 执行 `npm ci`（保留受许可的安装脚本），再按 `Podfile.lock` 记录的 CocoaPods 版本准备 Pods：镜像预装版本一致时直接复用，不一致时才用用户 gem 安装该精确版本，最后 `pod install --deployment`（锁与 Podfile 不一致时失败，不改写锁）。脚本打印实际 Node/npm/CocoaPods 版本；任何一步失败都会终止构建。
- `ci_scripts/ci_pre_xcodebuild.sh`：Expo scheme 分支要求正整数 `CI_BUILD_NUMBER`（拒绝空值、`0` 与前导 0）与非空 `CI_COMMIT`，把 `CFBundleVersion` 写成该构建号、`ETCommitHash` 写成完整小写 40 位提交，并跳过旧 Swift 的扩展本地化检查。旧 Swift scheme 仍执行原有本地化检查，并在缺少 `CI_COMMIT` 时回落到 `LocalBuild`。

### 本地归档入口

`npm run ios:archive`（在 `expo-client`）使用交付给 Cloud 的根级 `../ETOSExpo.xcworkspace` 与共享 scheme `ETOSExpo Dev Archive` 归档 Debug 配置，复用既有 DerivedData，输出固定到 `expo-client/build/ETOSExpo-dev.xcarchive`，不签名、不上传、不安装，也不为每个版本保留副本。本地 `ios:prepare` 仍用普通 `pod install`，`--deployment` 只用于云端。它只验证仓库接线，不能替代 Cloud 分发或真机结果。

## Xcode Cloud 配置步骤

在现有 ETOS Chat 产品下操作：

1. 确认 GitHub 镜像已包含本分支；Cloud 读取的是镜像仓库，不是内部 Forgejo。
2. 打开该产品（不要新建 App 或第二个产品），编辑现有 workflow：workspace 选根级 `ETOSExpo.xcworkspace`，scheme 选 `ETOSExpo Dev Archive`。
3. 若界面不允许就地更换 workspace/scheme，按 Xcode 提示在同一产品内重新选择产品与 workspace（必要时从 Cloud 的产品页重新走一次 Select a Product）。不能用创建新 App 绕过。
4. 在该产品上确认签名：团队 `RL5WAW5828`，并允许 Xcode 管理签名（Signing & Capabilities 的 Automatically manage signing）。仓库里的 Expo 工程只有 `DEVELOPMENT_TEAM`，没有签名方式字段，所以这一状态只能在 Cloud 入口核对；如果界面提示需要选择团队或启用自动签名，按提示在产品内完成，不要新建 App 绕过。
5. Archive action 选 iOS，分发选 **TestFlight and App Store**：Debug 编译配置来自共享 scheme，分发签名必须由 App Store 流程完成（导出包 `get-task-allow=false`）。不要复用本地 development profile 或 `devicectl` 安装链。
6. 触发条件沿用既有自定义 tag 且匹配给 **`v` 开头**；原生 Swift 的自动归档入口由本 workflow 替换，不要同时保留两套自动归档。
7. 构建编号：现有 `1.9.0` 记录用过 1–3，但那不是当前最新号。正式配置时先在 App Store Connect 读取该 App 当前可用编号，再在 Cloud 设置其后的编号；仓库不硬编码具体号，也不假设 `CI_BUILD_NUMBER` 从 1 开始安全。
8. 首次构建核对日志与产物：两个脚本被正确分派、`npm ci` 与 `pod install` 顺序与版本、scheme 被发现；归档 App 的 Bundle ID `io.guion.etos.cfl4960`、版本 `2.0.0`、Cloud 构建号与 `ETCommitHash`；导出包的签名与 `get-task-allow=false`。

## 用户安装与连接 Metro

1. 卸载设备上旧原生 ETOS Chat（这会删除该 App 的本地数据）。
2. 从现有 TestFlight 记录安装新 build。旧邀请链接指向同一 App，但仍需安装本次新 build；外部测试成员还要通过 Beta App Review。
3. 打开 App 后进入 Expo 自带的开发启动器。在 Mac 的 `expo-client` 运行 `npm run dev`（LAN，端口 8081），在启动器里选择局域网地址；网络环境不允许局域网发现时，在启动器手动输入 `<Mac IPv4>:8081`。
4. 开发服务器不可达或地址变化时，回到启动器重新选择，不依赖维护者的个人服务器。
5. JS/TS 改动可通过 Metro Fast Refresh 生效；新增或变更原生模块、原生依赖、权限或原生配置时必须重新构建并安装开发壳，旧壳不承诺兼容任意最新代码。

## 未验证与执行边界

- 本仓库只提供接线、入口和上述步骤；Cloud workflow 修改、触发构建、上传处理、测试组、外部审核与真机安装都需单独授权并实际执行。
- Mac 已核对（现有 checkout，候选源码）：`npm run typecheck` 通过，合成测试通过（Node 23/23、Python 7/7），`npm run ios:prepare` 成功（133 pods，随后 `pod install --deployment` 亦通过），根 workspace 能列出 `ETOSExpo`/`ETOSExpo Dev Archive` 两个 scheme 与 `ETOSInputArea`，`showBuildSettings` 得到 `PRODUCT_NAME=ETOSChat`、`FULL_PRODUCT_NAME=ETOSChat.app`、`PRODUCT_BUNDLE_IDENTIFIER=io.guion.etos.cfl4960`，`describeAllArchivableProducts` 的产品 bundle/team 正确。
- 本地归档已按本入口实际执行一次（用户批准，Xcode 26.6）：`npm run ios:archive` 归档成功，产出固定的 `expo-client/build/ETOSExpo-dev.xcarchive`（约 363 MiB）。包内 `ETOSChat.app` 未签名、arm64，`CFBundleIdentifier=io.guion.etos.cfl4960`、`CFBundleDisplayName=ETOS Chat`、`CFBundleShortVersionString=2.0.0`、`CFBundleVersion=1`（本地默认值，不是 ASC 可用号，本地未运行 Cloud stamp 所以没有 `ETCommitHash`）；Info.plist 保留本地网络使用说明与 `NSBonjourServices=_expo._tcp`，主可执行含 `EXDevLauncher`，没有 `main.jsbundle`（Debug 不内嵌 JS）。这只证明 Debug 开发壳能在本地归档，不证明能启动、不证明 Cloud stamp/签名/上传或 TestFlight。
- 未验证：Cloud 首次构建、Cloud 入口的自动签名状态与 App Store 分发签名结果（仓库工程没有 `CODE_SIGN_STYLE`/`ProvisioningStyle`，`CODE_SIGN_IDENTITY` 仍是 `iPhone Developer`）、Apple 对 Debug 开发客户端的上传校验、Beta App Review、TestFlight 安装与启动、设备上的局域网发现、可达 Metro 与 Fast Refresh；本地归档的产物未安装也未启动。
- TestFlight 每个 build 最多可用 90 天，过期后需重新构建分发；这不代表 App Store 正式上架。
- 历史记录中的临时开发身份（独立 Expo Bundle ID）已被撤销，仅作历史；现流程只使用 ETOS Chat 身份。
