# iOS Xcode Cloud 首包

`ETOS LLM Studio.xcworkspace` 中共享的 `ETOS LLM Studio Cloud` scheme 使用 `Cloud` 配置归档主 App。原有 `ETOS LLM Studio App` scheme 的 Debug／Release 和分享扩展开发路径保留。Cloud 配置指定团队 `RL5WAW5828`、Bundle ID `io.guion.etos.cfl4960` 和自动签名；独立 entitlements 只声明应用自身的 Keychain 组，范围与已制作的主 App build 3 一致。Xcode Cloud 的签名与分发 profile 仍需实际验证，不应把本地无签名构建当作签名验证。

首包没有 Share 扩展，不会出现在系统分享菜单。Cloud entitlement 不包含 App Group、iCloud、推送、HealthKit、HomeKit、WeatherKit、NFC 或额外内存权限；相应依赖这些权限的设备工具或服务不可用，不代表所有设备工具都不可用。未来恢复 Share 时需另行配置与验证扩展签名、主 App 与扩展的 App Group 和共享存储标识。

Cloud App 的 Info.plist 不指定 `ETKeychainAccessGroup` 或 `AppIdentifierPrefix`；现有代码因此使用默认 Keychain 组，其签名 entitlement 指向该 App 自身的组。这与 build 3 的 Info.plist 和 Keychain 范围一致，实际签名后的读写仍需验证。它与旧共享 Keychain 组隔离，不会自动读取或迁移旧组中的数据；不同团队或 Bundle ID 的旧安装也不会自动变成此 App 的安装。保留旧安装、数据库和密钥，不删除、不重置；旧数据若需迁移，应另行确认可行且安全的方案。曾使用其他签名组的现有安装也需要单独评估，不能假设直接升级可读到原密钥。

在 Xcode Cloud 中选择以上 workspace 和 scheme，选定 Xcode 27.1（27A9275），添加 iOS Archive 并选择 TestFlight and App Store；唯一自动启动条件设置为 Tag Changes，选择自定义标签并匹配**以 `v` 开头**。移除默认分支、PR 和定时触发条件，并确认其他 workflow 不会自动构建。标签创建或更新都可能触发构建；App Store Connect 的版本和构建号必须避免已有记录冲突。

已知 Xcode 26.6／Swift 6.3.3 在 Release 优化 `ChatSendContentSource.Coordinator` 的析构时崩溃；Linux Swift 6.4.1、SDK 27.1 的 Release 成功不能证明 Apple Xcode 或 Xcode Cloud 成功。Cloud 仍使用 Release 优化，需在可用的 Apple 工具链中验证。签名、归档包内无扩展、App Store Connect 上传与 TestFlight 分发也须在获授权后验证。`ci_scripts/ci_pre_xcodebuild.sh` 对 `ETOS LLM Studio Cloud` scheme 跳过扩展本地化检查，仍注入提交哈希；其他 scheme 继续执行原有检查。
