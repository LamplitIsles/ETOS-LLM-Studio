import Foundation

@main
enum CFLReplyDisplayChecks {
    static func main() {
        func check(_ input: String, streaming: Bool, _ expected: [String]) {
            let source = CFLReplyPresentation.visibleSource(input, streaming: streaming)
            let actual = CFLReplyPresentation.chunks(source).map(\.text)
            guard actual == expected else {
                fputs("Unexpected reply projection: \(String(reflecting: input))\nexpected \(expected)\nactual \(actual)\n", stderr)
                exit(1)
            }
        }
        check("第一句。同行第二句。\r\n第二行🙂\n未完成", streaming: true, ["第一句。同行第二句。\r\n", "第二行🙂\n"])
        check("第一句。同行第二句。\r\n第二行🙂\n未完成", streaming: false, ["第一句。同行第二句。\r\n", "第二行🙂\n", "未完成"])
        check("没有换行", streaming: true, [])
        check("\n\n", streaming: false, [])
        check("\n\nfirst\n\n\nlast", streaming: false, ["\n\nfirst\n\n\n", "last"])
        check(">\n>\n", streaming: false, [])
        check("前言\n\n- 一\n- 二\n\n```swift\nlet a = 1\n```\n\n结尾\n", streaming: false,
              ["前言\n\n", "- 一\n- 二\n\n", "```swift\nlet a = 1\n```\n\n", "结尾\n"])
        check("**跨行\n粗体**\n后续\n", streaming: false, ["**跨行\n粗体**\n", "后续\n"])
        check("stable\n**across\nlines\n", streaming: true, ["stable\n", "**across\nlines\n"])
        check("before\n`open\nlines\n", streaming: true, ["before\n", "`open\nlines\n"])
        check("[literal]\nafter", streaming: false, ["[literal]\n", "after"])
        check("word_with_underscore\nafter", streaming: false, ["word_with_underscore\n", "after"])
        check("[across\nlines](https://example.test)\nafter", streaming: false,
              ["[across\nlines](https://example.test)\n", "after"])
        check("[link][r]\nnext\n\n[r]: https://example.test", streaming: false,
              ["[link][r]\nnext\n\n[r]: https://example.test"])
        check("| A | B |\n|---|---|\n| x | y |\n\nafter", streaming: false,
              ["| A | B |\n|---|---|\n| x | y |\n\n", "after"])
        check("> first\n> second\n>\n> last", streaming: false,
              ["> first\n", "> second\n>\n", "> last"])
        let first = CFLReplyPresentation.chunks(CFLReplyPresentation.visibleSource("一\n二", streaming: true))
        let later = CFLReplyPresentation.chunks(CFLReplyPresentation.visibleSource("一\n二三", streaming: true))
        guard first == later, CFLReplyPresentation.chunks("一\n二三\n").first == first.first else {
            fputs("Completed reply identity changed while the tail grew\n", stderr)
            exit(1)
        }
        print("CFL source-line reply checks passed")
    }
}
