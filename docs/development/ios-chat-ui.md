# iOS 聊天界面与键盘

CFL 聊天时间线使用 Exyte Chat 3.3.7 的 `ChatView` 展示消息列表并负责滚动，`inputViewBuilder` 返回空视图。`CFLConversationView` 将会话消息映射到 Exyte，ETOS 输入栏作为底部透明悬浮层复用消息、附件与语音入口，顶部设置是单独的悬浮控件。列表首尾为控件留出空间，消息滚动时可延伸到控件下方，列表上下边缘透明渐隐。`CFLComposerTextView` 用 `UIViewRepresentable` 包装 `UITextView`；业务发送与历史仍走 CFL。Kingfisher 8.15.0 是 iOS 直接依赖，供聊天动态图片显示使用；图片和其他媒体能力仍须分别验证，不能由键盘结果推断通过。

## 输入焦点问题

曾出现点输入框后键盘立即收起：自定义输入的 `@FocusState` 没有与 UIKit 编辑状态同步，`updateUIView` 看到焦点为 `false` 后立即调用 `resignFirstResponder()`。未确认 `@FocusState` 未同步的根因，不要把它归因于某个特定手势或库。

当前实现由 `CFLConversationView` 持有普通 `@State`，通过 `Binding<Bool>` 传给输入框；`UITextViewDelegate` 在开始和结束编辑时回写，`updateUIView` 按同一状态协调 first responder。`CFLChatTableFocusBridge` 观察表格的点击和竖向拖动以收起焦点，并在拆除时移除观察和恢复表格设置；Exyte 同时配置了拖动收起键盘。

用户对 v10 的真机反馈：输入框中央、下半区域各点击 3 次均可打开键盘；点击聊天空白或滑动收起后可以再次打开。诊断版的附件与语音入口正常。这些是针对当时交互的阶段性结果，不代表后续悬浮布局或聊天、媒体等所有真机功能均已验收。

调整输入或手势时，应在获准的设备测试中重复覆盖输入框不同位置、空白处及上下滑动后的再次打开，并检查附件、语音入口及消息控件没有被手势遮挡。构建和安装边界见 [iOS 构建与签名](ios-xcode-cloud.md)。
