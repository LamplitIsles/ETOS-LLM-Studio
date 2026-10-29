// ============================================================================
// MCPBuiltInSearchServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证应用内置 MCP 搜索服务器能通过标准 MCP 客户端链路发现和调用真实搜索后端。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("内置 MCP 搜索服务器测试")
struct MCPBuiltInSearchServerTests {
    @Test("优先使用 DuckDuckGo")
    func testBuiltInSearchPrefersDuckDuckGo() async throws {
        let recorder = SearchRequestRecorder()
        let engine = MCPBuiltInSearchServerEngine { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch url.host {
            case "www.bing.com":
                recorder.sawBingRequest = true
                let html = """
                <html><body>
                  <li class="b_algo"><h2><a href="https://example.com/irrelevant">无关结果</a></h2></li>
                </body></html>
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (Data(html.utf8), response)
            case "html.duckduckgo.com":
                recorder.sawDuckDuckGoRequest = true
                let html = """
                <html><body>
                  <a class="result__a" href="https://swift.org/">Swift.org</a>
                  <div class="result__snippet">The Swift programming language.</div>
                </body></html>
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (Data(html.utf8), response)
            default:
                throw URLError(.cannotFindHost)
            }
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": MCPBuiltInSearchServer.toolID,
                "arguments": ["query": "Swift", "max_results": 1]
            ]
        ]
        let response = try await engine.handleMessage(JSONSerialization.data(withJSONObject: payload))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let structuredContent = result["structuredContent"] as? [String: Any],
              let items = structuredContent["items"] as? [[String: Any]],
              let firstItem = items.first else {
            Issue.record("备用搜索源应返回网页结果。")
            return
        }

