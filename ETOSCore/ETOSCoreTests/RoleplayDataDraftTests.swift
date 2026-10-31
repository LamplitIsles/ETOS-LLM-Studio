import Foundation
import Testing
@testable import ETOSCore

@Suite("角色宏与变量作用域草稿", .serialized)
struct RoleplayDataDraftTests {
    @Test("宏名称规范化拒绝冲突和非字符串值，向导沿用相同规则")
    func macroNormalizationRejectsDataLoss() throws {
        #expect(try RoleplayDataDraft.normalizeMacros([" hero ": .string("保留空格值 ")]) == ["hero": .string("保留空格值 ")])
        let invalidValues: [[String: JSONValue]] = [["": .string("空名")], ["{{name}}": .string("宏")], ["value": .int(1)], ["hero": .string("甲"), " hero ": .string("乙")], ["Hero": .string("甲"), "hero": .string("乙")]]
        for values in invalidValues {
            #expect(throws: RoleplayDataDraftError.self) { try RoleplayDataDraft.normalizeMacros(values) }
            #expect(throws: GuideError.self) { try GuideRoleplayDataSettingsSupport.normalizeMacros(.dictionary(values)) }
        }
    }
}
