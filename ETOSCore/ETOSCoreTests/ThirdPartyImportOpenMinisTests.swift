// ============================================================================
// ThirdPartyImportOpenMinisTests.swift
// ============================================================================
// OpenMinis 兼容导入测试
// - iOS 与 Android 会话导出
// - Provider、MCP 与 Skill 配置
// - 重复导入稳定标识与 ZIP 路径安全边界
// ============================================================================

import Foundation
import Testing
import ZIPFoundation
@testable import ETOSCore

@Suite("第三方导入 OpenMinis 兼容测试")
struct ThirdPartyImportOpenMinisTests {

    @Test("Provider 与本地 stdio MCP 会标记敏感凭据")
    func importProviderAndMCPWithSensitiveCredentials() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeJSON([
            "version": 1,
            "instanceId": "provider-1",
            "config": [
                "providerType": "openAIResponses",
                "label": "OpenMinis Provider",
                "apiKey": Data("secret-key".utf8).base64EncodedString(),
                "customBaseURL": "https://api.example.com/v1",
                "models": [[
                    "modelId": "gpt-5",
                    "displayName": "GPT-5",
                    "modalityOverride": 71,
                    "supportsReasoning": true,
                    "overrides": ["displayName": "GPT-5 自定义"]
                ]]
            ]
        ], to: directory.appendingPathComponent("provider.json"))
        try writeJSON([
            "mcpServers": [
                "git": [
                    "command": "uvx",
                    "args": ["mcp-server-git"],
                    "env": ["TOKEN": "mcp-secret"]
                ]
            ]
        ], to: directory.appendingPathComponent("mcp.json"))

        let prepared = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: directory)
        let provider = try #require(prepared.package.providers.first)
        let server = try #require(prepared.package.mcpServers.first)

        #expect(prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.mcpServers))
        #expect(prepared.containsSensitiveCredentials)
        #expect(provider.apiKeys == ["secret-key"])
        let model = try #require(provider.models.first)
        #expect(model.displayName == "GPT-5 自定义")
        #expect(model.inputModalities.contains(.image))
        #expect(model.outputModalities.contains(.image))
        #expect(model.capabilities.contains(.reasoning))
        #expect(server.displayName == "git")
        if case .localStdio(let configuration) = server.transport {
            #expect(configuration.command == "uvx")
            #expect(configuration.arguments == ["mcp-server-git"])
            #expect(configuration.environment["TOKEN"] == "mcp-secret")
        } else {
            Issue.record("OpenMinis stdio MCP 未解析为本地 stdio transport")
        }
    }

    @Test("Skill 目录会导入清单和资源但不执行脚本")
    func importSkillDirectoryWithResources() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let skillDirectory = directory.appendingPathComponent("skills/demo-skill", isDirectory: true)
        let referencesDirectory = skillDirectory.appendingPathComponent("references", isDirectory: true)
        let scriptsDirectory = skillDirectory.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: demo-skill
        description: OpenMinis Skill 导入测试
        ---

        只导入，不执行脚本。
        """.write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "参考资料".write(to: referencesDirectory.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        try "print('不应在导入时执行')".write(to: scriptsDirectory.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)

        let prepared = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: directory)
        let skill = try #require(prepared.package.skills.first)

        #expect(prepared.package.options.contains(.skills))
        #expect(skill.name == "demo-skill")
        #expect(Set(skill.files.map(\.relativePath)) == ["SKILL.md", "references/guide.md", "scripts/run.py"])
        #expect(prepared.warnings.contains(where: { $0.contains("不会执行") }))
    }

    @Test("包含路径穿越条目的 ZIP 会整体拒绝")
    func rejectArchivePathTraversal() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(data: Data(), accessMode: .create)
        let payload = Data("{}".utf8)
        try archive.addEntry(
            with: "../unsafe.json",
            type: .file,
            uncompressedSize: Int64(payload.count),
            compressionMethod: .none
        ) { position, size in
            payload.subdata(in: Int(position)..<Int(position) + size)
        }
        let archiveURL = directory.appendingPathComponent("unsafe.zip")
        try #require(archive.data).write(to: archiveURL)

        #expect(throws: ThirdPartyImportError.self) {
            _ = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: archiveURL)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openminis-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
