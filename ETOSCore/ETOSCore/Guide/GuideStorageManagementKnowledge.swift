import Foundation

public enum GuideStorageManagementKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "storage-management", title: chinese ? "存储占用与文件浏览" : "Storage Usage and File Browser",
            keywords: ["存储", "文件", "缓存", "孤立数据", "SQLite", "storage", "files", "cache", "Mac"],
            content: chinese ? """
            存储管理提供应用目录的大小统计和文件浏览。Mac 使用 Application Support，移动端使用 Documents。

            Mac 目录支持逐级进入、单项和多选删除。删除前核对文件信息；删除不可撤销，也不会自动修复文件引用。

            文件正文在本机预览：文本按 100 行分页，图片在后台读取，SQLite 支持表/视图列表、字段结构以及每页 50 行只读结果。长单元格先显示摘要，可打开完整分页。只读查询只接受单条 SELECT/WITH/PRAGMA，必须用户点击执行；编辑 SQL 会清除旧结果，翻页沿用已执行的 SQL，离页或恢复后不会自动重放草稿。实时数据库可能在翻页之间改变，结果不是跨页一致快照。

            清理缓存可能删除语音、图片、附件和角色素材，不只是可重建文件；操作前应确认影响。

            根页、目录、文件预览、数据库目录、表页、SQL 草稿、长单元格、清理确认和独立介绍各自声明向导。仅 SQL 草稿可经提案确认修改，仍需原生执行；其他页只读。快照只含扫描状态、分类字节和数量，不含路径、文件名、正文、数据库记录或错误原文；SQL 草稿会按普通页面字段提供。向导不能执行查询、读取文件正文、选择删除目标或确认清理。页面代次、语言、选择、锁定和恢复必须使旧提案失效。Mac 源码仍需工程接入及实际文件、键盘、恢复与退出验证。
            """ : """
            Storage Management shows app directory sizes and provides a file browser. Mac uses Application Support; mobile uses Documents.

            The Mac browser supports nested directories and selection for deletion. Deletion is irreversible and does not repair application references automatically.

            Previews stay local: text uses 100-line pages, images load in the background, and SQLite exposes tables/views, column declarations and 50-row read-only pages. Long cells show a bounded preview with full paged content available separately. Queries accept one SELECT/WITH/PRAGMA statement and require a native Run action. Editing SQL clears old results; paging uses the last executed SQL. Leaving or restoring never automatically reruns a query draft. Live databases can change between pages; this is not a multi-page snapshot.

            Clear Cache can delete audio, images, attachments and character assets, not only regenerable files; review its effects before confirming.

            Root, directory, file preview, database catalog, table, SQL draft, long cell, confirmation and introduction pages each declare guide context. Only the SQL draft is writable through a confirmed proposal; native execution is still required. Other pages are read-only. Snapshots expose status, category bytes and counts, never paths, filenames, file contents, database records or raw errors; the SQL draft is a normal page field. The guide cannot execute queries, read file contents, select deletion targets or confirm cleanup. Page revisions, language, selection, lock and restore invalidate stale proposals. Mac target integration and actual file, keyboard, restoration and termination behavior remain to be verified.
            """)
    }
}
