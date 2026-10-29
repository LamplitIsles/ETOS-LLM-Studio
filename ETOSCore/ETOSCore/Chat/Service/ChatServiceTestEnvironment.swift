// ============================================================================
// ChatServiceTestEnvironment.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 ChatService 的测试环境判断。
// ============================================================================

import Foundation

extension ChatService {
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