        #expect(recorder.sawDuckDuckGoRequest)
        #expect(!recorder.sawBingRequest)
        #expect(firstItem["source"] as? String == "duckduckgo_html")
        #expect(firstItem["url"] as? String == "https://swift.org/")
    }

    @Test("指定 Bing 时优先请求并在失败后回退 DuckDuckGo")
    func testBuiltInSearchPrefersBingAndFallsBackToDuckDuckGo() async throws {
        let recorder = SearchRequestRecorder()
        let engine = MCPBuiltInSearchServerEngine { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch url.host {
            case "html.duckduckgo.com":
                recorder.sawDuckDuckGoRequest = true
                let html = """
                <html><body>
                  <a class="result__a" href="https://swift.org/">Swift.org</a>
                  <div class="result__snippet">The Swift programming language.</div>
                </body></html>
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (Data(html.utf8), response)
            case "www.bing.com":
                recorder.sawBingRequest = true
                throw URLError(.cannotConnectToHost)
            default:
                throw URLError(.cannotFindHost)
            }
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": MCPBuiltInSearchServer.toolID,
                "arguments": [
                    "query": "Swift",
                    "search_engine": "bing",
                    "max_results": 1
                ]
            ]
        ]
        let response = try await engine.handleMessage(JSONSerialization.data(withJSONObject: payload))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let structuredContent = result["structuredContent"] as? [String: Any],
              let items = structuredContent["items"] as? [[String: Any]],
              let firstItem = items.first else {
            Issue.record("备用搜索源应返回网页结果。")
            return
        }

        #expect(recorder.sawDuckDuckGoRequest)
        #expect(recorder.sawBingRequest)
        #expect(firstItem["source"] as? String == "duckduckgo_html")
        #expect(firstItem["url"] as? String == "https://swift.org/")
    }

    @Test("query 包含 URL 时优先抓取网页标题和摘要")
    func testBuiltInSearchDirectURLFetch() async throws {
        let engine = MCPBuiltInSearchServerEngine(dataLoader: searchDataLoader)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": MCPBuiltInSearchServer.toolID,
                "arguments": [
                    "query": "爬取 blog.ericterminal.com",
                    "max_results": 1
                ]
            ]
        ]
        let response = try await engine.handleMessage(JSONSerialization.data(withJSONObject: payload))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let structuredContent = result["structuredContent"] as? [String: Any],
              let items = structuredContent["items"] as? [[String: Any]],
              let firstItem = items.first else {
            Issue.record("工具结果应包含直接抓取的 structuredContent.items。")
            return
        }

        #expect(structuredContent["provider"] as? String == "etos_builtin_web_search")
        #expect(firstItem["source"] as? String == "direct_fetch")
        #expect(firstItem["title"] as? String == "Eric Terminal Blog")
        #expect(firstItem["url"] as? String == "https://blog.ericterminal.com")
        #expect((firstItem["text"] as? String)?.contains("技术笔记") == true)
    }

    @Test("url 参数可直接抓取网页并在 Range 不支持时重试")
    func testBuiltInSearchURLArgumentFetchesPageWithRangeFallback() async throws {
        let recorder = SearchRequestRecorder()
        let engine = MCPBuiltInSearchServerEngine { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            #expect(request.timeoutInterval > 0)
            #expect(request.timeoutInterval <= 5)

            if request.value(forHTTPHeaderField: "Range") != nil {
                recorder.sawRangeRequest = true
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 416,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (Data(), response)
            }

            recorder.sawPlainRequest = true
            let html = """
            <!doctype html>
            <html>
            <head>
              <title>Range Fallback Page</title>
              <meta name="description" content="Fallback fetch succeeded.">
            </head>
            <body><main>正文。</main></body>
            </html>
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (Data(html.utf8), response)
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": MCPBuiltInSearchServer.toolID,
                "arguments": [
                    "url": "https://example.com/fallback",
                    "max_results": 1,
                    "timeout_seconds": 5
                ]
            ]
        ]

        let response = try await engine.handleMessage(JSONSerialization.data(withJSONObject: payload))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let structuredContent = result["structuredContent"] as? [String: Any],
              let items = structuredContent["items"] as? [[String: Any]],
              let firstItem = items.first else {
            Issue.record("工具结果应包含 url 参数直接抓取的 structuredContent.items。")
            return
        }

        #expect(recorder.sawRangeRequest)
        #expect(recorder.sawPlainRequest)
        #expect(structuredContent["query"] as? String == "https://example.com/fallback")
        #expect(structuredContent["timeout_seconds"] as? Double == 5)
        #expect(firstItem["source"] as? String == "direct_fetch")
        #expect(firstItem["title"] as? String == "Range Fallback Page")
        #expect(firstItem["url"] as? String == "https://example.com/fallback")
        #expect((firstItem["text"] as? String)?.contains("Fallback fetch succeeded") == true)
    }

    private var searchDataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let html: String
            switch url.host {
            case "html.duckduckgo.com":
                #expect(request.value(forHTTPHeaderField: "Range") == nil)
                html = """
                <html>
                <body>
                  <a class="result__a" href="https://swift.org/">Swift.org - Swift</a>
                  <div class="result__snippet">Swift is a powerful and intuitive programming language.</div>
                  <a class="result__a" href="https://modelcontextprotocol.io/">Model Context Protocol</a>
                  <div class="result__snippet">MCP is an open protocol for connecting AI applications.</div>
                </body>
                </html>
                """
            case "www.bing.com":
                #expect(request.value(forHTTPHeaderField: "Range") == nil)
                html = """
                <html>
                <body>
                  <li class="b_algo">
                    <div class="b_algoheader">
                      <a href="https://swift.org/"><h2>Swift.org - Swift</h2></a>
                    </div>
                    <div class="b_caption"><p>Swift is a powerful and intuitive programming language.</p></div>
                  </li>
                  <li class="b_algo">
                    <h2><a href="https://modelcontextprotocol.io/">Model Context Protocol</a></h2>
                    <div class="b_caption"><p>MCP is an open protocol for connecting AI applications.</p></div>
                  </li>
                </body>
                </html>
                """
            case "blog.ericterminal.com":
                html = """
                <!doctype html>
                <html>
                <head>
                  <title>Eric Terminal Blog</title>
                  <meta name="description" content="Eric 的技术笔记和项目记录。">
                </head>
                <body><main>这里是博客正文。</main></body>
                </html>
                """
            default:
                throw URLError(.cannotFindHost)
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (Data(html.utf8), response)
        }
    }

    private final class SearchRequestRecorder: @unchecked Sendable {
        var sawRangeRequest = false
        var sawPlainRequest = false
        var sawBingRequest = false
        var sawDuckDuckGoRequest = false
    }
}
