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

- `ci_scripts/ci_post_clone.sh`：仅当 `CI_XCODE_SCHEME` 为 `ETOSExpo Dev Archive` 时执行。按 `uname -m` 选择官方 Node 24.18.1 tarball（`arm64` → `darwin-arm64`，`x86_64` → `darwin-x64`，各自独立 SHA256；其他架构直接失败），校验摘要并解压，先把下载的 Node 加入 `PATH` 再自装 npm 12.0.2（官方 npm 的 shebang 是 `env node`，冷启动镜像可能没有 system Node）。随后导出 `NODE_USE_ENV_PROXY=1`，让 npm 与安装脚本（含 enriched-markdown 的原生资产下载）遵循镜像提供的 `HTTP(S)_PROXY`，不放宽 TLS 校验；写入 `expo-client/ios/.xcode.env.local` 的 `NODE_BINARY`（Xcode 构建阶段不继承脚本 PATH），在 `expo-client` 执行 `npm ci`（保留受许可的安装脚本）。随后调用与本地共用的 `ci_scripts/expo_pod.sh`，通过 Homebrew 查找 `ruby@3.3`、缺失时安装，检查 Ruby 3.3 后在 CI 工具目录准备 Bundler 2.4.22 和 `expo-client/Gemfile.lock` 的依赖；已满足时 `bundle check` 跳过安装。`expo_pod.rb` 在同一 Ruby 进程使用该锁，先激活 JSON 2.7.1，再载入 `Podfile.lock` 指定版本的 CocoaPods，并记录各版本。最后保留 `pod install --deployment`；Ruby、Homebrew 或依赖不可用时构建失败，不回退到另一套 Ruby。

- `package.json` 使用 Expo autolinking 的 `ios.buildFromSource` 将 `expo-modules-core` 切换为源码构建。原先预编译 podspec 的 `source.http` 和 `prepare_command` 包含本机绝对路径；隔离测试中生成的源码 podspec 不再包含测试根路径。预编译管线中受依赖级联影响的 Expo 模块回退源码，ExpoModulesJSI 仍以 xcframework 引用；新增 `libwebp`、`SDWebImage` 和 `SDWebImageWebPCoder`，最终安装 133 个 Podfile 依赖、136 个 Pods；React Native Core、Dependencies 和 Hermes 仍使用预编译制品。源码构建的实际编译耗时尚未测量。Cloud 日志的 121 项 checksum 差异中，120 项可由 JSON 空集合格式复现，最后一项还包含上述路径差异。

- `npm run ios:prepare` 通过同一入口使用 `PATH` 选定的 Ruby 3.3，并解析版本管理器的 shim 以使用实际 Ruby，按需在 `expo-client/.expo/etos-ruby-tools` 准备锁定的 gem 和缓存；已满足时跳过安装。Mac 实测 Ruby 3.3.0 所带的 mise RubyGems 插件源码通过 `PATH` 调用 `mise reshim`；安装子进程拦截此调用，避免改写用户 shims。其他 Ruby 安装的插件行为未知，此拦截只适用于通过 `PATH` 的调用。它会运行 prebuild 并改写生成物，脚本不主动修改全局 Ruby 或 mise 配置。首次准备或依赖缺失时需要联网和磁盘空间，使用方法见 [Expo README](../../expo-client/README.md)。

- 此前在 Mac Xcode 26.6、Ruby 3.3.0 和 JSON 2.7.1 下，在两个不同绝对路径的隔离环境对相同 Pod 锁执行 `pod install --deployment` 均通过；第二个路径的 132 份本地 podspec 的 SHA-1 均与锁匹配，且不含该测试根路径。两次 CocoaPods 生成的工程和隐私清单也逐字一致，已纳入仓库。这些验证早于当前 gem 依赖锁。

- 当前 gem 锁由 Ruby 3.3.0 和 Bundler 2.4.22 真实求解，不兼容 Ruby 2.6。Mac 隔离测试将实际 bootstrap、runner、Gemfile 和锁逐字复制并核对前后 SHA：首次冷启动因 `gem install` 的 `--config-file` 参数位置错误失败，修复后重试成功安装 Bundler，但网络连接约三分钟没有可见进展，测试主动终止，未触发自动超时。随后在同一目录通过临时 IPv4 HTTPS 代理续跑，复用只读复制的 30 个锁内 gem 缓存并下载缺失依赖；实际 helper 的 `--version` 成功，同一进程输出 Ruby 3.3.0、Bundler 2.4.22、JSON 2.7.1 和 CocoaPods 1.17.0。再次运行时将代理指向不可用端口，热缓存启动成功、输出中无下载，代理无新增连接；这不是完全断网测试。JSON 2.7.1 来自该 Ruby 的默认 gem。测试目录峰值约 48 MiB，结果保留后已清理专用目录。

- 当前锁和 bootstrap 组合尚未执行真实 `pod install --deployment`、Cloud 或 Xcode 构建。Mac 实测 Ruby 3.3.0 的默认 JSON 恰为 2.7.1；Cloud 的 Homebrew Ruby 默认 JSON 版本尚不确定。若默认版本不同，Bundler 使用锁定 JSON 2.7.1 的路径仍待 Cloud 实测。Cloud 的 Homebrew 安装权限、镜像架构、bottle 可用性、耗时和缓存保留均未知；`ruby@3.3` 的 patch 版本可能变化，冷构建可能需要重新下载 Ruby 和 gems。合成脚本测试只验证命令分派和失败传播；严格锁也不证明所有下载制品的完整性、签名或生产发布已验证。
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
- 历史验证（在本次 Expo 源码构建及锁更新之前）：Mac 现有 checkout 的 `npm run typecheck`、当时的合成测试和 `npm run ios:prepare` 通过；根 workspace 能列出两个 scheme 和 `ETOSInputArea`，`showBuildSettings` 及 `describeAllArchivableProducts` 的产品标识与团队正确。这些结果不证明当前锁和依赖配置的构建通过。
- 历史本地归档（在本次锁更新之前，用户批准，Xcode 26.6）：`npm run ios:archive` 曾成功生成未签名的 Debug 开发壳，包含 `EXDevLauncher`，不内嵌 JS。该产物未安装或启动；不能用它证明当前源码构建、Cloud stamp/签名/上传或 TestFlight。
- 未验证：本次修复后的 Cloud 构建、Cloud 入口的自动签名状态与 App Store 分发签名结果（仓库工程没有 `CODE_SIGN_STYLE`/`ProvisioningStyle`，`CODE_SIGN_IDENTITY` 仍是 `iPhone Developer`）、Apple 对 Debug 开发客户端的上传校验、Beta App Review、TestFlight 安装与启动、设备上的局域网发现、可达 Metro 与 Fast Refresh；本地归档的产物未安装也未启动。修复前的 Cloud Build 8 曾因 Podspec checksum 不一致而失败。
- TestFlight 每个 build 最多可用 90 天，过期后需重新构建分发；这不代表 App Store 正式上架。
- 历史记录中的临时开发身份（独立 Expo Bundle ID）已被撤销，仅作历史；现流程只使用 ETOS Chat 身份。
