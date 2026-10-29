import Foundation
import Testing
@testable import ETOSCore

@Suite("Linux 命令桥接额度")
struct LocalLinuxCommandLimitTests {
    @Test("模型可见的额度约束遵循平台实际执行后端")
    func toolSchemaLimits() throws {
        for tool in LocalLinuxToolDefinitions.all where tool.name != LocalLinuxToolName.process.rawValue {
            let data = try JSONEncoder().encode(tool.parameters)
            let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: [String: Any]])
            let timeout = try #require(properties["timeout_seconds"])
            let output = try #require(properties["output_limit_bytes"])
            #expect(timeout["minimum"] as? Int == 0)
            #expect(output["minimum"] as? Int == 0)
            #if os(macOS)
            #expect(timeout["maximum"] == nil)
            #expect(output["maximum"] == nil)
            #else
            #expect(timeout["maximum"] as? Int == 3_600)
            #expect(output["maximum"] as? Int == 67_108_864)
            #endif
        }
    }
}
