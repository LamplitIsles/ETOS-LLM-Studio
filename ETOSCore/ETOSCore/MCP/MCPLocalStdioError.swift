import Foundation

public enum MCPLocalStdioError: LocalizedError {
    case dependencyMissing(command: String, suggestedRecipe: String?)

    public var errorDescription: String? {
        switch self {
        case .dependencyMissing(let command, let suggestedRecipe):
            if let suggestedRecipe {
                return String(
                    format: NSLocalizedString("MCP_RUNTIME_DEPENDENCY_MISSING：找不到命令 %@。ETOS 不会自动安装；可前往“环境准备”运行 %@。", comment: "Local stdio MCP missing dependency with recipe"),
                    command,
                    suggestedRecipe
                )
            }
            return String(
                format: NSLocalizedString("MCP_RUNTIME_DEPENDENCY_MISSING：找不到命令 %@。ETOS 不会自动安装，请在终端中自行安装后重试。", comment: "Local stdio MCP missing dependency"),
                command
            )
        }
    }
}
