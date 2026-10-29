import Foundation

public enum GuideDataImportKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "data-import", title: chinese ? "数据导入" : "Data Import",
            keywords: ["导入", "备份", "ETOS", "Cherry Studio", "RikkaHub", "Kelivo", "ChatGPT", "ChatBox", "OpenMinis", "import", "Mac"],
            content: chinese ? """
            Mac 可从设置或拓展功能进入数据导入。按来源提示选择文件或解压目录；OpenMinis 支持多选。

            预览可识别提供商和 Skills，并估算提供商冲突。ETOS 数据包按其同步范围导入；快照使用独立恢复流程。

            来源和范围只是当前页草稿，离开不会自动导入。向导经原生提案确认可修改来源及当前可选范围；只能读取计数、固定范围、是否需要凭据确认和合并报告。不提供文件路径、正文、警告原文、Skill 内容或密钥；凭据只写不可读，本页不提供修改已有凭据的接口。向导不能选文件、批准凭据、确认导入、恢复数据库或执行快捷指令。介绍页和最终确认页独立只读；切换来源、范围、语言、标签、页面或锁定会使旧提案失效。语言切换清除已本地化的预览，需要重新选择文件。

            导入凭据需要确认；导入不会主动执行 Skill 脚本或安装依赖。
            """ : """
            Open Data Import from Settings or Extended Features. Follow the source-specific instructions; OpenMinis supports multiple selections.

            Preview recognizes providers and Skills, and estimates provider conflicts. ETOS packages use their declared sync scope; snapshots use a separate restore flow.

            Source and scope are page drafts, with no import on departure. After native proposal confirmation, the guide can change source and available scope only. It can read counts, fixed scope, whether credential acknowledgement is required and the merge report. It cannot read paths, bodies, raw warnings, Skill contents, or keys. Credentials are write-only and this page offers no existing-credential editing interface. The guide cannot choose files, acknowledge credentials, confirm an import, restore a database or execute Shortcuts. Introduction and final confirmation pages are independently read-only. Source, scope, language, tab, page and lock changes invalidate old proposals. Language changes clear localized previews and require file selection again.

            Importing credentials requires confirmation. Import does not proactively execute Skill scripts or install dependencies.
            """)
    }
}
