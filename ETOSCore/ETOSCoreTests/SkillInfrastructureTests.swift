// ============================================================================
// SkillInfrastructureTests.swift
// ============================================================================
// Agent Skills 基础能力测试
// - frontmatter 解析
// - 路径安全
// - 同步模型兼容性
// - use_skill 链接白名单策略
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("Agent Skills 基础能力测试")
struct SkillInfrastructureTests {

    @Test("frontmatter 解析与正文提取支持 Unicode")
    func testFrontmatterParserSupportsUnicode() {
        let content = """
---
name: 智能✨技能
description: "用于处理中文🙂"
compatibility: "v1"
allowed-tools: read_file, search_web
---

第一行正文
第二行正文
"""

        let frontmatter = SkillFrontmatterParser.parse(content)
        #expect(frontmatter["name"] == "智能✨技能")
        #expect(frontmatter["description"] == "用于处理中文🙂")
        #expect(frontmatter["compatibility"] == "v1")
        #expect(frontmatter["allowed-tools"] == "read_file, search_web")

        let body = SkillFrontmatterParser.extractBody(content)
        #expect(body == "第一行正文\n第二行正文")
    }

    @Test("frontmatter 解析支持 YAML 列表与多行文本")
    func testFrontmatterParserSupportsYAMLCollections() {
        let content = """
---
name: yaml-demo
description: >
  第一行描述
  第二行描述
when_to_use: |
  用户需要跨文件整理资料时使用。
  scripts 只能读取源码，不能执行。
compatibility:
  需要完整技能目录。
allowed-tools:
  - read_file
  - search_web
arguments: [topic, depth]
---

正文
"""

        let frontmatter = SkillFrontmatterParser.parse(content)

        #expect(frontmatter["name"] == "yaml-demo")
        #expect(frontmatter["description"] == "第一行描述 第二行描述")
        #expect(frontmatter["when_to_use"] == "用户需要跨文件整理资料时使用。\nscripts 只能读取源码，不能执行。")
        #expect(frontmatter["compatibility"] == "需要完整技能目录。")
        #expect(frontmatter["allowed-tools"] == "read_file, search_web")
        #expect(frontmatter["arguments"] == "topic, depth")
    }

    @Test("SkillManifestResolver 使用目录名和正文首段补齐缺省元数据")
    func testSkillManifestResolverUsesOfficialFallbacks() throws {
        let content = """
---
allowed-tools: read_file, search_web
when_to_use: 用户需要整理导入资料时使用。
---

# 标题不应作为描述

第一段正文会成为技能描述。
继续描述能力边界。

后续段落留给详细说明。
"""

        let manifest = try SkillManifestResolver.resolve(content: content, fallbackName: "fallback-skill")

        #expect(manifest.name == "fallback-skill")
        #expect(manifest.description.contains("第一段正文会成为技能描述。 继续描述能力边界。"))
        #expect(manifest.description.contains("用户需要整理导入资料时使用。"))
        #expect(manifest.allowedTools == ["read_file", "search_web"])
    }

    @Test("内置 Skill 创建指南可解析并使用 ELS 沙盒工具名")
    func testBuiltInCreateSkillGuideUsesAppSandboxTools() throws {
        let content = try #require(SkillStore.builtInSkillContentForTests(name: "create-skill"))
        let manifest = try SkillManifestResolver.resolve(content: content, fallbackName: nil)

        #expect(manifest.name == "create-skill")
        #expect(manifest.allowedTools == ["app_create_sandbox_directory", "app_write_sandbox_file"])
        #expect(content.contains("Skills/<skill-name>/SKILL.md"))
        #expect(!content.contains("mcp_app_create_sandbox_directory"))
        #expect(!content.contains("mcp_app_write_sandbox_file"))
    }

    @Test("SkillPaths 阻止路径穿越")
    func testSkillPathResolutionRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/skills-root-\(UUID().uuidString)", isDirectory: true)

        #expect(SkillPaths.isValidSkillName("openai-docs"))
        #expect(SkillPaths.isValidSkillName("OpenAI-Docs"))
        #expect(SkillPaths.isValidSkillName("openai_docs"))
        #expect(SkillPaths.isValidSkillName("openai.docs"))
        #expect(!SkillPaths.isValidSkillName("../openai-docs"))
        #expect(!SkillPaths.isValidSkillName(""))

        let dir = SkillPaths.resolveSkillDir(skillsRoot: root, skillName: "openai-docs")
        #expect(dir != nil)

