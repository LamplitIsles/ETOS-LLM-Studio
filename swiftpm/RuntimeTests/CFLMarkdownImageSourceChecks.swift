import Foundation
import Markdown
import cmark_gfm
import cmark_gfm_extensions

private struct ImageSources: MarkupWalker {
    var values: [String] = []
    mutating func visitImage(_ image: Markdown.Image) {
        if let source = image.source { values.append(source) }
        descendInto(image)
    }
}

// Use the same parser options and GFM extensions as MarkdownUI's MarkdownParser.
private func markdownUISources(_ markdown: String) -> [String] {
    cmark_gfm_core_extensions_ensure_registered()
    let parser = cmark_parser_new(CMARK_OPT_DEFAULT)!
    defer { cmark_parser_free(parser) }
    for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
    }
    markdown.withCString { cmark_parser_feed(parser, $0, markdown.utf8.count) }
    let document = cmark_parser_finish(parser)!
    defer { cmark_node_free(document) }
    let iterator = cmark_iter_new(document)!
    defer { cmark_iter_free(iterator) }
    var sources: [String] = []
    while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
        guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
              let node = cmark_iter_get_node(iterator), cmark_node_get_type(node) == CMARK_NODE_IMAGE,
              let raw = cmark_node_get_url(node) else { continue }
        let source = String(cString: raw)
        if !source.isEmpty { sources.append(source) }
    }
    return sources
}

