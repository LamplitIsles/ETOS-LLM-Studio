import Foundation

public enum GuideChatQuickActionsKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "chat-quick-actions",
            title: chinese ? "聊天快捷功能" : "Chat Quick Actions",
            keywords: ["快捷功能", "菜单", "入口", "Mac", "临时对话", "quick actions", "menu", "navigation"],
            content: chinese ? """
            iOS 与 Mac 使用聊天快捷功能配置，选择常用入口并按目录顺序显示。

            Mac 在设置→通用→显示设置→聊天快捷功能选择工具栏入口，至少保留一项；单选直接显示，多选显示菜单。

            页面向导只能经原生确认修改 actions 这个已选标识数组；数组必须非空、无重复且全部来自目录。确认后立即保存，不需要额外保存按钮。不能通过向导触发快捷功能、改变临时模式、打开终端或执行 MCP/快捷指令。介绍页独立只读；离页、锁定、配置或语言变化使旧提案失效，提交前核对当前原始配置，拒绝覆盖外部修改。目录、标签和向导值在后台准备，不在 SwiftUI 渲染中解码 CSV。

            """ : """
            iOS and Mac share chat quick action settings and display the selected entries in catalog order.

            On Mac, choose at least one toolbar entry in Settings → General → Display → Chat Quick Actions. One selection appears directly; multiple selections use a menu.

            The page guide can propose only the actions array after native confirmation. It must be nonempty, unique and contain catalog identifiers only. Confirmation saves immediately; there is no extra Save button. The guide cannot launch an action, change temporary mode, create a continuation, open a terminal or execute MCP or Shortcuts. Introductions are independently read-only. Leaving, locking, configuration changes and language changes invalidate old proposals. Submission checks the original configuration to reject overwriting external changes. CSV decoding, labels and guide values are prepared outside SwiftUI rendering.

            """)
    }
}
