// ============================================================================
// RoleplayCompatibilityTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 使用合成夹具验证角色卡、宏、正则与 MVU 兼容运行时。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("角色扮演与酒馆兼容", .serialized)
struct RoleplayCompatibilityTests {

    @Test("消息变量按消息版本隔离")
    func isolateMessageVersions() {
        let messageID = UUID()
        var snapshot = RoleplayVariableSnapshot()
        snapshot.setValue(.int(1), scope: .message, path: "value", messageID: messageID, versionIndex: 0)
        snapshot.setValue(.int(2), scope: .message, path: "value", messageID: messageID, versionIndex: 1)
        snapshot.setValue(
            .string("<b>内部显示</b>"),
            scope: .message,
            path: RoleplayDisplayedMessageBridge.variableKey,
            messageID: messageID,
            versionIndex: 1
        )
        snapshot.replaceMessageVariables(["value": .int(3)], messageID: messageID, versionIndex: 1)

        #expect(snapshot.value(scope: .message, path: "value", messageID: messageID, versionIndex: 0) == .int(1))
        #expect(snapshot.value(scope: .message, path: "value", messageID: messageID, versionIndex: 1) == .int(3))
        #expect(snapshot.messageVariables(messageID: messageID, versionIndex: 1)[RoleplayDisplayedMessageBridge.variableKey] == nil)
        #expect(snapshot.value(
            scope: .message,
            path: RoleplayDisplayedMessageBridge.variableKey,
            messageID: messageID,
            versionIndex: 1
        ) == .string("<b>内部显示</b>"))
        snapshot.removeMessageVariables(messageID: messageID)
        #expect(snapshot.messageVariables(messageID: messageID, versionIndex: 0).isEmpty)
        #expect(snapshot.messageVariables(messageID: messageID, versionIndex: 1).isEmpty)
    }

    @Test("脚本变量按脚本 ID 隔离且不进入合并提示词")
    func isolateScriptVariables() {
        let firstID = UUID()
        let secondID = UUID()
        var snapshot = RoleplayVariableSnapshot(script: ["shared": .int(1)])
        snapshot.replaceScriptVariables(["value": .string("first")], scriptID: firstID)
        snapshot.replaceScriptVariables(["value": .string("second")], scriptID: secondID)

        #expect(snapshot.scriptVariables(scriptID: firstID)["value"] == .string("first"))
        #expect(snapshot.scriptVariables(scriptID: secondID)["value"] == .string("second"))
        #expect(snapshot.mergedVariables()["shared"] == .int(1))
        #expect(snapshot.mergedVariables()["__etos_script_scopes"] == nil)
    }

    @Test("扩展变量与提示词初始变量分别隔离并兼容旧快照")
    func isolatesExtensionAndPromptTemplateVariables() throws {
        var snapshot = RoleplayVariableSnapshot()
        snapshot.replaceExtensionVariables(["启用": .bool(true)], extensionID: "example-extension")
        snapshot.replacePromptTemplateInitialVariables(["初始值": .int(7)])

        #expect(snapshot.extensionVariables(extensionID: "example-extension")["启用"] == .bool(true))
        #expect(snapshot.promptTemplateInitialVariables["初始值"] == .int(7))
        #expect(snapshot.mergedVariables()["__etos_prompt_template_initial"] == nil)

        let legacy = """
        {"global":{},"preset":{},"character":{},"persona":{},"chat":{},"messageVersions":{},"script":{}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RoleplayVariableSnapshot.self, from: legacy)
        #expect(decoded.extensionScopes == nil)
    }

    @Test("分层变量替换会清空旧值并持久承载自定义宏")
    func replaceScopedVariablesAndMacros() {
        var snapshot = RoleplayVariableSnapshot(chat: ["旧值": .int(1), "保留": .bool(true)])
        snapshot.replaceVariables(["新值": .int(2)], scope: .chat)
        snapshot.replaceCustomMacros(["称呼": "旅行者", "空白键": "保留"])

        #expect(snapshot.scopedVariables(.chat) == ["新值": .int(2)])
        #expect(snapshot.customMacros["称呼"] == "旅行者")
        #expect(snapshot.mergedVariables()["__etos_custom_macros"] == nil)
        #expect(snapshot.scopedVariables(.script)["__etos_custom_macros"] == nil)
    }

    @Test("MVU 将旧版根变量迁移到 stat_data")
    func migrateLegacyRootMVUVariables() {
        let data = RoleplayMVUData(migratingLegacyVariables: [
            "日期": .string("2026年1月8日"),
            "角色": .dictionary(["好感度": .int(12)]),
            "__etos_displayed_html": .string("<b>状态</b>")
        ])

        #expect(data.statData["日期"] == .string("2026年1月8日"))
        #expect(data.statData["角色"] == .dictionary(["好感度": .int(12)]))
        #expect(data.extra["__etos_displayed_html"] == .string("<b>状态</b>"))
    }

    @Test("MVU 使用 Zod 导出的 JSON Schema 调和类型、范围和枚举")
    func reconcileMVUJSONSchema() {
        let schema: JSONValue = .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "stat_data": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "好感度": .dictionary([
                            "type": .string("number"),
                            "minimum": .int(0),
                            "maximum": .int(100)
                        ]),
                        "状态": .dictionary([
                            "type": .string("string"),
                            "enum": .array([.string("正常"), .string("异常")]),
                            "default": .string("正常")
                        ])
                    ])
                ])
            ])
        ])
        let reconciled = RoleplayMVUSchemaValidator.reconcile(
            ["好感度": .int(130), "状态": .string("非法")],
            schema: schema,
            fallback: ["好感度": .int(10), "状态": .string("正常")]
        )

        #expect(reconciled["好感度"] == .int(100))
        #expect(reconciled["状态"] == .string("正常"))
    }

}