        if let dir {
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "refs/checklist.md") != nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "../etc/passwd") == nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "/absolute/path.md") == nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "refs//guide.md") == nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "refs/.hidden.md") == nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "") == nil)
        }
    }

    @Test("SkillPaths 相对路径计算兼容符号链接前缀")
    func testSkillPathRelativePathSupportsSymlinkedPrefixes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let realRoot = root.appendingPathComponent("real", isDirectory: true)
        let realSkillDir = realRoot.appendingPathComponent("demo", isDirectory: true)
        let linkedRoot = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realSkillDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

        let realSkillFile = realSkillDir.appendingPathComponent("SKILL.md", isDirectory: false)
        try "demo".write(to: realSkillFile, atomically: true, encoding: .utf8)

        let linkedSkillDir = linkedRoot.appendingPathComponent("demo", isDirectory: true)
        let linkedSkillFile = linkedSkillDir.appendingPathComponent("SKILL.md", isDirectory: false)

        #expect(SkillPaths.relativePath(for: realSkillFile, baseURL: linkedSkillDir) == "SKILL.md")
        #expect(SkillPaths.relativePath(for: linkedSkillFile, baseURL: realSkillDir) == "SKILL.md")
    }

    @Test("SyncedSkillBundle 校验和与文件顺序无关")
    func testSyncedSkillBundleChecksumIsOrderIndependent() {
        let filesA = [
            SyncedSkillFile(relativePath: "SKILL.md", content: "A"),
            SyncedSkillFile(relativePath: "refs/a.md", content: "B")
        ]
        let filesB = [
            SyncedSkillFile(relativePath: "refs/a.md", content: "B"),
            SyncedSkillFile(relativePath: "SKILL.md", content: "A")
        ]

        let bundleA = SyncedSkillBundle(name: "demo", files: filesA)
        let bundleB = SyncedSkillBundle(name: "demo", files: filesB)
        #expect(bundleA.checksum == bundleB.checksum)

        let changed = SyncedSkillBundle(
            name: "demo",
            files: [
                SyncedSkillFile(relativePath: "SKILL.md", content: "A"),
                SyncedSkillFile(relativePath: "refs/a.md", content: "Changed")
            ]
        )
        #expect(bundleA.checksum != changed.checksum)
    }

    @Test("SyncPackage 兼容旧数据：缺失 skills 字段时默认为空")
    func testSyncPackageDecodingDefaultsMissingSkills() throws {
        let legacyJSON = """
{
  "options": 0,
  "providers": [],
  "sessions": []
}
"""

        let package = try JSONDecoder().decode(SyncPackage.self, from: Data(legacyJSON.utf8))
        #expect(package.skills.isEmpty)
    }

    @Test("SkillResourcePolicy 允许读取技能包文本资源并拒绝危险路径")
    func testSkillResourcePolicyReadability() {
        #expect(SkillResourcePolicy.normalizeRelativePath("./references/guide.md#intro") == "references/guide.md")
        #expect(SkillResourcePolicy.normalizeRelativePath("scripts/run.py") == "scripts/run.py")
        #expect(SkillResourcePolicy.normalizeRelativePath("agents/openai.yaml") == "agents/openai.yaml")
        #expect(SkillResourcePolicy.normalizeRelativePath("assets/template.json") == "assets/template.json")
        #expect(SkillResourcePolicy.normalizeRelativePath(".secret/token.txt") == nil)
        #expect(SkillResourcePolicy.normalizeRelativePath("references//guide.md") == nil)
        #expect(SkillResourcePolicy.normalizeRelativePath("references/../secret.md") == nil)
        #expect(SkillResourcePolicy.normalizeRelativePath("https://example.com/a.md") == nil)

        #expect(SkillResourcePolicy.textReadability(relativePath: "scripts/run.py", size: 128).isReadable)
        #expect(SkillResourcePolicy.textReadability(relativePath: "references/guide.md", size: 128).isReadable)
        #expect(SkillResourcePolicy.candidateTextReadability(relativePath: "assets/template.unknown", size: 128).canAttemptRead)
        #expect(!SkillResourcePolicy.textReadability(relativePath: "references/large.md", size: SkillResourcePolicy.maxReadableTextBytes + 1).isReadable)
        #expect(SkillResourcePolicy.isImagePath("assets/diagram.png"))
        #expect(!SkillResourcePolicy.candidateTextReadability(relativePath: "assets/huge.png", size: SkillResourcePolicy.maxOCRImageBytes + 1).canAttemptRead)
        #if canImport(Vision) && !os(watchOS)
        #expect(SkillResourcePolicy.isOCRImagePath("assets/diagram.png"))
        #else
        #expect(!SkillResourcePolicy.isOCRImagePath("assets/diagram.png"))
        #endif
    }

}
