# iOS Xcode Cloud 首包

## 本地构建与安装

Xcode 工程的 `Cloud` 是本地 build configuration；即使在 Mac 上使用这个配置完成构建或安装，也不会因此运行 Xcode Cloud 服务、创建云端 Archive 或完成 TestFlight 分发。下面的本地诊断与后文云端 workflow 是不同操作。

接入 Exyte Chat 后，N5 的 xtool/SwiftBuild 在编译 Chat 和 MediaPicker 的资源时需要 `actool`。当前 xtool 重建临时 package 目录，SwiftBuild 实际尝试该目录下的 `actool`；将代理加入 shell `PATH` 的诊断未被选中。`ETOSAssetCompiler` 在 `xtool dev build` 之后处理主 App 资源，无法预先满足第三方包的资源编译；不要把空资源或假成功当成解决办法。Mac Xcode 26.6 的真实 `actool` 已分别编译这两个资源目录，但这不证明跨主机代理或 N5 增量构建可用。

Mac 本地 iOS 构建复用获准的现有 checkout、DerivedData 和 SwiftPM 缓存。已验证的无签名诊断使用 workspace、`ETOS LLM Studio App` scheme、`Cloud` 配置和 Xcode 26.6，覆盖 `SWIFT_OPTIMIZATION_LEVEL=-Onone`、`SWIFT_COMPILATION_MODE=incremental` 及 `CODE_SIGNING_ALLOWED=NO`；已有独立的 Debug 无签名构建也通过。`Cloud` 配置默认优化与该诊断不同，不能把 `-Onone` 成功当作优化归档通过。指定已有 DerivedData 和 SourcePackages 路径，避免意外新建缓存或下载；必要的新依赖或缓存须先取得明确授权。

在已有 ETOS 构建缓存和开发证书的 Mac 上，可从常驻 checkout 使用固定入口构建和安装：

```sh
python3 scripts/ios-device.py build
python3 scripts/ios-device.py install
```

两步复用同一个 `Cloud-iphoneos/ETOS LLM Studio App.app`；构建成功后记录源码状态和产物身份，安装前重新核对。安装只使用现有开发证书与匹配已连接 iPhone 的描述文件，不启动 App。多个符合条件的 iPhone 连接时，`install --device <设备标识>` 明确选择。安装提交后如果结果未知，先核实结果，不自动重试。构建或签名改变产物、源码状态变化时按提示重新构建。该脚本使用既有 Mac DerivedData 路径，不会创建独立依赖缓存。

使用已选定的 Xcode，在项目根目录运行时，将以下占位符替换为本次获准的现有路径和设备标识：

```sh
xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' \
  -scheme 'ETOS LLM Studio App' -configuration Cloud \
  -destination 'id=<设备标识>' \
  -derivedDataPath '<现有 DerivedData 路径>' \
  -clonedSourcePackagesDirPath '<现有 SourcePackages 路径>' \
  SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=incremental \
  CODE_SIGNING_ALLOWED=NO build
```

实际的开发安装是独立步骤，须取得针对该版本和设备的授权：

1. 确认准备安装的 App 来自目标构建，核对 App 标识、可执行文件及 debug dylib 的身份，并确认包内扩展符合本次构建范围。保持已有安装和用户数据，不通过卸载或重置解决签名问题。
2. 使用现有有效的 Apple Development 证书及匹配的开发 provisioning profile；核对团队、App 标识、证书、profile 有效期、开发 entitlement 与已授权设备，设备须启用开发者模式。签名或安装可能需要用户在 Mac 或设备上确认。
3. 将匹配的 profile 嵌入 App，按从内到外顺序签名内嵌 frameworks 和 dylib，再使用与 profile 一致的 entitlements 签名 App；验证各内嵌代码及整个 App 的签名。开发签名和 ad-hoc 签名不能互相替代。
4. 用 `xcrun devicectl device install app --device <设备标识> <已签名的 App 路径>` 安装到明确选定的设备。若安装结果不确定，先核实结果再决定是否重试；安装成功也只证明该包可以安装，不等于全部功能验收。

本地真机的键盘交互与范围见 [iOS 聊天界面](ios-chat-ui.md)。

## Xcode Cloud 配置

`ETOS LLM Studio.xcworkspace` 中共享的 `ETOS LLM Studio Cloud` scheme 使用 `Cloud` 配置归档主 App。原有 `ETOS LLM Studio App` scheme 的 Debug／Release 和分享扩展开发路径保留。Cloud 配置指定团队 `RL5WAW5828`、Bundle ID `io.guion.etos.cfl4960` 和自动签名；独立 entitlements 只声明应用自身的 Keychain 组，范围与已制作的主 App build 3 一致。Xcode Cloud 的签名与分发 profile 仍需实际验证，不应把本地无签名构建当作签名验证。

首包没有 Share 扩展，不会出现在系统分享菜单。Cloud entitlement 不包含 App Group、iCloud、推送、HealthKit、HomeKit、WeatherKit、NFC 或额外内存权限；相应依赖这些权限的设备工具或服务不可用，不代表所有设备工具都不可用。未来恢复 Share 时需另行配置与验证扩展签名、主 App 与扩展的 App Group 和共享存储标识。

Cloud App 的 Info.plist 不指定 `ETKeychainAccessGroup` 或 `AppIdentifierPrefix`；现有代码因此使用默认 Keychain 组，其签名 entitlement 指向该 App 自身的组。这与 build 3 的 Info.plist 和 Keychain 范围一致，实际签名后的读写仍需验证。它与旧共享 Keychain 组隔离，不会自动读取或迁移旧组中的数据；不同团队或 Bundle ID 的旧安装也不会自动变成此 App 的安装。保留旧安装、数据库和密钥，不删除、不重置；旧数据若需迁移，应另行确认可行且安全的方案。曾使用其他签名组的现有安装也需要单独评估，不能假设直接升级可读到原密钥。

在 Xcode Cloud 中选择以上 workspace 和 scheme，选定 Xcode 27.1（27A9275），添加 iOS Archive 并选择 TestFlight and App Store；唯一自动启动条件设置为 Tag Changes，选择自定义标签并匹配**以 `v` 开头**。移除默认分支、PR 和定时触发条件，并确认其他 workflow 不会自动构建。标签创建或更新都可能触发构建；App Store Connect 的版本和构建号必须避免已有记录冲突。

已知 Xcode 26.6／Swift 6.3.3 在 Release 优化 `ChatSendContentSource.Coordinator` 的析构时崩溃；Linux Swift 6.4.1、SDK 27.1 的 Release 成功不能证明 Apple Xcode 或 Xcode Cloud 成功。Cloud 仍使用 Release 优化，需在可用的 Apple 工具链中验证。签名、归档包内无扩展、App Store Connect 上传与 TestFlight 分发也须在获授权后验证。`ci_scripts/ci_pre_xcodebuild.sh` 对 `ETOS LLM Studio Cloud` scheme 跳过扩展本地化检查，仍注入提交哈希；其他 scheme 继续执行原有检查。

同一 App（ETOS Chat，Bundle ID `io.guion.etos.cfl4960`）的开发壳归档入口改为 Expo 工程：workspace `ETOSExpo.xcworkspace`、scheme `ETOSExpo Dev Archive`。此时 `ci_pre_xcodebuild.sh` 走 Expo 分支，写入 `CFBundleVersion` 与 `ETCommitHash` 并跳过上面的扩展本地化检查；`ci_post_clone.sh` 只在该 scheme 下准备 Node/npm 与 Pods。具体配置步骤、用户安装与 Metro 连接见 [Expo TestFlight 开发壳](expo-testflight-dev-shell.md)。