@main struct CFLMarkdownImageSourceChecks {
    static func main() async throws {
        func providerURL(_ source: String) -> URL { URL(string: source, relativeTo: nil)! }
        func check(_ markdown: String, _ source: String) {
            let sources = CFLMarkdownImageSources(markdown: markdown)
            precondition(sources.source(for: providerURL(source)) == source, "\(markdown): \(source)")
        }

        for source in ["work/a%20b.png", "work/a%2520b.png", "work/灯.png", "work/a%.png"] {
            check("![block](\(source))", source)
            check("inline ![image](\(source)) text", source)
            check("inline ![image][ref] text\n\n[ref]: \(source)", source)
        }
        check("![block](<work/a b.png>)", "work/a b.png")
        check("inline ![image](<work/a b.png>) text", "work/a b.png")
        check("![ref][id]\n\n[id]: <work/a b.png>", "work/a b.png")

        let invalid = CFLMarkdownImageSources(markdown: "![image](work/a%.png)")
        let original = invalid.source(for: providerURL("work/a%.png"))!
        precondition(original == "work/a%.png" && CFLMarkdownImage.resolve(original) == .invalid)
        for (left, right) in [("work/a b.png", "work/a%20b.png"), ("work/灯.png", "work/%E7%81%AF.png")] {
            precondition(providerURL(left).absoluteString == providerURL(right).absoluteString)
            precondition(CFLMarkdownImageSources.areEquivalent(left, right))
            let markdown = "![block](<\(left)>)\n\ninline ![image][ref]\n\n[ref]: <\(right)>"
            let sources = CFLMarkdownImageSources(markdown: markdown)
            for source in [left, right] {
                let recovered = sources.source(for: providerURL(source))!
                precondition(CFLMarkdownImageSources.areEquivalent(source, recovered))
            }
        }
        for (left, right) in [("work/a%.png", "work/a%25.png"), ("https://example.test/a b.png", "https://example.test/a%20b.png"), ("/api/a b.png", "/api/a%20b.png")] {
            precondition(providerURL(left).absoluteString == providerURL(right).absoluteString)
            precondition(!CFLMarkdownImageSources.areEquivalent(left, right))
            let sources = CFLMarkdownImageSources(markdown: "![one](<\(left)>) inline ![two](<\(right)>)")
            precondition(sources.source(for: providerURL(left)) == nil)
            precondition(sources.source(for: providerURL(right)) == nil)
            precondition(sources.targets(in: "![one](<\(left)>)") == [.ambiguous])
        }
        precondition(!CFLMarkdownImageSources.areEquivalent("work/a%20b.png", "work/a%2520b.png"))
        precondition(!CFLMarkdownImageSources.areEquivalent("work/caf\u{00e9}.png", "work/cafe\u{0301}.png"))
        precondition(!CFLMarkdownImageSources.areEquivalent("work/a%.png", "work/a%.png"))
        precondition(CFLMarkdownImageSources.areEquivalent("https://example.test/a.png", "https://example.test/a.png"))
        precondition(CFLMarkdownImageSources.areEquivalent("/api/a.png", "/api/a.png"))
        let repeated = CFLMarkdownImageSources(markdown: "![one](work/a%20b.png) ![two][same]\n\n[same]: work/a%20b.png")
        precondition(repeated.source(for: providerURL("work/a%20b.png")) == "work/a%20b.png")
        precondition(repeated.source(for: providerURL("work/unmentioned.png")) == nil)
        let notImage = CFLMarkdownImageSources(markdown: "`![image](work/a.png)`\n\n[link](work/a.png)")
        precondition(notImage.source(for: providerURL("work/a.png")) == nil)

        let chunk = "inline ![image](work/a%20b.png) text"
        let base = CFLMarkdownImageSources(markdown: chunk)
        let expected: [CFLMarkdownImageTarget] = [.workspace(Data("work/a b.png".utf8))]
        precondition(base.targets(in: chunk) == expected)
        precondition(CFLMarkdownImageSources(markdown: chunk + "\n\nunrelated later text ![other](work/other.png)").targets(in: chunk) == expected)
        precondition(CFLMarkdownImageSources(markdown: "![equivalent](<work/a b.png>)\n\n" + chunk).targets(in: chunk) == expected)
        precondition(CFLMarkdownImageSources(markdown: "![equivalent](<work/a b.png>)").targets(in: chunk) == expected)
        let percentChunk = "![image](work/a%25.png)"
        let percent = CFLMarkdownImageSources(markdown: percentChunk)
        precondition(percent.targets(in: percentChunk) == [.workspace(Data("work/a%.png".utf8))])
        let conflict = CFLMarkdownImageSources(markdown: percentChunk + "\n\n![invalid](work/a%.png)")
        precondition(conflict.targets(in: percentChunk) == [.ambiguous])
        let invalidChunk = "![invalid](work/a%.png)"
        precondition(CFLMarkdownImageSources(markdown: invalidChunk).targets(in: invalidChunk) == [.unavailable])
        precondition(conflict.targets(in: invalidChunk) == [.ambiguous])
        precondition(base.targets(in: "![missing](work/other.png)") == [.unavailable])
        precondition(base.targets(in: "![empty]()") == [.unavailable])
        let links = "![external](https://example.test/a.png) ![api](/api/a.png) ![local](work/a.png)"
        precondition(CFLMarkdownImageSources(markdown: links).targets(in: links) == [
            .external(Data("https://example.test/a.png".utf8)), .api(Data("/api/a.png".utf8)), .workspace(Data("work/a.png".utf8))
        ])
        let referenceChunk = "![ref][id]\n\n[id]: work/a%20b.png"
        precondition(base.targets(in: referenceChunk) == expected)
        // A reference whose definition is outside this chunk produces no image node.
        precondition(base.targets(in: "![ref][id]").isEmpty)
        let otherReference = "![ref][id]\n\n[id]: work/other.png"
        precondition(base.targets(in: otherReference) == [.unavailable])
        for markdown in [
            "![block](work/a%20b.png)\n\ninline ![image](work/a%2520b.png) text",
            "![a](<work/a b.png>) ![b](work/灯.png) ![c](work/a%.png)",
            "![ref][id] and ![again][id]\n\n[id]: work/a%2520b.png",
            "| image |\n| --- |\n| ![alt](work/a.png) |",
            "- [x] ![alt](work/a.png)\n\n~~![alt](work/b.png)~~"
        ] {
            var ast = ImageSources()
            ast.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
            precondition(ast.values == markdownUISources(markdown), markdown)
        }

        // Exercise the selected original destination through the authenticated fake transport.
        let socket = FakeSocket(snapshot: imageSnapshot()), http = FakeImageHTTP(), store = MemoryStore()
        let authorization = CFLAuthorization(store: ImageTestCredentials(), http: http)
        try await authorization.select(origin: "https://example.com")
        let client = CFLChatClient(target: "https://example.com", store: store,
            imageHTTP: CFLAuthorizedHTTP(authorization: authorization, http: http), transport: { socket })
        await client.connect()
        let revision = await client.currentState().sessionRevision
        for (left, right, path) in [("work/a b.png", "work/a%20b.png", "work/a b.png"),
                                   ("work/灯.png", "work/%E7%81%AF.png", "work/灯.png"),
                                   ("work/a%2520b.png", "work/a%2520b.png", "work/a%20b.png")] {
            let original = CFLMarkdownImageSources(markdown: "![block](<\(left)>)\n\ninline ![image][ref]\n\n[ref]: <\(right)>")
            let rendered = CFLMarkdownImageSources(markdown: "inline ![image](<\(right)>)")
            let url = providerURL(right)
            let source = original.source(for: url)!, renderedSource = rendered.source(for: url)!
            precondition(CFLMarkdownImageSources.areEquivalent(source, renderedSource))
            _ = try await client.markdownImage(source, expectedSessionId: "A", expectedSessionRevision: revision)
            let request = await http.allRequests().last!
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.first(where: { $0.name == "path" })?.value == path)
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        }
        await client.disconnect()
        print("CFL Markdown image source checks passed")
    }
}
