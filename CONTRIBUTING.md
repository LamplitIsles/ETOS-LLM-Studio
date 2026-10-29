# 贡献指南

欢迎给 ETOS LLM Studio 提 Issue、PR、文档修订、翻译和测试反馈。本分支
处于客户端裁剪与构建迁移阶段，面向 iOS 和 macOS；当前边界请先看
[README 顶部说明](README.md)和 [CONTEXT.md](CONTEXT.md)。

## 先读：许可证与 CLA

本仓库以 [GPL-3.0](LICENSE.txt) 发布。所有代码、文档、翻译、设计、资源和
测试贡献都需要签署 [CLA](CLA.md)，这样维护者才能把贡献同时纳入公开源码版
和官方构建。

首次 PR 请由 PR 作者完成以下任一项：

- 勾选 PR 模板里的 CLA 声明。
- 在 PR 评论区单独发送：

> I have read the CLA Document and I hereby sign the CLA.

维护者会在 review 时人工确认 CLA 是否已由 PR 作者本人签署。这个要求不区分
改动大小；错别字、文档、测试和资源文件也一样。

## 开始之前

- 复杂功能、架构调整、UI 大改、许可证相关变更，请先开 Issue 说明动机和
  方案，避免写完后方向不合。
- 小型 bug 修复、文档修正、翻译补全可以直接提 PR。
- 不要提交 API Key、证书、Provisioning Profile、个人日志、真实用户数据或
  其它敏感信息。
- 默认情况下，涉及功能或 UI 的改动要考虑 iOS 和 macOS；如果只改一端，
  请在 PR 里说明原因。

## 本地开发

在 N5 的现有 checkout 中，使用已安装的 Swift、xtool 和 Darwin SDK 进行
iPhone 开发构建。显式提供适用于该构建的 App ID 前缀（不带末尾的点）：

```bash
swiftpm/build-iphone.sh <AppIdentifierPrefix>
```

脚本构建 iPhone 主 App 和 Share、Widget、Workspace Provider 三个扩展，
编译资源，进行本地 ad-hoc 签名并检查权限和资源完整性。本分支已有 N5
本地打包检查证据；这不证明 Apple 签名或 provisioning、设备安装或运行、
实际功能，以及 macOS 构建已通过。macOS 的 Xcode 工程保留，尚未验证构建。

README 顶部是本分支构建状态的说明；其余历史功能和构建步骤不代表当前能力。

## 代码要求

- 保持改动聚焦。不要在修 bug 时顺手重构无关模块，也不要引入当前问题不需要
  的配置项、兼容层或抽象。
- SwiftUI 的 `body` 必须保持轻量。不要在 UI 渲染链路同步做磁盘 I/O、网络请求、
  JSON 解码、正则扫描、Markdown / Math 解析或其它 O(N) 级耗时计算。
- 耗时处理放到 ViewModel、Manager 或底层服务中预计算，再把可直接渲染的状态
  派发回主线程。
- 闭包、网络回调、计时器和后台任务要注意循环引用；需要持有对象时明确说明
  生命周期。
- 设置类数据不要使用 UserDefaults。项目运行时设置统一走数据库与现有配置存储。
- 所有用户可见文本都要走本地化。新增 iOS / macOS UI 文案、错误提示、状态
  标签、按钮、导航标题、页脚说明等，都需要按现有本地化方式补齐支持的语言。
- UI 请保持 Apple 平台原生质感。设置页优先用 `Form` / `List` + `Section`；
  避免深层导航和把多个交互控件塞进同一行。
- 新增或修改功能应补充对应测试；如果暂时无法补测，请在 PR 里写清楚原因和
  后续补测计划。

## PR 提交流程

1. 从最新的目标分支创建主题分支。
2. 保持提交粒度清晰，commit message 使用 Conventional Commits 风格。
3. PR 标题简洁说明目的；正文写清楚改了什么、为什么改、怎么验证。
4. UI 改动请附截图或录屏；iOS 和 macOS 都受影响时，两端都要说明。
5. 由 PR 作者勾选 CLA 声明，或在评论区发送 CLA 签署声明。

维护者可能会要求你拆分 PR、补测试、补本地化或调整实现边界。这不是形式主义，
而是为了让项目长期还能被人读懂和维护。

## English Summary

All contributions require signing [CLA.md](CLA.md). On your first pull
request, the PR author must either check the CLA statement in the pull
request template or comment:

> I have read the CLA Document and I hereby sign the CLA.

Keep changes focused, consider both iOS and macOS when applicable, localize
all user-facing strings, avoid blocking SwiftUI render paths, and include
tests or explain why tests cannot be added yet.
