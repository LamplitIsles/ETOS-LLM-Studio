#if os(macOS)
import Foundation
import Testing
@testable import ETOSCore

struct MacNativeProcessResolverTests {
    @Test("解析 PATH 中的可执行文件")
    func resolvesExecutableInPath() throws {
        let executable = try MacNativeProcess.resolveExecutable(
            "cat",
            environment: ["PATH": "/bin"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        #expect(executable.path == "/bin/cat")
    }

    @Test("缺失可执行文件保留原有错误")
    func missingExecutablePreservesError() {
        do {
            _ = try MacNativeProcess.resolveExecutable(
                "",
                environment: [:],
                workingDirectory: URL(fileURLWithPath: "/", isDirectory: true)
            )
            Issue.record("空命令应被拒绝。")
        } catch MCPLocalStdioError.dependencyMissing(let command, let recipe) {
            #expect(command.isEmpty)
            #expect(recipe == nil)
        } catch {
            Issue.record("返回了不符合预期的错误。")
        }
    }
}
#endif
