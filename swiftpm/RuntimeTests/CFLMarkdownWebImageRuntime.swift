import Foundation

// Supply only the containing type; the runtime itself is the production code.
struct ETMathWebShellConfiguration {}

@main
enum CFLMarkdownWebImageRuntime {
    static func main() {
        print(ETMathWebShellConfiguration.javascriptRuntime(
            enableMarkdown: true, cflImagePolicy: true, syntaxHighlightingEnabled: false,
            codeCopyText: "\"Copy\"", codeCopiedText: "\"Copied\"",
            codeExpandText: "\"Expand\"", codeCollapseText: "\"Collapse\"",
            imageRetryText: "\"Retry\""
        ))
    }
}
